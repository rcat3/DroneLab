package io.github.rcat3.dronelab

import android.content.Intent
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
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
    }

    private fun press(keyCode: Int) {
        channel?.invokeMethod("press", keyCode)
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
        stopSession()
        super.onDestroy()
    }
}
