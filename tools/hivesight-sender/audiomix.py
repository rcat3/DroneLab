"""The sound that goes to the Vessels as one stream beside the voice: the
soundtrack of whatever film is on (each deck's own, so a dissolve fades
one into the other) and the music. Tracks are mixed here, in numpy, in
10 ms blocks with gains that move smoothly, so crossfades are exact and
nothing is rebuilt. The mix goes out as RTP L16 stereo on the media port,
as a film's sound always did, so the Vessel needs nothing new."""
from __future__ import annotations

import logging
import threading
import time

import numpy as np

log = logging.getLogger("hivesight")

RATE = 48000
BLOCK = 480                      # 10 ms
RING_S = 6                       # seconds a track may hold
HOLD_S = 0.6                     # keeps sending this long after the last sound


class Track:
    """One source of sound: a ring of stereo float32 that the decoder fills
    (in real time) and the mixer empties, and a gain that ramps."""

    def __init__(self, name: str):
        self.name = name
        self._ring = np.zeros((RATE * RING_S, 2), np.float32)
        self._rd = 0
        self._fill = 0
        self._lock = threading.Lock()
        self._started = False
        self.gain = 1.0         # where the gain is now
        self.target = 1.0
        self._step = 0.0        # its change per block
        self.master = 1.0       # a second gain, the music's own volume

    def push(self, data: bytes):
        """Interleaved little-endian float32 stereo from the decoder."""
        a = np.frombuffer(data, np.float32)
        a = a[: len(a) // 2 * 2].reshape(-1, 2)
        n = len(a)
        with self._lock:
            cap = len(self._ring)
            if n >= cap:
                a, n = a[-cap:], cap
            if self._fill + n > cap:        # full: the oldest goes
                drop = self._fill + n - cap
                self._rd = (self._rd + drop) % cap
                self._fill -= drop
            w = (self._rd + self._fill) % cap
            first = min(n, cap - w)
            self._ring[w:w + first] = a[:first]
            if n > first:
                self._ring[: n - first] = a[first:]
            self._fill += n

    def buffered(self) -> float:
        return self._fill / RATE

    def clear(self):
        with self._lock:
            self._rd = 0
            self._fill = 0
            self._started = False

    def set(self, gain: float):
        """The gain at once."""
        self.gain = self.target = float(gain)
        self._step = 0.0

    def fade_to(self, gain: float, secs: float):
        """Ramp the gain to [gain] over [secs]."""
        self.target = float(gain)
        blocks = max(1.0, secs * RATE / BLOCK)
        self._step = (self.target - self.gain) / blocks if secs > 0 else self.target - self.gain

    def _take(self, n: int) -> np.ndarray | None:
        with self._lock:
            # Waits for a little to be in hand before it starts, then is
            # steady; running dry makes it wait again
            if not self._started:
                if self._fill < RATE // 20:
                    return None
                self._started = True
            if self._fill < n:
                self._started = False
                if self._fill == 0:
                    return None
                n_have = self._fill
            else:
                n_have = n
            cap = len(self._ring)
            idx = (self._rd + np.arange(n_have)) % cap
            out = self._ring[idx]
            self._rd = (self._rd + n_have) % cap
            self._fill -= n_have
        if n_have < n:
            out = np.vstack([out, np.zeros((n - n_have, 2), np.float32)])
        return out

    def block(self) -> np.ndarray | None:
        """The next 10 ms with the gain applied, or None for silence."""
        a = self._take(BLOCK)
        g0 = self.gain
        if self._step != 0.0:
            g1 = g0 + self._step
            if (self._step > 0 and g1 >= self.target) or (self._step < 0 and g1 <= self.target):
                g1, self._step = self.target, 0.0
            self.gain = g1
        else:
            g1 = g0
        if a is None:
            return None
        m = self.master
        if g0 == g1:
            return a * (g0 * m) if g0 * m != 1.0 else a
        return a * (np.linspace(g0, g1, BLOCK, dtype=np.float32) * m)[:, None]


class MediaMixer:
    """Mixes the tracks and sends them. [bind] gives it the appsrc to send
    through; until then (or with no destinations) it still runs, so a
    track's ring never backs up."""

    def __init__(self):
        self.tracks: dict[str, Track] = {}
        self._lock = threading.Lock()
        self._appsrc = None
        self._thread: threading.Thread | None = None
        self._run = False
        self._last_sound = 0.0
        self.level_db = -100.0

    def bind(self, appsrc):
        self._appsrc = appsrc

    def track(self, name: str) -> Track:
        with self._lock:
            t = self.tracks.get(name)
            if t is None:
                t = self.tracks[name] = Track(name)
            return t

    def drop(self, name: str):
        with self._lock:
            self.tracks.pop(name, None)

    def start(self):
        if self._thread:
            return
        self._run = True
        self._thread = threading.Thread(target=self._loop, daemon=True, name="media-mix")
        self._thread.start()

    def stop(self):
        self._run = False
        if self._thread:
            self._thread.join(1)
            self._thread = None

    def mix_block(self) -> np.ndarray | None:
        """One 10 ms block of every track together, or None if all are silent."""
        with self._lock:
            tracks = list(self.tracks.values())
        out = None
        for t in tracks:
            b = t.block()
            if b is None:
                continue
            out = b.copy() if out is None else out + b
        if out is not None:
            np.clip(out, -1.0, 1.0, out=out)
        return out

    def _loop(self):
        nxt = time.monotonic()
        while self._run:
            nxt += BLOCK / RATE
            wait = nxt - time.monotonic()
            if wait > 0:
                time.sleep(wait)
            elif wait < -0.2:
                nxt = time.monotonic()      # a long stall: carry on from now
            out = self.mix_block()
            now = time.monotonic()
            if out is not None:
                self._last_sound = now
                rms = float(np.sqrt(np.mean(out * out)))
                self.level_db = 20 * np.log10(rms + 1e-9)
            elif now - self._last_sound > HOLD_S:
                self.level_db = -100.0
                continue                      # nothing playing: nothing sent
            else:
                out = np.zeros((BLOCK, 2), np.float32)
            src = self._appsrc
            if src is not None:
                try:
                    from gi.repository import Gst
                    src.emit("push-buffer", Gst.Buffer.new_wrapped(out.astype(np.float32).tobytes()))
                except Exception:       # the pipeline's being rebuilt
                    pass
