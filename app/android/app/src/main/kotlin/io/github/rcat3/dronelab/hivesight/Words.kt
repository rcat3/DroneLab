package io.github.rcat3.dronelab.hivesight

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.opengl.GLES20
import android.opengl.GLUtils
import android.text.Layout
import android.text.SpannableString
import android.text.Spanned
import android.text.StaticLayout
import android.text.TextPaint
import android.text.style.ForegroundColorSpan
import org.json.JSONObject
import java.nio.FloatBuffer
import java.util.concurrent.ConcurrentLinkedQueue
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

/**
 * One phrase and how it looks and moves, as the Guide cued it. Every field
 * is checked and limited here, whatever the Guide sent.
 */
class Cue(j: JSONObject) {
    val text = j.optString("text").take(600)
    val font = j.optString("font", "sans").let { if (it in FONTS) it else "sans" }
    val bold = j.optBoolean("bold")
    val italic = j.optBoolean("italic")
    val underline = j.optBoolean("underline")
    val rgb: FloatArray = parseColor(j.optString("color", "#ffffff"))
    val size = j.optDouble("size", 0.12).toFloat().coerceIn(0.01f, 0.4f)
    val opacity = j.optDouble("opacity", 1.0).toFloat().coerceIn(0f, 1f)
    val fade = j.optDouble("fade", 1.0).toFloat().coerceIn(0f, 120f)
    val mode = j.optString("mode", "still")
    val speed = j.optDouble("speed", 0.5).toFloat().coerceIn(0f, 4f)
    val depth = j.optDouble("depth", 0.0).toFloat().coerceIn(0f, 1f)
    val x = j.optDouble("x", 0.0).toFloat().coerceIn(-1f, 1f)
    val y = j.optDouble("y", 0.0).toFloat().coerceIn(-1f, 1f)
    val yaw = j.optDouble("yaw", 0.0).toFloat().coerceIn(-180f, 180f)
    val pitch = j.optDouble("pitch", 0.0).toFloat().coerceIn(-180f, 180f)
    val roll = j.optDouble("roll", 0.0).toFloat().coerceIn(-180f, 180f)
    val distort = DISTORTIONS.indexOf(j.optString("distort", "none")).coerceAtLeast(0)
    val distAmount = j.optDouble("dist_amount", 0.5).toFloat().coerceIn(0f, 1f)
    val distFreq = j.optDouble("dist_freq", 0.5).toFloat().coerceIn(0f, 1f)
    val distSpeed = j.optDouble("dist_speed", 1.0).toFloat().coerceIn(0f, 4f)
    val crt = j.optBoolean("crt")
    val cursor = j.optBoolean("cursor")
    /** Types out letter by letter, like the unit's terminal; [typeSpeed] letters a second to start with. */
    val typing = j.optBoolean("typing")
    val typeSpeed = j.optDouble("type_speed", 25.0).toFloat().coerceIn(2f, 120f)
    /** A change to a phrase that's already showing: no fade out and in. */
    val update = j.optBoolean("update")

    /** What the texture depends on: a different key means redrawing it. */
    val key = "$text|$font|$bold|$italic|$underline|${Math.round(size * 500)}|$crt|$cursor|$typing"

    companion object {
        val FONTS = setOf("sans", "serif", "mono", "cursive", "casual", "condensed")
        val DISTORTIONS = listOf("none", "wave", "ripple", "wobble", "glitch")

        fun parseColor(s: String): FloatArray {
            val c = runCatching { Color.parseColor(if (s.startsWith("#")) s else "#$s") }.getOrDefault(Color.WHITE)
            return floatArrayOf(Color.red(c) / 255f, Color.green(c) / 255f, Color.blue(c) / 255f)
        }
    }
}

/**
 * The words layer: up to [LAYERS] phrases at once, each drawn as a plane in
 * 3D in front of each eye (perspective, rotation, depth, distortion), after
 * the picture and its effects. Each layer fades its old phrase out and the
 * new one in over the new cue's fade. The Guide times everything.
 *
 * A cue gets its depth as "nearness" (1 / distance): 0 is as far as the
 * lenses go, 1 is nearest, and the stereo offset between the eyes is
 * proportional to it. Size is how big it looks at rest, whatever the depth,
 * so moving it nearer or further changes how big it looks.
 *
 * Messages arrive on the network thread and are queued; everything else
 * runs on the GL thread.
 */
class Words {
    private sealed interface Cmd
    private class Show(val layer: Int, val cue: Cue) : Cmd
    private class Clear(val layers: List<Int>, val fade: Float) : Cmd

    private val queue = ConcurrentLinkedQueue<Cmd>()
    private val layers = Array(LAYERS) { Layer() }
    private var program = 0
    private val u = HashMap<String, Int>()
    private var blinkOn = true
    private var distClock = 0.0

    fun show(layer: Int, j: JSONObject) {
        if (layer !in 0 until LAYERS) return
        queue.add(Show(layer, Cue(j)))
    }

    fun clear(layerList: List<Int>?, fade: Float) {
        queue.add(Clear(layerList ?: (0 until LAYERS).toList(), fade.coerceIn(0f, 120f)))
    }

    fun onSurfaceCreated(build: (String, String) -> Int) {
        program = build(VERT, FRAG)
        for (n in UNIFORMS) u[n] = GLES20.glGetUniformLocation(program, n)
        for (l in layers) l.contextLost()
    }

    /** Immediately gone (the exit gesture). */
    fun clearNow() {
        queue.clear()
        for (l in layers) l.clearNow()
    }

    fun update(dt: Float, spin: Double, zoomPhase: Double, beatHz: Float) {
        while (true) {
            when (val c = queue.poll() ?: break) {
                is Show -> layers[c.layer].show(c.cue)
                is Clear -> for (n in c.layers) layers[n].clear(c.fade)
            }
        }
        blinkOn = (System.nanoTime() / 530_000_000L) % 2L == 0L
        distClock += dt
        for (l in layers) l.update(dt, spin, zoomPhase, beatHz)
    }

    /**
     * Draws every layer for one eye into the current viewport, over what's
     * there. [sign] is +1 for the left eye, -1 for the right; the rest is
     * what the picture's own shader is given for this eye. Leaves the
     * blend off; the caller picks its own program again.
     */
    fun drawEye(
        quad: FloatBuffer, originX: Float, lensX: Float, lensY: Float, radius: Float,
        k1: Float, k2: Float, sign: Float, fade: Float,
    ) {
        if (layers.none { it.drawable }) return
        GLES20.glUseProgram(program)
        GLES20.glEnable(GLES20.GL_BLEND)
        GLES20.glBlendFunc(GLES20.GL_ONE, GLES20.GL_ONE_MINUS_SRC_ALPHA)
        val pos = GLES20.glGetAttribLocation(program, "aPos")
        GLES20.glEnableVertexAttribArray(pos)
        GLES20.glVertexAttribPointer(pos, 2, GLES20.GL_FLOAT, false, 0, quad)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glUniform1i(u["uTex"]!!, 0)
        GLES20.glUniform2f(u["uOrigin"]!!, originX, 0f)
        GLES20.glUniform2f(u["uLens"]!!, lensX, lensY)
        GLES20.glUniform1f(u["uR"]!!, radius)
        GLES20.glUniform2f(u["uK"]!!, k1, k2)
        GLES20.glUniform1f(u["uEyeX"]!!, -sign * EYE_HALF)
        for (l in layers) if (l.drawable) l.draw(this, fade)
        GLES20.glDisableVertexAttribArray(pos)
        GLES20.glDisable(GLES20.GL_BLEND)
    }

    private fun hash(n: Int): Float {
        var h = n * 374761393 + 668265263
        h = (h xor (h ushr 13)) * 1274126177
        return ((h xor (h ushr 16)) and 0xFFFF) / 65535f
    }

    private inner class Layer {
        var shown: Cue? = null
        private var pending: Cue? = null
        private var pendingClear = false
        private var vis = 0f
        private var fadeS = 1f
        private var texA = 0
        private var texB = 0
        private var shownKey = ""
        private var bmpW = 1
        private var bmpH = 1
        private var phase = 0.0
        private var beatPhase = 0.0
        private var dist = 0.0
        private var cx = 0f; private var cy = 0f
        private var nz = 0.5f; private var nzRest = 0.5f
        private var scale = 1f
        private var alpha = 0f
        private val rot = FloatArray(9)
        private var useB = false
        // Typing out: how many letters are showing, and where the text sits in its texture
        private var typed = 0f
        private var layout: StaticLayout? = null
        private var layoutDx = 0f
        private var layoutPad = 0
        private var textPx = 12f

        val drawable get() = shown != null && alpha > 0.002f && texA != 0

        fun contextLost() { texA = 0; texB = 0; shownKey = "" }

        fun clearNow() {
            shown = null; pending = null; pendingClear = false; vis = 0f; alpha = 0f
            release()
        }

        fun show(c: Cue) {
            val cur = shown
            if (c.update && cur != null && cur.text.isNotEmpty() && pending == null) {
                shown = c // the same phrase, looking different
                return
            }
            pending = c; pendingClear = false; fadeS = max(c.fade, 0.01f)
        }

        fun clear(fade: Float) {
            if (shown == null && pending == null) return
            pending = null; pendingClear = true; fadeS = max(fade, 0.01f)
        }

        private fun release() {
            if (texA != 0) GLES20.glDeleteTextures(1, intArrayOf(texA), 0)
            if (texB != 0) GLES20.glDeleteTextures(1, intArrayOf(texB), 0)
            texA = 0; texB = 0; shownKey = ""
        }

        fun update(dt: Float, spin: Double, zoomPhase: Double, beatHz: Float) {
            val step = dt / fadeS
            if (pending != null || pendingClear) {
                if (shown != null && vis > 0f) {
                    vis = max(0f, vis - step)
                } else {
                    shown = pending
                    typed = 0f
                    pending = null
                    if (pendingClear) release()
                    pendingClear = false
                }
            } else if (shown != null) {
                vis = min(1f, vis + step)
            }
            val c = shown
            if (c == null || c.text.isEmpty() || vis <= 0f) { alpha = 0f; return }
            if (c.key != shownKey) { upload(c); shownKey = c.key }
            useB = c.cursor && !c.typing && !blinkOn
            if (c.typing) {
                val len = c.text.length
                if (typed < len) {
                    // The unit's pace (more at a time the more is left), with the
                    // odd hesitation of a modem
                    val boost = 1f + (len - typed) / 120f
                    val jitter = 0.45f + 1.1f * hash(typed.toInt())
                    typed = min(len.toFloat(), typed + dt * c.typeSpeed * boost * jitter)
                } else typed = len.toFloat()
            }

            phase = (phase + 2 * PI * c.speed * 0.25 * dt) % (2 * PI * 1000)
            beatPhase = (beatPhase + 2 * PI * beatHz.coerceIn(0f, StereoRenderer.MAX_PHOTIC_HZ) * dt) % (2 * PI)
            dist += c.distSpeed * dt

            var ox = 0f; var oy = 0f; var dn = 0f
            var yaw = Math.toRadians(c.yaw.toDouble()); var pitch = Math.toRadians(c.pitch.toDouble())
            var roll = Math.toRadians(c.roll.toDouble())
            var a = c.opacity * vis
            var sc = 1f
            when (c.mode) {
                "breathe" -> a *= (0.5 + 0.5 * sin(phase)).toFloat()
                "drift" -> {
                    ox = (0.22 * sin(phase * 0.7) + 0.08 * sin(phase * 1.9 + 1.0)).toFloat()
                    oy = (0.12 * sin(phase * 1.1 + 2.0) + 0.04 * sin(phase * 2.3)).toFloat()
                }
                "pulse" -> {
                    // The beat can be fast, so the brightness part (a light pulse)
                    // only goes with the Vessel's light-pulse allowance
                    val b = sin(beatPhase).toFloat()
                    sc = 1f + 0.08f * b
                    if (Params.lightPulse) a *= 0.7f + 0.3f * b
                }
                "spiral" -> {
                    // Rides the first arm of the spiral: where its brightness peaks
                    val arms = Params.i("spiral.arms").coerceIn(1, 12)
                    val twist = Params.f("spiral.twist")
                    val r = (0.32 + 0.12 * sin(phase * 0.5)).toFloat()
                    val th = spin + (PI / 2 + 2 * PI * zoomPhase - twist * ln(r.toDouble())) / arms
                    ox = (r * cos(th)).toFloat(); oy = (r * sin(th)).toFloat()
                }
                "orbit" -> { // round a point in front of you, turning to face along it
                    ox = (0.3 * sin(phase)).toFloat(); dn = (0.3 * cos(phase)).toFloat()
                    yaw += 0.6 * sin(phase)
                }
                "approach" -> dn = (0.45 * sin(phase)).toFloat() // nearer and further
                "tumble" -> { yaw += phase; pitch += 0.5 * sin(phase * 0.7); roll += 0.2 * sin(phase * 0.4) }
                "sway" -> {
                    yaw += 0.5 * sin(phase); roll += 0.12 * sin(phase * 0.5)
                    ox = (0.06 * sin(phase * 0.5)).toFloat()
                }
            }
            cx = c.x * 0.5f + ox; cy = c.y * 0.4f + oy
            nzRest = max(c.depth, MIN_NEAR)
            nz = (nzRest + dn).coerceIn(MIN_NEAR, 1f)
            scale = sc
            alpha = a.coerceIn(0f, 1f)
            // Local axes in the world: yaw about Y, then pitch about X, then roll about Z
            val cyw = cos(yaw).toFloat(); val syw = sin(yaw).toFloat()
            val cp = cos(pitch).toFloat(); val sp = sin(pitch).toFloat()
            val cr = cos(roll).toFloat(); val sr = sin(roll).toFloat()
            // R = Ry * Rx * Rz, columns = images of x, y, z
            rot[0] = cyw * cr + syw * sp * sr; rot[1] = cp * sr; rot[2] = -syw * cr + cyw * sp * sr
            rot[3] = -cyw * sr + syw * sp * cr; rot[4] = cp * cr; rot[5] = syw * sr + cyw * sp * cr
            rot[6] = syw * cp; rot[7] = -sp; rot[8] = cyw * cp
        }

        fun draw(w: Words, fade: Float) {
            val c = shown ?: return
            val z = 1f / nz
            val z0 = 1f / nzRest
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, if (useB && texB != 0) texB else texA)
            GLES20.glUniform3f(u["uC"]!!, cx * z, cy * z, z)
            GLES20.glUniformMatrix3fv(u["uRot"]!!, 1, false, rot, 0)
            GLES20.glUniform2f(u["uHalf"]!!, bmpW / PX_PER_UNIT / 2 * z0 * scale, bmpH / PX_PER_UNIT / 2 * z0 * scale)
            GLES20.glUniform4f(u["uColor"]!!, c.rgb[0], c.rgb[1], c.rgb[2], alpha * fade)
            GLES20.glUniform4f(u["uDist"]!!, c.distort.toFloat(), c.distAmount, 2f + c.distFreq * 10f, dist.toFloat())
            GLES20.glUniform1f(u["uCrt"]!!, if (c.crt) bmpH.toFloat() else 0f)
            GLES20.glUniform2f(u["uBmp"]!!, bmpW.toFloat(), bmpH.toFloat())
            val lay = layout
            if (c.typing && lay != null && c.text.isNotEmpty()) {
                val len = c.text.length
                val n = min(typed.toInt(), len)
                val line = lay.getLineForOffset(n)
                val top = lay.getLineTop(line) + layoutPad.toFloat()
                val bottom = lay.getLineBottom(line) + layoutPad.toFloat()
                val x = lay.getPrimaryHorizontal(n) + layoutDx
                val typingNow = typed < len
                GLES20.glUniform4f(u["uReveal"]!!, top, bottom, x, if (typingNow) 1f else 0f)
                // The cursor is solid while it types, then blinks
                GLES20.glUniform3f(u["uCur"]!!, textPx * 0.55f, if (c.cursor) 1f else 0f, if (typingNow || blinkOn) 1f else 0f)
            } else {
                GLES20.glUniform4f(u["uReveal"]!!, 0f, 0f, 0f, 0f)
                GLES20.glUniform3f(u["uCur"]!!, 0f, 0f, 0f)
            }
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        }

        private fun upload(c: Cue) {
            val textPx = max(6f, c.size * PX_PER_UNIT)
            val style = (if (c.bold) Typeface.BOLD else 0) or (if (c.italic) Typeface.ITALIC else 0)
            val face = when (c.font) {
                "serif" -> Typeface.create(Typeface.SERIF, style)
                "mono" -> Typeface.create(Typeface.MONOSPACE, style)
                "cursive" -> Typeface.create("cursive", style)
                "casual" -> Typeface.create("casual", style)
                "condensed" -> Typeface.create("sans-serif-condensed", style)
                else -> Typeface.create(Typeface.SANS_SERIF, style)
            }
            val paint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
                color = Color.WHITE
                textSize = textPx
                typeface = face
                isUnderlineText = c.underline
                // The glow of a CRT is the text's own colour; otherwise a soft dark edge
                if (c.crt) setShadowLayer(textPx * 0.25f, 0f, 0f, Color.argb(170, 255, 255, 255))
                else setShadowLayer(textPx * 0.08f, 0f, 0f, Color.argb(200, 0, 0, 0))
            }
            val pad = Math.ceil(textPx * 0.3).toInt() + 2
            val full = if (c.cursor && !c.typing) c.text + CURSOR else c.text
            val wrap = (1.3f * PX_PER_UNIT).toInt()
            val align = if (c.crt) Layout.Alignment.ALIGN_NORMAL else Layout.Alignment.ALIGN_CENTER
            val maxLines = max(1, ((MAX_TEX - 2 * pad) / (textPx * 1.25f)).toInt())
            fun layoutOf(t: CharSequence) = StaticLayout.Builder.obtain(t, 0, t.length, paint, wrap)
                .setAlignment(align).setMaxLines(maxLines).build()

            val layoutA = layoutOf(full)
            var widest = 1f
            for (i in 0 until layoutA.lineCount) widest = max(widest, layoutA.getLineWidth(i))
            bmpW = min(MAX_TEX, Math.ceil(widest.toDouble()).toInt() + 2 * pad)
            bmpH = min(MAX_TEX, layoutA.height + 2 * pad)

            fun draw(layout: StaticLayout, tex: Int): Int {
                val bmp = Bitmap.createBitmap(bmpW, bmpH, Bitmap.Config.ARGB_8888)
                val canvas = Canvas(bmp)
                val dx = if (c.crt) (bmpW - widest) / 2f else (bmpW - layout.width) / 2f
                canvas.translate(dx, pad.toFloat())
                layout.draw(canvas)
                var id = tex
                if (id == 0) {
                    val t = IntArray(1)
                    GLES20.glGenTextures(1, t, 0)
                    id = t[0]
                }
                GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, id)
                GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
                GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
                GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
                GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
                GLUtils.texImage2D(GLES20.GL_TEXTURE_2D, 0, bmp, 0)
                bmp.recycle()
                return id
            }
            texA = draw(layoutA, texA)
            layout = layoutA
            layoutPad = pad
            layoutDx = if (c.crt) (bmpW - widest) / 2f else (bmpW - layoutA.width) / 2f
            this.textPx = textPx
            typed = min(typed, c.text.length.toFloat())
            if (c.cursor && !c.typing) {
                // The same, with the cursor's block clear: it blinks between the two
                val s = SpannableString(full)
                s.setSpan(ForegroundColorSpan(Color.TRANSPARENT), full.length - 1, full.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                texB = draw(layoutOf(s), texB)
            } else if (texB != 0) {
                GLES20.glDeleteTextures(1, intArrayOf(texB), 0)
                texB = 0
            }
        }
    }

    companion object {
        const val LAYERS = 8
        /** Texture pixels per lens-space unit: about the screen's own resolution. */
        const val PX_PER_UNIT = 900f
        const val MAX_TEX = 1536
        /** Half the distance between the eyes, in the units of distance (1 / nearness). */
        const val EYE_HALF = 0.08f
        /** As far as it gets (beyond this the stereo offset would be nothing anyway). */
        const val MIN_NEAR = 0.01f
        private const val CURSOR = "█"

        private val UNIFORMS = listOf(
            "uTex", "uOrigin", "uLens", "uR", "uK", "uEyeX", "uC", "uRot", "uHalf", "uColor", "uDist", "uCrt", "uBmp", "uReveal", "uCur",
        )

        private const val VERT = """
            attribute vec2 aPos;
            void main() { gl_Position = vec4(aPos, 0.0, 1.0); }
        """

        // Same lens space as the picture's shader: the pixel's ray through the
        // eye, meeting the phrase's plane in 3D.
        private const val FRAG = """
            precision highp float;
            uniform sampler2D uTex;
            uniform vec2 uOrigin;
            uniform vec2 uLens;
            uniform float uR;
            uniform vec2 uK;
            uniform float uEyeX;     // the eye's place sideways
            uniform vec3 uC;         // the plane's centre
            uniform mat3 uRot;       // columns: the plane's x, y and normal
            uniform vec2 uHalf;      // half width, height
            uniform vec4 uColor;     // rgb, alpha
            uniform vec4 uDist;      // kind, amount, frequency, clock
            uniform float uCrt;
            uniform vec2 uBmp;       // the texture's size in pixels
            uniform vec4 uReveal;    // typing: top and bottom of the line being typed, how far along it, on
            uniform vec3 uCur;       // typing cursor: width, wanted, showing

            float hash(float n) { return fract(sin(n) * 43758.5453); }

            void main() {
                vec2 p = (gl_FragCoord.xy - uOrigin - uLens) / uR;
                float r2 = dot(p, p);
                vec2 q = p * (1.0 + uK.x * r2 + uK.y * r2 * r2);
                vec3 o = vec3(uEyeX, 0.0, 0.0);
                vec3 d = vec3(q, 1.0);
                vec3 n = uRot[2];
                float nd = dot(n, d);
                if (abs(nd) < 1e-4) discard;
                float t = dot(n, uC - o) / nd;
                if (t <= 0.0) discard;
                vec3 pt = o + t * d - uC;
                vec2 l = vec2(dot(uRot[0], pt), dot(uRot[1], pt));
                vec2 uv = vec2(0.5 + l.x / (2.0 * uHalf.x), 0.5 - l.y / (2.0 * uHalf.y));

                float kind = uDist.x, amt = uDist.y, fr = uDist.z, clk = uDist.w;
                if (kind > 0.5 && kind < 1.5) {                 // wave
                    uv.x += amt * 0.06 * sin(uv.y * fr * 3.0 + clk * 3.0);
                } else if (kind < 2.5 && kind > 1.5) {          // ripple
                    vec2 c = (uv - 0.5) * vec2(uHalf.x / uHalf.y, 1.0);
                    float rr = length(c);
                    uv += normalize(c + 1e-5) * amt * 0.04 * sin(rr * fr * 4.0 - clk * 3.0);
                } else if (kind < 3.5 && kind > 2.5) {          // wobble
                    uv += amt * 0.05 * vec2(sin(uv.y * 3.0 + clk * 1.3), sin(uv.x * 3.0 + clk));
                } else if (kind > 3.5) {                        // glitch
                    float row = floor(uv.y * fr * 4.0);
                    float h = hash(row * 12.9898 + floor(clk * 4.0) * 78.233);
                    if (h > 0.8) uv.x += (h - 0.9) * amt * 0.5;
                }
                if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) discard;
                vec4 w = texture2D(uTex, uv);   // premultiplied
                vec2 px = uv * uBmp;
                if (uReveal.w > 0.5 && (px.y >= uReveal.y || (px.y >= uReveal.x && px.x >= uReveal.z))) w = vec4(0.0);
                if (uCur.y > 0.5 && uCur.z > 0.5 && px.y >= uReveal.x && px.y < uReveal.y &&
                    px.x >= uReveal.z && px.x < uReveal.z + uCur.x) w = vec4(1.0);
                float a = uColor.a;
                if (uCrt > 0.5) {
                    // scanlines, one every 3 texture pixels (uCrt is the texture's height)
                    a *= 0.8 + 0.2 * sin(uv.y * uCrt * 2.0944);
                }
                gl_FragColor = vec4(w.rgb * uColor.rgb * a, w.a * a);
            }
        """
    }
}
