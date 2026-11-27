package io.github.rcat3.dronelab.hivesight

import android.content.Context
import org.json.JSONObject
import java.util.concurrent.ConcurrentHashMap

/**
 * Flat, thread-safe store of everything the Guide console can change,
 * keyed by dotted path ("fx.fade", "beats.carrier_hz", ...). Mirrors the
 * sender's state tree. Read from GL, audio and decoder threads; written by
 * the control client.
 *
 * The "view.*" section is the lens calibration for this phone + viewer, so it
 * is persisted locally and offered to the sender on connect.
 *
 * The light pulse ("photic.on") stays off unless the Vessel allows this
 * Guide it ([lightPulse], from Permissions when the session was joined).
 */
object Params {
    private val map = ConcurrentHashMap<String, Any>()
    private const val PREFS = "hivesight"
    private var appContext: Context? = null
    @Volatile var lightPulse = false
        set(v) { field = v; if (!v) map["photic.on"] = false }

    private val DEFAULTS = mapOf<String, Any>(
        "mix.master" to 1.0, "mix.voice_vol" to 0.9, "mix.voice_pan" to 0.0,
        "mix.autopan_hz" to 0.0, "mix.beats_vol" to 0.25, "mix.noise_vol" to 0.0, "mix.media_vol" to 1.0,
        "mix.jitter_ms" to 40,
        "beats.on" to true, "beats.carrier_hz" to 200.0, "beats.beat_hz" to 6.0,
        "beats.glide_s" to 4.0,
        "fx.fade" to 1.0, "fx.fade_s" to 1.5, "fx.delay_ms" to 0, "fx.swap" to false,
        "fx.mirror" to false, "fx.rotate180" to false, "fx.mono" to false,
        "fx.brightness" to 0.0, "fx.contrast" to 1.0, "fx.saturation" to 1.0,
        "fx.tint_r" to 1.0, "fx.tint_g" to 1.0, "fx.tint_b" to 1.0, "fx.invert" to false,
        "fx.vignette" to 0.35,
        "view.lens_sep_mm" to 64.0, "view.lens_y_mm" to 0.0, "view.k1" to 0.34,
        "view.k2" to 0.55, "view.zoom" to 1.0, "view.convergence" to 0.0,
        "view.vertical" to 0.0, "view.grid" to false, "view.stats" to false,
        "spiral.amount" to 0.0, "spiral.speed" to 0.25, "spiral.arms" to 3, "spiral.twist" to 6.0,
        "spiral.sharp" to 0.5, "spiral.hue" to 0.0, "spiral.sat" to 0.0, "spiral.zoom_hz" to 0.0,
        "photic.on" to false, "photic.sync" to true, "photic.hz" to 10.0, "photic.depth" to 0.5,
        "photic.amount" to 0.3, "photic.hue" to 0.6, "photic.sat" to 0.8, "photic.hue_cycle_s" to 0.0,
        "photic.alternate" to false,
        "preview.video" to false, "preview.audio" to false, "preview.fps" to 10,
                "stream.layout" to "sbs", "stream.width" to 2560, "stream.height" to 720,
        "stream.fps" to 30,
    )

    init {
        map.putAll(DEFAULTS)
    }

    fun init(ctx: Context) {
        appContext = ctx.applicationContext
        val saved = prefs()?.getString("view", null) ?: return
        runCatching {
            val j = JSONObject(saved)
            for (k in j.keys()) set("view.$k", j.get(k), persist = false)
        }
    }

    fun f(key: String): Float = (map[key] as? Number)?.toFloat() ?: 0f
    fun i(key: String): Int = (map[key] as? Number)?.toInt() ?: 0
    fun b(key: String): Boolean = map[key] as? Boolean ?: false
    fun s(key: String): String = map[key]?.toString() ?: ""

    private fun allowed(key: String, value: Any): Any =
        if (key == "photic.on" && !lightPulse) false else value

    fun set(key: String, value: Any, persist: Boolean = true) {
        if (value == JSONObject.NULL) return
        map[key] = allowed(key, value)
        if (persist && key.startsWith("view.")) saveView()
    }

    /** Apply a full {"section": {"key": value}} state tree from the sender. */
    fun applyState(state: JSONObject) {
        for (section in state.keys()) {
            val sec = state.optJSONObject(section) ?: continue
            for (k in sec.keys()) {
                val v = sec.get(k)
                if (v is JSONObject || v is org.json.JSONArray) continue
                map["$section.$k"] = allowed("$section.$k", v)
            }
        }
        saveView()
    }

    fun viewJson(): JSONObject {
        val j = JSONObject()
        for ((k, v) in map) if (k.startsWith("view.")) j.put(k.removePrefix("view."), v)
        return j
    }

    fun prefs() = appContext?.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun saveView() {
        prefs()?.edit()?.putString("view", viewJson().toString())?.apply()
    }
}
