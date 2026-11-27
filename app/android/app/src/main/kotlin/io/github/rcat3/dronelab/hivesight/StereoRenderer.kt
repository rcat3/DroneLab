package io.github.rcat3.dronelab.hivesight

import android.graphics.SurfaceTexture
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.opengl.GLSurfaceView
import android.view.Surface
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import javax.microedition.khronos.egl.EGLConfig
import javax.microedition.khronos.opengles.GL10

/**
 * Draws the decoded video into two eye viewports with Cardboard-style barrel
 * pre-distortion. Images are head-locked (the camera is fixed; head tracking
 * would only make the illusion worse).
 *
 * Geometry is physical: lens positions come from mm and the screen's dpi, and
 * distortion radius is measured in tan-angle units (screen distance / 39 mm
 * eye-relief), so k1/k2 match published Cardboard viewer profiles
 * (Cardboard v2: k1 = 0.34, k2 = 0.55).
 */
class StereoRenderer(
    private val pxPerMm: Float,
    /** Current (glided) binaural beat frequency from the audio engine, for photic sync. */
    private val beatHz: () -> Float,
    private val onSurfaceReady: (Surface) -> Unit,
    private val requestRender: () -> Unit,
) : GLSurfaceView.Renderer {

    private var program = 0
    private var oesTex = 0
    private var surfaceTexture: SurfaceTexture? = null
    private val texMatrix = FloatArray(16)
    @Volatile private var frameAvailable = false
    @Volatile var videoW = 0
    @Volatile var videoH = 0
    @Volatile var renderedFrames = 0L; private set
    private var width = 1
    private var height = 1
    private var fade = 0f
    private var lastNs = 0L
    // Animation phases are accumulated here (not computed from absolute time) so
    // changing a speed never makes the pattern jump, and floats never lose precision.
    private var spin = 0.0
    private var zoomPhase = 0.0
    private var photicPhase = 0.0
    private var photicRamp = 0f
    private var hueDrift = 0.0
    /** Guide preview capture; null when not wired up. */
    @Volatile var preview: PreviewVideo? = null
    private var fbo = 0
    private var fboTex = 0
    private var fboW = 0
    private var fboH = 0
    val words = Words()
    /** The exit gesture: black at once, whatever the Guide says. */
    @Volatile var exiting = false
    private lateinit var quad: FloatBuffer
    private val u = HashMap<String, Int>()

    override fun onSurfaceCreated(gl: GL10?, config: EGLConfig?) {
        program = buildProgram(VERT, FRAG)
        for (name in UNIFORMS) u[name] = GLES20.glGetUniformLocation(program, name)
        quad = ByteBuffer.allocateDirect(8 * 4).order(ByteOrder.nativeOrder()).asFloatBuffer()
            .apply { put(floatArrayOf(-1f, -1f, 1f, -1f, -1f, 1f, 1f, 1f)); position(0) }

        val t = IntArray(1)
        GLES20.glGenTextures(1, t, 0)
        oesTex = t[0]
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTex)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)

        words.onSurfaceCreated(::buildProgram)
        fbo = 0; fboTex = 0; fboW = 0; fboH = 0 // new EGL context: old objects are gone

        surfaceTexture?.release()
        val st = SurfaceTexture(oesTex)
        st.setOnFrameAvailableListener { frameAvailable = true; requestRender() }
        surfaceTexture = st
        android.opengl.Matrix.setIdentityM(texMatrix, 0)
        onSurfaceReady(Surface(st))
    }

    override fun onSurfaceChanged(gl: GL10?, w: Int, h: Int) {
        width = w; height = h
    }

    override fun onDrawFrame(gl: GL10?) {
        val st = surfaceTexture ?: return
        if (frameAvailable) {
            frameAvailable = false
            st.updateTexImage()
            st.getTransformMatrix(texMatrix)
            renderedFrames++
        }

        // Smooth fade toward the target over fx.fade_s seconds.
        val now = System.nanoTime()
        val dt = if (lastNs == 0L) 0f else (now - lastNs) / 1e9f
        lastNs = now
        val target = if (videoW == 0) 0f else Params.f("fx.fade").coerceIn(0f, 1f)
        val rate = 1f / Params.f("fx.fade_s").coerceAtLeast(0.01f)
        if (exiting) { fade = 0f; words.clearNow() }
        else fade = if (fade < target) minOf(target, fade + rate * dt) else maxOf(target, fade - rate * dt)

        spin = (spin + 2 * Math.PI * Params.f("spiral.speed") * dt) % (2 * Math.PI)
        zoomPhase = (zoomPhase + Params.f("spiral.zoom_hz") * dt) % 1.0
        val photicHz = (if (Params.b("photic.sync")) beatHz() else Params.f("photic.hz"))
            .coerceIn(0f, MAX_PHOTIC_HZ)
        photicPhase = (photicPhase + 2 * Math.PI * photicHz * dt) % (2 * Math.PI)
        // Photic stimulation always ramps in slowly (3 s) and out quickly (0.3 s).
        photicRamp = if (Params.b("photic.on")) minOf(1f, photicRamp + dt / 3f) else maxOf(0f, photicRamp - dt / 0.3f)
        val cycle = Params.f("photic.hue_cycle_s")
        if (cycle > 0.05f) hueDrift = (hueDrift + dt / cycle) % 1.0
        if (!exiting) words.update(dt, spin, zoomPhase, beatHz())

        GLES20.glViewport(0, 0, width, height)
        GLES20.glClearColor(0f, 0f, 0f, 1f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
        if (videoW == 0 || videoH == 0) return

        GLES20.glUseProgram(program)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTex)
        GLES20.glUniform1i(u["uTex"]!!, 0)

        GLES20.glUniformMatrix4fv(u["uTexMat"]!!, 1, false, texMatrix, 0)
        val pos = GLES20.glGetAttribLocation(program, "aPos")
        GLES20.glEnableVertexAttribArray(pos)
        GLES20.glVertexAttribPointer(pos, 2, GLES20.GL_FLOAT, false, 0, quad)

        // Stereo layout of the incoming frame:
        //   mono  one image for both eyes          sbs  side-by-side, full width per eye
        //   hsbs  side-by-side, squeezed (half)    tb   top-bottom (left eye on top)
        //   htb   top-bottom, squeezed (half)
        val layout = Params.s("stream.layout")
        val sideBySide = layout == "sbs" || layout == "hsbs"
        val topBottom = layout == "tb" || layout == "htb"
        val leftOnly = Params.b("fx.mono")
        val swap = Params.b("fx.swap")
        val eyeW = width / 2
        val sepPx = Params.f("view.lens_sep_mm") * pxPerMm
        val lensY = height / 2f + Params.f("view.lens_y_mm") * pxPerMm
        val radius = EYE_RELIEF_MM * pxPerMm
        val subW = if (sideBySide) 0.5f else 1f
        val subH = if (topBottom) 0.5f else 1f
        val aspect = when (layout) {
            "sbs" -> videoW * 0.5f / videoH
            "tb" -> videoW / (videoH * 0.5f)
            else -> videoW.toFloat() / videoH // mono, and half-* formats stretch back to full
        }
        val halfH = 0.7f * Params.f("view.zoom").coerceAtLeast(0.05f)
        val conv = Params.f("view.convergence")
        val vert = Params.f("view.vertical")

        val kNow = floatArrayOf(Params.f("view.k1"), Params.f("view.k2"))
        GLES20.glUniform2f(u["uK"]!!, kNow[0], kNow[1])
        GLES20.glUniform2f(u["uImgHalf"]!!, halfH * aspect, halfH)
        GLES20.glUniform1f(u["uMirror"]!!, if (Params.b("fx.mirror")) 1f else 0f)
        GLES20.glUniform1f(u["uRot"]!!, if (Params.b("fx.rotate180")) 1f else 0f)
        GLES20.glUniform1f(u["uFade"]!!, fade)
        GLES20.glUniform1f(u["uBright"]!!, Params.f("fx.brightness"))
        GLES20.glUniform1f(u["uContrast"]!!, Params.f("fx.contrast"))
        GLES20.glUniform1f(u["uSat"]!!, Params.f("fx.saturation"))
        GLES20.glUniform3f(u["uTint"]!!, Params.f("fx.tint_r"), Params.f("fx.tint_g"), Params.f("fx.tint_b"))
        GLES20.glUniform1f(u["uInvert"]!!, if (Params.b("fx.invert")) 1f else 0f)
        GLES20.glUniform1f(u["uVignette"]!!, Params.f("fx.vignette"))
        GLES20.glUniform1f(u["uGrid"]!!, if (Params.b("view.grid")) 1f else 0f)
        GLES20.glUniform1f(u["uEdge"]!!, (height / 2f) / radius)

        val sp = hsv(Params.f("spiral.hue"), Params.f("spiral.sat"))
        GLES20.glUniform4f(u["uSpiral"]!!, Params.f("spiral.amount").coerceIn(0f, 1f), spin.toFloat(),
            Params.i("spiral.arms").coerceIn(1, 12).toFloat(), Params.f("spiral.twist"))
        GLES20.glUniform2f(u["uSpiral2"]!!, 1.0f - 0.97f * Params.f("spiral.sharp").coerceIn(0f, 1f),
            zoomPhase.toFloat())
        GLES20.glUniform3f(u["uSpiralColor"]!!, sp[0], sp[1], sp[2])
        val pc = hsv(((Params.f("photic.hue") + hueDrift) % 1.0).toFloat(), Params.f("photic.sat"))
        GLES20.glUniform3f(u["uPhoticColor"]!!, pc[0], pc[1], pc[2])
        val pDepth = Params.f("photic.depth").coerceIn(0f, 1f) * photicRamp
        val pAmount = Params.f("photic.amount").coerceIn(0f, 1f) * photicRamp
        val alternate = Params.b("photic.alternate")

        // Draws both eyes into the current framebuffer at `s` x screen resolution.
        // All pixel-space uniforms scale with it, so the image is identical, just smaller.
        fun drawEyes(s: Float) {
          GLES20.glUniform1f(u["uR"]!!, radius * s)
          val ew = Math.round(eyeW * s)
          val eh = Math.round(height * s)
          for (eye in 0..1) { // 0 = left, 1 = right
            val x0 = eye * ew
            GLES20.glViewport(x0, 0, ew, eh)
            GLES20.glUniform2f(u["uOrigin"]!!, x0.toFloat(), 0f)
            // Lens centre in viewport-local px: the lenses sit symmetric about the screen centre.
            val lensX = if (eye == 0) width / 2f - sepPx / 2f else sepPx / 2f
            GLES20.glUniform2f(u["uLens"]!!, lensX * s, lensY * s)
            var srcEye = if (swap) 1 - eye else eye
            if (leftOnly || !(sideBySide || topBottom)) srcEye = 0
            val u0 = if (sideBySide) srcEye * 0.5f else 0f
            // Texture v runs bottom-up, so the top half (left eye) starts at 0.5.
            val v0 = if (topBottom) (if (srcEye == 0) 0.5f else 0f) else 0f
            GLES20.glUniform4f(u["uEyeRect"]!!, u0, subW, v0, subH)
            val sign = if (eye == 0) 1f else -1f
            GLES20.glUniform2f(u["uShift"]!!, sign * conv, sign * vert * 0.5f)
            // Smooth (sinusoidal) brightness pulse; alternate mode puts the eyes in anti-phase.
            val ph = photicPhase + if (alternate && eye == 1) Math.PI else 0.0
            val pulse = 1f - pDepth * (0.5f - 0.5f * kotlin.math.sin(ph).toFloat())
            GLES20.glUniform2f(u["uPhotic"]!!, pAmount, pulse)
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
            // The words, over it, through the same lens
            words.drawEye(quad, x0.toFloat(), lensX * s, lensY * s, radius * s, kNow[0], kNow[1], sign, fade)
            GLES20.glUseProgram(program)
            GLES20.glEnableVertexAttribArray(pos)
            GLES20.glVertexAttribPointer(pos, 2, GLES20.GL_FLOAT, false, 0, quad)
          }
        }

        drawEyes(1f)

        // Guide preview: redraw small into an offscreen buffer, after the real
        // frame, so the Vessel's display is never delayed. Lens distortion is
        // switched off here: the lenses cancel it, so the flat image is closer to
        // what the Vessel actually perceives.
        val pv = preview
        if (pv != null && pv.due(now)) {
            val pw = PREVIEW_WIDTH
            val ph = Math.round(PREVIEW_WIDTH.toFloat() * height / width)
            ensureFbo(pw, ph)
            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, fbo)
            GLES20.glViewport(0, 0, pw, ph)
            GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
            GLES20.glUniform2f(u["uK"]!!, 0f, 0f)
            kNow[0] = 0f; kNow[1] = 0f
            drawEyes(pw.toFloat() / width)
            val buf = pv.buffer(pw, ph)
            GLES20.glReadPixels(0, 0, pw, ph, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, buf)
            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
            pv.submit(buf, pw, ph)
        }
        GLES20.glDisableVertexAttribArray(pos)
    }

    private fun ensureFbo(w: Int, h: Int) {
        if (fbo != 0 && fboW == w && fboH == h) return
        if (fbo != 0) {
            GLES20.glDeleteFramebuffers(1, intArrayOf(fbo), 0)
            GLES20.glDeleteTextures(1, intArrayOf(fboTex), 0)
        }
        val t = IntArray(1)
        GLES20.glGenTextures(1, t, 0); fboTex = t[0]
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, fboTex)
        GLES20.glTexImage2D(GLES20.GL_TEXTURE_2D, 0, GLES20.GL_RGBA, w, h, 0,
            GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, null)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
        GLES20.glGenFramebuffers(1, t, 0); fbo = t[0]
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, fbo)
        GLES20.glFramebufferTexture2D(GLES20.GL_FRAMEBUFFER, GLES20.GL_COLOR_ATTACHMENT0,
            GLES20.GL_TEXTURE_2D, fboTex, 0)
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
        // Leave the video texture bound on unit 0 for the draw that follows.
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTex)
        fboW = w; fboH = h
    }

    fun release() {
        surfaceTexture?.release()
        surfaceTexture = null
    }

    private fun buildProgram(vs: String, fs: String): Int {
        fun compile(type: Int, src: String): Int {
            val s = GLES20.glCreateShader(type)
            GLES20.glShaderSource(s, src)
            GLES20.glCompileShader(s)
            val ok = IntArray(1)
            GLES20.glGetShaderiv(s, GLES20.GL_COMPILE_STATUS, ok, 0)
            check(ok[0] != 0) { "shader compile failed: " + GLES20.glGetShaderInfoLog(s) }
            return s
        }
        val p = GLES20.glCreateProgram()
        GLES20.glAttachShader(p, compile(GLES20.GL_VERTEX_SHADER, vs))
        GLES20.glAttachShader(p, compile(GLES20.GL_FRAGMENT_SHADER, fs))
        GLES20.glLinkProgram(p)
        val ok = IntArray(1)
        GLES20.glGetProgramiv(p, GLES20.GL_LINK_STATUS, ok, 0)
        check(ok[0] != 0) { "link failed: " + GLES20.glGetProgramInfoLog(p) }
        return p
    }

    companion object {
        /** Lens-to-screen distance used to convert screen mm into tan-angle units. */
        const val EYE_RELIEF_MM = 39f

        private val UNIFORMS = listOf(
            "uTex", "uTexMat", "uOrigin", "uLens", "uR", "uK", "uImgHalf", "uEyeRect", "uShift",
            "uMirror", "uRot", "uFade", "uBright", "uContrast", "uSat", "uTint", "uInvert",
            "uVignette", "uGrid", "uEdge", "uSpiral", "uSpiral2", "uSpiralColor",
            "uPhotic", "uPhoticColor",
        )

        /** Flicker ceiling. Above this a 120 Hz display can't render a clean sine anyway. */
        const val MAX_PHOTIC_HZ = 30f
        const val PREVIEW_WIDTH = 640

        fun hsv(h: Float, s: Float, v: Float = 1f): FloatArray {
            val hh = ((h % 1f) + 1f) % 1f * 6f
            val i = hh.toInt()
            val f = hh - i
            val p = v * (1 - s); val q = v * (1 - s * f); val t = v * (1 - s * (1 - f))
            return when (i) {
                0 -> floatArrayOf(v, t, p); 1 -> floatArrayOf(q, v, p); 2 -> floatArrayOf(p, v, t)
                3 -> floatArrayOf(p, q, v); 4 -> floatArrayOf(t, p, v); else -> floatArrayOf(v, p, q)
            }
        }

        private const val VERT = """
            attribute vec2 aPos;
            void main() { gl_Position = vec4(aPos, 0.0, 1.0); }
        """

        private const val FRAG = """
            #extension GL_OES_EGL_image_external : require
            precision highp float;
            uniform samplerExternalOES uTex;
            uniform mat4 uTexMat;
            uniform vec2 uOrigin;   // viewport origin (px)
            uniform vec2 uLens;     // lens centre within viewport (px)
            uniform float uR;       // px per tan-angle unit
            uniform vec2 uK;        // radial distortion k1, k2
            uniform vec2 uImgHalf;  // half extent of the image, tan-angle units
            uniform vec4 uEyeRect;  // u0, width, v0, height of this eye in the texture
            uniform vec2 uShift;    // convergence / vertical alignment (image units)
            uniform float uMirror, uRot, uFade, uBright, uContrast, uSat, uInvert, uVignette, uGrid, uEdge;
            uniform vec3 uTint;
            uniform vec4 uSpiral;       // amount, spin angle, arms, twist
            uniform vec2 uSpiral2;      // edge softness, zoom phase (0..1)
            uniform vec3 uSpiralColor;
            uniform vec2 uPhotic;       // amount (colour field mix), pulse brightness for this eye
            uniform vec3 uPhoticColor;

            void main() {
                vec2 p = (gl_FragCoord.xy - uOrigin - uLens) / uR;
                float r2 = dot(p, p);
                vec2 q = p * (1.0 + uK.x * r2 + uK.y * r2 * r2);
                vec2 uv = q / (2.0 * uImgHalf) + 0.5 + uShift;
                if (uRot > 0.5) uv = 1.0 - uv;
                if (uMirror > 0.5) uv.x = 1.0 - uv.x;
                bool inside = uv.x >= 0.0 && uv.y >= 0.0 && uv.x <= 1.0 && uv.y <= 1.0;
                vec3 c = vec3(0.0);
                if (inside) {
                    vec2 tc = vec2(uEyeRect.x + uv.x * uEyeRect.y, uEyeRect.z + uv.y * uEyeRect.w);
                    c = texture2D(uTex, (uTexMat * vec4(tc, 0.0, 1.0)).xy).rgb;
                    c = (c - 0.5) * uContrast + 0.5 + uBright;
                    float l = dot(c, vec3(0.299, 0.587, 0.114));
                    c = mix(vec3(l), c, uSat) * uTint;
                    c = mix(c, 1.0 - c, uInvert);
                }

                // Logarithmic spiral centred on the lens (drawn in undistorted lens space,
                // so it is perfectly round through the optics).
                if (uSpiral.x > 0.001) {
                    float r = max(length(q), 1e-4);
                    float th = atan(q.y, q.x);
                    float v = sin(uSpiral.z * (th - uSpiral.y) + uSpiral.w * log(r) - 6.2831853 * uSpiral2.y);
                    float s = smoothstep(-uSpiral2.x, uSpiral2.x, v);
                    s = mix(0.5, s, smoothstep(0.0, 0.08, r)); // avoid aliasing at the centre
                    c = mix(c, uSpiralColor * s, uSpiral.x);
                }

                // Light-and-sound-machine colour field + brightness pulse.
                c = mix(c, uPhoticColor, uPhotic.x) * uPhotic.y;

                if (inside && uGrid > 0.5) {
                    // Lines every 0.1 in image space: should look straight through the lens
                    // when k1/k2 are right.
                    vec2 g = abs(fract(uv * 10.0 + 0.5) - 0.5);
                    float line = 1.0 - smoothstep(0.0, 0.03, min(g.x, g.y));
                    c = mix(c, vec3(0.2, 1.0, 0.4), line * 0.8);
                }

                float edge = length(p) / uEdge;
                c *= 1.0 - uVignette * smoothstep(0.55, 1.05, edge);
                gl_FragColor = vec4(clamp(c, 0.0, 1.0) * uFade, 1.0);
            }
        """
    }
}
