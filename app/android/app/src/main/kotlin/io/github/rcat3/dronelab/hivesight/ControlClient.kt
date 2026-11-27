package io.github.rcat3.dronelab.hivesight

import android.os.Build
import android.util.Log
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString.Companion.toByteString
import org.json.JSONObject
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLContext
import javax.net.ssl.X509TrustManager

/** A session joined from a Guide's invitation, as the app checked it. */
data class Session(
    val hosts: List<String>,
    val port: Int,
    val fingerprint: String,    // the Guide's certificate's SHA-256, hex
    val token: String,
    val expiresMs: Long,
    val guide: String,          // the Guide's name, for showing
    val key: String,            // our identity key, hex
    val sig: String,            // our signature for this session, hex
    val lightPulse: Boolean,    // we allow the Guide the light pulse
    val name: String,
)

/**
 * Keeps a WebSocket open to the Guide's sender, over TLS with the
 * certificate pinned from the invitation, trying its addresses in turn;
 * applies state updates to Params, and reports stats back. Stops for good
 * when the Guide ends the session or removes us, or it expires.
 */
class ControlClient(
    private val session: Session,
    private val videoPort: Int,
    private val audioPort: Int,
    private val onStatus: (String) -> Unit,
    private val onEnded: (String) -> Unit,
) {
    private val http: OkHttpClient
    @Volatile private var ws: WebSocket? = null
    @Volatile private var running = false
    @Volatile var connectedHost: String? = null; private set
    @Volatile var rttMs = -1; private set
    private var thread: Thread? = null
    private var lastKeyReq = 0L

    init {
        // Trust the one certificate the invitation names, whatever the host
        // is called: the pin is the check
        val pin = object : X509TrustManager {
            override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) =
                throw CertificateException("no client certificates")

            override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) {
                val leaf = chain.firstOrNull() ?: throw CertificateException("no certificate")
                val fp = MessageDigest.getInstance("SHA-256").digest(leaf.encoded)
                    .joinToString("") { "%02x".format(it) }
                if (!MessageDigest.isEqual(fp.toByteArray(), session.fingerprint.lowercase().toByteArray()))
                    throw CertificateException("not the Guide's certificate")
            }

            override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
        }
        val tls = SSLContext.getInstance("TLS").apply { init(null, arrayOf(pin), SecureRandom()) }
        http = OkHttpClient.Builder()
            .sslSocketFactory(tls.socketFactory, pin)
            .hostnameVerifier { _, _ -> true }
            .pingInterval(3, TimeUnit.SECONDS)
            .connectTimeout(3, TimeUnit.SECONDS)
            .build()
    }

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

    private fun end(why: String) {
        running = false
        onEnded(why)
    }

    private fun loop() {
        var next = 0
        while (running) {
            if (System.currentTimeMillis() >= session.expiresMs) {
                end("The session has ended"); return
            }
            val host = session.hosts[next % session.hosts.size]
            next++
            onStatus("Connecting to ${session.guide}…")
            val closed = Object()
            var done = false
            var opened = false
            val req = Request.Builder().url("wss://$host:${session.port}/ws").build()
            ws = http.newWebSocket(req, object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) {
                    opened = true
                    connectedHost = host
                    onStatus("Connected to ${session.guide}")
                    webSocket.send(
                        JSONObject().put("type", "hello").put("role", "vessel")
                            .put("token", session.token)
                            .put("name", session.name.ifEmpty { "${Build.MANUFACTURER} ${Build.MODEL}" })
                            .put("key", session.key).put("sig", session.sig)
                            .put("allow", JSONObject().put("light_pulse", session.lightPulse))
                            .put("video_port", videoPort).put("audio_port", audioPort)
                            .put("media_port", HiveSightActivity.MEDIA_PORT)
                            .put("view", Params.viewJson()).toString()
                    )
                }

                override fun onMessage(webSocket: WebSocket, text: String) = handle(text)

                override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                    when (code) {
                        4001 -> end(if (reason.isNotEmpty()) reason.replaceFirstChar { it.uppercase() } else "The session has ended")
                        4002 -> end("${session.guide} removed you from the session")
                    }
                    webSocket.close(1000, null)
                }

                override fun onClosed(webSocket: WebSocket, code: Int, reason: String) = finish()
                override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                    Log.w(TAG, "ws failure ($host): ${t.message}")
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
            // Straight on to the next address if this one never answered;
            // a pause once they've all been tried, or the link dropped
            if (running && (opened || next % session.hosts.size == 0)) {
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

    companion object {
        private const val TAG = "HiveSightControl"
    }
}
