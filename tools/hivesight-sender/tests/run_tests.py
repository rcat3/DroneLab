#!/usr/bin/python3
"""Golden tests for the studio chain (core/audio/studio/), the Guide's voice
effects in C, against what the sender used before: EyeStream's Python
(reference/dynamics.py, reference/voicefx.py) and GStreamer's audiocheblimit,
audioecho and freeverb (reference/gst_ref.py). Simple pitch (it was
SoundTouch) and RNNoise have nothing to compare with, so they're checked for
what they should do.

    tools/hivesight-sender/build_fx.sh && /usr/bin/python3 tools/hivesight-sender/tests/run_tests.py

The test signal is made here, the same every time: no recordings in the repo.
"""
from __future__ import annotations

import ast
import copy
import ctypes
import json
import sys
import time
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "reference"))
import dynamics as ref_dynamics  # noqa: E402
import gst_ref  # noqa: E402
import voicefx as ref_voicefx  # noqa: E402

sys.path.insert(0, str(HERE.parent))
import settings  # noqa: E402

BUILD = HERE.parent / "build"
RATE = 48000
BLOCK = 240     # the sender's microphone buffers (5 ms)

F = ctypes.POINTER(ctypes.c_float)
T = ctypes.CDLL(str(BUILD / "libstudio_test.so"))
FX = ctypes.CDLL(str(BUILD / "libdronelab_fx.so"))
c_f = ctypes.c_float
c_i = ctypes.c_int
T.t_dynamics.argtypes = [F, c_i, c_i, c_f, c_f, c_f, c_i]
T.t_spectral.argtypes = [F, c_i, c_i, c_i, c_i, c_f, c_f, c_f, c_f]
T.t_spectral.restype = c_i
T.t_cheb.argtypes = [F, c_i, c_i, c_f]
T.t_echo.argtypes = [F, c_i, c_f, c_f, c_f]
T.t_reverb.argtypes = [F, F, c_i, c_f, c_f, c_f]
T.t_pitch.argtypes = [F, c_i, c_i, c_f]
T.t_pitch.restype = c_i
T.t_denoise.argtypes = [F, c_i, c_i]
T.t_denoise.restype = c_i
T.t_drive.argtypes = [F, c_i, c_f]
T.t_ring.argtypes = [F, c_i, c_f, c_f]
T.t_crush.argtypes = [F, c_i, c_f]
T.t_chorus.argtypes = [F, c_i, c_f, c_f, c_f]
T.t_crowd.argtypes = [F, c_i]
FX.dl_voice_new.restype = ctypes.c_void_p
FX.dl_voice_free.argtypes = [ctypes.c_void_p]
FX.dl_voice_key.argtypes = [ctypes.c_char_p]
FX.dl_voice_set.argtypes = [ctypes.c_void_p, c_i, c_f]
FX.dl_voice_process.argtypes = [ctypes.c_void_p, F, c_i, F]
FX.dl_voice_latency.argtypes = [ctypes.c_void_p]


def ptr(a: np.ndarray):
    return a.ctypes.data_as(F)


# ---------------------------------------------------------------------------
# The test signal: something like speech, made here
# ---------------------------------------------------------------------------
def resonator(x, f, bw, rate):
    r = np.exp(-np.pi * bw / rate)
    a1, a2 = 2 * r * np.cos(2 * np.pi * f / rate), -r * r
    y = np.zeros_like(x)
    y1 = y2 = 0.0
    g = 1 - r
    for i, v in enumerate(x):
        y0 = g * v + a1 * y1 + a2 * y2
        y[i] = y0
        y2, y1 = y1, y0
    return y


def speech(seconds=4.0, rate=RATE, seed=3, f0=120.0, noise_db=-65.0):
    """Vowels on a glottal pulse train with some vibrato and glide, through
    three formants, in syllables with pauses, with hiss bursts for
    consonants and a little background noise."""
    rng = np.random.default_rng(seed)
    n = int(seconds * rate)
    t = np.arange(n) / rate
    pitch = f0 * (1 + 0.15 * np.sin(2 * np.pi * 0.7 * t) + 0.03 * np.sin(2 * np.pi * 5.5 * t))
    phase = np.cumsum(pitch / rate)
    pulses = np.diff(np.floor(phase), prepend=0.0)          # one per cycle
    src = resonator(pulses, 0.0, 300.0, rate) * 4            # softened glottal shape
    vowels = [(730, 1090, 2440), (270, 2290, 3010), (300, 870, 2240), (530, 1840, 2480)]
    syl = int(0.32 * rate)
    out = np.zeros(n)
    for s0 in range(0, n, syl):
        seg = slice(s0, min(n, s0 + syl))
        k = (s0 // syl) % len(vowels)
        v = src[seg]
        y = sum(resonator(v, f, 80 + f * 0.05, rate) for f in vowels[k])
        m = len(y)
        env = np.sin(np.pi * np.arange(m) / m) ** 0.6
        if (s0 // syl) % 3 == 2:
            env[int(0.7 * m):] = 0                           # a pause
        out[seg] = y * env
    out /= np.max(np.abs(out)) + 1e-12
    out *= 10 ** (-12 / 20)
    # Hiss bursts (consonants)
    for s0 in range(int(0.25 * rate), n, int(0.96 * rate)):
        m = int(0.06 * rate)
        burst = rng.standard_normal(m) * np.hanning(m) * 0.05
        burst = np.diff(burst, prepend=0.0)
        out[s0:s0 + m] += burst[:max(0, min(m, n - s0))]
    out += rng.standard_normal(n) * 10 ** (noise_db / 20)
    return out.astype(np.float32)


def blocks(x, fn, block=BLOCK):
    return np.concatenate([fn(x[i:i + block]) for i in range(0, len(x), block)])


def snr_db(ref, test):
    ref = np.asarray(ref, np.float64)
    test = np.asarray(test, np.float64)
    err = np.sum((ref - test) ** 2)
    return 10 * np.log10(np.sum(ref ** 2) / max(err, 1e-30))


def rms_db(x):
    return 10 * np.log10(np.mean(np.asarray(x, np.float64) ** 2) + 1e-20)


RESULTS = []


def check(name, ok, detail):
    RESULTS.append((name, ok, detail))
    print(f"{'PASS' if ok else 'FAIL'}  {name}: {detail}")


# ---------------------------------------------------------------------------
# Against the Python
# ---------------------------------------------------------------------------
def test_dynamics(x):
    for gain, gate, ratio, mute in [(12, -55, 3, False), (24, -40, 6, False), (0, -90, 1, False),
                                    (12, -55, 3, True)]:
        d = ref_dynamics.Dynamics(RATE)
        ref = blocks(x, lambda b: d.process(b.copy(), gain, gate, ratio, mute))
        y = x.copy()
        T.t_dynamics(ptr(y), len(y), BLOCK, gain, gate, ratio, int(mute))
        err = float(np.max(np.abs(ref - y)))
        check(f"dynamics gain {gain} gate {gate} ratio {ratio} mute {mute}", err < 1e-4, f"max diff {err:.2e}")


def ref_spectral(x, rate, mode, pitch, formant, robot_hz, noise):
    # The reference's frame is fixed at 2048; at other rates the C takes the
    # nearest power of two to the same length, so the reference is set to match
    n = 2048 if rate == 48000 else 512
    saved = (ref_voicefx.N, ref_voicefx.HOP, ref_voicefx.NBINS, ref_voicefx.LIFTER)
    ref_voicefx.N, ref_voicefx.HOP, ref_voicefx.NBINS = n, n // 8, n // 2 + 1
    ref_voicefx.LIFTER = round(100 * n / 2048)
    try:
        v = ref_voicefx.SpectralVoice(rate)
        return blocks(x, lambda b: v.process(b, mode, pitch, formant, robot_hz, noise))
    finally:
        ref_voicefx.N, ref_voicefx.HOP, ref_voicefx.NBINS, ref_voicefx.LIFTER = saved


def c_spectral(x, rate, mode, pitch, formant, robot_hz, noise):
    y = x.copy()
    m = {"shift": 1, "robot": 2}[mode]
    T.t_spectral(ptr(y), len(y), BLOCK, rate, m, pitch, formant, robot_hz, noise)
    return y


def band_levels(x, rate):
    spec = np.abs(np.fft.rfft(x * np.hanning(len(x)))) ** 2
    freqs = np.fft.rfftfreq(len(x), 1 / rate)
    edges = 100 * 2 ** (np.arange(0, 7.5, 0.5))
    edges = edges[edges < rate / 2]
    return np.array([10 * np.log10(spec[(freqs >= a) & (freqs < b)].sum() + 1e-20)
                     for a, b in zip(edges[:-1], edges[1:])])


def test_spectral(x48, x16):
    for rate, x in [(48000, x48), (16000, x16)]:
        cases = [("shift", 1.75, 1.18, 200, 0.0), ("shift", 1.5, 1.25, 200, 0.0),
                 ("shift", 0.75, 0.875, 200, 0.0), ("robot", 1.0, 1.0, 110, 0.0),
                 ("robot", 1.0, 1.2, 220, 0.0)]
        for mode, pitch, formant, hz, noise in cases:
            ref = ref_spectral(x, rate, mode, pitch, formant, hz, noise)
            y = c_spectral(x, rate, mode, pitch, formant, hz, noise)
            s = snr_db(ref, y)
            check(f"spectral {rate} {mode} pitch {pitch} formant {formant} robot {hz} Hz", s > 40,
                  f"{s:.1f} dB apart")
        # Robot with its breath noise: the noise can't match, so its level and spectrum
        for hz, formant, noise in [(220, 1.2, 0.08), (110, 1.0, 0.3)]:
            ref = ref_spectral(x, rate, "robot", 1.0, formant, hz, noise)
            y = c_spectral(x, rate, "robot", 1.0, formant, hz, noise)
            dl = abs(rms_db(ref) - rms_db(y))
            db = float(np.max(np.abs(band_levels(ref, rate) - band_levels(y, rate))))
            check(f"spectral {rate} robot {hz} Hz noise {noise}", dl < 1.0 and db < 3.0,
                  f"level {dl:.2f} dB off, bands at most {db:.2f} dB off")


# ---------------------------------------------------------------------------
# Against GStreamer
# ---------------------------------------------------------------------------
def test_filters(x):
    for hp, cutoff in [(True, 90), (True, 40), (True, 450), (False, 16000), (False, 3200), (False, 2600)]:
        mode = "high-pass" if hp else "low-pass"
        ref = gst_ref.run(x, f"audiocheblimit mode={mode} poles=4 cutoff={cutoff}")
        y = x.copy()
        T.t_cheb(ptr(y), len(y), int(hp), cutoff)
        err = float(np.max(np.abs(ref - y)))
        check(f"{mode} {cutoff} Hz", err < 1e-4, f"max diff {err:.2e}")


def test_echo(x):
    for ms, fb, mix in [(90, 0.25, 0.25), (380, 0.45, 0.45), (9, 0.75, 0.7), (1, 0.0, 0.0), (240, 0.55, 0.5)]:
        ref = gst_ref.run(x, f"audioecho max-delay=2000000000 delay={int(ms * 1e6)} feedback={fb} "
                             f"intensity={mix}")
        y = x.copy()
        T.t_echo(ptr(y), len(y), ms, fb, mix)
        err = float(np.max(np.abs(ref - y)))
        check(f"echo {ms} ms feedback {fb} mix {mix}", err < 1e-4, f"max diff {err:.2e}")


def test_reverb(x):
    for room, damp, level in [(0.2, 0.5, 0.0), (0.15, 0.8, 0.12), (0.97, 0.25, 0.55), (0.95, 0.3, 0.65),
                              (0.5, 0.6, 0.2)]:
        ref = gst_ref.run(x, f"freeverb room-size={room} damping={damp} level={level}", channels_out=2)
        y = np.zeros((len(x), 2), np.float32)
        T.t_reverb(ptr(x.copy()), ptr(y), len(x), room, damp, level)
        err = float(np.max(np.abs(ref - y)))
        check(f"reverb room {room} damp {damp} level {level}", err < 1e-4, f"max diff {err:.2e}")


# ---------------------------------------------------------------------------
# Simple pitch and denoise: what they should do
# ---------------------------------------------------------------------------
def peak_hz(x, rate):
    w = x * np.hanning(len(x))
    spec = np.abs(np.fft.rfft(w, 8 * len(w)))
    k = int(np.argmax(spec))
    a, b, c = np.log(spec[k - 1:k + 2] + 1e-20)
    k = k + 0.5 * (a - c) / (a - 2 * b + c)
    return k * rate / (8 * len(w)), spec


def test_pitch():
    t = np.arange(3 * RATE) / RATE
    for ratio in [0.6, 0.78, 0.9, 0.94, 1.4, 2.0, 0.5]:
        for f in [110.0, 220.0]:
            x = (0.3 * np.sin(2 * np.pi * f * t)).astype(np.float32)
            y = x.copy()
            T.t_pitch(ptr(y), len(y), BLOCK, ratio)
            seg = y[RATE // 2:]
            got, spec = peak_hz(seg, RATE)
            want = f * ratio
            err = abs(got / want - 1)
            level = rms_db(seg) - rms_db(x[RATE // 2:])
            # Everything away from the new tone: joins that click or beat show up here
            freqs = np.arange(len(spec)) * RATE / (8 * len(seg))
            near = np.abs(freqs - want) < want * 0.08
            junk = 10 * np.log10(np.sum(spec[~near] ** 2) / np.sum(spec[near] ** 2))
            check(f"pitch {ratio} on {f:.0f} Hz", err < 0.005 and abs(level) < 1.0 and junk < -30,
                  f"{got:.1f} Hz for {want:.1f}, level {level:+.2f} dB, rest {junk:.1f} dB")
    # Speech: level kept
    x = speech()
    for ratio in [0.6, 0.78, 1.4]:
        y = x.copy()
        T.t_pitch(ptr(y), len(y), BLOCK, ratio)
        level = rms_db(y[RATE // 2:]) - rms_db(x[RATE // 2:])
        check(f"pitch {ratio} on speech", abs(level) < 1.5 and np.all(np.isfinite(y)), f"level {level:+.2f} dB")


def test_denoise():
    x = speech(noise_db=-200)
    rng = np.random.default_rng(11)
    noise = (rng.standard_normal(len(x)) * 10 ** (-40 / 20)).astype(np.float32)
    noisy = x + noise
    y = noisy.copy()
    lat = T.t_denoise(ptr(y), len(y), BLOCK)
    # The delay it says it has: where the output lines up best with the input
    lags = range(lat - 240, lat + 241, 4)
    best = max(lags, key=lambda lag: float(np.dot(y[lag:], noisy[:len(y) - lag])))
    y = np.concatenate([y[lat:], np.zeros(lat, np.float32)])
    # The pauses and the voice, by 10 ms windows of the clean signal
    w = RATE // 100
    frames = len(x) // w
    level = np.array([rms_db(x[i * w:(i + 1) * w]) for i in range(frames)])
    pause = np.repeat(level < -70, w)
    voice = np.repeat(level > -30, w)
    pause[:RATE // 2] = False
    voice[:RATE // 2] = False
    n = len(pause)
    drop = rms_db(noisy[:n][pause]) - rms_db(y[:n][pause])
    keep = rms_db(y[:n][voice]) - rms_db(noisy[:n][voice])
    check("denoise: noise in the pauses", drop > 10, f"{drop:.1f} dB lower")
    check("denoise: the voice kept", keep > -6, f"{keep:+.1f} dB")
    check("denoise: delay", abs(best - lat) <= 48, f"says {lat}, lines up best at {best}")


# ---------------------------------------------------------------------------
# The display unit's simpler effects: against the board's own code
# (core/audio/voice_fx_chain.c), written out here in numpy at 48 kHz
# ---------------------------------------------------------------------------
def test_character(x):
    k = 10 ** (-24 / 20)
    ref = (k * np.tanh(x.astype(np.float64) / k)).astype(np.float32)
    y = x.copy()
    T.t_drive(ptr(y), len(y), 24)
    check("drive 24 dB", float(np.max(np.abs(ref - y))) < 1e-5, f"max diff {np.max(np.abs(ref - y)):.1e}")

    for hz, mix in [(30, 1.0), (500, 0.15), (60, 0.6)]:
        step = np.float32(2 * np.pi * hz / RATE)
        ph = np.float32(0)
        ref = np.empty_like(x)
        tp = np.float32(2 * np.pi)
        for i in range(len(x)):
            ph = np.float32(ph + step)
            if ph > tp:
                ph = np.float32(ph - tp)
            ref[i] = x[i] * (np.float32(1 - mix) + np.float32(mix) * np.sin(ph))
        y = x.copy()
        T.t_ring(ptr(y), len(y), hz, mix)
        err = float(np.max(np.abs(ref - y)))
        check(f"ring {hz} Hz mix {mix}", err < 1e-4, f"max diff {err:.1e}")

    for bits in [12, 10]:
        lv = 2.0 ** (bits - 1)
        ref = (np.round(x.astype(np.float64) * lv) / lv).astype(np.float32)
        y = x.copy()
        T.t_crush(ptr(y), len(y), bits)
        # roundf rounds halves away from zero, numpy to even: at most one step apart, rarely
        bad = int(np.sum(np.abs(ref - y) > 1e-6))
        check(f"crush {bits} bits", bad <= len(x) // 10000 + 1, f"{bad} samples a step apart")

    for rate, depth, mix in [(0.4, 4, 0.3), (1.5, 2, 0.4), (0.3, 2, 0.5)]:
        d = depth * RATE / 1000
        base = d + 2
        buf = np.zeros(len(x) + 4096)
        # The sweep's phase kept in float, as the C does (in double it drifts apart over seconds)
        ph = np.float32(0)
        step = np.float32(2 * np.pi * rate / RATE)
        tp = np.float32(2 * np.pi)
        ref = np.empty_like(x)
        for i in range(len(x)):
            buf[i + 4096] = x[i]
            ph = np.float32(ph + step)
            if ph > tp:
                ph = np.float32(ph - tp)
            wet = 0.0
            for tap in range(2):
                dl = base + d * 0.5 * (1 + np.sin(ph + np.pi * tap))
                w = int(dl)
                fr = dl - w
                a = buf[i + 4096 - w]
                b = buf[i + 4096 - w - 1]
                wet += a + (b - a) * fr
            ref[i] = (1 - mix) * x[i] + mix * 0.5 * wet
        y = x.copy()
        T.t_chorus(ptr(y), len(y), rate, depth, mix)
        err = float(np.max(np.abs(ref - y)))
        check(f"chorus {rate} Hz {depth} ms mix {mix}", err < 1e-4, f"max diff {err:.1e}")

    y = x.copy()
    T.t_crowd(ptr(y), len(y))
    level = rms_db(y[RATE // 2:]) - rms_db(x[RATE // 2:])
    check("crowd", np.all(np.isfinite(y)) and abs(level) < 3, f"level {level:+.1f} dB")


# ---------------------------------------------------------------------------
# The whole chain: presets against the old pipeline, and speed
# ---------------------------------------------------------------------------
def c_chain(x, settings, block=BLOCK):
    v = FX.dl_voice_new()
    for k, val in settings.items():
        key = FX.dl_voice_key(k.encode())
        if key >= 0:
            FX.dl_voice_set(v, key, float({"off": 0, "shift": 1, "robot": 2}.get(val, val)
                                          if isinstance(val, str) else val))
    out = np.zeros((len(x), 2), np.float32)
    xin = np.ascontiguousarray(x)
    t0 = time.perf_counter()
    for i in range(0, len(x), block):
        m = min(block, len(x) - i)
        FX.dl_voice_process(v, ptr(xin[i:]), m, ptr(out[i:]))
    took = time.perf_counter() - t0
    FX.dl_voice_free(v)
    return out, took


def old_chain(x, v):
    """The sender before: GStreamer filters, the Python dynamics and spectral
    effects, then GStreamer's echo and reverb (no simple pitch, no denoise)."""
    y = gst_ref.run(x, f"audiocheblimit mode=high-pass poles=4 cutoff={max(10, v['highpass_hz'])} ! "
                       f"audiocheblimit mode=low-pass poles=4 cutoff={min(23000, max(200, v['lowpass_hz']))}")
    d = ref_dynamics.Dynamics(RATE)
    y = blocks(y, lambda b: d.process(b.copy(), v["gain_db"], v["gate_db"], v["comp_ratio"], False))
    if v["fx_mode"] in ("shift", "robot"):
        s = ref_voicefx.SpectralVoice(RATE)
        y = blocks(y, lambda b: s.process(b, v["fx_mode"], v["shift_pitch"], v["shift_formant"],
                                          v["robot_hz"], v["robot_noise"]))
    return gst_ref.run(y, f"audioecho max-delay=2000000000 delay={int(max(1, v['echo_ms']) * 1e6)} "
                          f"feedback={min(0.95, v['echo_feedback'])} intensity={v['echo_mix']} ! "
                          f"freeverb room-size={v['reverb_room']} damping={v['reverb_damp']} "
                          f"level={v['reverb_mix']}", channels_out=2)


def test_presets(x):
    presets = json.loads((HERE.parent / "presets.json").read_text())
    base = {"mute": False, "gain_db": 12.0, "denoise": False, "gate_db": -55.0, "comp_ratio": 3.0, "pitch": 1.0,
            "fx_mode": "off", "shift_pitch": 1.0, "shift_formant": 1.0, "robot_hz": 200.0, "robot_noise": 0.1}
    seconds = len(x) / RATE
    for name, p in presets.items():
        v = dict(base, **p)
        y, took = c_chain(x, v)
        if name.endswith("(unit)"):
            # The display unit's presets: the old pipeline hadn't these effects. Fine, and fast
            ok = bool(np.all(np.isfinite(y))) and np.max(np.abs(y)) <= 1.0 and seconds / took > 10
            check(f"preset {name}", ok, f"{seconds / took:.0f}x real time, level {rms_db(y[RATE // 2:]):.1f} dBFS, "
                                        f"peak {np.max(np.abs(y)):.2f}")
            continue
        ok = bool(np.all(np.isfinite(y)))
        speed = seconds / took
        detail = f"{speed:.0f}x real time"
        # The spectral effects are compared sample for sample on their own (test_spectral): in the
        # chain, the filters' float rounding (1e-5 from GStreamer's doubles) is enough to move
        # their phases, as it moves the reference's own (1e-6 of noise: 23-45 dB apart), so here
        # the level and spectrum
        if abs(v["pitch"] - 1) < 1e-3 and v["fx_mode"] == "off":
            ref = old_chain(x, v)
            skip = RATE // 10       # the first fade
            s = snr_db(ref[skip:], y[skip:])
            ok = ok and s > 40
            detail += f", {s:.1f} dB from the old pipeline"
        elif abs(v["pitch"] - 1) < 1e-3:
            ref = old_chain(x, v)[RATE // 2:, 0]
            got = y[RATE // 2:, 0]
            level = rms_db(got) - rms_db(ref)
            bands = float(np.max(np.abs(band_levels(ref, RATE) - band_levels(got, RATE))))
            ok = ok and abs(level) < 1 and bands < 3
            detail += f", level {level:+.2f} dB and bands at most {bands:.1f} dB from the old pipeline"
        else:
            level = rms_db(y[RATE // 2:]) - rms_db(old_chain_level_ref(x, v))
            ok = ok and abs(level) < 3
            detail += f", level {level:+.1f} dB from the old pipeline (without its simple pitch)"
        ok = ok and speed > 20
        check(f"preset {name}", ok, detail)
    # Denoise on top of a preset, and a setting changed mid-stream: still fine
    v = dict(base, **presets["male → female"], denoise=True)
    y, took = c_chain(x, v)
    check("preset male → female with denoise", bool(np.all(np.isfinite(y))) and seconds / took > 10,
          f"{seconds / took:.0f}x real time")


def old_chain_level_ref(x, v):
    # Simple pitch (SoundTouch) and robot noise can't be compared sample for
    # sample: the old pipeline without them, for its level
    w = dict(v, pitch=1.0)
    return old_chain(x, w)[RATE // 2:]


def test_switching(x):
    """Settings changed while it runs: no jumps bigger than the signal's own."""
    v = FX.dl_voice_new()
    key = {k: FX.dl_voice_key(k.encode()) for k in ("fx_mode", "pitch", "denoise", "shift_pitch")}
    out = np.zeros((len(x), 2), np.float32)
    xin = np.ascontiguousarray(x)
    changes = {RATE // 2: ("fx_mode", 1), RATE: ("pitch", 0.8), 3 * RATE // 2: ("denoise", 1),
               2 * RATE: ("fx_mode", 2), 5 * RATE // 2: ("fx_mode", 0), 3 * RATE: ("pitch", 1.0)}
    for i in range(0, len(x), BLOCK):
        if i in changes:
            k, val = changes[i]
            FX.dl_voice_set(v, key[k], val)
        FX.dl_voice_process(v, ptr(xin[i:]), min(BLOCK, len(x) - i), ptr(out[i:]))
    lat = FX.dl_voice_latency(v)
    FX.dl_voice_free(v)
    jump = float(np.max(np.abs(np.diff(out[:, 0]))))
    own = float(np.max(np.abs(np.diff(x)))) * 10 ** (12 / 20) * 1.5
    check("settings switched while running", np.all(np.isfinite(out)) and jump < max(own, 0.5),
          f"largest step {jump:.3f}, latency at the end {lat}")


def sender_constants():
    """DEFAULT_STATE and VOICE_MIC_KEYS as the sender has them, read from its
    source (the sender itself needs GStreamer to import)."""
    tree = ast.parse((HERE.parent / "hivesight_sender.py").read_text())
    found = {}
    for node in tree.body:
        if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name) \
                and node.targets[0].id in ("DEFAULT_STATE", "VOICE_MIC_KEYS"):
            found[node.targets[0].id] = ast.literal_eval(node.value)
    return found["DEFAULT_STATE"], found["VOICE_MIC_KEYS"]


def test_set_many():
    default, mic_keys = sender_constants()
    state = copy.deepcopy(default)
    done, skipped = settings.set_many(state, {
        "spiral.amount": "0.5", "spiral.arms": 5.4, "beats.on": 1, "voice.fx_mode": "robot",
        "voice.nope": 1, "nosection.x": 2, "mix.master": "loud"})
    check("set_many sets what it can", state["spiral"]["amount"] == 0.5 and state["spiral"]["arms"] == 5
          and state["beats"]["on"] is True and state["voice"]["fx_mode"] == "robot",
          f"{len(done)} set, skipped {sorted(skipped)}")
    check("set_many skips the unknown and the unusable",
          sorted(skipped) == ["mix.master", "nosection.x", "voice.nope"] and state["mix"]["master"] == 1.0,
          "unknown paths and a word for a number are left alone")
    check("set_many keeps the types", isinstance(state["spiral"]["arms"], int)
          and isinstance(state["spiral"]["amount"], float), "int stays int, float stays float")
    check("set_many with nothing", settings.set_many(state, None) == ({}, []) and
          settings.set_many(state, {}) == ({}, []), "no values, nothing set")
    # One by one comes to the same as all at once
    values = {"fx.contrast": 1.4, "fx.invert": True, "photic.hz": 12.5, "voice.preset": "mine"}
    one, many = copy.deepcopy(default), copy.deepcopy(default)
    for k, v in values.items():
        settings.set_path(one, k, v)
    settings.set_many(many, values)
    check("set_many is the same as one by one", one == many, f"{len(values)} values")


def test_preset_values():
    default, mic_keys = sender_constants()
    presets = json.loads((HERE.parent / "presets.json").read_text())
    voice = default["voice"]
    resolved = settings.resolved_presets(presets, voice, mic_keys)
    check("every preset resolved", set(resolved) == set(presets), f"{len(resolved)} presets")
    ok = all(not (set(r) & mic_keys) and set(r) == set(voice) - mic_keys for r in resolved.values())
    check("resolved presets cover every effect and no mic setting", ok, "keys match the voice state's")
    # An effect a preset doesn't mention is at its default, so a preset after a
    # ring or chorus one doesn't keep it
    extra = {k for p in presets.values() for k in p} - set(voice)
    unit = [n for n in presets if n.endswith("(unit)")]
    quiet = next((n for n in presets if not n.endswith("(unit)") and "ring_mix" not in presets[n]), None)
    check("a preset leaves unmentioned effects at default",
          quiet is not None and resolved[quiet]["ring_mix"] == voice["ring_mix"] and not extra,
          f"{quiet}: ring_mix {resolved[quiet]['ring_mix']}" if quiet else "no preset to try")
    check("a preset's own values win",
          all(resolved[n][k] == v for n, p in presets.items() for k, v in p.items() if k in resolved[n]),
          f"{len(unit)} unit presets among {len(presets)}")
    # What the sender does on choosing a preset is what the Guide is told it comes to
    state = copy.deepcopy(default)
    state["voice"]["gain_db"] = 20.0
    name = next(iter(presets))
    state["voice"].update(settings.preset_values(presets[name], voice, mic_keys))
    check("choosing a preset leaves the mic's settings", state["voice"]["gain_db"] == 20.0,
          "gain stays where it was")


def main():
    x = speech()
    x16 = speech(rate=16000, seconds=3.0)
    test_dynamics(x)
    test_spectral(x, x16)
    test_filters(x)
    test_echo(x)
    test_reverb(x)
    test_pitch()
    test_denoise()
    test_character(x)
    test_presets(x)
    test_switching(x)
    test_set_many()
    test_preset_values()
    failed = [r for r in RESULTS if not r[1]]
    print(f"\n{len(RESULTS) - len(failed)} passed, {len(failed)} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
