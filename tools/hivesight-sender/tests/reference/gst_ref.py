"""Run a block of audio through GStreamer elements, for the golden tests.

The sender used GStreamer's audiocheblimit (high and low pass), audioecho and
freeverb for the Guide's voice; core/audio/studio/ does the same in C. This
runs the same test signal through those elements so the C can be compared
with them.
"""
from __future__ import annotations

import gi
import numpy as np

gi.require_version("Gst", "1.0")
from gi.repository import Gst  # noqa: E402

Gst.init(None)

RATE = 48000


def run(x: np.ndarray, elements: str, channels_out: int = 1, rate: int = RATE) -> np.ndarray:
    """x: mono float32. elements: a gst-launch fragment. Returns float32,
    shape (n,) for mono out or (n, 2) for stereo."""
    desc = (f"appsrc name=src format=time caps=audio/x-raw,format=F32LE,rate={rate},channels=1,"
            f"layout=interleaved ! {elements} ! audioconvert ! "
            f"audio/x-raw,format=F32LE,rate={rate},channels={channels_out} ! "
            "appsink name=sink sync=false")
    pipe = Gst.parse_launch(desc)
    src = pipe.get_by_name("src")
    sink = pipe.get_by_name("sink")
    out = []
    pipe.set_state(Gst.State.PLAYING)
    x = np.ascontiguousarray(x, dtype=np.float32)
    block = 480
    t = 0
    for i in range(0, len(x), block):
        seg = x[i:i + block]
        buf = Gst.Buffer.new_wrapped(seg.tobytes())
        buf.pts = Gst.util_uint64_scale(t, Gst.SECOND, rate)
        buf.duration = Gst.util_uint64_scale(len(seg), Gst.SECOND, rate)
        t += len(seg)
        src.emit("push-buffer", buf)
    src.emit("end-of-stream")
    while True:
        s = sink.emit("try-pull-sample", 5 * Gst.SECOND)
        if s is None:
            break
        b = s.get_buffer()
        ok, info = b.map(Gst.MapFlags.READ)
        out.append(np.frombuffer(info.data, dtype=np.float32).copy())
        b.unmap(info)
    pipe.set_state(Gst.State.NULL)
    y = np.concatenate(out) if out else np.zeros(0, np.float32)
    return y.reshape(-1, 2) if channels_out == 2 else y
