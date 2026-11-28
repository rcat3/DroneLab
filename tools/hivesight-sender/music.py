"""The Guide's music: files played to the Vessels through the media mixer,
with a queue, and a crossfade from one track into the next, when they
change over by themselves or when told to. Runs on the GLib thread."""
from __future__ import annotations

import logging
from pathlib import Path

import gi

gi.require_version("Gst", "1.0")
from gi.repository import GLib, Gst  # noqa: E402

import audiomix  # noqa: E402

log = logging.getLogger("hivesight")

AUDIO_EXTS = {".mp3", ".flac", ".ogg", ".opus", ".wav", ".m4a", ".aac", ".wma", ".oga", ".mka", ".aif", ".aiff"}


def list_audio(folder: Path, limit: int = 4000) -> list[str]:
    if not folder.is_dir():
        return []
    out = []
    for p in folder.rglob("*"):
        if p.is_file() and p.suffix.lower() in AUDIO_EXTS and not p.name.startswith("."):
            out.append(str(p.relative_to(folder)))
            if len(out) >= limit:
                break
    return sorted(out, key=str.lower)


def resolve(folder: Path, name: str) -> Path | None:
    try:
        p = (folder / name).resolve(strict=True)
        p.relative_to(folder.resolve())
    except (OSError, ValueError):
        return None
    return p if p.is_file() else None


class Playing:
    """One track being played: its decoder, and its place in the mixer."""
    _n = 0

    def __init__(self, mixer: audiomix.MediaMixer, name: str, path: Path, on_eos, on_error):
        Playing._n += 1
        self.id = f"music{Playing._n}"
        self.name = name
        self.mixer = mixer
        self.track = mixer.track(self.id)
        self.paused = False
        self.leaving = False            # fading out: on its way off
        self.on_eos = on_eos
        self.pipeline = Gst.parse_launch(
            f'uridecodebin uri="{path.resolve().as_uri()}" name=dec ! audioconvert ! audioresample ! '
            "audio/x-raw,format=F32LE,rate=48000,channels=2,layout=interleaved ! "
            "appsink name=out sync=true max-buffers=4 drop=false emit-signals=true")
        self.pipeline.get_by_name("out").connect("new-sample", self._sample)
        bus = self.pipeline.get_bus()
        bus.add_signal_watch()
        bus.connect("message", self._message, on_error)
        self.pipeline.set_state(Gst.State.PLAYING)

    def _sample(self, sink):
        s = sink.emit("pull-sample")
        if s is None:
            return Gst.FlowReturn.EOS
        buf = s.get_buffer()
        ok, info = buf.map(Gst.MapFlags.READ)
        if ok:
            self.track.push(bytes(info.data))
            buf.unmap(info)
        return Gst.FlowReturn.OK

    def _message(self, _bus, msg, on_error):
        if msg.type == Gst.MessageType.EOS:
            GLib.idle_add(lambda: (self.on_eos(self), False)[1])
        elif msg.type == Gst.MessageType.ERROR:
            err, _ = msg.parse_error()
            GLib.idle_add(lambda: (on_error(self, err.message), False)[1])

    def position(self) -> float:
        ok, pos = self.pipeline.query_position(Gst.Format.TIME)
        return pos / Gst.SECOND if ok and pos >= 0 else 0.0

    def duration(self) -> float:
        ok, d = self.pipeline.query_duration(Gst.Format.TIME)
        return d / Gst.SECOND if ok and d > 0 else 0.0

    def pause(self, on: bool):
        self.paused = on
        self.pipeline.set_state(Gst.State.PAUSED if on else Gst.State.PLAYING)

    def seek(self, seconds: float):
        self.pipeline.seek_simple(Gst.Format.TIME, Gst.SeekFlags.FLUSH | Gst.SeekFlags.ACCURATE,
                                  int(max(0.0, seconds) * Gst.SECOND))
        self.track.clear()

    def stop(self):
        self.pipeline.get_bus().remove_signal_watch()
        self.pipeline.set_state(Gst.State.NULL)
        self.mixer.drop(self.id)


class MusicPlayer:
    def __init__(self, mixer: audiomix.MediaMixer, folder: Path, settings, notify):
        self.mixer = mixer
        self.folder = folder
        self.settings = settings        # () -> the music section of the state
        self.notify = notify            # (text) -> None, to the Guide
        self.queue: list[str] = []
        self.current: Playing | None = None
        self._ticker = None

    # ---- the queue ----
    def enqueue(self, name: str):
        if resolve(self.folder, name) is None:
            self.notify(f"not found in the music folder: {name}")
            return
        self.queue.append(name)

    def remove(self, index: int):
        if 0 <= index < len(self.queue):
            del self.queue[index]

    def move(self, src: int, dst: int):
        if 0 <= src < len(self.queue):
            item = self.queue.pop(src)
            self.queue.insert(max(0, min(dst, len(self.queue))), item)

    def clear(self):
        self.queue.clear()

    # ---- playing ----
    def _vol(self) -> float:
        return float(self.settings().get("vol", 0.8))

    def _xfade(self) -> float:
        return max(0.0, float(self.settings().get("xfade_s", 4.0)))

    def play(self, name: str, fade: float | None = None):
        """Start [name] now: the track playing goes out as this one comes in."""
        p = resolve(self.folder, name)
        if p is None:
            self.notify(f"not found in the music folder: {name}")
            return
        xf = self._xfade() if fade is None else fade
        try:
            new = Playing(self.mixer, name, p, self._eos, self._error)
        except Exception as e:      # unreadable
            self.notify(f"can't play {name}: {e}")
            return
        old = self.current
        self.current = new
        new.track.master = self._vol()
        if old is not None and xf > 0:
            new.track.gain = 0.0
            new.track.fade_to(1.0, xf)
            self._leave(old, xf)
        elif old is not None:
            self._leave(old, 0.0)
        self._start_ticker()

    def _leave(self, old: Playing, secs: float):
        old.leaving = True
        old.track.fade_to(0.0, secs)
        GLib.timeout_add(int((secs + 0.4) * 1000), lambda: (self._gone(old), False)[1])

    def _gone(self, p: Playing):
        p.stop()

    def next(self):
        """The next queued track now, crossfaded. With none queued, nothing."""
        if self.queue:
            self.play(self.queue.pop(0))

    def pause(self, on: bool):
        if self.current:
            self.current.pause(on)

    def seek(self, seconds: float):
        if self.current:
            self.current.seek(seconds)

    def stop(self):
        old, self.current = self.current, None
        if old:
            self._leave(old, min(self._xfade(), 1.5))

    def shutdown(self):
        if self._ticker:
            GLib.source_remove(self._ticker)
            self._ticker = None
        if self.current:
            self.current.stop()
            self.current = None

    # ---- by itself ----
    def _start_ticker(self):
        if self._ticker is None:
            self._ticker = GLib.timeout_add(100, self._tick)

    def _tick(self):
        cur = self.current
        if cur is None:
            self._ticker = None
            return False
        cur.track.master = self._vol()
        if cur.paused or cur.leaving:
            return True
        dur = cur.duration()
        if dur > 0:
            left = dur - cur.position()
            if left <= self._xfade() + 0.05:
                if self.queue:
                    self.next()
                elif self.settings().get("at_end") == "loop":
                    self.play(cur.name)
        return True

    def _eos(self, p: Playing):
        if p is not self.current:
            return
        if self.queue:
            self.next()
        elif self.settings().get("at_end") == "loop":
            self.play(p.name, fade=0.0)
        else:
            self.current = None
            p.stop()

    def _error(self, p: Playing, message: str):
        self.notify(f"can't play {p.name}: {message}")
        if p is self.current:
            self.current = None
        p.stop()
        if self.queue:
            self.next()

    def status(self) -> dict:
        cur = self.current
        return {
            "dir": str(self.folder),
            "queue": list(self.queue),
            "current": None if cur is None else {
                "name": cur.name, "position": round(cur.position(), 1),
                "duration": round(cur.duration(), 1), "paused": cur.paused},
        }
