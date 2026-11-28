"""Where the Guide's voice comes from, besides a computer microphone.

The display unit's microphone: the Guide page records it dry from the unit
over Bluetooth (no effect on the unit; the studio chain makes the voice
here) and sends it to the sender as binary messages on its own WebSocket,
[0x01][16-bit little-endian PCM at 48 kHz, mono]. It arrives in bursts, so
it's held in a small buffer and taken out at the pace of the sender's own
clock (a silent live source in the pipeline).

Later, music and sound files mix in here too, each at its own level.
"""
from __future__ import annotations

import threading
import time

import numpy as np

UNIT_SOURCE = "@unit"   # the --mic / capture "mic" that means the display unit
MSG_UNIT_VOICE = 0x01

RATE = 48000
TARGET_MS = 60          # how much is held before it plays, after a gap
MAX_MS = 250            # more than this and the oldest goes (the two clocks drift)


class UnitVoice:
    """The unit's voice, from the Guide page's messages (asyncio thread),
    taken by the audio's streaming thread."""

    def __init__(self):
        self._lock = threading.Lock()
        self._buf = np.zeros(0, dtype=np.float32)
        self._playing = False
        self.underruns = 0
        self.last_t = 0.0

    def add(self, pcm: bytes):
        x = np.frombuffer(pcm[: len(pcm) // 2 * 2], dtype="<i2").astype(np.float32) / 32768.0
        with self._lock:
            self._buf = np.concatenate([self._buf, x])
            most = RATE * MAX_MS // 1000
            if len(self._buf) > most:
                self._buf = self._buf[len(self._buf) - RATE * TARGET_MS // 1000:]
            self.last_t = time.monotonic()

    def take(self, n: int) -> np.ndarray:
        """n samples: the voice once enough's come, silence till then."""
        with self._lock:
            if not self._playing and len(self._buf) >= RATE * TARGET_MS // 1000:
                self._playing = True
            if not self._playing:
                return np.zeros(n, dtype=np.float32)
            if len(self._buf) < n:
                # Ran dry: what's there, then wait to fill up again
                out = np.concatenate([self._buf, np.zeros(n - len(self._buf), dtype=np.float32)])
                self._buf = np.zeros(0, dtype=np.float32)
                self._playing = False
                self.underruns += 1
                return out
            out, self._buf = self._buf[:n], self._buf[n:]
            return out

    def status(self) -> dict:
        with self._lock:
            ms = len(self._buf) * 1000 // RATE
        return {"receiving": time.monotonic() - self.last_t < 1.0, "buffer_ms": ms,
                "underruns": self.underruns}
