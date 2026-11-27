package io.github.rcat3.dronelab.hivesight

import android.graphics.Bitmap
import android.graphics.Matrix
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Guide preview ("confidence monitor"): small JPEG snapshots of what the
 * Vessel sees and a copy of the final audio mix, sent back to the sender over
 * the control WebSocket, which relays them to consoles.
 *
 * Binary message format: 1 type byte, then the payload.
 *   0x01  JPEG of the two eye views (flat, i.e. without lens pre-distortion)
 *   0x02  PCM audio: S16LE stereo interleaved, 24 kHz
 *
 * Only active while the console has preview.video / preview.audio switched on.
 */
object PreviewProtocol {
    const val VIDEO: Byte = 0x01
    const val AUDIO: Byte = 0x02
    const val AUDIO_RATE = 24000
}

class PreviewVideo(private val send: (Byte, ByteArray) -> Unit) {
    private val busy = AtomicBoolean(false)
    private val worker = Executors.newSingleThreadExecutor { Thread(it, "preview-jpeg") }
    private var lastNs = 0L
    private var pixels: ByteBuffer? = null

    /** Called on the GL thread each frame: is a snapshot wanted now? */
    fun due(nowNs: Long): Boolean {
        if (!Params.b("preview.video") || busy.get()) return false
        val fps = Params.f("preview.fps").coerceIn(1f, 20f)
        if (nowNs - lastNs < (1e9f / fps).toLong()) return false
        lastNs = nowNs
        return true
    }

    /** Buffer for glReadPixels (GL thread). */
    fun buffer(w: Int, h: Int): ByteBuffer {
        val need = w * h * 4
        val b = pixels?.takeIf { it.capacity() == need }
            ?: ByteBuffer.allocateDirect(need).order(ByteOrder.nativeOrder()).also { pixels = it }
        b.rewind()
        return b
    }

    /** Hand over pixels just read on the GL thread; JPEG encoding happens off-thread. */
    fun submit(buf: ByteBuffer, w: Int, h: Int) {
        if (!busy.compareAndSet(false, true)) return
        val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        buf.rewind()
        bmp.copyPixelsFromBuffer(buf) // fast memcpy; keep the GL thread short
        worker.execute {
            try {
                // GL rows are bottom-up.
                val flipped = Bitmap.createBitmap(bmp, 0, 0, w, h, Matrix().apply { preScale(1f, -1f) }, false)
                val out = ByteArrayOutputStream(32 * 1024)
                flipped.compress(Bitmap.CompressFormat.JPEG, 65, out)
                flipped.recycle()
                send(PreviewProtocol.VIDEO, out.toByteArray())
            } finally {
                bmp.recycle()
                busy.set(false)
            }
        }
    }
}

/** Downsamples the 48 kHz float mix to 24 kHz S16 and ships 20 ms chunks. */
class PreviewAudio(private val send: (Byte, ByteArray) -> Unit) {
    private val chunkFrames = PreviewProtocol.AUDIO_RATE / 50
    private val chunk = ByteArray(chunkFrames * 4)
    private var frames = 0

    /** Audio thread: `mix` is interleaved stereo at 48 kHz. */
    fun feed(mix: FloatArray, count: Int) {
        if (!Params.b("preview.audio")) { frames = 0; return }
        var i = 0
        while (i + 3 < count) {
            // 2:1 decimation by averaging pairs (cheap anti-alias; it's only a monitor).
            val l = (mix[i] + mix[i + 2]) * 0.5f
            val r = (mix[i + 1] + mix[i + 3]) * 0.5f
            putS16(frames * 4, l); putS16(frames * 4 + 2, r)
            frames++
            if (frames == chunkFrames) { send(PreviewProtocol.AUDIO, chunk.copyOf()); frames = 0 }
            i += 4
        }
    }

    private fun putS16(off: Int, v: Float) {
        val s = (v.coerceIn(-1f, 1f) * 32767f).toInt()
        chunk[off] = (s and 0xff).toByte()
        chunk[off + 1] = (s shr 8 and 0xff).toByte()
    }
}
