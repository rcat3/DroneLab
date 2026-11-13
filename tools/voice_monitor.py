#!/usr/bin/env python3
"""Listen to the board's microphone over WiFi, with voice effects.

Turn on Voice Lab on the board (Voice feature, last page), then run:

    python3 tools/voice_monitor.py                      # listen to the microphone as it is
    python3 tools/voice_monitor.py --effect robot       # through an effect
    python3 tools/voice_monitor.py --record take1.wav   # and save the microphone to a file

The board is found automatically on the local network. If it isn't (some
networks block broadcasts), give its address, shown on the Voice Lab page:

    python3 tools/voice_monitor.py --board 192.168.1.23

The board can run the effects itself too (Voice feature, Voice Effect
page). To hear its version instead of the microphone:

    python3 tools/voice_monitor.py --listen effect

Effects can also be tried on a recording, without the board, which is the
quickest way to compare them:

    python3 tools/voice_monitor.py --input take1.wav --effect robot
    python3 tools/voice_monitor.py --input take1.wav --effect pitch:0.8,ring:40 --output out.wav

--meter prints the microphone level every second, for measuring how much of
the speaker the microphone picks up.

Needs numpy and sounddevice (pip install numpy sounddevice).
"""

import argparse
import math
import queue
import socket
import struct
import sys
import threading
import time
import wave

import numpy as np

BOARD_PORT = 5005
HELLO = b"RCAT-HELLO"
HELLO_INTERVAL_S = 1.0
HEADER = struct.Struct("<IIIHH")
PACKET_MAGIC = 0x31564352  # "RCV1"
KINDS = {"mic": 0, "effect": 1}


# ----- Effects --------------------------------------------------------------
#
# Each effect processes float32 samples (-1 to 1) a block at a time and keeps
# whatever state it needs between blocks. The output is the same length as
# the input.


class Gain:
    """gain:<dB> - louder or quieter."""

    def __init__(self, fs, db=6.0):
        self.factor = 10 ** (float(db) / 20)

    def process(self, x):
        return x * self.factor


class Gate:
    """gate:<dBFS> - silence below this level, so quiet noise and breathing
    don't come through (and can't feed back)."""

    def __init__(self, fs, threshold_db=-45.0):
        self.threshold = float(threshold_db)
        self.gain = 0.0
        self.fs = fs

    def process(self, x):
        rms = math.sqrt(float(np.mean(x * x)) + 1e-12)
        db = 20 * math.log10(rms)
        target = 1.0 if db > self.threshold else 0.0
        # Open in about 5 ms, close over about 150 ms.
        rate = len(x) / self.fs / (0.005 if target > self.gain else 0.15)
        new_gain = self.gain + max(-rate, min(rate, target - self.gain))
        ramp = np.linspace(self.gain, new_gain, len(x), endpoint=False, dtype=np.float32)
        self.gain = new_gain
        return x * ramp


class Pitch:
    """pitch:<ratio> - shift the pitch (0.5 = an octave down, 0.8 = deeper,
    1.25 = higher). Two delay taps sweep through a short window and cross
    fade, which keeps the timing but adds a slight warble."""

    def __init__(self, fs, ratio=0.8, window_ms=20.0):
        self.ratio = float(ratio)
        self.window = int(fs * float(window_ms) / 1000)
        self.history = np.zeros(self.window + 4, dtype=np.float32)
        self.phase = 0.0

    def process(self, x):
        n = len(x)
        keep = len(self.history)
        buf = np.concatenate([self.history, x])
        pos = keep + np.arange(n)
        step = (1.0 - self.ratio) / self.window
        phase = (self.phase + step * (np.arange(n) + 1)) % 1.0
        self.phase = float(phase[-1])
        out = np.zeros(n, dtype=np.float32)
        for offset in (0.0, 0.5):
            p = (phase + offset) % 1.0
            delay = p * self.window + 1.0
            read = pos - delay
            i = np.floor(read).astype(int)
            frac = (read - i).astype(np.float32)
            tap = buf[i] * (1 - frac) + buf[i + 1] * frac
            out += tap * (1.0 - np.abs(2.0 * p - 1.0)).astype(np.float32)
        self.history = buf[-keep:]
        return out


class Ring:
    """ring:<Hz> - ring modulator. Around 30 Hz is the classic Dalek, higher
    sounds more metallic."""

    def __init__(self, fs, freq=30.0, mix=1.0):
        self.step = 2 * math.pi * float(freq) / fs
        self.mix = float(mix)
        self.phase = 0.0

    def process(self, x):
        t = self.phase + self.step * np.arange(1, len(x) + 1)
        self.phase = float(t[-1]) % (2 * math.pi)
        return x * (1 - self.mix + self.mix * np.sin(t).astype(np.float32))


class Resynth:
    """Rebuilds the voice from its spectral envelope (the shape that makes
    vowels and consonants) on a new buzz, so the pitch and the formants can
    be set separately. Used by the vocoder and tune effects."""

    def __init__(self, fs, formant=1.0, slice_ms=16):
        # The voice is reshaped in short slices to keep the delay down, the
        # same as the board does.
        self.fs = fs
        self.size = 1 << round(math.log2(fs * slice_ms / 1000))
        self.hop = self.size // 4
        self.window = np.hanning(self.size).astype(np.float32)
        self.inbuf = np.zeros(self.size, dtype=np.float32)
        self.history = np.zeros(2 * self.size, dtype=np.float32)  # for finding the pitch
        self.carrier = np.zeros(self.size, dtype=np.float32)
        self.outbuf = np.zeros(self.size, dtype=np.float32)
        self.pending = np.zeros(0, dtype=np.float32)
        self.ready = np.zeros(0, dtype=np.float32)
        self.phase = 0.0
        self.rng = np.random.default_rng(1)
        # Smooth the spectrum over about 200 Hz to find its shape.
        width = max(3, int(200 / (fs / self.size)) | 1)
        self.smooth = np.ones(width, dtype=np.float32) / width
        bins = np.arange(self.size // 2 + 1, dtype=np.float32)
        self.formant = float(formant)
        self.warp = bins / self.formant      # where each output bin reads the envelope from

    def carrier_hz(self):
        """The pitch of the buzz for the next hop, or 0 for a hiss (for
        consonants)."""
        raise NotImplementedError

    def _next_carrier(self):
        hz = self.carrier_hz()
        if hz <= 0:
            return self.rng.uniform(-1, 1, self.hop).astype(np.float32)
        saw = (self.phase + hz / self.fs * np.arange(1, self.hop + 1)) % 1.0
        self.phase = float(saw[-1])
        return (2 * saw - 1).astype(np.float32)

    def _frame(self):
        voice = np.abs(np.fft.rfft(self.inbuf * self.window))
        envelope = np.convolve(voice, self.smooth, mode="same")
        if self.formant != 1.0:
            envelope = np.interp(self.warp, np.arange(len(envelope)), envelope, right=0.0)
        carrier = np.fft.rfft(self.carrier * self.window)
        flat = carrier / (np.convolve(np.abs(carrier), self.smooth, mode="same") + 1e-6)
        self.outbuf += np.fft.irfft(envelope * flat, self.size).astype(np.float32)
        done = self.outbuf[: self.hop] * 0.5  # Hann windows at 75% overlap add up to 2
        self.outbuf = np.concatenate([self.outbuf[self.hop:], np.zeros(self.hop, dtype=np.float32)])
        return done

    def process(self, x):
        self.pending = np.concatenate([self.pending, x])
        out = []
        while len(self.pending) >= self.hop:
            chunk, self.pending = self.pending[: self.hop], self.pending[self.hop:]
            self.inbuf = np.concatenate([self.inbuf[self.hop:], chunk])
            self.history = np.concatenate([self.history[self.hop:], chunk])
            self.carrier = np.concatenate([self.carrier[self.hop:], self._next_carrier()])
            out.append(self._frame())
        self.ready = np.concatenate([self.ready] + out)
        # Hand back as much as came in, starting once the first frame is ready.
        if len(self.ready) < len(x):
            return np.zeros(len(x), dtype=np.float32)
        result, self.ready = self.ready[: len(x)], self.ready[len(x):]
        return result


class Vocoder(Resynth):
    """vocoder:<Hz>:<formant> - monotone robot. Your voice's spectral shape on
    a buzz at a fixed pitch. formant above 1 (like 1.2) moves the vowels up,
    toward a female voice."""

    def __init__(self, fs, pitch=110.0, formant=1.0):
        super().__init__(fs, formant)
        self.pitch = float(pitch)

    def carrier_hz(self):
        return self.pitch


class Tune(Resynth):
    """tune:<ratio>:<formant>:<snap> - follows your pitch and multiplies it by
    ratio (1.6 takes a deep voice to a typical female one), with the formants
    moved by formant (around 1.15-1.2 for female). snap:1 snaps the pitch to
    musical notes, for a stepped, auto-tuned robot sound. Consonants come
    through as a hiss."""

    def __init__(self, fs, ratio=1.6, formant=1.18, snap=0):
        super().__init__(fs, formant)
        self.ratio = float(ratio)
        self.snap = bool(int(float(snap)))
        self.hz = 0.0
        self.min_lag = int(fs / 500)
        self.max_lag = int(fs / 60)
        # The pitch is found from the last 32 ms (two slices), to catch at
        # least two cycles of a deep voice. The autocorrelation of its window
        # undoes the window's fade at long lags.
        n = len(self.history)
        self.detect_window = np.hanning(n).astype(np.float32)
        w = np.fft.rfft(self.detect_window, 2 * n)
        self.window_ac = np.fft.irfft(np.abs(w) ** 2)[:n]
        self.window_ac /= self.window_ac[0]

    def _detect(self):
        """Your pitch in Hz, or 0 if this bit isn't voiced."""
        n = len(self.history)
        x = self.history * self.detect_window
        if float(np.mean(x * x)) < 1e-7:
            return 0.0
        spectrum = np.fft.rfft(x, 2 * n)
        ac = np.fft.irfft(np.abs(spectrum) ** 2)[:n]
        ac = ac / (ac[0] + 1e-12) / (self.window_ac + 1e-6)
        lags = ac[self.min_lag:self.max_lag]
        best = int(np.argmax(lags))
        if lags[best] < 0.45:
            return 0.0
        lag = best + self.min_lag
        # Refine the peak between samples.
        if 0 < best < len(lags) - 1:
            a, b, c = lags[best - 1], lags[best], lags[best + 1]
            lag += 0.5 * (a - c) / (a - 2 * b + c + 1e-12)
        return self.fs / lag

    def carrier_hz(self):
        f0 = self._detect()
        if f0 <= 0:
            self.hz = 0.0
            return 0.0
        target = f0 * self.ratio
        if self.snap:
            note = round(12 * math.log2(target / 440.0))
            target = 440.0 * 2 ** (note / 12)
            self.hz = target
        else:
            # Glide a little, so the pitch doesn't jitter.
            self.hz = target if self.hz <= 0 else self.hz + 0.5 * (target - self.hz)
        return self.hz


class Shift:
    """shift:<ratio>:<formant>:<snap> - raises or lowers your pitch by ratio
    while keeping your own voice's texture (PSOLA: pitch-synchronous overlap
    and add). It finds your pitch, cuts your voice into grains two pitch
    periods long, one per period, and lays them down closer together (higher)
    or further apart (lower). Squeezing each grain by formant moves the vowels
    up as well, less than the pitch (around 1.15-1.2 for female). snap:1 snaps
    the pitch to musical notes. Unvoiced sounds (consonants, breath) pass
    through. It adds about 20 ms of delay, two pitch periods."""

    HOP = 64            # how often the pitch is found, in samples at 16 kHz
    HISTORY = 512       # the pitch is found from the last 32 ms
    DECIMATE = 4
    DELAY_MS = 5.0      # on top of a grain's reach either side, about 20 ms in all
    UNVOICED_MS = 5.0   # grain spacing for unvoiced sound
    LAG_RELAX = 8.0     # samples per grain
    MIN_WEIGHT = 0.5    # the windows' sum is divided out, but never more than doubles anything

    def __init__(self, fs, ratio=1.9, formant=1.2, snap=0):
        self.fs = fs
        self.ratio = float(ratio)
        self.formant = float(formant)
        self.snap = bool(int(float(snap)))
        self.delay = int(fs * self.DELAY_MS / 1000)
        self.unvoiced = int(fs * self.UNVOICED_MS / 1000)
        self.max_period = fs // 60
        self.min_period = fs // 500
        self.buf = np.zeros(0, dtype=np.float32)    # input, from absolute sample self.base
        self.base = 0
        self.count = 0                              # input samples so far
        self.since_detect = 0
        self.period = 0.0                           # current pitch period in samples, 0 unvoiced
        self.marks = []                             # analysis marks: (position, period or 0)
        self.last_mark = 0
        self.next_synth = 0.0                       # next synthesis mark, in output time
        self.lag = 0.0                              # how far behind each synthesis mark its grain is taken from
        self.out = np.zeros(0, dtype=np.float32)    # overlap-add, from absolute output time self.out_base
        self.weight = np.zeros(0, dtype=np.float32) # the windows' sum there, to even out the level
        self.out_base = -self.delay

    def _at(self, pos, n):
        """n input samples from absolute position pos (fractional positions
        are interpolated)."""
        idx = pos - self.base
        i = np.floor(idx).astype(int)
        f = (idx - i).astype(np.float32)
        i = np.clip(i, 0, len(self.buf) - 2)
        return self.buf[i] * (1 - f) + self.buf[i + 1] * f

    def _detect(self):
        """The board's pitch detector: normalized autocorrelation at 4 kHz."""
        h = self.buf[-self.HISTORY:]
        if len(h) < self.HISTORY:
            return 0.0
        x = h.reshape(-1, self.DECIMATE).mean(axis=1)
        n = len(x)
        energy = np.concatenate([[0.0], np.cumsum(x * x)])
        if energy[-1] / n < 1e-7:
            return 0.0
        pfs = self.fs / self.DECIMATE
        lo, hi = int(pfs / 500), int(pfs / 60)
        r = {}
        for lag in range(lo - 1, hi + 2):
            r[lag] = float(np.dot(x[:n - lag], x[lag:])) / math.sqrt(energy[n - lag] * (energy[n] - energy[lag]) + 1e-12)
        best = max(range(lo, hi + 1), key=lambda k: r[k])
        if r[best] < 0.5:
            return 0.0
        a, b, c = r[best - 1], r[best], r[best + 1]
        lag = best + 0.5 * (a - c) / (a - 2 * b + c + 1e-12)
        return self.fs / (lag * self.DECIMATE)

    def _refine(self, guess, period):
        """Move a new mark to where the waveform best matches the one at the
        last mark, so every grain starts at the same point in its cycle."""
        half = int(period / 2)
        reach = int(period / 4)
        ref = self._at(self.last_mark + np.arange(-half, half), 2 * half)
        best, best_d = -1e9, 0
        for d in range(-reach, reach + 1):
            seg = self._at(guess + d + np.arange(-half, half), 2 * half)
            score = float(np.dot(ref, seg)) / math.sqrt(float(np.dot(seg, seg)) + 1e-12)
            if score > best:
                best, best_d = score, d
        return guess + best_d

    def _peak(self, guess, period):
        """The strongest point within half a period of guess: where the vocal
        cords close, which is where a grain is best centered."""
        half = int(period / 2)
        seg = np.abs(self._at(guess + np.arange(-half, half + 1), 2 * half + 1))
        return guess - half + int(np.argmax(seg))

    def _add_marks(self):
        while True:
            p = self.period
            if p > 0:
                if self.last_mark + p + p * 0.75 + 1 > self.count:
                    return
                if self.marks and self.marks[-1][1] > 0:
                    pos = self._refine(self.last_mark + int(p + 0.5), p)
                else:
                    # The first of a voiced run: start at a peak, and the rest
                    # follow it
                    pos = self._peak(self.last_mark + int(p + 0.5), p)
            else:
                if self.last_mark + 2 * self.unvoiced + 1 > self.count:
                    return
                pos = self.last_mark + self.unvoiced
            self.marks.append((pos, p))
            self.last_mark = pos

    def _next_half(self):
        """About how far the next grain reaches back from its center."""
        return self.period / self.formant if self.period > 0 else self.unvoiced

    def _grain(self, mark, at):
        """Overlap-add the grain at an analysis mark, centered at output time
        at. Returns how far on the next synthesis mark is."""
        pos, p = mark
        if p > 0:
            f0 = self.fs / p
            target = f0 * self.ratio
            if self.snap:
                target = 440.0 * 2 ** (round(12 * math.log2(target / 440.0)) / 12)
            half = p / self.formant
            spacing = self.fs / target
        else:
            half = self.unvoiced
            spacing = self.unvoiced
            p = self.unvoiced
        k = np.arange(-int(half), int(half) + 1)
        grain = self._at(pos + k * (p / half), len(k))
        window = (0.5 + 0.5 * np.cos(np.pi * k / half)).astype(np.float32)
        start = int(round(at)) + k[0] - self.out_base
        need = start + len(k)
        self._grow(need)
        if start >= 0:
            self.out[start:need] += grain * window
            self.weight[start:need] += window
        return spacing

    def _grow(self, need):
        if need > len(self.out):
            extra = np.zeros(need - len(self.out), dtype=np.float32)
            self.out = np.concatenate([self.out, extra])
            self.weight = np.concatenate([self.weight, extra])

    def process(self, x):
        n = len(x)
        self.buf = np.concatenate([self.buf, x.astype(np.float32)])
        for i in range(n):
            self.count += 1
            self.since_detect += 1
            if self.since_detect == self.HOP:
                self.since_detect = 0
                f0 = self._detect_upto(self.count)
                self.period = self.fs / f0 if f0 > 0 else 0.0
                self._add_marks()
        self._add_marks()

        # Synthesis marks, up to where the output's needed, from the nearest
        # analysis mark that's ready (its grain is all in)
        # Each synthesis mark takes the grain nearest to the same time in the
        # input, lag behind it, so the timing stays as it was. lag grows at
        # once when a grain isn't ready yet, and shrinks back slowly, so the
        # delay stays steady from voiced sounds to unvoiced ones and back.
        end = self.count - self.delay
        while self.next_synth - self._next_half() < end:
            ready = [m for m in self.marks if m[0] + (m[1] or self.unvoiced) <= self.count]
            if not ready:
                break
            newest = ready[-1][0]
            if newest < self.next_synth - self.lag:
                self.lag = self.next_synth - newest
            want = self.next_synth - self.lag
            mark = min(ready, key=lambda m: abs(m[0] - want))
            self.next_synth += self._grain(mark, self.next_synth)
            self.lag -= self.LAG_RELAX

        start = end - n
        y = np.zeros(n, dtype=np.float32)
        self._grow(end - self.out_base)
        lo = max(start, self.out_base)
        if end > lo:
            done = slice(lo - self.out_base, end - self.out_base)
            y[lo - start:] = self.out[done] / np.maximum(self.weight[done], self.MIN_WEIGHT)
        # Forget what's done with
        drop = end - self.out_base
        if drop > 0:
            self.out = self.out[drop:]
            self.weight = self.weight[drop:]
            self.out_base = end
        keep_from = self.count - 4 * self.max_period - self.delay
        if keep_from > self.base:
            self.buf = self.buf[keep_from - self.base:]
            self.base = keep_from
        self.marks = [m for m in self.marks if m[0] > keep_from + self.max_period]
        return y

    def _detect_upto(self, count):
        h = self.buf[count - self.base - self.HISTORY:count - self.base] if count - self.base >= self.HISTORY else None
        if h is None:
            return 0.0
        saved = self.buf
        self.buf = h
        try:
            return self._detect()
        finally:
            self.buf = saved


class Chorus:
    """chorus:<Hz>:<ms>:<mix> - adds two slightly detuned copies of the voice,
    for a synthetic shimmer. Short delays (ms around 2) sound more like a
    flanger."""

    def __init__(self, fs, rate=0.8, depth_ms=8.0, mix=0.5):
        self.fs = fs
        self.rate = float(rate)
        self.depth = fs * float(depth_ms) / 1000
        self.base = self.depth + 2
        self.mix = float(mix)
        self.history = np.zeros(int(self.base + self.depth) + 4, dtype=np.float32)
        self.t = 0

    def process(self, x):
        n = len(x)
        keep = len(self.history)
        buf = np.concatenate([self.history, x])
        pos = keep + np.arange(n)
        t = (self.t + np.arange(n)) / self.fs
        self.t += n
        wet = np.zeros(n, dtype=np.float32)
        for offset in (0.0, math.pi):
            delay = self.base + self.depth * 0.5 * (1 + np.sin(2 * math.pi * self.rate * t + offset))
            read = pos - delay
            i = np.floor(read).astype(int)
            frac = (read - i).astype(np.float32)
            wet += buf[i] * (1 - frac) + buf[i + 1] * frac
        self.history = buf[-keep:]
        return (1 - self.mix) * x + self.mix * 0.5 * wet


class Highpass:
    """highpass:<Hz> - takes out the low rumble below this, for a thinner,
    lighter voice."""

    def __init__(self, fs, freq=200.0):
        # A second order Butterworth filter (RBJ's cookbook).
        w = 2 * math.pi * float(freq) / fs
        alpha = math.sin(w) / math.sqrt(2)
        a0 = 1 + alpha
        self.b = [(1 + math.cos(w)) / 2 / a0, -(1 + math.cos(w)) / a0, (1 + math.cos(w)) / 2 / a0]
        self.a = [-2 * math.cos(w) / a0, (1 - alpha) / a0]
        self.state = [0.0, 0.0, 0.0, 0.0]

    def process(self, x):
        b0, b1, b2 = self.b
        a1, a2 = self.a
        x1, x2, y1, y2 = self.state
        out = np.empty_like(x)
        for i, v in enumerate(x.tolist()):
            y = b0 * v + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2, x1, y2, y1 = x1, v, y1, y
            out[i] = y
        self.state = [x1, x2, y1, y2]
        return out


class Lowpass(Highpass):
    """lowpass:<Hz> - takes out everything above this, for a narrower, radio
    or speaker-like voice."""

    def __init__(self, fs, freq=3000.0):
        w = 2 * math.pi * float(freq) / fs
        alpha = math.sin(w) / math.sqrt(2)
        a0 = 1 + alpha
        self.b = [(1 - math.cos(w)) / 2 / a0, (1 - math.cos(w)) / a0, (1 - math.cos(w)) / 2 / a0]
        self.a = [-2 * math.cos(w) / a0, (1 - alpha) / a0]
        self.state = [0.0, 0.0, 0.0, 0.0]


class Drive:
    """drive:<dB> - soft clipping above this many dB below full scale. Quiet
    sound passes as it is, and louder sound is squashed, which adds a harsh
    edge and evens out the level."""

    def __init__(self, fs, db=30.0):
        self.knee = 10 ** (-float(db) / 20)

    def process(self, x):
        return (self.knee * np.tanh(x / self.knee)).astype(np.float32)


class Crush:
    """crush:<bits>:<factor> - fewer bits and a lower sample rate, for a
    lo-fi digital edge."""

    def __init__(self, fs, bits=8, factor=2):
        self.levels = 2 ** (int(bits) - 1)
        self.factor = max(1, int(factor))
        self.held = 0.0
        self.count = 0

    def process(self, x):
        out = np.empty_like(x)
        for i, v in enumerate(x):
            if self.count == 0:
                self.held = round(float(v) * self.levels) / self.levels
            out[i] = self.held
            self.count = (self.count + 1) % self.factor
        return out


EFFECTS = {"gain": Gain, "gate": Gate, "pitch": Pitch, "ring": Ring, "vocoder": Vocoder, "tune": Tune, "shift": Shift,
           "chorus": Chorus, "highpass": Highpass, "lowpass": Lowpass, "drive": Drive, "crush": Crush}

# Named combinations to start from.
PRESETS = {
    # Your own voice, like a mask's voice amplifier
    "natural": "gate:-45,highpass:200,lowpass:5000",
    # Lower and robotic
    "robot": "gate:-45,vocoder:110",
    "deep": "gate:-45,pitch:0.75",
    "dalek": "gate:-45,highpass:400,pitch:1.26,drive:24,ring:30,lowpass:3500,gain:8",
    "drone": "gate:-45,pitch:0.85,ring:60:0.6,crush:10:1",
    # Higher, toward a female voice. Your own pitch, raised, with the vowels
    # moved up less than the pitch so it doesn't sound like a chipmunk. Female
    # and Fembot keep your own voice (shift); the others rebuild it (tune).
    "female": "gate:-45,shift:1.9:1.2,highpass:250,lowpass:4500,gain:2",
    "fembot": "gate:-45,shift:1.9:1.2:1,ring:300:0.2,crush:10:1,chorus:2:1.5:0.5,highpass:250,lowpass:4500,gain:8",
    "synthetic": "gate:-45,tune:1.7:1.2:1,ring:500:0.15,crush:12:1",
    "android": "gate:-45,vocoder:220:1.18,chorus:0.4:4:0.3",
    "ai": "gate:-45,highpass:250,tune:1.75:1.22:1,chorus:1.5:2:0.4",
    "cyborg": "gate:-45,tune:1.5:1.15,ring:90:0.35,crush:10:1",
    # For comparison: the plain pitch shifter, which moves the vowels as well
    "chipmunk": "gate:-45,pitch:1.6",
}


def build_chain(spec, fs):
    if not spec:
        return []
    spec = PRESETS.get(spec, spec)
    chain = []
    for part in spec.split(","):
        name, *params = part.strip().split(":")
        if name not in EFFECTS:
            sys.exit(f"Unknown effect '{name}'. Effects: {', '.join(EFFECTS)}. Presets: {', '.join(PRESETS)}")
        chain.append(EFFECTS[name](fs, *params))
    return chain


def run_chain(chain, x):
    for effect in chain:
        x = effect.process(x)
    return np.clip(x, -1.0, 1.0)


# ----- Files ----------------------------------------------------------------


class WavWriter:
    def __init__(self, path, fs):
        self.wav = wave.open(path, "wb")
        self.wav.setnchannels(1)
        self.wav.setsampwidth(2)
        self.wav.setframerate(fs)

    def write(self, x):
        self.wav.writeframes((np.clip(x, -1, 1) * 32767).astype("<i2").tobytes())

    def close(self):
        self.wav.close()


def read_wav(path):
    with wave.open(path, "rb") as w:
        if w.getsampwidth() != 2:
            sys.exit(f"{path}: only 16-bit WAV files are supported")
        data = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.float32) / 32768
        channels = w.getnchannels()
        if channels > 1:
            data = data.reshape(-1, channels).mean(axis=1)
        return data, w.getframerate()


def process_file(args):
    x, fs = read_wav(args.input)
    chain = build_chain(args.effect, fs)
    block = fs // 100
    y = np.concatenate([run_chain(chain, x[i:i + block]) for i in range(0, len(x), block)])
    if args.output:
        out = WavWriter(args.output, fs)
        out.write(y)
        out.close()
        print(f"Wrote {args.output}")
    if not args.no_play:
        import sounddevice as sd
        sd.play(y, fs)
        sd.wait()


# ----- Streaming from the board ----------------------------------------------


class Player:
    """Plays blocks as they arrive, keeping a little in hand to ride out
    WiFi hiccups."""

    def __init__(self, fs, latency_ms):
        import sounddevice as sd
        self.target = int(fs * latency_ms / 1000)
        self.buffer = np.zeros(0, dtype=np.float32)
        self.lock = threading.Lock()
        self.priming = True
        self.underruns = 0
        self.stream = sd.OutputStream(samplerate=fs, channels=1, dtype="float32", callback=self._callback)
        self.stream.start()

    def add(self, x):
        with self.lock:
            self.buffer = np.concatenate([self.buffer, x])
            # If it's fallen far behind, skip ahead rather than lag.
            if len(self.buffer) > 3 * self.target:
                self.buffer = self.buffer[-self.target:]

    def _callback(self, out, frames, time_info, status):
        with self.lock:
            if self.priming and len(self.buffer) >= self.target:
                self.priming = False
            if self.priming or len(self.buffer) < frames:
                out.fill(0)
                if not self.priming:
                    self.underruns += 1
                    self.priming = True
                return
            out[:, 0] = self.buffer[:frames]
            self.buffer = self.buffer[frames:]


def stream(args):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    sock.bind(("", 0))
    sock.settimeout(0.2)
    target = (args.board or "255.255.255.255", BOARD_PORT)

    print(f"Looking for the board{' at ' + args.board if args.board else ''}... (Ctrl+C to stop)")
    last_hello = 0.0
    fs = None
    chain = []
    player = None
    raw_file = out_file = None
    last_seq = None
    received = lost = 0
    meter_sum = 0.0
    meter_peak = 0.0
    meter_count = 0
    last_report = time.time()

    try:
        while True:
            now = time.time()
            if now - last_hello >= HELLO_INTERVAL_S:
                sock.sendto(HELLO, target)
                last_hello = now

            try:
                data, sender = sock.recvfrom(2048)
            except socket.timeout:
                continue
            if len(data) < HEADER.size:
                continue
            magic, seq, rate, kind, count = HEADER.unpack_from(data)
            if magic != PACKET_MAGIC or len(data) < HEADER.size + 2 * count or kind != KINDS[args.listen]:
                continue
            x = np.frombuffer(data, dtype="<i2", count=count, offset=HEADER.size).astype(np.float32) / 32768

            if fs != rate:
                fs = rate
                print(f"Streaming from {sender[0]} at {fs} Hz")
                chain = build_chain(args.effect, fs)
                if not args.no_play:
                    player = Player(fs, args.latency)
                if args.record:
                    raw_file = WavWriter(args.record, fs)
                if args.record_effect:
                    out_file = WavWriter(args.record_effect, fs)

            # Fill lost packets with silence, so the timing stays right.
            if last_seq is not None:
                gap = (seq - last_seq - 1) & 0xFFFFFFFF
                if 0 < gap < 50:
                    lost += gap
                    x = np.concatenate([np.zeros(gap * count, dtype=np.float32), x])
            last_seq = seq
            received += 1

            if raw_file:
                raw_file.write(x)
            y = run_chain(chain, x)
            if out_file:
                out_file.write(y)
            if player:
                player.add(y)

            meter_sum += float(np.sum(x * x))
            meter_peak = max(meter_peak, float(np.max(np.abs(x))))
            meter_count += len(x)
            if now - last_report >= 1.0:
                if args.meter and meter_count:
                    rms_db = 10 * math.log10(meter_sum / meter_count + 1e-12)
                    peak_db = 20 * math.log10(meter_peak + 1e-12)
                    print(f"level {rms_db:6.1f} dBFS   peak {peak_db:6.1f} dBFS   "
                          f"lost {100 * lost / max(1, received + lost):.1f}%")
                meter_sum = meter_peak = 0.0
                meter_count = 0
                last_report = now
    except KeyboardInterrupt:
        pass
    finally:
        for f in (raw_file, out_file):
            if f:
                f.close()
        if received:
            print(f"\n{received} packets, {lost} lost"
                  + (f", {player.underruns} gaps in playback" if player else ""))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--board", help="the board's IP address, if it isn't found automatically")
    parser.add_argument("--effect", default="",
                        help=f"an effect chain like pitch:0.8,ring:40, or a preset: {', '.join(PRESETS)}")
    parser.add_argument("--listen", choices=KINDS, default="mic",
                        help="mic: the microphone, as it is (default). effect: the board's own voice effect")
    parser.add_argument("--record", help="save what's received, before --effect, to this WAV file")
    parser.add_argument("--record-effect", help="save the sound after the effect to this WAV file")
    parser.add_argument("--input", help="process this WAV file instead of listening to the board")
    parser.add_argument("--output", help="with --input, save the result to this WAV file")
    parser.add_argument("--no-play", action="store_true", help="don't play anything")
    parser.add_argument("--meter", action="store_true", help="print the microphone level every second")
    parser.add_argument("--latency", type=float, default=80, help="playback buffer in ms (default 80)")
    args = parser.parse_args()

    if args.input:
        process_file(args)
    else:
        stream(args)


if __name__ == "__main__":
    main()
