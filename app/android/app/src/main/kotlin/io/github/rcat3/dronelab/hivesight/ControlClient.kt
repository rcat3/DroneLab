package io.github.rcat3.dronelab.hivesight

import android.content.Context
import android.net.wifi.WifiManager
import android.os.Build
import android.util.Log
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString.Companion.toByteString
import org.json.JSONObject
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetSocketAddress
import java.net.SocketTimeoutException
import java.util.concurrent.TimeUnit

/**
 * Finds the sender (UDP broadcast beacon on 5010, or a fixed host from
 * settings), keeps a WebSocket open to it, applies state updates to Params,
 * and reports stats back.
 */
class ControlClient(
    context: Context,
    private val videoPort: Int,
    private val audioPort: Int,
    private val onStatus: (String) -> Unit,
) {
    private val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
    private val http = OkHttpClient.Builder()
        .pingInterval(3, TimeUnit.SECONDS)
        .connectTimeout(3, TimeUnit.SECONDS)
        .build()
    @Volatile private var ws: WebSocket? = null
    @Volatile private var running = false
    @Volatile var connectedHost: String? = null; private set
    @Volatile var rttMs = -1; private set
    private var thread: Thread? = null
    private var lastKeyReq = 0L

    fun start() {
        running = true
        thread = Thread(::loop, "control").apply { start() }
    }

    fun stop() {
        running = false
        ws?.close(1000, "bye")
        thread?.interrupt()
        thread?.join(1500)
    }

    fun requestKeyframe() {
        val now = System.nanoTime()
        if (now - lastKeyReq < 200_000_000L) return
        lastKeyReq = now
        send(JSONObject().put("type", "keyframe"))
    }

    fun sendStats(stats: JSONObject) = send(JSONObject().put("type", "stats").put("stats", stats))

    /** Preview payloads. Dropped (not queued) if the link is backed up. */
    fun sendBinary(type: Byte, payload: ByteArray) {
        val w = ws ?: return
        if (w.queueSize() > 512 * 1024) return
        val msg = ByteArray(payload.size + 1)
        msg[0] = type
        System.arraycopy(payload, 0, msg, 1, payload.size)
        w.send(msg.toByteString())
    }

    private fun send(j: JSONObject) {
        ws?.send(j.toString())
    }

    private fun loop() {
        while (running) {
            val manual = Params.prefs()?.getString("host", "")?.trim().orEmpty()
            val target = if (manual.isNotEmpty()) {
                val parts = manual.split(":")
                parts[0] to (parts.getOrNull(1)?.toIntOrNull() ?: 8080)
            } else {
                onStatus("Searching for sender…")
                discover() ?: continue
            }
            onStatus("Connecting to ${target.first}…")
            val closed = Object()
            var done = false
            val req = Request.Builder().url("ws://${target.first}:${target.second}/ws").build()
            ws = http.newWebSocket(req, object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) {
                    connectedHost = target.first
                    onStatus("Connected to ${target.first}")
                    webSocket.send(
                        JSONObject().put("type", "hello").put("role", "receiver")
                            .put("name", "${Build.MANUFACTURER} ${Build.MODEL}")
                            .put("video_port", videoPort).put("audio_port", audioPort)
                            .put("media_port", HiveSightActivity.MEDIA_PORT)
                            .put("view", Params.viewJson()).toString()
                    )
                }

                override fun onMessage(webSocket: WebSocket, text: String) = handle(text)

                override fun onClosed(webSocket: WebSocket, code: Int, reason: String) = finish()
                override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                    Log.w(TAG, "ws failure: ${t.message}")
                    finish()
                }

                private fun finish() = synchronized(closed) { done = true; closed.notifyAll() }
            })
            // Ping for RTT once a second until the socket dies.
            try {
                synchronized(closed) {
                    while (!done && running) {
                        send(JSONObject().put("type", "ping").put("t", System.nanoTime()))
                        (closed as Object).wait(1000)
                    }
                }
            } catch (_: InterruptedException) {
            }
            ws?.cancel()
            ws = null
            connectedHost = null
            if (running) {
                onStatus("Disconnected — retrying")
                try { Thread.sleep(1000) } catch (_: InterruptedException) {}
            }
        }
    }

    private fun handle(text: String) {
        val m = runCatching { JSONObject(text) }.getOrNull() ?: return
        when (m.optString("type")) {
            "state" -> m.optJSONObject("state")?.let { Params.applyState(it) }
            "set" -> Params.set(m.getString("path"), m.get("value"))
            "pong" -> rttMs = ((System.nanoTime() - m.optLong("t")) / 1_000_000L).toInt()
        }
    }

    /** Listen for the sender's beacon for up to ~3 s. */
    private fun discover(): Pair<String, Int>? {
        val lock = wifi.createMulticastLock("hivesight-discovery").apply { setReferenceCounted(false); acquire() }
        try {
            DatagramSocket(null).use { s ->
                s.reuseAddress = true
                s.broadcast = true
                s.soTimeout = 3000
                s.bind(InetSocketAddress(BEACON_PORT))
                val buf = ByteArray(1024)
                val p = DatagramPacket(buf, buf.size)
                s.receive(p)
                val j = JSONObject(String(buf, 0, p.length))
                if (j.optInt("eyestream") != 1) return null
                return p.address.hostAddress!! to j.optInt("port", 8080)
            }
        } catch (_: SocketTimeoutException) {
            return null
        } catch (e: Exception) {
            Log.w(TAG, "discovery: ${e.message}")
            try { Thread.sleep(1000) } catch (_: InterruptedException) {}
            return null
        } finally {
            lock.release()
        }
    }

    companion object {
        private const val TAG = "HiveSightControl"
        const val BEACON_PORT = 5010
    }
}
