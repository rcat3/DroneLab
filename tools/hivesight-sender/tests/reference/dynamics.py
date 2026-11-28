"""Envelope-following gate, compressor and limiter for the operator's voice.

GStreamer's `audiodynamic` computes gain from each *instantaneous* sample value,
which makes it a waveshaper: quiet speech gets its zero-crossings crushed (the
expander) and loud speech gets its peaks bent (the compressor). This version
tracks a smoothed level and applies gain as a smooth ramp, so the waveform
itself is never distorted.

Processing runs in ~1 ms sub-blocks: one level measurement and gain decision per
sub-block, with gain linearly interpolated across samples.
"""
from __future__ import annotations

import math

import numpy as np

SUB = 48            # 1 ms at 48 kHz
GATE_FLOOR_DB = -30.0  # closed gate attenuates rather than mutes: less choppy
GATE_HOLD_S = 0.20
COMP_THRESHOLD_DB = -24.0
LIMIT_CEILING = 0.89   # -1 dBFS


def _coef(tau_s: float, dt: float) -> float:
    return 1.0 - math.exp(-dt / tau_s) if tau_s > 0 else 1.0


def db(x: float) -> float:
    return 20.0 * math.log10(max(x, 1e-9))


class Dynamics:
    def __init__(self, rate: int = 48000):
        self.rate = rate
        self.env_db = -100.0     # smoothed input level (pre-gain)
        self.gate_db = GATE_FLOOR_DB
        self.hold = 0.0
        self.comp_db = 0.0
        self.lim = 1.0
        self.prev_gain = 0.0     # linear gain at end of previous sub-block
        self.in_db = -100.0      # for metering
        self.out_db = -100.0
        self.gate_open = False

    def process(self, x: np.ndarray, gain_db: float, gate_thr_db: float,
                ratio: float, mute: bool) -> np.ndarray:
        n = len(x)
        y = np.empty_like(x)
        dt = SUB / self.rate
        a_env_up, a_env_dn = _coef(0.002, dt), _coef(0.12, dt)
        a_gate_open, a_gate_close = _coef(0.002, dt), _coef(0.08, dt)
        a_comp_att, a_comp_rel = _coef(0.005, dt), _coef(0.15, dt)
        a_lim_rel = _coef(0.05, dt)
        ratio = max(1.0, ratio)
        makeup = -COMP_THRESHOLD_DB * (1.0 - 1.0 / ratio) * 0.5
        in_sq = 0.0
        out_sq = 0.0

        for start in range(0, n, SUB):
            seg = x[start:start + SUB]
            m = len(seg)
            peak = float(np.max(np.abs(seg))) if m else 0.0
            in_sq += float(np.dot(seg, seg))
            level = db(peak)
            a = a_env_up if level > self.env_db else a_env_dn
            self.env_db += (level - self.env_db) * a

            # Gate (on the raw mic level, so the threshold doesn't move with gain).
            if self.env_db > gate_thr_db:
                self.hold = GATE_HOLD_S
            else:
                self.hold = max(0.0, self.hold - dt)
            self.gate_open = self.hold > 0.0
            target = 0.0 if self.gate_open else GATE_FLOOR_DB
            a = a_gate_open if target > self.gate_db else a_gate_close
            self.gate_db += (target - self.gate_db) * a

            # Compressor (on the level after pre-gain).
            over = self.env_db + gain_db - COMP_THRESHOLD_DB
            want = -over * (1.0 - 1.0 / ratio) if over > 0 else 0.0
            a = a_comp_att if want < self.comp_db else a_comp_rel
            self.comp_db += (want - self.comp_db) * a

            g_db = gain_db + self.gate_db + self.comp_db + (makeup if ratio > 1.0 else 0.0)
            g = 0.0 if mute else 10.0 ** (g_db / 20.0)

            # Limiter: instant attack, smooth release.
            if peak * g * self.lim > LIMIT_CEILING:
                self.lim = LIMIT_CEILING / (peak * g)
            else:
                self.lim += (1.0 - self.lim) * a_lim_rel
            g *= self.lim

            ramp = np.linspace(self.prev_gain, g, m, endpoint=True, dtype=np.float32)
            out = seg * ramp
            y[start:start + m] = out
            out_sq += float(np.dot(out, out))
            self.prev_gain = g

        np.clip(y, -0.99, 0.99, out=y)
        if n:
            self.in_db = db(math.sqrt(in_sq / n))
            self.out_db = db(math.sqrt(out_sq / n))
        return y
