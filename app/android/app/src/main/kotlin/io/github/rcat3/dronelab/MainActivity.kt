package io.github.rcat3.dronelab

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.ClipData
import android.content.ClipboardManager
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.net.wifi.WifiNetworkSuggestion
import android.os.Build
import android.provider.Settings
import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Headset buttons, for talking: the play/pause button on Bluetooth
 * headphones goes to the app with the active, playing media session. While
 * the comm channel's on, the app's playing (silence between voices, at
 * least), so it holds one, and passes each press to Dart on
 * "dronelab/media_buttons" as "press". The iPhone's equivalent would be
 * MPRemoteCommandCenter's togglePlayPauseCommand.
 */
class MainActivity : FlutterActivity() {
    private var session: MediaSession? = null
    private var channel: MethodChannel? = null
    private var dev: BroadcastReceiver? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val c = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dronelab/media_buttons")
        c.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> { startSession(); result.success(null) }
                "stop" -> { stopSession(); result.success(null) }
                else -> result.notImplemented()
            }
        }
        channel = c
        // Android's own settings for one of the app's notification channels:
        // its sound, pop-up, status bar and so on
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dronelab/notifications").setMethodCallHandler { call, result ->
            if (call.method == "channelSettings") {
                val id = call.argument<String>("id")
                val intent = if (id != null && Build.VERSION.SDK_INT >= 26) {
                    Intent(android.provider.Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS)
                        .putExtra(android.provider.Settings.EXTRA_CHANNEL_ID, id)
                } else {
                    Intent(android.provider.Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                }
                intent.putExtra(android.provider.Settings.EXTRA_APP_PACKAGE, packageName)
                startActivity(intent)
                result.success(null)
            } else {
                result.notImplemented()
            }
        }
        // The developer options over adb (text_responder.dart's DevRemote):
        // only the shell can send it, as it needs DUMP, which apps can't have
        val devChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dronelab/dev")
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                val pending = goAsync()
                devChannel.invokeMethod("command", intent.getStringExtra("c") ?: "", object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        pending.resultData = result as? String
                        pending.finish()
                    }
                    override fun error(code: String, message: String?, details: Any?) {
                        pending.resultData = "error: $message"
                        pending.finish()
                    }
                    override fun notImplemented() {
                        pending.resultData = "not ready"
                        pending.finish()
                    }
                })
            }
        }
        val filter = IntentFilter("io.github.rcat3.dronelab.DEV")
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(receiver, filter, android.Manifest.permission.DUMP, null, Context.RECEIVER_EXPORTED)
        } else {
            registerReceiver(receiver, filter, android.Manifest.permission.DUMP, null)
        }
        dev = receiver
        // A Bluetooth headset's mic, for talking without a unit (phone_mic.dart):
        // "find" names the headset there is, "start" puts it in call mode,
        // as the place for the call's voice both ways, "stop" back to media.
        // Each answers the headset's name, or null for none.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dronelab/headset").setMethodCallHandler { call, result ->
            when (call.method) {
                "find" -> result.success(headset()?.let { it.productName?.toString() ?: "Headset" })
                "start" -> result.success(startHeadset())
                "stop" -> { stopHeadset(); result.success(null) }
                else -> result.notImplemented()
            }
        }
        // The phone, for the About page
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dronelab/device").setMethodCallHandler { call, result ->
            if (call.method == "info") {
                result.success(mapOf(
                    "release" to Build.VERSION.RELEASE,
                    "sdk" to Build.VERSION.SDK_INT,
                    "manufacturer" to Build.MANUFACTURER,
                    "model" to Build.MODEL,
                ))
            } else {
                result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dronelab/wifi").setMethodCallHandler { call, result ->
            if (call.method == "join") {
                try {
                    joinWifi(call.argument<String>("ssid") ?: "", call.argument<String>("password") ?: "")
                    result.success(true)
                } catch (e: Exception) {
                    result.error("join", e.message, null)
                }
            } else {
                result.notImplemented()
            }
        }
    }

    /**
     * Join the unit's WiFi hotspot remote on this phone. From Android 11, the
     * system's own "save this network?" dialog, then its WiFi panel, where
     * the phone connects to it; before that, WiFi settings, with the
     * password on the clipboard to paste. The iPhone's equivalent would be
     * NEHotspotConfiguration.
     */
    private fun joinWifi(ssid: String, password: String) {
        if (Build.VERSION.SDK_INT >= 30) {
            val network = WifiNetworkSuggestion.Builder().setSsid(ssid).setWpa2Passphrase(password).build()
            val intent = Intent(Settings.ACTION_WIFI_ADD_NETWORKS)
                .putParcelableArrayListExtra(Settings.EXTRA_WIFI_NETWORK_LIST, arrayListOf(network))
            @Suppress("DEPRECATION")
            startActivityForResult(intent, ADD_WIFI)
        } else {
            val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            clipboard.setPrimaryClip(ClipData.newPlainText("WiFi password", password))
            startActivity(Intent(Settings.ACTION_WIFI_SETTINGS))
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        // Saved: the WiFi panel, to connect to it now
        if (requestCode == ADD_WIFI && resultCode == RESULT_OK && Build.VERSION.SDK_INT >= 29) {
            startActivity(Intent(Settings.Panel.ACTION_WIFI))
        }
    }

    private fun press(keyCode: Int) {
        channel?.invokeMethod("press", keyCode)
    }

    private val audio by lazy { getSystemService(Context.AUDIO_SERVICE) as AudioManager }
    private var headsetOn = false

    private fun isHeadset(d: AudioDeviceInfo) =
        d.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO ||
            (Build.VERSION.SDK_INT >= 31 && d.type == AudioDeviceInfo.TYPE_BLE_HEADSET)

    /** The Bluetooth headset to talk through, if there's one. */
    private fun headset(): AudioDeviceInfo? =
        if (Build.VERSION.SDK_INT >= 31) {
            audio.availableCommunicationDevices.firstOrNull { isHeadset(it) }
        } else {
            audio.getDevices(AudioManager.GET_DEVICES_INPUTS).firstOrNull { isHeadset(it) }
        }

    private fun startHeadset(): String? {
        val d = headset() ?: return null
        audio.mode = AudioManager.MODE_IN_COMMUNICATION
        if (Build.VERSION.SDK_INT >= 31) {
            if (!audio.setCommunicationDevice(d)) {
                audio.mode = AudioManager.MODE_NORMAL
                return null
            }
        } else {
            @Suppress("DEPRECATION")
            audio.startBluetoothSco()
            @Suppress("DEPRECATION")
            audio.isBluetoothScoOn = true
        }
        headsetOn = true
        return d.productName?.toString() ?: "Headset"
    }

    private fun stopHeadset() {
        if (!headsetOn) return
        headsetOn = false
        if (Build.VERSION.SDK_INT >= 31) {
            audio.clearCommunicationDevice()
        } else {
            @Suppress("DEPRECATION")
            audio.isBluetoothScoOn = false
            @Suppress("DEPRECATION")
            audio.stopBluetoothSco()
        }
        audio.mode = AudioManager.MODE_NORMAL
    }

    private fun startSession() {
        if (session != null) return
        val s = MediaSession(this, "DroneLab comm channel")
        s.setCallback(object : MediaSession.Callback() {
            override fun onMediaButtonEvent(intent: Intent): Boolean {
                val event: KeyEvent? = if (Build.VERSION.SDK_INT >= 33) {
                    intent.getParcelableExtra(Intent.EXTRA_KEY_EVENT, KeyEvent::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(Intent.EXTRA_KEY_EVENT)
                }
                when (event?.keyCode) {
                    KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE, KeyEvent.KEYCODE_HEADSETHOOK,
                    KeyEvent.KEYCODE_MEDIA_PLAY, KeyEvent.KEYCODE_MEDIA_PAUSE -> {
                        // Once per press: headphones send the press and the
                        // release together, so there's no holding
                        if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) {
                            press(event.keyCode)
                        }
                        return true
                    }
                }
                return super.onMediaButtonEvent(intent)
            }

            // Some phones skip the key event and go straight to these
            override fun onPlay() = press(KeyEvent.KEYCODE_MEDIA_PLAY)
            override fun onPause() = press(KeyEvent.KEYCODE_MEDIA_PAUSE)
        })
        s.setPlaybackState(
            PlaybackState.Builder()
                .setActions(PlaybackState.ACTION_PLAY_PAUSE or PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE)
                .setState(PlaybackState.STATE_PLAYING, PlaybackState.PLAYBACK_POSITION_UNKNOWN, 1f)
                .build()
        )
        s.isActive = true
        session = s
    }

    private fun stopSession() {
        session?.isActive = false
        session?.release()
        session = null
    }

    override fun onDestroy() {
        stopHeadset()
        stopSession()
        dev?.let { unregisterReceiver(it) }
        dev = null
        super.onDestroy()
    }

    companion object {
        private const val ADD_WIFI = 4711
    }
}
