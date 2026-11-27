package io.github.rcat3.dronelab.hivesight

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.opengl.GLES20
import android.opengl.GLUtils
import android.text.Layout
import android.text.StaticLayout
import android.text.TextPaint
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

/**
 * The words layer: the Guide's current phrase, drawn as a texture and
 * placed in the same undistorted lens space as the video, so it reads
 * flat through the lenses and takes the same distortion. The Guide times
 * the cues; each cue (a new `words.seq`) carries its own `words.fade_s`:
 * what's showing fades out, then the new phrase fades in. An empty phrase
 * just fades out.
 *
 * Everything here runs on the GL thread. BLACKOUT is the shader's final
 * fade, which words go through like the picture does.
 */
class Words {
    var tex = 0; private set
    /** Placement in lens space: centre x/y, half width/height (tan-angle units). */
    val pos = FloatArray(4)
    /** Colour and the alpha to draw with (0 draws nothing). */
    val color = FloatArray(4)
    /** Per-eye offset for the stereo depth, in lens-space units (+ = nearer). */
    var eyeOffset = 0f; private set

    private var shown = ""          // what the texture holds
    private var pending: String? = null
    private var shownKey = ""
    private var bmpW = 1
    private var bmpH = 1
    private var lastSeq = Int.MIN_VALUE
    private var vis = 0f
    private var fadeS = 1f
    private var phase = 0.0         // drift, breathing
    private var beatPhase = 0.0

    fun onSurfaceCreated() {
        val t = IntArray(1)
        GLES20.glGenTextures(1, t, 0)
        tex = t[0]
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, tex)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
        // A transparent pixel, so the sampler is always valid
        val one = Bitmap.createBitmap(1, 1, Bitmap.Config.ARGB_8888)
        GLUtils.texImage2D(GLES20.GL_TEXTURE_2D, 0, one, 0)
        one.recycle()
        shownKey = "" // the old texture went with the old context
        bmpW = 1; bmpH = 1
    }

    /** Immediately gone (the exit gesture). */
    fun clearNow() { vis = 0f; shown = ""; pending = null; color[3] = 0f }

    /**
     * Advances by [dt] seconds; [spin] and [zoomPhase] are the spiral's, [beatHz]
     * the binaural beat's. Leaves [pos], [color] and [eyeOffset] ready to draw.
     */
    fun update(dt: Float, spin: Double, zoomPhase: Double, beatHz: Float) {
        // A new cue
        val seq = Params.i("words.seq")
        if (seq != lastSeq) {
            lastSeq = seq
            fadeS = Params.f("words.fade_s").coerceIn(0.01f, 120f)
            pending = Params.s("words.text").take(600)
        }
        val step = dt / fadeS
        if (pending != null) {
            // What's showing goes first, unless it's the same phrase, already there
            if (shown.isNotEmpty() && vis > 0f) {
                vis = max(0f, vis - step)
            } else {
                shown = pending!!
                pending = null
            }
        } else if (shown.isNotEmpty()) {
            vis = min(1f, vis + step)
        }
        if (shown.isEmpty() || vis <= 0f) { color[3] = 0f; return }

        val size = Params.f("words.size").coerceIn(0.01f, 0.4f)
        val key = "$shown|${Math.round(size * 500)}"
        if (key != shownKey) { upload(shown, size); shownKey = key }

        val speed = Params.f("words.speed").coerceIn(0f, 4f)
        phase = (phase + 2 * PI * speed * 0.25 * dt) % (2 * PI * 1000)
        beatPhase = (beatPhase + 2 * PI * beatHz.coerceIn(0f, StereoRenderer.MAX_PHOTIC_HZ) * dt) % (2 * PI)

        var cx = 0f; var cy = 0f
        var alpha = Params.f("words.opacity").coerceIn(0f, 1f) * vis
        var scale = 1f
        when (Params.s("words.mode")) {
            "breathe" -> alpha *= (0.5 + 0.5 * sin(phase)).toFloat()
            "drift" -> {
                cx = (0.22 * sin(phase * 0.7) + 0.08 * sin(phase * 1.9 + 1.0)).toFloat()
                cy = (0.12 * sin(phase * 1.1 + 2.0) + 0.04 * sin(phase * 2.3)).toFloat()
            }
            "pulse" -> {
                // The beat can be fast, so the brightness part (a light pulse)
                // only goes with the Vessel's light-pulse allowance
                val b = sin(beatPhase).toFloat()
                scale = 1f + 0.08f * b
                if (Params.lightPulse) alpha *= 0.7f + 0.3f * b
            }
            "spiral" -> {
                // Rides the first arm of the spiral: where its brightness peaks
                val arms = Params.i("spiral.arms").coerceIn(1, 12)
                val twist = Params.f("spiral.twist")
                val r = (0.32 + 0.12 * sin(phase * 0.5)).toFloat()
                val th = spin + (PI / 2 + 2 * PI * zoomPhase - twist * ln(r.toDouble())) / arms
                cx = (r * cos(th)).toFloat(); cy = (r * sin(th)).toFloat()
            }
        }
        pos[0] = cx; pos[1] = cy
        pos[2] = bmpW / PX_PER_UNIT / 2 * scale; pos[3] = bmpH / PX_PER_UNIT / 2 * scale
        val c = StereoRenderer.hsv(Params.f("words.hue"), Params.f("words.sat").coerceIn(0f, 1f))
        color[0] = c[0]; color[1] = c[1]; color[2] = c[2]; color[3] = alpha.coerceIn(0f, 1f)
        eyeOffset = Params.f("words.depth").coerceIn(MIN_DEPTH, 1f) * MAX_DISPARITY
    }

    private fun upload(text: String, size: Float) {
        val textPx = max(6f, size * PX_PER_UNIT)
        val paint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.WHITE
            textSize = textPx
            setShadowLayer(textPx * 0.08f, 0f, 0f, Color.argb(200, 0, 0, 0))
        }
        val pad = Math.ceil(textPx * 0.2).toInt() + 2
        val wrap = (1.3f * PX_PER_UNIT).toInt()
        val layout = StaticLayout.Builder.obtain(text, 0, text.length, paint, wrap)
            .setAlignment(Layout.Alignment.ALIGN_CENTER)
            .setMaxLines(max(1, ((MAX_TEX - 2 * pad) / (textPx * 1.25f)).toInt()))
            .build()
        var widest = 1f
        for (i in 0 until layout.lineCount) widest = max(widest, layout.getLineWidth(i))
        bmpW = min(MAX_TEX, Math.ceil(widest.toDouble()).toInt() + 2 * pad)
        bmpH = min(MAX_TEX, layout.height + 2 * pad)
        val bmp = Bitmap.createBitmap(bmpW, bmpH, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bmp)
        canvas.translate((bmpW - layout.width) / 2f, pad.toFloat())
        layout.draw(canvas)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, tex)
        GLUtils.texImage2D(GLES20.GL_TEXTURE_2D, 0, bmp, 0)
        bmp.recycle()
    }

    companion object {
        /** Texture pixels per lens-space unit: about the screen's own resolution. */
        const val PX_PER_UNIT = 900f
        const val MAX_TEX = 2048
        /** Depth 1 puts each eye's copy this far (lens-space units) off centre. */
        const val MAX_DISPARITY = 0.08f
        /** Below this the eyes would have to diverge: nobody can fuse it. */
        const val MIN_DEPTH = -0.05f
    }
}
