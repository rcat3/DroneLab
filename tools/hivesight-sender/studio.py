"""The Guide's voice effects: the studio chain in libdronelab_fx
(core/audio/studio/, the same C the app uses), through ctypes.

Denoise, high and low pass, gain/gate/compressor/limiter, spectral shift or
robot, simple pitch, echo and reverb, at 48 kHz, mono in and stereo out.
Settings go by the voice.* names in the sender's state.
"""
from __future__ import annotations

import ctypes
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
RATE = 48000
FX_MODES = {"off": 0, "shift": 1, "robot": 2}

_F = ctypes.POINTER(ctypes.c_float)


class LibraryMissing(Exception):
    pass


def find_library(given: str | None) -> Path:
    """--fx-lib if given; else the app bundle's lib/ beside this folder, then
    build/ here (build_fx.sh)."""
    candidates = [Path(given)] if given else [HERE.parent / "lib" / "libdronelab_fx.so",
                                              HERE / "build" / "libdronelab_fx.so"]
    for c in candidates:
        if c.is_file():
            return c
    raise LibraryMissing("Voice effects library not found (" + ", ".join(str(c) for c in candidates) + ")")


class Studio:
    def __init__(self, lib_path: Path):
        try:
            lib = ctypes.CDLL(str(lib_path))
            lib.dl_voice_new.restype = ctypes.c_void_p
            lib.dl_voice_free.argtypes = [ctypes.c_void_p]
            lib.dl_voice_key.argtypes = [ctypes.c_char_p]
            lib.dl_voice_set.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_float]
            lib.dl_voice_process.argtypes = [ctypes.c_void_p, _F, ctypes.c_int, _F]
            lib.dl_voice_meter.argtypes = [ctypes.c_void_p, _F, _F, ctypes.POINTER(ctypes.c_int)]
            lib.dl_voice_latency.argtypes = [ctypes.c_void_p]
            lib.dl_voice_rate.restype = ctypes.c_int
        except (OSError, AttributeError) as e:
            raise LibraryMissing(f"Voice effects library unusable: {e}") from e
        if lib.dl_voice_rate() != RATE:
            raise LibraryMissing("Voice effects library runs at another sample rate")
        self._lib = lib
        self._v = lib.dl_voice_new()
        if not self._v:
            raise MemoryError("voice effects")
        self._keys: dict[str, int] = {}

    def close(self):
        if self._v:
            self._lib.dl_voice_free(self._v)
            self._v = None

    def __del__(self):
        self.close()

    def set(self, name: str, value) -> bool:
        """One voice.* setting; False if the chain doesn't have it (preset and
        the like). Safe from any thread."""
        key = self._keys.get(name)
        if key is None:
            key = self._lib.dl_voice_key(name.encode())
            self._keys[name] = key
        if key < 0:
            return False
        if isinstance(value, str):
            value = FX_MODES.get(value, 0)
        self._lib.dl_voice_set(self._v, key, float(value))
        return True

    def set_all(self, voice: dict):
        for k, v in voice.items():
            self.set(k, v)

    def process(self, x: np.ndarray) -> np.ndarray:
        """Mono float32 in, interleaved stereo float32 out (2 * len)."""
        x = np.ascontiguousarray(x, dtype=np.float32)
        out = np.empty(2 * len(x), dtype=np.float32)
        self._lib.dl_voice_process(self._v, x.ctypes.data_as(_F), len(x), out.ctypes.data_as(_F))
        return out

    def meter(self) -> tuple[float, float, bool]:
        """The microphone's level before the gain, the output's over 100 ms
        (dBFS), and whether the gate is open."""
        a, b, g = ctypes.c_float(), ctypes.c_float(), ctypes.c_int()
        self._lib.dl_voice_meter(self._v, ctypes.byref(a), ctypes.byref(b), ctypes.byref(g))
        return a.value, b.value, bool(g.value)

    def latency(self) -> int:
        return self._lib.dl_voice_latency(self._v)
