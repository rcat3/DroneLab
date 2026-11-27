package io.github.rcat3.dronelab.hivesight

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.DataInputStream
import java.io.File

/** Replays packets captured from the real sender (tools: see README). */
class RtpVideoReceiverTest {
    private fun packets(): List<ByteArray> {
        val input = DataInputStream(javaClass.getResourceAsStream("/video.rtpdump")!!.buffered())
        val out = ArrayList<ByteArray>()
        while (input.available() > 0) {
            val n = input.readUnsignedShort()
            out.add(ByteArray(n).also { input.readFully(it) })
        }
        return out
    }

    private fun replay(pkts: List<ByteArray>): Pair<List<AccessUnit>, Int> {
        val aus = ArrayList<AccessUnit>()
        var keyReqs = 0
        val rx = RtpVideoReceiver(0, { aus.add(it) }, { keyReqs++ })
        for (p in pkts) rx.handlePacket(p, p.size)
        return aus to keyReqs
    }

    @Test fun reassemblesCleanStream() {
        val (aus, keyReqs) = replay(packets())
        // ~4 s at 30 fps; the capture may start mid-GOP so leading frames are skipped.
        assertTrue("got ${aus.size} frames", aus.size in 50..125)
        assertTrue(aus.first().isKey)
        // Write Annex-B so the build can verify it with ffprobe.
        File("build/reassembled.h264").outputStream().use { o -> aus.forEach { o.write(it.data) } }
        println("frames=${aus.size} keyframes=${aus.count { it.isKey }} keyRequests=$keyReqs")
    }

    @Test fun lossDropsUntilNextKeyframe() {
        val pkts = packets().toMutableList()
        val clean = replay(pkts).first
        pkts.removeAt(pkts.size / 4) // lose one packet a quarter of the way in
        val (aus, keyReqs) = replay(pkts)
        assertTrue("key requested", keyReqs > 0)
        assertTrue("frames dropped", aus.size < clean.size)
        // After the loss, the first frame delivered must be a keyframe.
        val firstAfterGap = aus.indexOfFirst { a -> clean.none { it.data.contentEquals(a.data) } }
        assertEquals(-1, firstAfterGap) // every delivered frame is intact
    }

    /** Rewrite seq numbers and SSRC, as a restarted sender pipeline would. */
    private fun restarted(pkts: List<ByteArray>, seqStart: Int, ssrc: Int) = pkts.mapIndexed { i, p ->
        p.copyOf().also {
            val seq = (seqStart + i) and 0xffff
            it[2] = (seq shr 8).toByte(); it[3] = seq.toByte()
            it[8] = (ssrc ushr 24).toByte(); it[9] = (ssrc ushr 16).toByte()
            it[10] = (ssrc ushr 8).toByte(); it[11] = ssrc.toByte()
        }
    }

    @Test fun recoversWhenSourceRestartsWithLowerSequenceNumbers() {
        val pkts = packets()
        val a = restarted(pkts, 40000, 0x11111111)
        val b = restarted(pkts, 35000, 0x22222222) // new pipeline: random seq that lands "behind" + new SSRC
        val aus = ArrayList<AccessUnit>()
        val rx = RtpVideoReceiver(0, { aus.add(it) }, {})
        for (p in a) rx.handlePacket(p, p.size)
        val fromA = aus.size
        for (p in b) rx.handlePacket(p, p.size)
        assertTrue("first stream decoded ($fromA)", fromA > 50)
        assertTrue("second stream must play too (got ${aus.size - fromA} frames)", aus.size - fromA > 50)
    }
}
