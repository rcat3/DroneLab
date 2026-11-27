package io.github.rcat3.dronelab.hivesight

import android.app.Activity
import android.app.AlertDialog
import android.content.Context
import android.content.pm.ActivityInfo
import android.content.pm.PackageManager
import android.graphics.Color
import android.net.wifi.WifiManager
import android.opengl.GLSurfaceView
import android.os.BatteryManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import androidx.annotation.RequiresApi
import android.view.Gravity
import android.view.GestureDetector
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.widget.CheckBox
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import org.json.JSONObject

@RequiresApi(30)
class HiveSightActivity : Activity() {
    private lateinit var glView: GLSurfaceView
    private lateinit var renderer: StereoRenderer
    private lateinit var labels: List<TextView>
    private lateinit var control: ControlClient
    private lateinit var video: RtpVideoReceiver
    private lateinit var decoder: VideoDecoder
    private lateinit var audio: AudioEngine
    private var wifiLock: WifiManager.WifiLock? = null
    private val ui = Handler(Looper.getMainLooper())
    @Volatile private var status = "Starting…"
    @Volatile private var ended: String? = null
    private lateinit var session: Session

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Only ever opened by the app, with a session it has checked
        val s = sessionOf(intent)
        if (s == null) { finish(); return }
        session = s
        Params.init(this)
        Params.lightPulse = s.lightPulse
        applyOrientation()
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        window.attributes = window.attributes.apply {
            layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
            preferredDisplayModeId = highestRefreshMode()
        }
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        if (pm.isSustainedPerformanceModeSupported) window.setSustainedPerformanceMode(true)

        val dm = resources.displayMetrics
        val pxPerMm = maxOf(dm.xdpi, dm.ydpi) / 25.4f

        decoder = VideoDecoder(
            onNeedKeyframe = { control.requestKeyframe() },
            onVideoSize = { w, h -> renderer.videoW = w; renderer.videoH = h },
        )
        renderer = StereoRenderer(pxPerMm,
            beatHz = { if (::audio.isInitialized) audio.currentBeatHz else 0f },
            onSurfaceReady = { decoder.surface = it },
            requestRender = { glView.requestRender() })
        glView = GLSurfaceView(this).apply {
            setEGLContextClientVersion(2)
            setRenderer(renderer)
            renderMode = GLSurfaceView.RENDERMODE_CONTINUOUSLY // smooth fades; picks up frames at vsync
        }

        // Status text, drawn once per eye so it is readable inside the viewer.
        val root = FrameLayout(this)
        root.setBackgroundColor(Color.BLACK)
        root.addView(glView)
        val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        labels = List(2) {
            TextView(this).apply {
                setTextColor(Color.rgb(170, 170, 170)); textSize = 13f; gravity = Gravity.CENTER
                setShadowLayer(4f, 0f, 0f, Color.BLACK)
            }
        }
        for (l in labels) row.addView(l, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, 1f))
        root.addView(row, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
        setContentView(root)

        // Long-press (outside the viewer) opens settings. A Cardboard button tap
        // is a plain touch, so short taps toggle the stats overlay.
        val gestures = GestureDetector(this, object : GestureDetector.SimpleOnGestureListener() {
            override fun onLongPress(e: MotionEvent) = showSettings()
            override fun onSingleTapConfirmed(e: MotionEvent): Boolean {
                Params.set("view.stats", !Params.b("view.stats")); return true
            }
        })
        glView.setOnTouchListener { _, e -> gestures.onTouchEvent(e); true }

        control = newControl()
        video = RtpVideoReceiver(VIDEO_PORT, onAccessUnit = decoder::submit, onNeedKeyframe = { control.requestKeyframe() })
        audio = AudioEngine(AUDIO_PORT, MEDIA_PORT)
        // Guide preview: both taps send through whichever control client is current.
        renderer.preview = PreviewVideo { t, b -> control.sendBinary(t, b) }
        audio.monitor = PreviewAudio { t, b -> control.sendBinary(t, b) }

        requestLocalNetworkIfNeeded()
    }

    private fun newControl() = ControlClient(session, VIDEO_PORT, AUDIO_PORT, onStatus = { status = it },
        onEnded = { ended = it })

    override fun onResume() {
        super.onResume()
        if (!::session.isInitialized) return
        hideSystemUi()
        glView.onResume()
        val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        // Disables Wi-Fi power save while we're in the foreground: big jitter win.
        wifiLock = wm.createWifiLock(WifiManager.WIFI_MODE_FULL_LOW_LATENCY, "hivesight").apply {
            setReferenceCounted(false); acquire()
        }
        decoder.start(); video.start(); audio.start()
        if (ended == null) control.start()
        ui.post(statsTick)
    }

    override fun onPause() {
        if (!::session.isInitialized) { super.onPause(); return }
        ui.removeCallbacks(statsTick)
        control.stop(); video.stop(); audio.stop(); decoder.stop()
        wifiLock?.release()
        glView.onPause()
        super.onPause()
    }

    // ------------------------------------------------------------ exit gesture
    // Holding volume-down for 1.5 s leaves the session, with the headset on:
    // the view goes black at once, the Guide is told, and the Activity closes.
    // There's no confirmation, on purpose.
    private val exitNow = Runnable { leaveSession() }

    override fun dispatchKeyEvent(e: KeyEvent): Boolean {
        if (e.keyCode == KeyEvent.KEYCODE_VOLUME_DOWN) {
            if (e.action == KeyEvent.ACTION_DOWN && e.repeatCount == 0) ui.postDelayed(exitNow, EXIT_HOLD_MS)
            if (e.action == KeyEvent.ACTION_UP) ui.removeCallbacks(exitNow)
            return true // no volume change either: it's a button, not a volume control
        }
        return super.dispatchKeyEvent(e)
    }

    private fun leaveSession() {
        if (!::renderer.isInitialized || isFinishing) return
        renderer.exiting = true
        Params.set("fx.fade", 0.0)
        Params.set("photic.on", false)
        Params.set("words.text", "")
        if (::control.isInitialized) control.sendLeft() // control.stop() closes after it's sent
        ui.postDelayed({ finish() }, 150)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) hideSystemUi()
    }

    // ------------------------------------------------------------------ stats
    private var lastBytes = 0L
    private var lastFrames = 0L
    private var lastTick = 0L

    private val statsTick = object : Runnable {
        override fun run() {
            val now = System.nanoTime()
            val dt = if (lastTick == 0L) 1.0 else (now - lastTick) / 1e9
            lastTick = now
            val fps = ((renderer.renderedFrames - lastFrames) / dt).toInt()
            val kbps = ((video.bytes - lastBytes) * 8 / 1000 / dt).toInt()
            lastFrames = renderer.renderedFrames; lastBytes = video.bytes
            val videoLive = now - video.lastPacketNs < 1_000_000_000L
            val bm = getSystemService(Context.BATTERY_SERVICE) as BatteryManager
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            val stats = JSONObject()
                .put("fps", fps).put("kbps", kbps).put("loss", video.lost)
                .put("res", decoder.resolution).put("rtt_ms", control.rttMs)
                .put("audio_ms", audio.bufferedMs).put("underruns", audio.underruns)
                .put("media_ms", audio.mediaBufferedMs)
                .put("out_latency_ms", audio.outLatencyMs)
                .put("battery", bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY))
                .put("thermal", pm.currentThermalStatus)
            control.sendStats(stats)

            val text = when {
                ended != null -> "$ended\nBack leaves the view"
                control.connectedHost == null -> status
                !videoLive -> "$status\nwaiting for video…"
                Params.b("view.stats") ->
                    "$fps fps  $kbps kb/s  loss ${video.lost}\nrtt ${control.rttMs} ms  " +
                        "voice buf ${audio.bufferedMs} ms  out ${audio.outLatencyMs} ms\n${decoder.resolution}"
                else -> ""
            }
            for (l in labels) l.text = text
            ui.postDelayed(this, 1000)
        }
    }

    // --------------------------------------------------------------- settings
    private fun showSettings() {
        val prefs = Params.prefs() ?: return
        val pad = (16 * resources.displayMetrics.density).toInt()
        val reverse = CheckBox(this).apply {
            text = "Flip screen (reverse landscape)"
            isChecked = prefs.getBoolean("reverse", false)
        }
        val box = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL; setPadding(pad, pad, pad, 0)
            addView(TextView(context).apply { text = "Guided by ${session.guide}" })
            addView(reverse)
            addView(TextView(context).apply {
                text = "\nLens calibration is adjusted from the Guide page and saved on this phone."
            })
        }
        AlertDialog.Builder(this).setTitle("HiveSight").setView(box)
            .setPositiveButton("Save") { _, _ ->
                prefs.edit().putBoolean("reverse", reverse.isChecked).apply()
                applyOrientation()
            }
            .setNegativeButton("Cancel", null)
            .setOnDismissListener { hideSystemUi() }
            .show()
    }

    // ------------------------------------------------------------------ misc
    private fun applyOrientation() {
        requestedOrientation = if (Params.prefs()?.getBoolean("reverse", false) == true)
            ActivityInfo.SCREEN_ORIENTATION_REVERSE_LANDSCAPE else ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
    }

    private fun hideSystemUi() {
        window.insetsController?.let {
            it.hide(WindowInsets.Type.systemBars())
            it.systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
        @Suppress("DEPRECATION")
        window.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or
            View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or View.SYSTEM_UI_FLAG_FULLSCREEN
    }

    private fun highestRefreshMode(): Int {
        @Suppress("DEPRECATION")
        val d = windowManager.defaultDisplay
        val cur = d.mode
        return d.supportedModes
            .filter { it.physicalWidth == cur.physicalWidth && it.physicalHeight == cur.physicalHeight }
            .maxByOrNull { it.refreshRate }?.modeId ?: 0
    }

    /** Newer Android versions gate LAN access behind a runtime permission. */
    private fun requestLocalNetworkIfNeeded() {
        val perm = LOCAL_NETWORK_PERMISSION
        val exists = runCatching { packageManager.getPermissionInfo(perm, 0) }.isSuccess
        if (exists && checkSelfPermission(perm) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(perm), 1)
        }
    }

    companion object {
        /** How long volume-down is held to leave the session. */
        const val EXIT_HOLD_MS = 1500L

        /** The session, from the intent MainActivity starts this with; null if it isn't one. */
        fun sessionOf(i: android.content.Intent): Session? {
            val hosts = i.getStringArrayListExtra("hosts")?.filter { it.isNotBlank() } ?: return null
            val fp = i.getStringExtra("fingerprint") ?: return null
            val token = i.getStringExtra("token") ?: return null
            if (hosts.isEmpty() || fp.length != 64) return null
            return Session(
                hosts = hosts, port = i.getIntExtra("port", 0), fingerprint = fp, token = token,
                expiresMs = i.getLongExtra("expires", 0), guide = i.getStringExtra("guide") ?: "your Guide",
                key = i.getStringExtra("key") ?: "", sig = i.getStringExtra("sig") ?: "",
                lightPulse = i.getBooleanExtra("lightPulse", false), name = i.getStringExtra("name") ?: "",
            )
        }

        const val VIDEO_PORT = 5004
        const val AUDIO_PORT = 5006
        const val MEDIA_PORT = 5008
        private const val LOCAL_NETWORK_PERMISSION = "android.permission.ACCESS_LOCAL_NETWORK"
    }
}
