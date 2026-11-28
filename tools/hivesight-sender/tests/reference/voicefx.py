"""Spectral voice transformation: independent pitch and formant shifting, and
a formant-preserving robot (vocoder).

Plain pitch shifting (resample + time-stretch, as GStreamer's `pitch` does)
moves the formants (the vocal-tract resonances that identify a voice) along
with the pitch. A deep male voice pitched up an octave then sounds like a
chipmunk rather than a woman. A typical male to female change is about 1.7-1.9x
pitch but only about 1.15-1.2x formants, so the two have to be separate.

Method, per STFT frame (2048 samples, hop 256, Hann windows):
  1. Phase-vocoder analysis gives each bin's magnitude and true frequency.
  2. Cepstral smoothing of the log magnitude gives the spectral envelope
     (formants). Dividing by it leaves the "flat" harmonic fine structure.
  3. shift:  the fine structure is moved to k * pitch (frequencies scaled),
             then multiplied by the envelope warped to k / formant.
     robot:  the fine structure is replaced by harmonics of a fixed f0 (plus a
             little noise for consonants), shaped by the warped envelope.
  4. Phase-vocoder synthesis (accumulated phase) and windowed overlap-add.

Latency is one frame (2048 samples, about 43 ms). It only applies while a
mode is active: with mode "off" the audio passes straight through.
"""
from __future__ import annotations

import numpy as np

N = 2048
HOP = 256
NBINS = N // 2 + 1
LIFTER = 100         # cepstral coefficients kept for the envelope (~2 ms; below the pitch
                     # period of voices up to ~400 Hz, fine enough to separate F1 and F2)
TWO_PI = 2.0 * np.pi


class SpectralVoice:
    def __init__(self, rate: int = 48000, seed: int = 7):
        self.rate = rate
        self.win = (0.5 - 0.5 * np.cos(TWO_PI * np.arange(N) / N))  # periodic Hann
        # OLA gain of analysis*synthesis Hann at hop N/8: sum(w^2) / HOP = 3/8 * N / HOP
        self.norm = (self.win ** 2).sum() / HOP
        self.k = np.arange(NBINS, dtype=np.float64)
        self.expected = TWO_PI * HOP * self.k / N
        self.rng = np.random.default_rng(seed)
        self.reset()

    def reset(self):
        self.frame = np.zeros(N)
        self.pending = np.zeros(0)
        self.ola = np.zeros(N)
        self.out = np.zeros(HOP)     # prefill = fixed latency, never runs dry
        self.last_phase = np.zeros(NBINS)
        self.sum_phase = np.zeros(NBINS)
        self.gain = 1.0
        # Slow loudness match between input and output (handles overlap-add
        # losses the per-frame energy match can't see).
        self.p_in = 0.0
        self.p_out = 0.0
        self.corr = 1.0

    # ------------------------------------------------------------------
    def process(self, x: np.ndarray, mode: str, pitch: float = 1.0, formant: float = 1.0,
                robot_hz: float = 200.0, robot_noise: float = 0.1) -> np.ndarray:
        if mode not in ("shift", "robot"):
            if self.pending.size or self.out.size != HOP:
                self.reset()
            return x
        self.pending = np.concatenate([self.pending, x.astype(np.float64)])
        produced = []
        a = 1.0 - np.exp(-HOP / (0.3 * self.rate))  # ~300 ms loudness window
        while self.pending.size >= HOP:
            hop_in = self.pending[:HOP]
            self.frame = np.concatenate([self.frame[HOP:], hop_in])
            self.pending = self.pending[HOP:]
            y = self._frame(mode, pitch, formant, robot_hz, robot_noise)
            self.p_in += (float(np.mean(hop_in ** 2)) - self.p_in) * a
            self.p_out += (float(np.mean(y ** 2)) - self.p_out) * a
            if self.p_in > 1e-8 and self.p_out > 1e-10:  # only adapt while there is signal
                want = float(np.clip(np.sqrt(self.p_in / self.p_out), 0.5, 6.0))
                self.corr += (want - self.corr) * 0.05
            produced.append(y * self.corr)
        if produced:
            self.out = np.concatenate([self.out, *produced])
        y, self.out = self.out[:x.size], self.out[x.size:]
        return y.astype(np.float32)

    # ------------------------------------------------------------------
    def _envelope(self, mag: np.ndarray) -> np.ndarray:
        cep = np.fft.irfft(np.log(mag + 1e-9), n=N)
        cep[LIFTER:N - LIFTER + 1] = 0.0
        return np.exp(np.fft.rfft(cep).real)

    def _frame(self, mode, pitch, formant, robot_hz, robot_noise) -> np.ndarray:
        X = np.fft.rfft(self.frame * self.win)
        mag = np.abs(X)
        phase = np.angle(X)

        # True frequency of each bin, in bins (phase-vocoder analysis).
        dphi = phase - self.last_phase - self.expected
        self.last_phase = phase
        dphi = (dphi + np.pi) % TWO_PI - np.pi
        true_bin = self.k + dphi * N / (TWO_PI * HOP)

        env = self._envelope(mag)
        formant = float(np.clip(formant, 0.5, 2.0))
        env_w = np.interp(self.k / formant, self.k, env, right=env[-1] * 1e-3)

        syn_mag = np.zeros(NBINS)
        syn_bin = self.k.copy()  # default: bin centre (keeps phase advancing sanely)

        if mode == "shift":
            pitch = float(np.clip(pitch, 0.25, 4.0))
            flat = np.minimum(mag / env, 20.0)
            dest = np.rint(self.k * pitch).astype(np.int64)
            ok = (dest > 0) & (dest < NBINS)
            np.add.at(syn_mag, dest[ok], flat[ok])
            syn_bin[dest[ok]] = true_bin[ok] * pitch
            syn_mag *= env_w
        else:  # robot: harmonics of a fixed f0, shaped by the (warped) voice envelope
            f0_bins = float(np.clip(robot_hz, 40.0, 1000.0)) * N / self.rate
            h = np.arange(1, int((NBINS - 2) / f0_bins) + 1)
            hb = h * f0_bins
            dest = np.rint(hb).astype(np.int64)
            syn_mag[dest] = env_w[dest]
            syn_bin[dest] = hb
            if robot_noise > 0:
                syn_mag += robot_noise * env_w * self.rng.random(NBINS)

        # Keep frame energy matched to the input so the effect isn't louder/quieter.
        e_in = float(np.sum(mag ** 2))
        e_out = float(np.sum(syn_mag ** 2))
        g = np.sqrt(e_in / e_out) if e_out > 1e-12 else 0.0
        self.gain += (min(g, 8.0) - self.gain) * 0.3
        syn_mag *= self.gain

        self.sum_phase = (self.sum_phase + TWO_PI * HOP * syn_bin / N) % TWO_PI
        if mode == "robot" and robot_noise > 0:
            # Noise bins get random phase; harmonic bins keep coherent phase.
            noisy = np.ones(NBINS, dtype=bool)
            noisy[dest] = False
            ph = np.where(noisy, self.rng.random(NBINS) * TWO_PI, self.sum_phase)
        else:
            ph = self.sum_phase
        y = np.fft.irfft(syn_mag * np.exp(1j * ph), n=N) * self.win / self.norm

        self.ola += y
        out = self.ola[:HOP].copy()
        self.ola = np.concatenate([self.ola[HOP:], np.zeros(HOP)])
        return out
