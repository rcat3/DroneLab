package io.github.rcat3.dronelab.hivesight

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTimestamp
import android.media.AudioTrack
import java.net.DatagramPacket
import java.net.SocketTimeoutException
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.sin
import kotlin.math.sqrt
import kotlin.math.tanh

/**
 * Vessel's audio: the Guide's (already effected) voice from the sender,
 * mixed with locally synthesised binaural beats and pink noise.
 *
 * The beats are generated here rather than streamed so they are sample-exact
 * and never touched by network jitter or lossy coding: the effect depends on
 * the left/right frequency difference reaching each ear cleanly.
 */
/**
 * One incoming RTP L16 stereo stream (S16BE, 48 kHz) with its own jitter
 * buffer. Used twice: the Guide's voice and a media file's soundtrack.
 */
class PcmStream(private val port: Int, private val payloadType: Int, private val name: String) {
    private val rate = 48000

    @Volatile private var running = false
    private var thread: Thread? = null

    // Interleaved stereo floats, ring buffer guarded by `lock`.
    private val lock = Object()
    private val ring = FloatArray(rate * 2 * 2) // 2 s stereo
    private var rHead = 0 // read index (samples)
    private var rFill = 0 // samples available
    private var buffering = true

    @Volatile var bufferedMs = 0; private set
    @Volatile var underruns = 0L; private set
    @Volatile var lastPacketNs = 0L; private set

    fun start() {
        running = true
        thread = Thread(::receive, name).apply { priority = Thread.MAX_PRIORITY; start() }
    }

    fun stop() {
        running = false
        thread?.join(1000)
    }

    private fun receive() {
        val sock = openUdp(port, 1 shl 20)
        val buf = ByteArray(4096)
        val pkt = DatagramPacket(buf, buf.size)
        val rtp = RtpPacket()
        val seq = SeqTracker()
        sock.use {
            while (running) {
                try {
                    pkt.length = buf.size
                    sock.receive(pkt)
                } catch (_: SocketTimeoutException) {
                    continue
                }
                if (!rtp.parse(buf, pkt.length) || rtp.payloadType != payloadType) continue
                // Late/duplicate packets are dropped; a restarted stream is accepted.
                if (seq.accept(rtp) == SeqTracker.Result.STALE) continue
                lastPacketNs = System.nanoTime()
                push(buf, rtp.payloadOffset, rtp.payloadLength)
            }
        }
    }

    /** Append big-endian S16 stereo samples to the ring. */
    private fun push(b: ByteArray, off: Int, len: Int) {
        val n = len / 2
        synchronized(lock) {
            val cap = ring.size
            for (k in 0 until n) {
                val hi = b[off + 2 * k].toInt()
                val lo = b[off + 2 * k + 1].toInt() and 0xff
                val s = ((hi shl 8) or lo).toShort() / 32768f
                if (rFill == cap) { rHead = (rHead + 1) % cap; rFill-- } // overflow: drop oldest
                ring[(rHead + rFill) % cap] = s
                rFill++
            }
            // Keep latency bounded: if we've drifted well past the target, skip ahead.
            val target = targetSamples()
            if (rFill > target * 2 + rate / 25 * 2) {
                val drop = (rFill - target) and 1.inv()
                rHead = (rHead + drop) % cap
                rFill -= drop
            }
        }
    }

    private fun targetSamples() = (Params.i("mix.jitter_ms").coerceIn(5, 500) * rate / 1000) * 2

    /** Pull one block of stereo into `out` (zeros on underrun). */
    fun pull(out: FloatArray) {
        synchronized(lock) {
            val need = out.size
            if (buffering && rFill >= targetSamples()) buffering = false
            if (buffering || rFill < need) {
                if (!buffering && rFill < need) { buffering = true; underruns++ }
                out.fill(0f)
            } else {
                val cap = ring.size
                for (k in 0 until need) out[k] = ring[(rHead + k) % cap]
                rHead = (rHead + need) % cap
                rFill -= need
            }
            bufferedMs = rFill / 2 * 1000 / rate
        }
    }
}

class AudioEngine(voicePort: Int, mediaPort: Int) {
    /** Guide preview tap on the final mix (set by the activity). */
    @Volatile var monitor: PreviewAudio? = null
    private val rate = 48000
    private val block = 240 // 5 ms

    @Volatile private var running = false
    private var outThread: Thread? = null
    private val voiceIn = PcmStream(voicePort, 97, "rtp-voice")
    private val mediaIn = PcmStream(mediaPort, 98, "rtp-media")

    val bufferedMs get() = voiceIn.bufferedMs
    val underruns get() = voiceIn.underruns
    val mediaBufferedMs get() = mediaIn.bufferedMs
    @Volatile var outLatencyMs = -1; private set
    /** Beat frequency currently being produced (after glide), for photic sync. */
    @Volatile var currentBeatHz = 0f; private set

    fun start() {
        running = true
        voiceIn.start(); mediaIn.start()
        outThread = Thread(::play, "audio-out").apply { priority = Thread.MAX_PRIORITY; start() }
    }

    fun stop() {
        running = false
        voiceIn.stop(); mediaIn.stop()
        outThread?.join(1000)
    }

    // ---------------------------------------------------------------- output
    private fun play() {
        val minBuf = AudioTrack.getMinBufferSize(rate, AudioFormat.CHANNEL_OUT_STEREO, AudioFormat.ENCODING_PCM_FLOAT)
        val track = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build()
            )
            .setAudioFormat(
                AudioFormat.Builder().setSampleRate(rate)
                    .setEncoding(AudioFormat.ENCODING_PCM_FLOAT)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO).build()
            )
            .setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
            .setBufferSizeInBytes(maxOf(minBuf, block * 2 * 4 * 4))
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
        track.play()

        val out = FloatArray(block * 2)
        val voice = FloatArray(block * 2)
        val mediaBuf = FloatArray(block * 2)
        val ts = AudioTimestamp()
        var written = 0L
        var lastTsCheck = 0L

        // Synth state
        var phL = 0.0; var phR = 0.0; var phPan = 0.0
        var carrier = Params.f("beats.carrier_hz").toDouble()
        var beat = Params.f("beats.beat_hz").toDouble()
        var beatsGain = 0.0; var noiseGain = 0.0; var voiceGain = 0.0; var mediaGain = 0.0
        val pink = Array(2) { DoubleArray(7) }
        var rng = 0x2545F491L
        val noiseBeats = NoiseBeats(rate)
        val typeSynth = TypeSynth(rate)
        var typeGain = 0.0
        val nb = DoubleArray(2)
        val dt = block.toDouble() / rate

        while (running) {
            voiceIn.pull(voice)
            mediaIn.pull(mediaBuf)

            // Parameter smoothing once per block.
            val glide = Params.f("beats.glide_s").toDouble().coerceAtLeast(0.0)
            val a = if (glide < 1e-3) 1.0 else 1.0 - exp(-dt / (glide / 3.0))
            carrier += (Params.f("beats.carrier_hz") - carrier) * a
            beat += (Params.f("beats.beat_hz") - beat) * a
            currentBeatHz = beat.toFloat()
            val master = Params.f("mix.master").toDouble()
            val gs = 1.0 - exp(-dt / 0.05) // 50 ms de-zipper for gains
            beatsGain += ((if (Params.b("beats.on")) Params.f("mix.beats_vol") else 0f) * master - beatsGain) * gs
            noiseGain += (Params.f("mix.noise_vol") * master - noiseGain) * gs
            typeGain = Params.f("mix.type_vol") * master.toDouble()
            typeSynth.poll()
            voiceGain += (Params.f("mix.voice_vol") * master - voiceGain) * gs
            mediaGain += (Params.f("mix.media_vol") * master - mediaGain) * gs

            val apHz = Params.f("mix.autopan_hz").toDouble()
            val pan = if (apHz > 0.0) {
                phPan = (phPan + 2 * PI * apHz * dt) % (2 * PI); sin(phPan)
            } else Params.f("mix.voice_pan").toDouble().coerceIn(-1.0, 1.0)
            // Equal-power pan applied as a balance on the stereo voice.
            val ang = (pan + 1.0) * PI / 4
            val vl = voiceGain * cos(ang) * 1.4142
            val vr = voiceGain * sin(ang) * 1.4142

            val fL = carrier - beat / 2
            val fR = carrier + beat / 2
            val dL = 2 * PI * fL / rate
            val dR = 2 * PI * fR / rate
            // The beat on noise (pink or white) rather than two tones: the right ear's noise is the
            // left's, moved up by the beat in frequency, so the beat is there at every pitch
            val src = Params.s("beats.source")
            val noiseBeat = src == "pink" || src == "white"
            if (noiseBeat) noiseBeats.setBand(carrier, Params.f("beats.noise_bw").toDouble())
            for (n in 0 until block) {
                var l: Double
                var r: Double
                if (noiseBeat) {
                    noiseBeats.next(src == "pink", beat, nb)
                    l = beatsGain * nb[0]
                    r = beatsGain * nb[1]
                } else {
                    phL += dL; if (phL > 2 * PI) phL -= 2 * PI
                    phR += dR; if (phR > 2 * PI) phR -= 2 * PI
                    l = beatsGain * 0.5 * sin(phL)
                    r = beatsGain * 0.5 * sin(phR)
                }
                if (noiseGain > 1e-4) {
                    for (ch in 0..1) {
                        // xorshift white noise -> Paul Kellet pink filter
                        rng = rng xor (rng shl 13); rng = rng xor (rng ushr 7); rng = rng xor (rng shl 17)
                        val w = (rng and 0xffffff).toDouble() / 0x800000 - 1.0
                        val b = pink[ch]
                        b[0] = 0.99886 * b[0] + w * 0.0555179
                        b[1] = 0.99332 * b[1] + w * 0.0750759
                        b[2] = 0.96900 * b[2] + w * 0.1538520
                        b[3] = 0.86650 * b[3] + w * 0.3104856
                        b[4] = 0.55000 * b[4] + w * 0.5329522
                        b[5] = -0.7616 * b[5] - w * 0.0168980
                        val p = (b[0] + b[1] + b[2] + b[3] + b[4] + b[5] + b[6] + w * 0.5362) * 0.11
                        b[6] = w * 0.115926
                        if (ch == 0) l += noiseGain * p else r += noiseGain * p
                    }
                }
                val tk = typeSynth.next() * typeGain
                l += tk; r += tk
                l += vl * voice[2 * n] + mediaGain * mediaBuf[2 * n]
                r += vr * voice[2 * n + 1] + mediaGain * mediaBuf[2 * n + 1]
                out[2 * n] = softClip(l)
                out[2 * n + 1] = softClip(r)
            }
            track.write(out, 0, out.size, AudioTrack.WRITE_BLOCKING)
            monitor?.feed(out, out.size)
            written += block

            // Estimate output latency (includes Bluetooth on modern Android).
            val now = System.nanoTime()
            if (now - lastTsCheck > 500_000_000L && track.getTimestamp(ts)) {
                lastTsCheck = now
                val playedNow = ts.framePosition + (now - ts.nanoTime) * rate / 1_000_000_000L
                outLatencyMs = ((written - playedNow) * 1000 / rate).toInt()
            }
        }
        track.stop()
        track.release()
    }

    private fun softClip(x: Double): Float =
        if (abs(x) < 0.9) x.toFloat() else (0.9 + 0.1 * tanh((abs(x) - 0.9) / 0.1)).toFloat() * if (x < 0) -1f else 1f
}


/** A second-order Butterworth high or low pass (RBJ cookbook), one sample at a time. */
private class Biquad {
    private var b0 = 1.0; private var b1 = 0.0; private var b2 = 0.0
    private var a1 = 0.0; private var a2 = 0.0
    private var x1 = 0.0; private var x2 = 0.0; private var y1 = 0.0; private var y2 = 0.0

    fun set(high: Boolean, f: Double, rate: Int) {
        val w0 = 2 * PI * f / rate
        val al = sin(w0) / (2 * 0.7071)
        val c = cos(w0)
        val a0 = 1 + al
        if (high) { b0 = (1 + c) / 2; b1 = -(1 + c); b2 = (1 + c) / 2 }
        else { b0 = (1 - c) / 2; b1 = 1 - c; b2 = (1 - c) / 2 }
        b0 /= a0; b1 /= a0; b2 /= a0; a1 = -2 * c / a0; a2 = (1 - al) / a0
    }

    fun process(v: Double): Double {
        val o = b0 * v + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = v; y2 = y1; y1 = o
        return o
    }
}

/**
 * Binaural beats carried by noise. Noise (white or pink) kept to a band around
 * the carrier goes to the left ear as it is, and to the right moved up in
 * frequency by the beat (a single-sideband shift: the noise's analytic signal,
 * made with a Hilbert FIR, turned by the beat's phase). Every frequency in it
 * then has the same phase difference between the ears, rotating at the beat, so
 * the beat is heard as with two tones, but on a sound that is easier on the ears.
 * Its level is kept steady (about that of the tones) whatever the width.
 */
private class NoiseBeats(private val rate: Int) {
    private val taps = 127
    private val mid = taps / 2
    private val hist = DoubleArray(taps)
    private var pos = 0
    private val hk = IntArray((taps + 1) / 2)       // the taps that aren't zero: k even
    private val hv = DoubleArray((taps + 1) / 2)
    private val hp = Biquad()
    private val lp = Biquad()
    private val pinkState = DoubleArray(7)
    private var rng = 0x6C8E9CF5L
    private var phase = 0.0
    private var power = 0.05
    private var lastCarrier = -1.0
    private var lastWidth = -1.0

    init {
        var n = 0
        for (k in 0 until taps) {
            val m = k - mid
            if (m % 2 != 0) {
                hk[n] = k
                hv[n] = 2 / (PI * m) * (0.54 + 0.46 * cos(PI * m / mid))
                n++
            }
        }
    }

    /** The band: [width] Hz around [carrier], set again only when it has moved. */
    fun setBand(carrier: Double, width: Double) {
        val w = width.coerceIn(50.0, 8000.0)
        if (abs(carrier - lastCarrier) < 0.5 && abs(w - lastWidth) < 1.0) return
        lastCarrier = carrier; lastWidth = w
        val lo = maxOf(20.0, carrier - w / 2)
        val hi = minOf(rate * 0.45, maxOf(lo * 1.5, carrier + w / 2))
        hp.set(true, lo, rate)
        lp.set(false, hi, rate)
    }

    private fun white(): Double {
        rng = rng xor (rng shl 13); rng = rng xor (rng ushr 7); rng = rng xor (rng shl 17)
        return (rng and 0xffffff).toDouble() / 0x800000 - 1.0
    }

    /** One sample for each ear into [out]: left, right. */
    fun next(pink: Boolean, beatHz: Double, out: DoubleArray) {
        val w = white()
        val nz = if (pink) {
            val b = pinkState
            b[0] = 0.99886 * b[0] + w * 0.0555179
            b[1] = 0.99332 * b[1] + w * 0.0750759
            b[2] = 0.96900 * b[2] + w * 0.1538520
            b[3] = 0.86650 * b[3] + w * 0.3104856
            b[4] = 0.55000 * b[4] + w * 0.5329522
            b[5] = -0.7616 * b[5] - w * 0.0168980
            val p = (b[0] + b[1] + b[2] + b[3] + b[4] + b[5] + b[6] + w * 0.5362) * 0.11
            b[6] = w * 0.115926
            p
        } else w * 0.5
        val x = lp.process(hp.process(nz))
        hist[pos] = x
        val latest = pos
        pos = (pos + 1) % taps
        var q = 0.0
        for (i in hk.indices) q += hv[i] * hist[(latest - hk[i] + taps) % taps]
        val inPhase = hist[(latest - mid + taps) % taps]
        power += (inPhase * inPhase - power) / rate     // about a second to settle
        val norm = (0.354 / sqrt(power + 1e-9)).coerceAtMost(40.0)
        phase += 2 * PI * beatHz / rate
        if (phase > 2 * PI) phase -= 2 * PI
        out[0] = inPhase * norm
        out[1] = (inPhase * cos(phase) - q * sin(phase)) * norm
    }
}


/**
 * The sound of text being typed, made as it's needed (the words layer says a letter has been typed):
 * "blip", short electronic chirps at a pitch that goes with the letter, as on an old computer's
 * screen; "click", a teletype's key. Several in one block are spread out a little.
 */
object TypeSound {
    const val OFF = 0
    const val BLIP = 1
    const val CLICK = 2
    private val pending = java.util.concurrent.ConcurrentLinkedQueue<Int>()

    fun trigger(kind: Int, code: Int) {
        if (pending.size < 64) pending.add((kind shl 16) or (code and 0xffff))
    }

    internal fun take(): Int? = pending.poll()
}

private class TypeSynth(private val rate: Int) {
    private class Voice(var kind: Int, var freq: Double, var delay: Int, var age: Int, val len: Int, var phase: Double = 0.0)
    private val voices = ArrayList<Voice>()
    private var rng = 0x1F3D5B79L

    /** Starts a voice for each letter typed since the last block. */
    fun poll() {
        var n = 0
        while (true) {
            val e = TypeSound.take() ?: break
            val kind = e shr 16
            val code = e and 0xffff
            if (voices.size >= 24) { voices.removeAt(0) }
            val spread = n * rate / 90
            if (kind == TypeSound.BLIP) {
                // A pitch from the letter: a run of a few notes, like the chirps of a screen filling
                val f = 880.0 + (code * 37 % 9) * 165.0
                voices.add(Voice(kind, f, spread, 0, rate * 26 / 1000))
            } else {
                voices.add(Voice(kind, 1500.0 + (code * 13 % 5) * 220.0, spread, 0, rate * 14 / 1000))
            }
            n++
        }
    }

    fun next(): Double {
        if (voices.isEmpty()) return 0.0
        var out = 0.0
        val it = voices.iterator()
        while (it.hasNext()) {
            val v = it.next()
            if (v.delay > 0) { v.delay--; continue }
            if (v.age >= v.len) { it.remove(); continue }
            val t = v.age.toDouble() / rate
            if (v.kind == TypeSound.BLIP) {
                val env = minOf(1.0, v.age / (rate * 0.0015)) * exp(-t * 90.0)
                v.phase += 2 * PI * v.freq / rate
                if (v.phase > 2 * PI) v.phase -= 2 * PI
                // A sine with some of a square's edge to it
                out += 0.30 * env * (sin(v.phase) + 0.35 * sin(3 * v.phase))
            } else {
                rng = rng xor (rng shl 13); rng = rng xor (rng ushr 7); rng = rng xor (rng shl 17)
                val w = (rng and 0xffffff).toDouble() / 0x800000 - 1.0
                v.phase += 2 * PI * v.freq / rate
                out += 0.45 * exp(-t * 600.0) * w + 0.25 * exp(-t * 350.0) * sin(v.phase) + 0.2 * exp(-t * 200.0) * sin(2 * PI * 140.0 * t)
            }
            v.age++
        }
        return out
    }
}
