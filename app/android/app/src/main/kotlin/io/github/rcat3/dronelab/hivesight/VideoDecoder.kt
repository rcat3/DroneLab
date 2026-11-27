package io.github.rcat3.dronelab.hivesight

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Build
import android.util.Log
import android.view.Surface
import java.nio.ByteBuffer
import java.util.concurrent.LinkedBlockingDeque
import java.util.concurrent.TimeUnit

/**
 * Feeds access units into a low-latency MediaCodec H.264 decoder that renders
 * straight to the renderer's SurfaceTexture. Frames are held back by
 * fx.delay_ms (compressed frames are cheap to buffer, so multi-second delays
 * cost a few MB).
 */
class VideoDecoder(
    private val onNeedKeyframe: () -> Unit,
    private val onVideoSize: (Int, Int) -> Unit,
) {
    private val queue = LinkedBlockingDeque<AccessUnit>()
    @Volatile private var running = false
    @Volatile var surface: Surface? = null
    private var thread: Thread? = null
    private var codec: MediaCodec? = null
    private var codecSurface: Surface? = null
    private var codecSps: ByteArray? = null
    private var pts = 0L
    @Volatile var decoded = 0L; private set
    @Volatile var resolution = ""; private set

    fun submit(au: AccessUnit) {
        queue.offer(au)
        // Safety valve: never let the queue grow without bound (e.g. huge delay
        // or a stalled decoder). Drop everything and resync on a keyframe.
        if (queue.size > 600) {
            queue.clear()
            onNeedKeyframe()
        }
    }

    fun start() {
        running = true
        thread = Thread(::run, "video-decode").apply { priority = Thread.MAX_PRIORITY; start() }
    }

    fun stop() {
        running = false
        thread?.join(1000)
        releaseCodec()
    }

    private fun run() {
        val info = MediaCodec.BufferInfo()
        while (running) {
            drain(info)
            val head = queue.peekFirst()
            if (head == null) {
                // Wait briefly for the next frame.
                val au = queue.pollFirst(4, TimeUnit.MILLISECONDS) ?: continue
                queue.offerFirst(au)
                continue
            }
            val delayNs = Params.i("fx.delay_ms") * 1_000_000L
            val dueIn = head.arrivalNs + delayNs - System.nanoTime()
            if (dueIn > 0) {
                Thread.sleep(minOf(4L, dueIn / 1_000_000L + 1))
                continue
            }
            queue.pollFirst()
            val surf = surface ?: continue
            // A keyframe with a different SPS means a new source or resolution
            // (e.g. camera -> video file): start a fresh decoder for it.
            if (codec != null && head.isKey) {
                val sps = extractParamSets(head.data)?.first
                if (sps != null && codecSps != null && !sps.contentEquals(codecSps)) releaseCodec()
            }
            if (codec == null || codecSurface !== surf) {
                if (!head.isKey) { onNeedKeyframe(); continue }
                if (!createCodec(head, surf)) continue
            }
            if (!feed(head)) { releaseCodec(); onNeedKeyframe() }
        }
    }

    private fun createCodec(key: AccessUnit, surf: Surface): Boolean {
        releaseCodec()
        val w = Params.i("stream.width").takeIf { it > 0 } ?: 2560
        val h = Params.i("stream.height").takeIf { it > 0 } ?: 720
        return try {
            val fmt = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, w, h)
            extractParamSets(key.data)?.let { (sps, pps) ->
                codecSps = sps
                fmt.setByteBuffer("csd-0", ByteBuffer.wrap(sps))
                fmt.setByteBuffer("csd-1", ByteBuffer.wrap(pps))
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) fmt.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            fmt.setInteger(MediaFormat.KEY_PRIORITY, 0) // realtime
            fmt.setInteger(MediaFormat.KEY_OPERATING_RATE, 120)
            // Qualcomm (Galaxy S23 is Snapdragon) vendor low-latency switches; ignored elsewhere.
            fmt.setInteger("vendor.qti-ext-dec-low-latency.enable", 1)
            fmt.setInteger("vendor.qti-ext-dec-picture-order.enable", 1)
            fmt.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            val c = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
            c.configure(fmt, surf, null, 0)
            c.start()
            codec = c
            codecSurface = surf
            Log.i(TAG, "decoder ${c.name} started for ${w}x$h")
            true
        } catch (e: Exception) {
            Log.e(TAG, "decoder create failed", e)
            releaseCodec()
            false
        }
    }

    private fun feed(au: AccessUnit): Boolean {
        val c = codec ?: return false
        return try {
            val idx = c.dequeueInputBuffer(20_000)
            if (idx < 0) return true // decoder busy; drop this frame (rare)
            val buf = c.getInputBuffer(idx) ?: return true
            if (au.data.size > buf.capacity()) {
                c.queueInputBuffer(idx, 0, 0, pts, 0)
                return false
            }
            buf.clear(); buf.put(au.data)
            pts += 33_333
            c.queueInputBuffer(idx, 0, au.data.size, pts, if (au.isKey) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0)
            true
        } catch (e: Exception) {
            Log.w(TAG, "feed failed", e)
            false
        }
    }

    private fun drain(info: MediaCodec.BufferInfo) {
        val c = codec ?: return
        try {
            while (true) {
                val idx = c.dequeueOutputBuffer(info, 0)
                when {
                    idx >= 0 -> {
                        c.releaseOutputBuffer(idx, true) // render immediately
                        decoded++
                    }
                    idx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val f = c.outputFormat
                        var w = f.getInteger(MediaFormat.KEY_WIDTH)
                        var h = f.getInteger(MediaFormat.KEY_HEIGHT)
                        if (f.containsKey("crop-right") && f.containsKey("crop-left")) {
                            w = f.getInteger("crop-right") - f.getInteger("crop-left") + 1
                            h = f.getInteger("crop-bottom") - f.getInteger("crop-top") + 1
                        }
                        resolution = "${w}x$h"
                        onVideoSize(w, h)
                    }
                    else -> return
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "drain failed", e)
            releaseCodec()
            onNeedKeyframe()
        }
    }

    private fun releaseCodec() {
        codec?.let { runCatching { it.stop() }; runCatching { it.release() } }
        codec = null
        codecSurface = null
        codecSps = null
    }

    /** Pull SPS/PPS (with start codes) out of an Annex-B keyframe. */
    private fun extractParamSets(d: ByteArray): Pair<ByteArray, ByteArray>? {
        var sps: ByteArray? = null
        var pps: ByteArray? = null
        val starts = ArrayList<Int>()
        var i = 0
        while (i + 3 < d.size) {
            if (d[i].toInt() == 0 && d[i + 1].toInt() == 0 && d[i + 2].toInt() == 0 && d[i + 3].toInt() == 1) {
                starts.add(i); i += 4
            } else i++
        }
        for ((n, s) in starts.withIndex()) {
            val end = if (n + 1 < starts.size) starts[n + 1] else d.size
            if (s + 4 >= end) continue
            when (d[s + 4].toInt() and 0x1f) {
                7 -> sps = d.copyOfRange(s, end)
                8 -> pps = d.copyOfRange(s, end)
            }
        }
        return if (sps != null && pps != null) sps to pps else null
    }

    companion object { private const val TAG = "HiveSightDecoder" }
}
