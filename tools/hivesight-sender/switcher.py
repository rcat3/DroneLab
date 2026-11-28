"""The Guide's video switcher: what the Vessels see, as one steady stream.

The program is a permanent pipeline: two decks (slots) are mixed over
black by a compositor, then encoded and sent, so the stream never stops
or restarts however the sources change, and a paused film simply holds
its last picture. Every source (the camera or test pattern, a video file,
a solid colour, a still image) runs on its own and hands finished program
frames (both eyes side by side, 2560x720) to a deck. A change of source
puts the new one on the free deck, waits for its first picture, then
crosses over by a cut, a fade (out to black and in on the new one) or a
dissolve (straight from one to the other). A film's sound goes with its
deck, through the media mixer (audiomix.py).

Everything here but the frame callbacks runs on the GLib thread."""
from __future__ import annotations

import logging
import threading
import time
from pathlib import Path


import gi

gi.require_version("Gst", "1.0")
from gi.repository import GLib, Gst  # noqa: E402

import audiomix  # noqa: E402
import stills  # noqa: E402

log = logging.getLogger("hivesight")

EYE_W, EYE_H, FPS = 1280, 720, 30
W, H = EYE_W * 2, EYE_H
PROGRAM_CAPS = f"video/x-raw,format=I420,width={W},height={H},framerate={FPS}/1"
TICK_MS = 33


# ---------------------------------------------------------- transitions
class Transition:
    """How one deck gives way to the other. To add one: subclass, set [id] and
    [label], make [apply] set the decks' picture (alpha 0..1: [new] is above
    [old] over black) and their film sound for the progress [p] (0..1), and
    add an instance to TRANSITIONS. The Guide is told the list, so its menu has it."""
    id = ""
    label = ""
    instant = False         # takes no time whatever the time set

    def apply(self, p: float, old: "Slot", new: "Slot"):
        raise NotImplementedError

    @staticmethod
    def show(slot: "Slot", alpha: float, sound: float | None = None):
        slot.alpha(alpha)
        if slot.film is not None:
            slot.film.set(alpha if sound is None else sound)


class Cut(Transition):
    id, label, instant = "cut", "Cut", True

    def apply(self, p, old, new):
        self.show(old, 0.0)
        self.show(new, 1.0)


class FadeThroughBlack(Transition):
    id, label = "fade", "Fade"

    def apply(self, p, old, new):
        if p < 0.5:
            self.show(old, 1 - 2 * p)
            self.show(new, 0.0)
        else:
            self.show(old, 0.0)
            self.show(new, 2 * p - 1)


class Dissolve(Transition):
    id, label = "dissolve", "Dissolve"

    def apply(self, p, old, new):
        # The old stays whole below while the new comes up over it; the sound crosses the same way
        old.alpha(1.0)
        new.alpha(p)
        if old.film is not None:
            old.film.set(1 - p)
        if new.film is not None:
            new.film.set(p)


TRANSITIONS: dict[str, Transition] = {t.id: t for t in (Cut(), FadeThroughBlack(), Dissolve())}
EFFECTS = tuple(TRANSITIONS)


def program_desc(encoder_chain: str, dscp: int, latency_ms: int = 60) -> str:
    """The permanent part: black and two decks, mixed, encoded, sent."""
    deck = (f'appsrc name=s{{n}} is-live=true format=time do-timestamp=true block=false caps="{PROGRAM_CAPS}" ! '
            "queue max-size-buffers=2 leaky=downstream ! comp.sink_{k}")
    return (
        f"compositor name=comp background=black latency={latency_ms * 1000000} "
        "sink_0::zorder=0 sink_1::zorder=1 sink_2::zorder=2 sink_1::alpha=0 sink_2::alpha=0 ! "
        f"{PROGRAM_CAPS} ! {encoder_chain} "
        f"videotestsrc is-live=true pattern=black ! {PROGRAM_CAPS} ! comp.sink_0 "
        + deck.format(n=0, k=1) + " " + deck.format(n=1, k=2)
    )


def arrange(layout: str, sw: int, sh: int) -> str:
    """Pipeline text from a decoded I420 picture of sw x sh to one program
    frame, ending in the appsink 'vsink' (the caller sets its sync)."""
    left, right, stretch = stills.eye_regions(layout, sw, sh)

    def eye(r, n):
        x, y, w, h = (v // 2 * 2 for v in r)
        return (f"queue max-size-buffers=3 ! videocrop left={x} right={max(0, sw - x - w)} top={y} "
                f"bottom={max(0, sh - y - h)} ! videoscale {'' if stretch else 'add-borders=true '}! "
                f"video/x-raw,width={EYE_W},height={EYE_H},pixel-aspect-ratio=1/1 ! eyes.sink_{n}")
    return (f"tee name=t t. ! {eye(left, 0)} t. ! {eye(right, 1)} "
            f"compositor name=eyes background=black sink_1::xpos={EYE_W} ! {PROGRAM_CAPS} ! ")


class Slot:
    """A deck: the appsrc into the program mix, and what's playing on it."""

    def __init__(self, idx: int):
        self.idx = idx
        self.appsrc = None
        self.pad = None
        self.source: Source | None = None
        self.last = None            # the last picture, held for a source that has stopped sending
        self.last_t = 0.0
        self.first = threading.Event()
        self.film: audiomix.Track | None = None

    def push(self, buf):
        self.last, self.last_t = buf, time.monotonic()
        self.first.set()
        self._send(buf)

    def _send(self, buf):
        src = self.appsrc
        if src is not None:
            src.emit("push-buffer", buf.copy_region(Gst.BufferCopyFlags.MEMORY, 0, buf.get_size()))

    def alpha(self, a: float):
        if self.pad is not None:
            self.pad.set_property("alpha", max(0.0, min(1.0, float(a))))

    def reset(self):
        self.source = None
        self.last = None
        self.first.clear()
        if self.film:
            self.film.clear()
            self.film.set(0.0)


class PreviewSlot:
    """Where a source about to go on sends its pictures: not to the program
    but, small and a few times a second, to the Guide (as JPEG), so it can be
    seen before it's cut to. A film shows its first picture and waits there."""
    PERIOD = 0.25

    def __init__(self, on_jpeg, on_first):
        self.film = None
        self.on_jpeg = on_jpeg
        self.on_first = on_first
        self._t = 0.0
        self._seen = None
        self._first = False

    def push(self, buf):
        now = time.monotonic()
        if not self._first:
            self._first = True
            self.on_first()
        # A still sends the same picture over and over: once is enough, then now and then
        if buf is self._seen and now - self._t < 2.0:
            return
        if now - self._t < self.PERIOD:
            return
        self._t, self._seen = now, buf
        ok, info = buf.map(Gst.MapFlags.READ)
        if not ok:
            return
        try:
            self.on_jpeg(stills.i420_to_jpeg(info.data, W, H))
        finally:
            buf.unmap(info)


# ---------------------------------------------------------------- sources
class Source:
    kind = ""
    name = ""
    static = False          # makes its picture at once (no waiting for a first frame)

    def start(self, slot: Slot):
        self.slot = slot

    def stop(self):
        pass

    # Playback, for a source that has any
    def set_paused(self, on: bool):
        pass

    def seek(self, seconds: float):
        pass

    def position(self) -> float:
        return 0.0

    duration = 0.0
    has_audio = False

    def apply_offsets(self, v_off: int, a_off: int):
        pass

    def spec(self) -> dict:
        return {"kind": self.kind}


class _PipelineSource(Source):
    """A source made of a GStreamer pipeline that ends in appsink 'vsink'."""
    pipeline = None

    def _build(self, desc: str, sync: bool, on_eos=None, on_error=None):
        log.debug("%s source: %s", self.kind, desc)
        self.pipeline = Gst.parse_launch(desc)
        self._on_eos, self._on_error = on_eos, on_error
        v = self.pipeline.get_by_name("vsink")
        v.set_property("emit-signals", True)
        v.set_property("sync", sync)
        v.set_property("max-buffers", 2)
        v.set_property("drop", not sync)
        v.connect("new-sample", self._video)
        bus = self.pipeline.get_bus()
        bus.add_signal_watch()
        bus.connect("message", self._message)

    def _video(self, sink):
        s = sink.emit("pull-sample")
        if s is None:
            return Gst.FlowReturn.EOS
        self.slot.push(s.get_buffer())
        return Gst.FlowReturn.OK

    def _message(self, _bus, msg):
        if msg.type == Gst.MessageType.EOS and self._on_eos:
            GLib.idle_add(lambda: (self._on_eos(self), False)[1])
        elif msg.type == Gst.MessageType.ERROR and self._on_error:
            err, dbg = msg.parse_error()
            log.error("%s source error: %s (%s)", self.kind, err.message, dbg)
            GLib.idle_add(lambda: (self._on_error(self, err.message), False)[1])

    def start(self, slot):
        super().start(slot)
        self.pipeline.set_state(Gst.State.PLAYING)

    def stop(self):
        if self.pipeline is not None:
            self.pipeline.get_bus().remove_signal_watch()
            self.pipeline.set_state(Gst.State.NULL)
            self.pipeline = None


class CameraSource(_PipelineSource):
    """The camera, or the test pattern: two moving balls, one per eye."""
    kind = "camera"

    def __init__(self, args, on_error):
        self.name = "test pattern" if args.test_pattern else args.device
        if args.test_pattern:
            eyes = "".join(
                f" videotestsrc is-live=true pattern=ball ! video/x-raw,width={EYE_W},height={EYE_H},"
                f"framerate={FPS}/1 ! textoverlay text={label} font-desc=\"Sans 36\" valignment=top ! "
                f"timeoverlay font-desc=\"Sans 28\" ! eyes.sink_{i}"
                for i, label in enumerate(("LEFT", "RIGHT")))
            desc = (f"compositor name=eyes background=black sink_1::xpos={EYE_W} ! {PROGRAM_CAPS} ! "
                    f"appsink name=vsink{eyes}")
        else:
            w, h, fps = args.width, args.height, args.fps
            if args.format == "mjpeg":
                caps, dec = f"image/jpeg,width={w},height={h},framerate={fps}/1", "jpegdec ! "
            else:
                caps, dec = f"video/x-raw,format=YUY2,width={w},height={h},framerate={fps}/1", ""
            desc = (f"v4l2src device={args.device} do-timestamp=true ! {caps} ! {dec}videoconvert ! "
                    f"video/x-raw,format=I420 ! videorate drop-only=true max-rate={FPS} ! "
                    f"{arrange(args.layout, w, h)}appsink name=vsink")
        self._build(desc, sync=False, on_error=on_error)

    def spec(self):
        return {"kind": "camera"}


class FileSource(_PipelineSource):
    """A video file, played in real time, its soundtrack to the deck's film track."""
    kind = "file"

    def __init__(self, name: str, info, layout: str, av_offset_ms: int, on_eos, on_error, autoplug=None,
                 start_pos: float = 0.0):
        self.name = name
        self.start_pos = start_pos
        self._started = False
        self.info = info
        self.layout = layout
        self.duration = info.duration_s
        self.has_audio = info.has_audio
        v_off, a_off = self._offsets(av_offset_ms)
        big_q = "queue max-size-time=2000000000 max-size-buffers=0 max-size-bytes=0"
        desc = (f'uridecodebin uri="{info.path.resolve().as_uri()}" name=dec '
                f"dec. ! video/x-raw ! {big_q} ! videoconvert ! video/x-raw,format=I420 ! "
                f"{arrange(layout, info.width // 2 * 2, info.height // 2 * 2)}"
                f"appsink name=vsink ts-offset={v_off}")
        if info.has_audio:
            desc += (f" dec. ! audio/x-raw ! {big_q} ! audioconvert ! audioresample ! "
                     "audio/x-raw,format=F32LE,rate=48000,channels=2,layout=interleaved ! "
                     f"appsink name=asink sync=true max-buffers=8 drop=false emit-signals=true ts-offset={a_off}")
        self._build(desc, sync=True, on_eos=on_eos, on_error=on_error)
        if autoplug:
            self.pipeline.get_by_name("dec").connect("autoplug-select", autoplug)
        a = self.pipeline.get_by_name("asink")
        if a is not None:
            a.connect("new-sample", self._audio)

    @staticmethod
    def _offsets(ms):
        off = int(ms * Gst.MSECOND)
        return (off, 0) if off >= 0 else (0, -off)

    def _audio(self, sink):
        s = sink.emit("pull-sample")
        if s is None:
            return Gst.FlowReturn.EOS
        buf = s.get_buffer()
        ok, info = buf.map(Gst.MapFlags.READ)
        if ok:
            if self.slot.film is not None:
                self.slot.film.push(bytes(info.data))
            buf.unmap(info)
        return Gst.FlowReturn.OK

    def apply_offsets(self, v_off_ms, a_off_ms=None):
        v, a = self._offsets(v_off_ms)
        if self.pipeline is None:
            return
        self.pipeline.get_by_name("vsink").set_property("ts-offset", v)
        s = self.pipeline.get_by_name("asink")
        if s is not None:
            s.set_property("ts-offset", a)

    def start(self, slot):
        # Starts paused, to go to where it was left (if it was) before it plays
        self.slot = slot
        self.pipeline.get_bus().connect("message::async-done", self._ready)
        self.pipeline.set_state(Gst.State.PAUSED if self.start_pos > 0 else Gst.State.PLAYING)

    def _ready(self, _bus, _msg):
        if self._started or self.pipeline is None:
            return
        self._started = True
        if self.start_pos > 0:
            self.pipeline.seek_simple(Gst.Format.TIME, Gst.SeekFlags.FLUSH | Gst.SeekFlags.ACCURATE,
                                      int(self.start_pos * Gst.SECOND))
            self.pipeline.set_state(Gst.State.PLAYING)

    def set_paused(self, on):
        if self.pipeline is not None:
            self.pipeline.set_state(Gst.State.PAUSED if on else Gst.State.PLAYING)

    def seek(self, seconds):
        if self.pipeline is not None:
            self.pipeline.seek_simple(Gst.Format.TIME, Gst.SeekFlags.FLUSH | Gst.SeekFlags.ACCURATE,
                                      int(max(0.0, seconds) * Gst.SECOND))
            if self.slot.film is not None:
                self.slot.film.clear()

    def position(self):
        if self.pipeline is None:
            return 0.0
        ok, pos = self.pipeline.query_position(Gst.Format.TIME)
        return pos / Gst.SECOND if ok and pos >= 0 else 0.0

    def spec(self):
        return {"kind": "file", "file": self.name}


class ColorSource(_PipelineSource):
    """One colour, changeable while it's on."""
    kind = "color"
    static = False

    def __init__(self, rgb: int, on_error):
        self.rgb = rgb & 0xFFFFFF
        self.name = f"#{self.rgb:06X}"
        self._build(f"videotestsrc name=vts is-live=true pattern=solid-color foreground-color={0xFF000000 | self.rgb} "
                    f"! {PROGRAM_CAPS} ! appsink name=vsink", sync=False, on_error=on_error)

    def set_color(self, rgb: int):
        self.rgb = rgb & 0xFFFFFF
        self.name = f"#{self.rgb:06X}"
        if self.pipeline is not None:
            self.pipeline.get_by_name("vts").set_property("foreground-color", 0xFF000000 | self.rgb)

    def spec(self):
        return {"kind": "color", "rgb": self.rgb}


class ImageSource(Source):
    """A still picture, placed in each eye with a zoom and a position."""
    kind = "image"

    def __init__(self, name: str, path: Path, layout: str, zoom: float, x: float, y: float, fit: str = "fit"):
        self.name = name
        self.im = stills.load(path)
        self.layout = layout
        self.fit = fit
        self.zoom, self.x, self.y = zoom, x, y
        self.buf = None
        self._timer = None
        self._render()

    def _render(self):
        rgb = stills.render_program(self.im, self.layout, EYE_W, EYE_H, self.zoom, self.x, self.y, self.fit)
        self.buf = Gst.Buffer.new_wrapped(stills.to_i420(rgb))

    def place(self, zoom: float, x: float, y: float, layout: str | None = None, fit: str | None = None):
        layout, fit = layout or self.layout, fit or self.fit
        if (zoom, x, y, layout, fit) == (self.zoom, self.x, self.y, self.layout, self.fit):
            return
        self.zoom, self.x, self.y, self.layout, self.fit = zoom, x, y, layout, fit
        self._render()
        if self._timer is not None:
            self._push()

    def start(self, slot):
        super().start(slot)
        self._push()
        self._timer = GLib.timeout_add(200, self._push)

    def _push(self):
        if self.buf is not None and getattr(self, "slot", None) is not None:
            self.slot.push(self.buf)
        return True

    def stop(self):
        if self._timer is not None:
            GLib.source_remove(self._timer)
            self._timer = None

    def spec(self):
        return {"kind": "image", "file": self.name}


# ------------------------------------------------------------- the switcher
class Switcher:
    def __init__(self, mixer: audiomix.MediaMixer, on_change, notify):
        self.mixer = mixer
        self.on_change = on_change      # () -> None: what's on air (or a transition) changed
        self.notify = notify            # (text) -> None, to the Guide
        self.slots = [Slot(0), Slot(1)]
        for s in self.slots:
            s.film = mixer.track(f"film{s.idx}")
            s.film.set(0.0)
        self.program = 0                # the deck on air
        self.trans = None
        self._ticker = None
        self._keep = None
        self.effect = "fade"
        self.secs = 1.5
        self.resume: dict[str, float] = {}      # where each film was when it went off air
        self.pv: Source | None = None   # the source being looked at before it goes on
        self.on_preview = lambda jpeg: None

    # ---- the program pipeline ----
    def bind(self, pipeline):
        comp = pipeline.get_by_name("comp")
        for s in self.slots:
            s.appsrc = pipeline.get_by_name(f"s{s.idx}")
            s.pad = comp.get_static_pad(f"sink_{s.idx + 1}")
        self._show(self.program, 1.0)
        if self._keep is None:
            self._keep = GLib.timeout_add(100, self._keepalive)

    def _keepalive(self):
        """A source that's paused (or a still) sends nothing: its deck's last picture again."""
        now = time.monotonic()
        for s in self.slots:
            if s.source is not None and s.last is not None and now - s.last_t > 0.12:
                s._send(s.last)
        return True

    def _show(self, idx: int, alpha: float):
        for s in self.slots:
            s.alpha(alpha if s.idx == idx else 0.0)
        if self.slots[idx].film:
            self.slots[idx].film.set(alpha)

    # ---- the preview ----
    def preview(self, src: Source | None):
        """Look at [src] before it's on (None: nothing). One camera can't be
        opened twice, so one that's on air isn't looked at again."""
        old, self.pv = self.pv, None
        if old is not None:
            old.stop()
        if src is None:
            self.on_preview(b"")
            return
        air = self.on_air
        if src.kind == "camera" and (air is not None and air.kind == "camera" or
                                     self.trans is not None and self.trans["src"].kind == "camera"):
            src.stop()
            self.on_preview(b"")
            return
        self.pv = src
        slot = PreviewSlot(self.on_preview, lambda: GLib.idle_add(self._pause_preview, src))
        src.start(slot)

    def _pause_preview(self, src):
        if src is self.pv and src.kind == "file":
            src.set_paused(True)
        return False

    # ---- what's on ----
    @property
    def on_air(self) -> Source | None:
        return self.slots[self.program].source

    def status(self) -> dict:
        t = self.trans
        return {"effect": self.effect, "secs": self.secs,
                "effects": [{"id": t.id, "label": t.label, "instant": t.instant} for t in TRANSITIONS.values()],
                "resume": {k: round(v, 1) for k, v in self.resume.items()},
                "transition": None if t is None else {"to": t["src"].spec(), "phase": t["phase"],
                                                     "progress": round(t.get("p", 0.0), 2)}}

    def take(self, src: Source, effect: str | None = None, secs: float | None = None):
        """Put [src] on air by [effect]. Nothing on air yet: a cut."""
        effect = effect if effect in EFFECTS else self.effect
        secs = self.secs if secs is None else max(0.0, float(secs))
        if self.pv is not None and (src.kind == "camera" or self.pv.kind == src.kind == "camera"):
            self.preview(None)          # the camera's wanted for the program
        if self.trans is not None:
            self._finish()              # one at a time: the last is over at once
        cur = self.slots[self.program]
        free = self.slots[1 - self.program]
        if free.source is not None:     # an abandoned attempt
            free.source.stop()
            free.reset()
        free.reset()
        free.source = src
        src.start(free)
        if cur.source is None or TRANSITIONS[effect].instant:
            effect, secs = ("cut" if cur.source is None else effect), 0.0
        self.trans = {"src": src, "slot": free, "effect": effect, "secs": secs, "phase": "waiting",
                      "t0": time.monotonic(), "p": 0.0}
        self.on_change()
        if self._ticker is None:
            self._ticker = GLib.timeout_add(TICK_MS, self._tick)

    def _tick(self):
        t = self.trans
        if t is None:
            self._ticker = None
            return False
        now = time.monotonic()
        free, cur = t["slot"], self.slots[self.program]
        if t["phase"] == "waiting":
            if free.first.is_set():
                t["phase"], t["t0"] = "ramp", now
                # The new deck goes above the old, quiet until it comes in
                free.pad.set_property("zorder", 3)
                cur.pad.set_property("zorder", 2)
                free.alpha(0.0)
                self.on_change()
            elif now - t["t0"] > 8.0:
                self.notify(f"No picture from {t['src'].name}: staying on what's on")
                t["src"].stop()
                free.source = None
                free.reset()
                self.trans = None
                self._ticker = None
                self.on_change()
                return False
            else:
                return True
        secs = t["secs"]
        p = 1.0 if secs <= 0 else min(1.0, (now - t["t0"]) / secs)
        t["p"] = p
        TRANSITIONS[t["effect"]].apply(p, cur, free)
        if p >= 1.0:
            self._finish()
            return False
        return True

    @staticmethod
    def _film(slot: Slot, g: float):
        if slot.film is not None:
            slot.film.set(g)

    def _finish(self):
        t, self.trans = self.trans, None
        if t is None:
            return
        old = self.slots[self.program]
        free = t["slot"]
        free.alpha(1.0)
        self._film(free, 1.0)
        old.alpha(0.0)
        if old.source is not None:
            self._remember(old.source)
            old.source.stop()
        old.reset()
        self.program = free.idx
        self._ticker = None
        self.on_change()

    def _remember(self, src: Source):
        """A film going off air keeps its place, to carry on from when it's back."""
        if src.kind != "file":
            return
        pos = src.position()
        if src.duration and pos > src.duration - 1.5:
            self.resume.pop(src.name, None)     # it had finished
        elif pos > 1.0:
            self.resume[src.name] = pos

    def forget(self, name: str | None = None):
        if name is None:
            self.resume.clear()
        else:
            self.resume.pop(name, None)

    # ---- the source on air ----
    def set_paused(self, on: bool):
        s = self.on_air
        if s:
            s.set_paused(on)

    def seek(self, seconds: float):
        s = self.on_air
        if s:
            s.seek(seconds)

    def position(self) -> float:
        s = self.on_air
        return s.position() if s else 0.0

    def stop_all(self):
        """No session: every source is let go (the camera's light goes out)."""
        self.trans = None
        self.resume.clear()
        self.preview(None)
        for s in self.slots:
            if s.source is not None:
                s.source.stop()
            s.reset()
            s.alpha(0.0)
        self.program = 0
        self.on_change()
