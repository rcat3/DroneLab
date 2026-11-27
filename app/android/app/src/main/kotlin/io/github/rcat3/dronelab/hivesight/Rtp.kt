package io.github.rcat3.dronelab.hivesight

import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetSocketAddress
import java.net.SocketTimeoutException

/** Minimal RTP header view (RFC 3550). */
class RtpPacket {
    var seq = 0
    var timestamp = 0L
    var ssrc = 0L
    var marker = false
    var payloadType = 0
    var payloadOffset = 0
    var payloadLength = 0

    /** Parse in place; returns false for anything that isn't a sane RTP v2 packet. */
    fun parse(b: ByteArray, len: Int): Boolean {
        if (len < 12) return false
        val b0 = b[0].toInt() and 0xff
        if (b0 ushr 6 != 2) return false
        val padding = b0 and 0x20 != 0
        val ext = b0 and 0x10 != 0
        val cc = b0 and 0x0f
        val b1 = b[1].toInt() and 0xff
        marker = b1 and 0x80 != 0
        payloadType = b1 and 0x7f
        seq = ((b[2].toInt() and 0xff) shl 8) or (b[3].toInt() and 0xff)
        timestamp = ((b[4].toLong() and 0xff) shl 24) or ((b[5].toLong() and 0xff) shl 16) or
            ((b[6].toLong() and 0xff) shl 8) or (b[7].toLong() and 0xff)
        ssrc = ((b[8].toLong() and 0xff) shl 24) or ((b[9].toLong() and 0xff) shl 16) or
            ((b[10].toLong() and 0xff) shl 8) or (b[11].toLong() and 0xff)
        var off = 12 + cc * 4
        if (ext) {
            if (off + 4 > len) return false
            val words = ((b[off + 2].toInt() and 0xff) shl 8) or (b[off + 3].toInt() and 0xff)
            off += 4 + words * 4
        }
        var end = len
        if (padding) end -= b[len - 1].toInt() and 0xff
        if (off >= end) return false
        payloadOffset = off
        payloadLength = end - off
        return true
    }
}

/**
 * Tracks one RTP stream's sequence numbers. A new SSRC, or a large jump
 * backwards, means the sender restarted its pipeline (e.g. switched source):
 * that is a new stream, not a pile of late packets. Treating it as late would
 * drop everything until the 16-bit counter caught up, up to a minute later.
 */
class SeqTracker {
    private var lastSeq = -1
    private var ssrc = -1L

    enum class Result { NEXT, GAP, RESTART, STALE }
    var gap = 0; private set

    fun accept(rtp: RtpPacket): Result {
        if (lastSeq < 0 || rtp.ssrc != ssrc) {
            val first = lastSeq < 0
            ssrc = rtp.ssrc; lastSeq = rtp.seq
            return if (first) Result.NEXT else Result.RESTART
        }
        val d = seqDelta(lastSeq, rtp.seq)
        return when {
            d == 1 -> { lastSeq = rtp.seq; Result.NEXT }
            d > 1 -> { gap = d - 1; lastSeq = rtp.seq; Result.GAP }
            d > -STALE_WINDOW -> Result.STALE // duplicate or slightly reordered: drop it
            else -> { lastSeq = rtp.seq; Result.RESTART }
        }
    }

    companion object { const val STALE_WINDOW = 512 }
}

/** Signed distance from a to b in 16-bit sequence space. */
fun seqDelta(a: Int, b: Int): Int {
    var d = (b - a) and 0xffff
    if (d >= 0x8000) d -= 0x10000
    return d
}

fun openUdp(port: Int, bufBytes: Int): DatagramSocket =
    DatagramSocket(null).apply {
        reuseAddress = true
        receiveBufferSize = bufBytes
        soTimeout = 500
        bind(InetSocketAddress(port))
    }

/** One complete H.264 access unit in Annex-B form. */
class AccessUnit(val data: ByteArray, val isKey: Boolean, val arrivalNs: Long)

/**
 * Receives H.264 RTP (RFC 6184: single NAL, STAP-A, FU-A) and reassembles
 * access units. On packet loss it drops the damaged frame, discards everything
 * up to the next keyframe (a brief freeze looks far better than smeared
 * macroblocks inside a headset) and asks the sender for a keyframe.
 */
class RtpVideoReceiver(
    private val port: Int,
    private val onAccessUnit: (AccessUnit) -> Unit,
    private val onNeedKeyframe: () -> Unit,
) {
    @Volatile private var running = false
    private var thread: Thread? = null

    // Stats (read by the stats reporter)
    @Volatile var packets = 0L; private set
    @Volatile var bytes = 0L; private set
    @Volatile var lost = 0L; private set
    @Volatile var frames = 0L; private set
    @Volatile var lastPacketNs = 0L; private set

    private val au = ByteArray(4 * 1024 * 1024)
    private var auLen = 0
    private var auTs = -1L
    private var auCorrupt = false
    private var auKey = false
    private var inFu = false
    private val seq = SeqTracker()
    private var waitingForKey = true

    fun start() {
        running = true
        thread = Thread(::run, "rtp-video").apply { priority = Thread.MAX_PRIORITY; start() }
    }

    fun stop() {
        running = false
        thread?.join(1000)
    }

    private fun run() {
        val sock = openUdp(port, 8 * 1024 * 1024)
        val buf = ByteArray(65536)
        val pkt = DatagramPacket(buf, buf.size)
        val rtp = RtpPacket()
        sock.use {
            while (running) {
                try {
                    pkt.length = buf.size
                    sock.receive(pkt)
                } catch (_: SocketTimeoutException) {
                    continue
                }
                handlePacket(buf, pkt.length, rtp)
            }
        }
    }

    /** Process one datagram (exposed for tests). */
    internal fun handlePacket(buf: ByteArray, len: Int, rtp: RtpPacket = RtpPacket()) {
        if (!rtp.parse(buf, len) || rtp.payloadType != 96) return
        packets++; bytes += len; lastPacketNs = System.nanoTime()
        handle(rtp, buf)
    }

    private fun handle(rtp: RtpPacket, b: ByteArray) {
        when (seq.accept(rtp)) {
            SeqTracker.Result.STALE -> return
            SeqTracker.Result.GAP -> { lost += seq.gap; auCorrupt = true; inFu = false }
            SeqTracker.Result.RESTART -> {
                // New stream: discard any half-built frame and resync on its first keyframe.
                auLen = 0; auTs = -1L; auCorrupt = false; auKey = false; inFu = false
                waitingForKey = true
            }
            SeqTracker.Result.NEXT -> {}
        }

        // A new timestamp means a new frame even if we missed the marker packet.
        if (auTs != rtp.timestamp && auLen > 0) flush()
        auTs = rtp.timestamp

        val p = rtp.payloadOffset
        val n = rtp.payloadLength
        val nalHeader = b[p].toInt() and 0xff
        when (val type = nalHeader and 0x1f) {
            in 1..23 -> {
                appendNal(b, p, n, type)
            }
            24 -> { // STAP-A
                var o = p + 1
                val end = p + n
                while (o + 2 <= end) {
                    val sz = ((b[o].toInt() and 0xff) shl 8) or (b[o + 1].toInt() and 0xff)
                    o += 2
                    if (sz == 0 || o + sz > end) { auCorrupt = true; break }
                    appendNal(b, o, sz, b[o].toInt() and 0x1f)
                    o += sz
                }
            }
            28 -> { // FU-A
                if (n < 2) return
                val fu = b[p + 1].toInt() and 0xff
                val start = fu and 0x80 != 0
                val nalType = fu and 0x1f
                if (start) {
                    if (!ensure(5 + n)) return
                    writeStartCode()
                    au[auLen++] = ((nalHeader and 0xe0) or nalType).toByte()
                    inFu = true
                    if (nalType == 5 || nalType == 7) auKey = true
                } else if (!inFu) {
                    auCorrupt = true
                    return
                }
                if (!ensure(n)) return
                System.arraycopy(b, p + 2, au, auLen, n - 2)
                auLen += n - 2
                if (fu and 0x40 != 0) inFu = false
            }
            else -> {} // STAP-B/MTAP/FU-B are not produced by GStreamer's payloader
        }
        if (rtp.marker) flush()
    }

    private fun ensure(extra: Int): Boolean {
        if (auLen + extra + 4 > au.size) { auCorrupt = true; return false }
        return true
    }

    private fun writeStartCode() {
        au[auLen++] = 0; au[auLen++] = 0; au[auLen++] = 0; au[auLen++] = 1
    }

    private fun appendNal(b: ByteArray, off: Int, len: Int, type: Int) {
        if (!ensure(len + 4)) return
        writeStartCode()
        System.arraycopy(b, off, au, auLen, len)
        auLen += len
        if (type == 5 || type == 7) auKey = true
    }

    private fun flush() {
        if (auLen > 0) {
            when {
                auCorrupt -> { waitingForKey = true; onNeedKeyframe() }
                waitingForKey && !auKey -> onNeedKeyframe()
                else -> {
                    waitingForKey = false
                    frames++
                    onAccessUnit(AccessUnit(au.copyOf(auLen), auKey, System.nanoTime()))
                }
            }
        }
        auLen = 0
        auCorrupt = false
        auKey = false
        inFu = false
    }
}
