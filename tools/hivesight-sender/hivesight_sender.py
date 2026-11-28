#!/usr/bin/python3
"""HiveSight sender: the Guide's side of a HiveSight session.

Captures (stereo) video and the Guide's microphone and streams them as RTP/UDP
to one or more Vessels' phones. The DroneLab app starts it as a helper and
drives it over a WebSocket of its own; Vessels join with an invitation.

Ports (sender side):   --guide-port/tcp   the Guide page's /ws, 127.0.0.1 only
                       --vessel-port/tcp  the Vessels' /ws, TLS (wss://)
Ports (Vessel side):   5004/udp  H.264 RTP video
                       5006/udp  L16 stereo RTP audio (the Guide's voice)
                       5008/udp  L16 stereo RTP audio (video file soundtrack)

The app writes one JSON line to stdin at start, {"guide_token": "...", and
"session": {"token": ..., "expires": ...} if one is on}, and keeps stdin
open: when it closes, the sender stops. Once listening, the sender prints
one line, HIVESIGHT {"guide_port": n, "vessel_port": n, "addrs": [...]}.

Who may connect:
  - the Guide page: from loopback, with the guide token in its hello;
  - Vessels: over TLS (--cert/--key), with the session token from their
    invitation in their hello. The Guide page starts a session
    ({"type": "session", "token": ..., "expires": unix seconds}) and ends it
    ({"type": "session_end"}), which drops every Vessel. Vessels can only
    report (stats, pings, keyframe requests, preview); they can't change
    settings.

The Guide page changes the camera, its mode, the microphone and the media
folder while it runs ({"type": "capture", "device": ..., ...}), Vessels
staying connected.

The Guide's voice effects are the studio chain in libdronelab_fx
(core/audio/studio/, studio.py), the app's own C: --fx-lib, or the app
bundle's lib/, or build/ from build_fx.sh. Without it there's no voice, and
the clients summary's voice_problem says why.
"""
from __future__ import annotations

import argparse
import asyncio
import copy
import json
import logging
import random
import re
import secrets
import ssl
import subprocess
import sys
import threading
import time
from pathlib import Path

import gi

gi.require_version("Gst", "1.0")
from gi.repository import GLib, Gst  # noqa: E402

import numpy as np  # noqa: E402
from aiohttp import WSMsgType, web  # noqa: E402

import audiomix  # noqa: E402
import media  # noqa: E402
import music  # noqa: E402
import switcher  # noqa: E402
import studio  # noqa: E402
import voice_input  # noqa: E402
from settings import preset_values, resolved_presets, set_many, set_path  # noqa: E402

HERE = Path(__file__).resolve().parent
log = logging.getLogger("hivesight")

VIDEO_PORT, AUDIO_PORT, MEDIA_PORT = 5004, 5006, 5008
WORD_LAYERS = 8  # phrases the Vessel can show at once
RTP_PAYLOADERS = ("pay", "mpay")  # element names whose RTP numbering survives rebuilds
VIDEO_DSCP = 40  # CS5 -> WMM video access category
AUDIO_DSCP = 48  # CS6 -> WMM voice access category

# --------------------------------------------------------------------------
# Shared state. Everything the Guide page can change lives here; the whole
# tree is mirrored to every client. The Vessel's Params.kt uses the same
# dotted keys. Sections:
#   voice  - the Guide's mic effect chain (applied here, on the sender)
#   mix    - Vessel-side audio mix levels
#   beats  - Vessel-side binaural beat / noise synth
#   fx     - Vessel-side video effects
#   view   - Vessel-side lens/IPD calibration (phone-specific; phone stores it)
#   video  - encoder settings
#   stream - read-only description of what is being sent
# --------------------------------------------------------------------------
DEFAULT_STATE = {
    "voice": {
        "preset": "clean", "mute": False, "gain_db": 12.0, "denoise": False,
        "gate_db": -55.0, "comp_ratio": 3.0, "pitch": 1.0,
        "fx_mode": "off", "shift_pitch": 1.0, "shift_formant": 1.0,
        "robot_hz": 200.0, "robot_noise": 0.1, "highpass_hz": 90, "lowpass_hz": 16000,
        "echo_ms": 1, "echo_feedback": 0.0, "echo_mix": 0.0,
        "reverb_room": 0.2, "reverb_damp": 0.5, "reverb_mix": 0.0,
        # The display unit's simpler effects, for its presets ("... (unit)")
        "crowd": False, "drive_db": 0.0, "ring_hz": 30.0, "ring_mix": 0.0, "crush_bits": 0.0,
        "chorus_rate": 0.5, "chorus_depth_ms": 2.0, "chorus_mix": 0.0, "out_gain_db": 0.0,
    },
    "mix": {
        "master": 1.0, "voice_vol": 0.9, "voice_pan": 0.0, "autopan_hz": 0.0,
        "beats_vol": 0.25, "noise_vol": 0.0, "media_vol": 1.0, "jitter_ms": 40,
    },
    # source: tone (two sine waves), or pink or white noise with the same beat (the
    # right ear's noise is the left's moved up by the beat, so there is a true binaural
    # beat in it), kept to noise_bw Hz wide around the carrier
    "beats": {"on": False, "carrier_hz": 200.0, "beat_hz": 6.0, "glide_s": 4.0,
              "source": "tone", "noise_bw": 1500.0},
    "fx": {
        "fade": 1.0, "fade_s": 1.5, "screen": 0.0, "delay_ms": 0, "swap": False, "mirror": False,
        "rotate180": False, "mono": False, "brightness": 0.0, "contrast": 1.0,
        "saturation": 1.0, "tint_r": 1.0, "tint_g": 1.0, "tint_b": 1.0,
        "invert": False, "vignette": 0.35,
    },
    "view": {
        "lens_sep_mm": 64.0, "lens_y_mm": 0.0, "k1": 0.34, "k2": 0.55,
        "zoom": 1.0, "convergence": 0.0, "vertical": 0.0, "grid": False,
        "stats": False,
    },
    # Hypnotic spiral overlay, centred on each lens.
    "spiral": {
        "amount": 0.0, "speed": 0.25, "arms": 3, "twist": 6.0, "sharp": 0.5,
        "hue": 0.0, "sat": 0.0, "zoom_hz": 0.0,
    },
    # Light-and-sound-machine style colour pulsing. Follows the binaural beat
    # frequency when sync is on. Capped at 30 Hz on the phone, and only shown
    # by a Vessel who allows the Guide the light pulse.
    "photic": {
        "on": False, "sync": True, "hz": 10.0, "depth": 0.5, "amount": 0.3,
        "hue": 0.6, "sat": 0.8, "hue_cycle_s": 0.0, "alternate": False,
    },
    # Guide preview: the phone mirrors back what it shows and plays.
    # Switched off automatically when the last Guide page disconnects.
    "preview": {"video": False, "audio": False, "fps": 10},
    # Video source: the live camera (or test pattern) or a file from --media-dir.
    # av_offset_ms > 0 delays the file's video to line up with the phone's
    # later-arriving audio (jitter buffer + Bluetooth); < 0 delays the audio.
    # at_end: loop, camera, hold, or next (the next one queued)
    "media": {"source": "camera", "file": "", "paused": False, "at_end": "loop",
              "av_offset_ms": 150},
    # How the picture changes over: fade (out to black, then in), dissolve, or cut
    "switch": {"effect": "fade", "secs": 1.5},
    "color": {"rgb": 0x202020},
    # A still picture's place in each eye: zoom 1 shows all of it; x, y -1..1
    "image": {"zoom": 1.0, "x": 0.0, "y": 0.0},
    # The music: volume, how long one track crossfades into the next, and what's
    # done when the queue is empty: stop or loop
    "music": {"vol": 0.8, "xfade_s": 4.0, "at_end": "stop"},
    "video": {"bitrate_kbps": 8000},
    "stream": {},
}

# Settings saved with a scene (calibration and encoder settings are not).
# The Guide's own microphone settings, which a voice preset leaves as they are
VOICE_MIC_KEYS = {"preset", "mute", "gain_db", "denoise", "gate_db", "comp_ratio"}
SCENE_SECTIONS = ("voice", "mix", "beats", "fx", "spiral", "photic")


def get_path(tree, path):
    node = tree
    for key in path.split("."):
        node = node[key]
    return node


# --------------------------------------------------------------------------
# GStreamer helpers
# --------------------------------------------------------------------------
def element_exists(name: str) -> bool:
    return Gst.ElementFactory.find(name) is not None


def try_pipeline(desc: str, timeout: float = 6.0) -> bool:
    """Run a short pipeline to completion; True if it reached EOS cleanly."""
    try:
        p = Gst.parse_launch(desc)
    except GLib.Error:
        return False
    p.set_state(Gst.State.PLAYING)
    msg = p.get_bus().timed_pop_filtered(
        int(timeout * Gst.SECOND), Gst.MessageType.EOS | Gst.MessageType.ERROR)
    p.set_state(Gst.State.NULL)
    return msg is not None and msg.type == Gst.MessageType.EOS


ENCODERS = {
    # name: (element description template, bitrate property scale)
    "nvenc": ("nvh264enc name=enc preset=low-latency-hq rc-mode=cbr bitrate={kbps} "
              "gop-size={gop} zerolatency=true bframes=0 rc-lookahead=0"),
    "va": ("vah264enc name=enc rate-control=cbr bitrate={kbps} key-int-max={gop} b-frames=0"),
    "vaapi": ("vaapih264enc name=enc rate-control=cbr bitrate={kbps} keyframe-period={gop} "
              "max-bframes=0"),
    "x264": ("x264enc name=enc tune=zerolatency speed-preset=ultrafast bitrate={kbps} "
             "key-int-max={gop} bframes=0 sliced-threads=true vbv-buf-capacity=200"),
    "openh264": ("openh264enc name=enc bitrate={bps} gop-size={gop} rate-control=bitrate "
                 "complexity=low"),
}
ENCODER_ORDER = ["nvenc", "va", "vaapi", "x264", "openh264"]
ENCODER_ELEMENT = {"nvenc": "nvh264enc", "va": "vah264enc", "vaapi": "vaapih264enc",
                   "x264": "x264enc", "openh264": "openh264enc"}


def encoder_desc(name, kbps, gop):
    return ENCODERS[name].format(kbps=kbps, bps=kbps * 1000, gop=gop)


def pick_encoder(requested: str) -> str:
    candidates = ENCODER_ORDER if requested == "auto" else [requested]
    for name in candidates:
        if not element_exists(ENCODER_ELEMENT[name]):
            continue
        test = ("videotestsrc num-buffers=10 ! video/x-raw,width=1280,height=720 ! videoconvert ! "
                f"{encoder_desc(name, 4000, 30)} ! h264parse ! fakesink")
        if try_pipeline(test):
            return name
        log.info("encoder %s present but failed a test encode; skipping", name)
    raise SystemExit(f"No working H.264 encoder found (tried {candidates})")


def h264_bitrate_prop(enc_name):
    return ("bitrate", 1000) if enc_name == "openh264" else ("bitrate", 1)


# H.264 profiles NVIDIA's decoders (nvh264dec / nvh264sldec) handle. For others
# (High 4:4:4, High 4:2:2, High 10) they are still auto-plugged at equal rank to
# the software decoder and then stall silently, so steer decodebin away from them.
NV_H264_PROFILES = {"baseline", "constrained-baseline", "main", "high", "extended", None}


def _autoplug_select(_bin, _pad, caps, factory):
    TRY, SKIP = 0, 2  # GstAutoplugSelectResult
    name = factory.get_name()
    if name.startswith("nvh264") and caps.get_size():
        profile = caps.get_structure(0).get_string("profile")
        if profile not in NV_H264_PROFILES:
            log.info("using software H.264 decoding for profile %s", profile)
            return SKIP
    return TRY


class GstPipeline:
    """Owns one Gst pipeline: build, watch bus, restart on error."""

    def __init__(self, name, build_desc, on_built=None, on_eos=None, on_error=None):
        self.name = name
        self.on_error = on_error
        # Off, it isn't built at all (the camera and mic are let go), and
        # start() just stops it
        self.enabled = True
        self.build_desc = build_desc
        self.on_built = on_built
        self.on_eos = on_eos
        self.pipeline = None
        self._restart_pending = False
        self._restart_id = 0
        # RTP continuity across rebuilds: payloader name -> (ssrc, next seqnum).
        # Without it every rebuild (source switch, preset change) starts a new
        # random sequence, which Vessels can mistake for stale packets.
        self._rtp = {}

    def start(self):
        if self._restart_id:  # a rebuild supersedes any pending error-retry
            GLib.source_remove(self._restart_id)
            self._restart_id = 0
            self._restart_pending = False
        self.stop()
        if not self.enabled:
            return
        desc = self.build_desc()
        log.debug("%s pipeline: %s", self.name, desc)
        self.pipeline = Gst.parse_launch(desc)
        for name in RTP_PAYLOADERS:
            pay = self.pipeline.get_by_name(name)
            if pay is None:
                continue
            ssrc, seq = self._rtp.setdefault(name, (random.getrandbits(32), random.getrandbits(16)))
            pay.set_property("ssrc", ssrc)
            pay.set_property("seqnum-offset", seq)
        bus = self.pipeline.get_bus()
        bus.add_signal_watch()
        bus.connect("message", self._on_message)
        if self.on_built:
            self.on_built(self.pipeline)
        ret = self.pipeline.set_state(Gst.State.PLAYING)
        if ret == Gst.StateChangeReturn.FAILURE:
            log.error("%s pipeline failed to start; retrying in 3 s", self.name)
            self._schedule_restart()

    def stop(self):
        if self.pipeline is not None:
            for name in RTP_PAYLOADERS:
                pay = self.pipeline.get_by_name(name)
                if pay is not None and name in self._rtp:
                    self._rtp[name] = (self._rtp[name][0], (pay.get_property("seqnum") + 1) & 0xFFFF)
            bus = self.pipeline.get_bus()
            bus.remove_signal_watch()
            self.pipeline.set_state(Gst.State.NULL)
            self.pipeline = None

    def get(self, name):
        return self.pipeline.get_by_name(name) if self.pipeline else None

    def _schedule_restart(self):
        if self._restart_pending:
            return
        self._restart_pending = True

        def restart():
            self._restart_pending = False
            self._restart_id = 0
            try:
                self.start()
            except GLib.Error as e:
                log.error("%s rebuild failed: %s", self.name, e)
                self._schedule_restart()
            return False

        self._restart_id = GLib.timeout_add_seconds(3, restart)

    def _on_message(self, _bus, msg):
        t = msg.type
        if t == Gst.MessageType.EOS and self.on_eos:
            self.on_eos()
        elif t == Gst.MessageType.ERROR:
            err, dbg = msg.parse_error()
            log.error("%s error: %s (%s)", self.name, err.message, dbg)
            if self.on_error:
                self.on_error(err.message)
            self._schedule_restart()
        elif t == Gst.MessageType.WARNING:
            w, _ = msg.parse_warning()
            log.warning("%s warning: %s", self.name, w.message)


# --------------------------------------------------------------------------
# The sender
# --------------------------------------------------------------------------
class Sender:
    def __init__(self, args):
        self.args = args
        self.loop: asyncio.AbstractEventLoop | None = None
        self.state = copy.deepcopy(DEFAULT_STATE)
        self.word_cues = {}  # layer -> the cue showing there, for Vessels who join later
        self.presets = json.loads((HERE / "presets.json").read_text())
        self.scenes_path = Path(args.scenes)
        self.scenes = json.loads(self.scenes_path.read_text()) if self.scenes_path.exists() else {}
        self.clients: dict[web.WebSocketResponse, dict] = {}
        # Who may connect: the Guide page's token (from stdin), and the
        # session's, which Vessels' invitations carry (None: no session).
        self.guide_token: str = ""
        self.session_token: str | None = None
        self.session_expires = 0.0
        self.stopped: asyncio.Event | None = None
        # Destinations as (host, video_port, voice_port, media_audio_port)
        self.destinations: set[tuple[str, int, int, int]] = set()
        for host in args.also_send:
            self.destinations.add((host, VIDEO_PORT, AUDIO_PORT, MEDIA_PORT))
        self.media_dir = Path(args.media_dir).expanduser()
        self.music_dir = Path(args.music_dir).expanduser()
        self.media_info: media.MediaInfo | None = None
        self._media_list: list[str] = []
        self._image_list: list[str] = []
        self._media_list_t = 0.0
        self._music_list: list[str] = []
        self._music_list_t = 0.0
        self.queue: list[dict] = []     # what's to go on next: {"kind": "file", "file": ...} ...
        self.cue_spec: dict | None = None   # what's picked to go on, and looked at
        self.preview_gen = 0
        self.last_keyframe = 0.0
        self.video_packets = 0
        # The Guide's voice effects (libdronelab_fx's studio chain); without the
        # library there's no voice, and the Guide page is told why
        self.voice_problem = ""
        self.studio: studio.Studio | None = None
        self.unit_voice = voice_input.UnitVoice()
        if not args.no_audio:
            try:
                path = studio.find_library(args.fx_lib)
                self.studio = studio.Studio(path)
                log.info("voice effects: %s", path)
            except studio.LibraryMissing as e:
                self.voice_problem = str(e)
                log.error("%s: no voice", e)

        self.encoder = pick_encoder(args.encoder)
        log.info("video encoder: %s", self.encoder)
        self.state["video"]["bitrate_kbps"] = args.bitrate
        self.apply_preset_values(self.state["voice"]["preset"])

        # The picture: a permanent program stream, and the switcher that feeds it
        self.mixer = audiomix.MediaMixer()
        self.switcher = switcher.Switcher(self.mixer, self._switch_changed, self._notify_sync)
        self.switcher.on_preview = self._preview_jpeg
        self.music = music.MusicPlayer(self.mixer, self.music_dir, lambda: self.state["music"], self._notify_sync)
        self._set_stream_state(None)
        self.video = GstPipeline("video", self.video_desc, on_built=self._attach_video_clients,
                                 on_error=self._on_video_error)
        self.media_pipe = GstPipeline("media", self.media_desc, on_built=self._attach_media_clients)
        self.audio = GstPipeline("audio", self.audio_desc, on_built=self._attach_audio_clients) \
            if self.studio else None
        self.apply_voice()
        # The camera and mic run only while there's a session (or --also-send)
        for p in (self.video, self.audio, self.media_pipe):
            if p:
                p.enabled = False

    # ---------------- pipelines ----------------
    def video_desc(self):
        """The program: black and two decks mixed, encoded and sent
        (switcher.py). The encoder never restarts when a source changes."""
        vbr = self.state["video"]["bitrate_kbps"]
        # Force 4:2:0 into the encoder: phone hardware decoders reject High 4:4:4
        yuv = "I420" if self.encoder == "openh264" else "NV12"
        chain = (f"videoconvert ! video/x-raw,format={yuv} ! queue max-size-buffers=1 leaky=downstream ! "
                 f"{encoder_desc(self.encoder, vbr, switcher.FPS * 2)} ! "
                 "h264parse config-interval=-1 ! "
                 "rtph264pay name=pay pt=96 mtu=1200 config-interval=-1 aggregate-mode=zero-latency ! "
                 f"multiudpsink name=sink sync=false async=false qos-dscp={VIDEO_DSCP} buffer-size=4194304")
        return switcher.program_desc(chain, VIDEO_DSCP)

    def media_desc(self):
        """What the media mixer makes (films' sound, music) as RTP L16 on the media port."""
        return ("appsrc name=out is-live=true format=time do-timestamp=true block=false "
                "caps=audio/x-raw,format=F32LE,rate=48000,channels=2,layout=interleaved ! queue ! audioconvert ! "
                "audio/x-raw,format=S16BE,rate=48000,channels=2 ! "
                "rtpL16pay name=mpay pt=98 max-ptime=10000000 min-ptime=10000000 ! "
                f"multiudpsink name=sink sync=false async=false qos-dscp={AUDIO_DSCP}")

    # ---------------- the switcher's sources ----------------
    def _glib(self, fn, *a):
        GLib.idle_add(lambda: (fn(*a), False)[1])

    def _notify_sync(self, text):
        if self.loop:
            asyncio.run_coroutine_threadsafe(self.notify(text), self.loop)

    def _source_error(self, src, message):
        self._notify_sync(f"{src.name}: {message}")

    def _set_stream_state(self, src):
        """What the Vessels are told about the stream: always the program,
        both eyes side by side."""
        what = "test pattern" if src is None and self.args.test_pattern else \
            "camera" if src is None else (src.name if src.kind == "camera" else f"{src.kind}: {src.name}")
        self.state["stream"] = {"layout": "sbs", "width": switcher.W, "height": switcher.H, "fps": switcher.FPS,
                                "encoder": self.encoder, "source": what}

    def _switch_changed(self):
        """GLib thread: what's on air, or a change over, moved."""
        sw = self.switcher
        t = sw.trans
        src = t["src"] if t is not None and t["phase"] == "ramp" else sw.on_air
        if src is not None:
            m = self.state["media"]
            if (m["source"], m["file"]) != (src.kind, src.name if src.kind in ("file", "image") else ""):
                m.update(source=src.kind, file=src.name if src.kind in ("file", "image") else "", paused=False)
            self.media_info = getattr(src, "info", None)
            self._set_stream_state(src)
        if self.loop:
            asyncio.run_coroutine_threadsafe(self.broadcast({"type": "state", "state": self.state}), self.loop)

    def _fx(self):
        return self.state["switch"]["effect"], self.state["switch"]["secs"]

    def _list_media(self):
        if time.monotonic() - self._media_list_t > 5:
            self._media_list, self._image_list = media.list_media(self.media_dir), media.list_images(self.media_dir)
            self._media_list_t = time.monotonic()

    def media_files(self):
        self._list_media()
        return self._media_list

    def image_files(self):
        self._list_media()
        return self._image_list

    def music_files(self):
        if time.monotonic() - self._music_list_t > 30:
            self._music_list = music.list_audio(self.music_dir)
            self._music_list_t = time.monotonic()
        return self._music_list

    def _camera_source(self):
        return switcher.CameraSource(self.args, self._source_error)

    async def make_source(self, spec):
        """A source for [spec] (not started), or None, the Guide told why."""
        kind = spec.get("kind") if isinstance(spec, dict) else None
        if kind == "camera":
            return self._camera_source()
        if kind == "color":
            rgb = spec.get("rgb")
            if rgb is not None:
                self.state["color"]["rgb"] = int(rgb) & 0xFFFFFF
            return switcher.ColorSource(self.state["color"]["rgb"], self._source_error)
        name = str(spec.get("file", "")) if isinstance(spec, dict) else ""
        trusted = bool(spec.get("trusted")) if isinstance(spec, dict) else False
        # A path on the command line (--file) may be anywhere; the Guide's names are in the media folder
        p = Path(name).expanduser() if trusted and Path(name).expanduser().is_file() \
            else media.resolve(self.media_dir, name)
        if kind in ("file", "image") and p is None:
            await self.notify(f"not found in media folder: {name}")
            return None
        if kind == "file":
            try:
                mi = await asyncio.get_running_loop().run_in_executor(None, media.probe, p)
            except Exception as e:  # unreadable / no video stream
                log.warning("can't play %s: %s", name, e)
                await self.notify(f"can't play {name}: {e}")
                return None
            layout = media.guess_layout(name, mi.width, mi.height)
            log.info("file %s (%dx%d @ %.2f fps, %s, audio: %s, layout guess: %s)", name, mi.width, mi.height,
                     mi.fps, media.fmt_time(mi.duration_s), "yes" if mi.has_audio else "no", layout)
            return switcher.FileSource(name, mi, layout, self.state["media"]["av_offset_ms"], self._on_file_eos,
                                       self._source_error, autoplug=_autoplug_select)
        if kind == "image":
            try:
                im = self.state["image"]
                src = await asyncio.get_running_loop().run_in_executor(
                    None, lambda: switcher.ImageSource(name, p, "mono", im["zoom"], im["x"], im["y"]))
                src.layout = media.guess_layout(name, src.im.width, src.im.height)
                src._render()
                return src
            except Exception as e:
                await self.notify(f"can't show {name}: {e}")
        return None

    async def take_spec(self, spec):
        src = await self.make_source(spec)
        if src is not None:
            eff, secs = self._fx()
            self._glib(self.switcher.take, src, eff, secs)
            if spec == self.cue_spec:
                self.cue_spec = None
            await self.update_preview()

    async def take_camera(self, effect=None):
        eff, secs = self._fx()
        self._glib(self.switcher.take, self._camera_source(), effect or eff, secs)

    async def take_file(self, name: str, trusted: bool = False):
        await self.take_spec({"kind": "file", "file": name, "trusted": trusted})

    async def update_preview(self):
        """Look at what's cued, or failing that what's first in the queue."""
        spec = self.cue_spec or (self.queue[0] if self.queue else None)
        if spec is None or not self.video.enabled:
            self._glib(self.switcher.preview, None)
            return
        self.preview_gen += 1
        gen = self.preview_gen
        src = await self.make_source(spec)
        if src is None or gen != self.preview_gen:
            if src is not None:
                src.stop()
            return
        self._glib(self.switcher.preview, src)

    def _preview_jpeg(self, jpeg: bytes):
        """Streaming thread: a picture of what's next, to the Guide pages."""
        if self.loop:
            self.loop.call_soon_threadsafe(self._relay_preview, bytes([0x02]) + jpeg)

    async def take_next(self):
        if not self.queue:
            await self.notify("Nothing queued")
            return
        await self.take_spec(self.queue.pop(0))
        await self.update_preview()
        await self.broadcast(self.summary(), roles={"guide"})

    def _clean_spec(self, spec):
        """A queue item from the Guide, kept to what it's allowed to say."""
        if not isinstance(spec, dict):
            return None
        kind = spec.get("kind")
        if kind in ("file", "image") and isinstance(spec.get("file"), str):
            return {"kind": kind, "file": spec["file"][:300]}
        if kind == "color":
            try:
                return {"kind": "color", "rgb": int(spec.get("rgb", 0)) & 0xFFFFFF}
            except (TypeError, ValueError):
                return None
        if kind == "camera":
            return {"kind": "camera"}
        return None

    async def set_capture(self, msg):
        """A new camera, mode, microphone or media folder, without stopping:
        the camera is rebuilt if it's on, and the voice if the microphone
        changed. Vessels stay connected."""
        a = self.args
        old_mic = a.mic
        try:
            device = str(msg.get("device", ""))
            a.test_pattern = not device
            if device:
                a.device = device
                a.format = "yuyv" if msg.get("format") == "yuyv" else "mjpeg"
            a.width, a.height = int(msg.get("width", a.width)), int(msg.get("height", a.height))
            a.fps = int(msg.get("fps", a.fps))
            a.layout = "mono" if msg.get("layout") == "mono" and device else "sbs"
            a.mic = str(msg.get("mic") or "") or None
            if "media_dir" in msg:
                a.media_dir_given = bool(msg["media_dir"])
                self.media_dir = Path(msg["media_dir"] or "~/Videos").expanduser()
                self._media_list_t = 0.0
            if "music_dir" in msg:
                self.music_dir = Path(msg["music_dir"] or "~/Music").expanduser()
                self.music.folder = self.music_dir
                self._music_list_t = 0.0
        except (TypeError, ValueError):
            await self.notify("bad camera settings")
            return
        log.info("capture: %s %s %dx%d@%d %s, mic %s", "test pattern" if a.test_pattern else a.device,
                 a.format, a.width, a.height, a.fps, a.layout, a.mic or "default")
        if self.state["media"]["source"] == "camera" and self.video.enabled:
            await self.take_camera("cut")
        if self.audio and a.mic != old_mic:
            GLib.idle_add(lambda: (self.audio.start(), False)[1])
        await self.broadcast(self.summary(), roles={"guide"})

    def seek(self, seconds: float):
        self.switcher.seek(seconds)
        GLib.timeout_add(150, lambda: (self.force_keyframe(), False)[1])

    def media_position(self):
        return self.switcher.position()

    def apply_media_settings(self):
        m = self.state["media"]
        src = self.switcher.on_air
        if src is None:
            return
        if src.kind == "file":
            src.set_paused(m["paused"])
            src.apply_offsets(m["av_offset_ms"])
        if not m["paused"]:
            GLib.timeout_add(100, lambda: (self.force_keyframe(), False)[1])

    def apply_switch_settings(self, paths):
        sw, st = self.switcher, self.state
        sw.effect, sw.secs = st["switch"]["effect"], float(st["switch"]["secs"])
        for src in [sw.on_air, sw.pv] + ([sw.trans["src"]] if sw.trans else []):
            if isinstance(src, switcher.ColorSource) and any(p.startswith("color.") for p in paths):
                src.set_color(st["color"]["rgb"])
            if isinstance(src, switcher.ImageSource) and any(p.startswith("image.") for p in paths):
                src.place(st["image"]["zoom"], st["image"]["x"], st["image"]["y"])

    def _on_file_eos(self, src):
        if src is not self.switcher.on_air:
            return False
        action = self.state["media"]["at_end"]
        if action == "loop":
            src.seek(0.0)
        elif action == "camera" and self.loop:
            asyncio.run_coroutine_threadsafe(self.take_camera(), self.loop)
        elif action == "next" and self.queue and self.loop:
            asyncio.run_coroutine_threadsafe(self.take_next(), self.loop)
        else:  # hold the last frame
            self.state["media"]["paused"] = True
            if self.loop:
                asyncio.run_coroutine_threadsafe(
                    self.broadcast({"type": "set", "path": "media.paused", "value": True}), self.loop)
        return False

    def _on_video_error(self, message):
        """Tell the Guide page, once per failure run: a camera that's
        unplugged or busy fails every few seconds as it's retried."""
        now = time.monotonic()
        if now - getattr(self, "_video_error_t", 0.0) < 15:
            return
        self._video_error_t = now
        src = self.state["stream"].get("source", "")
        if self.loop:
            asyncio.run_coroutine_threadsafe(
                self.notify(f"No video from {src}: {message.rstrip('.')}. Retrying; pick another camera under Source."),
                self.loop)

    async def notify(self, text):
        await self.broadcast({"type": "notice", "text": text}, roles={"guide"})

    def audio_desc(self):
        """The microphone out through appsink to the studio chain (studio.py),
        and its stereo back in through appsrc to RTP. All the voice effects,
        denoise included, are in the chain."""
        mic = f"device={self.args.mic} " if self.args.mic else ""
        if self.args.test_tone:
            src = ("audiotestsrc is-live=true wave=sine freq=300 volume=0.012 "
                   "samplesperbuffer=240")
        elif self.args.mic == voice_input.UNIT_SOURCE:
            # The display unit's voice comes from the Guide page (voice_input.py):
            # a silent live source is the clock it's taken at
            src = "audiotestsrc is-live=true wave=silence samplesperbuffer=240"
        else:
            src = f"pulsesrc {mic}buffer-time=20000 latency-time=5000 do-timestamp=true"
        chain = [
            src,
            "audio/x-raw,rate=48000,channels=1",
            "audioconvert",
            "audio/x-raw,format=F32LE,rate=48000,channels=1",
            "appsink name=voice_in emit-signals=true sync=false max-buffers=8 drop=true",
        ]
        chain_b = [
            "appsrc name=voice_out is-live=true format=time do-timestamp=false "
            "caps=audio/x-raw,format=F32LE,rate=48000,channels=2,layout=interleaved",
            "audioconvert",
            "audio/x-raw,format=S16BE,rate=48000,channels=2",
            "rtpL16pay name=pay pt=97 max-ptime=5000000 min-ptime=5000000",
            f"multiudpsink name=sink sync=false async=false qos-dscp={AUDIO_DSCP}",
        ]
        return " ! ".join(chain) + "  " + " ! ".join(chain_b)

    def _attach_video_clients(self, pipeline):
        pay = pipeline.get_by_name("pay")
        if pay is not None:
            pay.get_static_pad("src").add_probe(Gst.PadProbeType.BUFFER, self._count_video)
        sink = pipeline.get_by_name("sink")
        for host, vport, _, _ in self.destinations:
            sink.emit("add", host, vport)
        self.switcher.bind(pipeline)
        if self.switcher.on_air is None and self.switcher.trans is None:
            # Starting: the camera (or test pattern) is on, or the --file
            self.switcher.take(self._camera_source(), "cut", 0.0)
            if self.args.file and self.loop:
                asyncio.run_coroutine_threadsafe(self.take_file(self.args.file, trusted=True), self.loop)

    def _attach_media_clients(self, pipeline):
        sink = pipeline.get_by_name("sink")
        for host, _, _, mport in self.destinations:
            sink.emit("add", host, mport)
        self.mixer.bind(pipeline.get_by_name("out"))

    def _attach_audio_clients(self, pipeline):
        sink = pipeline.get_by_name("sink")
        for host, _, aport, _ in self.destinations:
            sink.emit("add", host, aport)
        voice_out = pipeline.get_by_name("voice_out")
        pipeline.get_by_name("voice_in").connect("new-sample", self._on_voice_block, voice_out)

    def _on_voice_block(self, appsink, appsrc):
        """Streaming thread: one microphone buffer through the voice effects."""
        sample = appsink.emit("pull-sample")
        if sample is None:
            return Gst.FlowReturn.EOS
        buf = sample.get_buffer()
        ok, info = buf.map(Gst.MapFlags.READ)
        if not ok:
            return Gst.FlowReturn.OK
        x = np.frombuffer(info.data, dtype=np.float32)
        if self.args.mic == voice_input.UNIT_SOURCE and not self.args.test_tone:
            x = self.unit_voice.take(len(x))
        y = self.studio.process(x)
        buf.unmap(info)
        out = Gst.Buffer.new_wrapped(y.tobytes())
        out.pts, out.dts, out.duration = buf.pts, buf.dts, buf.duration
        appsrc.emit("push-buffer", out)
        return Gst.FlowReturn.OK

    def apply_voice(self):
        """The voice settings to the effects: they take them at the next block,
        from any thread, so nothing's rebuilt."""
        if self.studio:
            self.studio.set_all(self.state["voice"])

    def apply_preset_values(self, name):
        p = self.presets.get(name)
        if not p:
            return False
        # The effects a preset doesn't mention go back to none, so one preset's
        # ring or chorus doesn't stay on in the next; the mic's own settings stay
        self.state["voice"].update(preset_values(p, DEFAULT_STATE["voice"], VOICE_MIC_KEYS))
        self.state["voice"]["preset"] = name
        return True

    def apply_bitrate(self):
        enc = self.video.get("enc")
        if enc:
            prop, scale = h264_bitrate_prop(self.encoder)
            try:
                enc.set_property(prop, int(self.state["video"]["bitrate_kbps"] * scale))
            except Exception as e:  # some encoders only accept it in NULL/READY
                log.warning("live bitrate change failed (%s); restarting video", e)
                GLib.idle_add(lambda: (self.video.start(), False)[1])

    def force_keyframe(self):
        now = time.monotonic()
        if now - self.last_keyframe < 0.25:
            return
        self.last_keyframe = now
        enc = self.video.get("enc")
        if not enc:
            return
        s = Gst.Structure.new_from_string("GstForceKeyUnit, all-headers=(boolean)true")
        enc.get_static_pad("src").send_event(Gst.Event.new_custom(Gst.EventType.CUSTOM_UPSTREAM, s))

    def add_destination(self, dest):
        if dest in self.destinations:
            return
        self.destinations.add(dest)
        host, vport, aport, mport = dest
        log.info("streaming to %s (video %d, voice %d, media audio %d)", host, vport, aport, mport)

        def do():
            for pl, el, port in ((self.video, "sink", vport), (self.audio, "sink", aport),
                                 (self.media_pipe, "sink", mport)):
                if pl and pl.get(el):
                    pl.get(el).emit("add", host, port)
            return False
        GLib.idle_add(do)

    def remove_destination(self, dest):
        if dest not in self.destinations or dest[0] in self.args.also_send:
            return
        self.destinations.discard(dest)
        host, vport, aport, mport = dest
        log.info("stopped streaming to %s", host)

        def do():
            for pl, el, port in ((self.video, "sink", vport), (self.audio, "sink", aport),
                                 (self.media_pipe, "sink", mport)):
                if pl and pl.get(el):
                    pl.get(el).emit("remove", host, port)
            return False
        GLib.idle_add(do)

    def _count_video(self, _pad, _info):
        self.video_packets += 1
        return Gst.PadProbeReturn.OK

    # ---------------- control protocol ----------------
    async def broadcast(self, msg, roles=None, exclude=None):
        """To every client that has said hello ([roles]: only those)."""
        data = json.dumps(msg)
        for ws, info in list(self.clients.items()):
            if ws is exclude or info.get("role") is None or (roles and info.get("role") not in roles):
                continue
            try:
                await ws.send_str(data)
            except ConnectionError:
                pass

    def _voice_meters(self):
        if not self.studio:
            return {"mic_db": -100.0, "out_db": -100.0, "gate_open": False, "voice_problem": self.voice_problem}
        mic, out, gate = self.studio.meter()
        if not (self.audio and self.audio.enabled):
            mic = out = -100.0
        return {"mic_db": round(mic, 1), "out_db": round(out, 1), "gate_open": gate, "voice_problem": "",
                **({"unit_voice": self.unit_voice.status()}
                   if self.args.mic == voice_input.UNIT_SOURCE else {})}

    def summary(self):
        return {
            "type": "clients",
            "clients": [
                {"id": i["id"], "role": i.get("role"), "name": i.get("name"), "addr": i["addr"],
                 "key": i.get("key", ""), "sig": i.get("sig", ""), "allow": i.get("allow", {}),
                 "stats": i.get("stats"), "toys": i.get("toys")}
                for i in self.clients.values() if i.get("role")
            ],
            "session": {"on": self.session_token is not None, "expires": self.session_expires},
            "scenes": sorted(self.scenes),
            "presets": list(self.presets),
            **self._voice_meters(),
            "media": {
                "dir": str(self.media_dir), "files": self.media_files(),
                "position": round(self.media_position(), 2),
                "duration": round(self.media_info.duration_s, 2) if self.media_info else 0.0,
                "has_audio": bool(self.media_info and self.media_info.has_audio),
                "images": self.image_files(),
            },
            "switch": {**self.switcher.status(), "queue": list(self.queue), "cue": self.cue_spec},
            "music": {**self.music.status(), "files": self.music_files(),
                      "level_db": round(self.mixer.level_db, 1)},
        }

    def _side_effects(self, paths):
        """What changed settings do besides being kept: the voice effects take
        them, the encoder its bitrate, the media player its own."""
        sections = {p.split(".")[0] for p in paths}
        if "voice" in sections:
            self.apply_voice()
        if "video.bitrate_kbps" in paths:
            GLib.idle_add(lambda: (self.apply_bitrate(), False)[1])
        if "media" in sections:
            GLib.idle_add(lambda: (self.apply_media_settings(), False)[1])
        if sections & {"switch", "color", "image"}:
            GLib.idle_add(lambda: (self.apply_switch_settings(list(paths)), False)[1])

    async def handle_set(self, path, value):
        try:
            value = set_path(self.state, path, value)
        except (KeyError, TypeError, ValueError) as e:
            log.warning("bad set %s=%r (%s)", path, value, e)
            return
        if path == "voice.preset":
            self.apply_preset_values(value)
            self.apply_voice()
            await self.broadcast({"type": "state", "state": self.state})
            return
        self._side_effects([path])
        await self.broadcast({"type": "set", "path": path, "value": value})

    async def handle_set_many(self, values):
        """Many settings at once (a preset, a layout of values): all set, the
        voice given them once, and the state sent once. voice.preset here is
        only the name: its values are in [values] if they're wanted."""
        done, skipped = set_many(self.state, values)
        if skipped:
            log.warning("set_many skipped %s", ", ".join(skipped[:8]))
        if not done:
            return
        self._side_effects(list(done))
        await self.broadcast({"type": "state", "state": self.state})

    # Messages each role may send. Vessels only report; the Guide page drives.
    VESSEL_MESSAGES = {"hello", "ping", "stats", "keyframe", "left", "toys_state"}

    def _session_valid(self, token) -> bool:
        return (self.session_token is not None and isinstance(token, str)
                and secrets.compare_digest(token, self.session_token)
                and time.time() < self.session_expires)

    async def handle_message(self, ws, info, msg):
        t = msg.get("type")
        role = info.get("role")
        if role is None and t != "hello":
            return
        if role == "vessel" and t not in self.VESSEL_MESSAGES:
            log.warning("vessel %s sent %r; ignored", info["id"], t)
            return
        if t == "hello":
            if role is not None:
                return
            want = msg.get("role")
            if want == "guide" and info["site"] == "guide" and self.guide_token and \
                    secrets.compare_digest(str(msg.get("token", "")), self.guide_token):
                info["role"] = "guide"
            elif want == "vessel" and info["site"] == "vessel" and self._session_valid(msg.get("token")):
                info["role"] = "vessel"
            else:
                log.warning("refused %s: not invited", info["id"])
                await ws.close(code=4001, message=b"not invited")
                return
            info["name"] = str(msg.get("name", ""))[:64]
            if info["role"] == "vessel":
                # Who they say they are, signed: the Guide page checks it.
                info["key"] = str(msg.get("key", ""))[:64]
                info["sig"] = str(msg.get("sig", ""))[:128]
                info["allow"] = {k: bool(v) for k, v in (msg.get("allow") or {}).items()}
                dest = (info["addr"], int(msg.get("video_port", VIDEO_PORT)),
                        int(msg.get("audio_port", AUDIO_PORT)), int(msg.get("media_port", MEDIA_PORT)))
                info["dest"] = dest
                # The phone owns its calibration; adopt what it remembers.
                for k, v in (msg.get("view") or {}).items():
                    if k in self.state["view"]:
                        try:
                            set_path(self.state, f"view.{k}", v)
                        except (TypeError, ValueError):
                            pass
                self.add_destination(dest)
                GLib.timeout_add(300, lambda: (self.force_keyframe(), False)[1])
            await ws.send_str(json.dumps({"type": "state", "state": self.state}))
            if info["role"] == "guide":
                # What each built-in preset comes to, for the Guide to compare with
                await ws.send_str(json.dumps({
                    "type": "preset_values",
                    "presets": resolved_presets(self.presets, DEFAULT_STATE["voice"], VOICE_MIC_KEYS),
                    # And every setting's default, for the Guide's reset buttons
                    "defaults": DEFAULT_STATE}))
            if info["role"] == "vessel":
                for cue in self.word_cues.values():
                    await ws.send_str(json.dumps(cue))
            await self.broadcast({"type": "state", "state": self.state}, exclude=ws)
            await self.broadcast(self.summary(), roles={"guide"})
        elif t == "set":
            await self.handle_set(msg["path"], msg["value"])
        elif t == "set_many":
            await self.handle_set_many(msg.get("values"))
        elif t == "words":
            # Words for a Vessel's view, one of WORD_LAYERS layers: relayed as
            # they are (the Vessel checks them) and kept for Vessels who join later
            layer = msg.get("layer")
            if isinstance(layer, int) and 0 <= layer < WORD_LAYERS and len(json.dumps(msg)) <= 4096:
                self.word_cues[layer] = msg
                await self.broadcast(msg, roles={"vessel"})
        elif t == "words_clear":
            layers = msg.get("layers")
            if not isinstance(layers, list):
                layers = list(range(WORD_LAYERS))
            layers = [n for n in layers if isinstance(n, int) and 0 <= n < WORD_LAYERS]
            for n in layers:
                self.word_cues.pop(n, None)
            await self.broadcast({"type": "words_clear", "layers": layers, "fade": msg.get("fade", 1.0)},
                                 roles={"vessel"})
        elif t == "toys":
            # Toy commands (the bytes of an others.h Vibe command, base64) for
            # one Vessel: relayed to it alone, which checks them against its own
            # permissions before its unit gets them. Nothing is kept for late joiners.
            data = msg.get("v")
            if isinstance(data, str) and len(data) <= 400:
                for w, i in list(self.clients.items()):
                    if i.get("role") == "vessel" and i["id"] == msg.get("to"):
                        await w.send_str(json.dumps({"type": "toys", "v": data}))
        elif t == "toys_state":
            # What a Vessel's unit and permissions allow the Guide, as it says
            info["toys"] = {
                "unit": bool(msg.get("unit")),
                "mapped": int(msg.get("mapped", 0)) & 0x3F,
                "allowed": bool(msg.get("allowed")),
                "why": str(msg.get("why", ""))[:40],
            }
            await self.broadcast(self.summary(), roles={"guide"})
        elif t == "session":
            token, expires = msg.get("token"), float(msg.get("expires", 0))
            if not isinstance(token, str) or len(token) < 16 or expires <= time.time():
                await self.notify("bad session")
                return
            if token != self.session_token:
                await self.end_session()
            self.session_token, self.session_expires = token, expires
            log.info("session open until %s", time.strftime("%H:%M", time.localtime(expires)))
            self._set_live(True)
            await self.broadcast(self.summary(), roles={"guide"})
        elif t == "session_end":
            await self.end_session()
            await self.broadcast(self.summary(), roles={"guide"})
        elif t == "kick":
            for w, i in list(self.clients.items()):
                if i.get("role") == "vessel" and i["id"] == msg.get("id"):
                    await w.close(code=4002, message=b"removed by the Guide")
        elif t == "media_play" and msg.get("file"):
            await self.take_file(str(msg["file"]))
        elif t == "media_camera":
            await self.take_camera()
        elif t == "take":
            await self.take_spec(self._clean_spec(msg.get("spec")))
        elif t == "cue":
            self.cue_spec = self._clean_spec(msg.get("spec"))
            await self.update_preview()
        elif t == "next":
            await self.take_next()
        elif t == "queue_add":
            spec = self._clean_spec(msg.get("spec"))
            if spec and len(self.queue) < 200:
                self.queue.append(spec)
                await self.update_preview()
        elif t == "queue_remove":
            i = msg.get("index")
            if isinstance(i, int) and 0 <= i < len(self.queue):
                del self.queue[i]
                await self.update_preview()
        elif t == "queue_move":
            i, j = msg.get("from"), msg.get("to")
            if isinstance(i, int) and isinstance(j, int) and 0 <= i < len(self.queue):
                self.queue.insert(max(0, min(j, len(self.queue) - 1)), self.queue.pop(i))
                await self.update_preview()
        elif t == "queue_clear":
            self.queue.clear()
            await self.update_preview()
        elif t == "music_play" and isinstance(msg.get("file"), str):
            self._glib(self.music.play, msg["file"])
        elif t == "music_add" and isinstance(msg.get("file"), str):
            self._glib(self.music.enqueue, msg["file"])
        elif t == "music_remove" and isinstance(msg.get("index"), int):
            self._glib(self.music.remove, msg["index"])
        elif t == "music_move" and isinstance(msg.get("from"), int) and isinstance(msg.get("to"), int):
            self._glib(self.music.move, msg["from"], msg["to"])
        elif t == "music_clear":
            self._glib(self.music.clear)
        elif t == "music_next":
            self._glib(self.music.next)
        elif t == "music_pause":
            self._glib(self.music.pause, bool(msg.get("paused")))
        elif t == "music_seek":
            self._glib(self.music.seek, float(msg.get("pos", 0)))
        elif t == "music_stop":
            self._glib(self.music.stop)
        elif t == "capture":
            await self.set_capture(msg)
        elif t == "media_seek":
            pos = float(msg.get("pos", 0))
            GLib.idle_add(lambda: (self.seek(pos), False)[1])
        elif t == "keyframe":
            GLib.idle_add(lambda: (self.force_keyframe(), False)[1])
        elif t == "left":
            # The Vessel used the exit gesture; its socket closes next.
            info["left"] = True
            await self.broadcast({"type": "vessel_left", "id": info["id"]}, roles={"guide"})
        elif t == "ping":
            await ws.send_str(json.dumps({"type": "pong", "t": msg.get("t")}))
        elif t == "stats":
            info["stats"] = msg.get("stats")
        elif t == "scene_save" and msg.get("name"):
            self.scenes[msg["name"]] = {s: copy.deepcopy(self.state[s]) for s in SCENE_SECTIONS}
            self.scenes_path.write_text(json.dumps(self.scenes, indent=2))
            await self.broadcast(self.summary(), roles={"guide"})
        elif t == "scene_load" and msg.get("name") in self.scenes:
            for section, values in self.scenes[msg["name"]].items():
                if section in self.state:
                    self.state[section].update(values)
            self.apply_voice()
            await self.broadcast({"type": "state", "state": self.state})
        elif t == "scene_delete" and msg.get("name") in self.scenes:
            del self.scenes[msg["name"]]
            self.scenes_path.write_text(json.dumps(self.scenes, indent=2))
            await self.broadcast(self.summary(), roles={"guide"})

    def _set_live(self, on: bool):
        """Run the camera and mic, or let them go (their lights go out)."""
        on = on or bool(self.args.also_send)
        if not on:
            # Every source goes first (the camera's light goes out), then the pipelines
            self.queue.clear()
            self._glib(self.switcher.stop_all)
            self._glib(self.music.shutdown)
            self.mixer.stop()
        else:
            self.mixer.start()
        for p in (self.video, self.audio, self.media_pipe):
            if p is None or p.enabled == on:
                continue
            p.enabled = on
            log.info("%s %s", p.name, "on" if on else "off: no session")
            GLib.idle_add(lambda p=p: (p.start(), False)[1])
        if on:
            GLib.timeout_add(400, lambda: (self.force_keyframe(), False)[1])

    async def end_session(self):
        """No session any more: every Vessel is dropped, and can't come back
        with that invitation. The camera and mic are let go."""
        if self.session_token is not None:
            log.info("session ended")
        self.session_token, self.session_expires = None, 0.0
        self.word_cues.clear()
        self._set_live(False)
        for w, i in list(self.clients.items()):
            if i.get("role") == "vessel":
                await w.close(code=4001, message=b"the session has ended")

    def _ws_handler(self, site):
        async def handler(request):
            return await self.ws_handler(request, site)
        return handler

    async def ws_handler(self, request, site):
        ws = web.WebSocketResponse(heartbeat=5.0, max_msg_size=4 * 1024 * 1024)
        await ws.prepare(request)
        peer = request.transport.get_extra_info("peername")
        info = {"id": f"{peer[0]}:{peer[1]}", "addr": peer[0], "role": None, "site": site,
                "previewq": asyncio.Queue(maxsize=32)}
        self.clients[ws] = info
        log.info("client connected from %s (%s port)", info["id"], site)
        pump = asyncio.create_task(self._preview_pump(ws, info["previewq"]))
        # A client that hasn't said who it is within a few seconds goes.
        asyncio.get_running_loop().call_later(
            5, lambda: info.get("role") is None and not ws.closed and asyncio.ensure_future(ws.close(code=4001)))
        try:
            async for m in ws:
                if m.type == WSMsgType.TEXT:
                    try:
                        await self.handle_message(ws, info, json.loads(m.data))
                    except Exception:
                        log.exception("error handling %s", m.data[:200])
                elif m.type == WSMsgType.BINARY and info.get("role") == "vessel":
                    self._relay_preview(m.data)
                elif m.type == WSMsgType.BINARY and info.get("role") == "guide" and m.data[:1] == \
                        bytes([voice_input.MSG_UNIT_VOICE]):
                    self.unit_voice.add(m.data[1:])
                elif m.type == WSMsgType.ERROR:
                    break
        finally:
            pump.cancel()
            del self.clients[ws]
            if info.get("role") == "guide" and not any(
                    i.get("role") == "guide" for i in self.clients.values()):
                for k in ("video", "audio"):
                    if self.state["preview"][k]:
                        await self.handle_set(f"preview.{k}", False)
            if "dest" in info and not any(i.get("dest") == info["dest"] for i in self.clients.values()):
                self.remove_destination(info["dest"])
            log.info("client %s (%s) disconnected", info["id"], info.get("role"))
            await self.broadcast(self.summary(), roles={"guide"})
        return ws

    def _relay_preview(self, data: bytes):
        """Fan a preview message out to Guide pages; a slow one only drops its own frames."""
        for i in self.clients.values():
            if i.get("role") != "guide":
                continue
            q = i["previewq"]
            if q.full():
                try:
                    q.get_nowait()  # drop the oldest; fresh frames matter more
                except asyncio.QueueEmpty:
                    pass
            q.put_nowait(data)

    @staticmethod
    async def _preview_pump(ws, q):
        try:
            while True:
                data = await q.get()
                await ws.send_bytes(data)
        except (asyncio.CancelledError, ConnectionError):
            pass

    async def status_task(self):
        while True:
            await asyncio.sleep(0.5)
            if self.session_token is not None and time.time() >= self.session_expires:
                await self.end_session()
            await self.broadcast(self.summary(), roles={"guide"})

    # ---------------- the app ----------------
    def _read_first_line(self):
        """The app's line: the Guide page's token, and the session if one is
        on (a restart: its Vessels come straight back)."""
        line = sys.stdin.readline()
        try:
            j = json.loads(line)
            self.guide_token = str(j.get("guide_token", ""))
            s = j.get("session") or {}
            token, expires = s.get("token"), float(s.get("expires", 0))
            if isinstance(token, str) and len(token) >= 16 and expires > time.time():
                self.session_token, self.session_expires = token, expires
                log.info("session open until %s", time.strftime("%H:%M", time.localtime(expires)))
        except (ValueError, AttributeError, TypeError):
            log.error("bad first line on stdin")

    def _read_stdin(self):
        """Wait: stdin closing means the app's gone."""
        for _ in sys.stdin:
            pass
        log.info("stdin closed; stopping")
        if self.loop and self.stopped:
            self.loop.call_soon_threadsafe(self.stopped.set)

    # ---------------- run ----------------
    async def run(self):
        self.loop = asyncio.get_running_loop()
        self.stopped = asyncio.Event()
        a = self.args
        if a.guide_token:
            self.guide_token = a.guide_token
        else:
            await self.loop.run_in_executor(None, self._read_first_line)
            threading.Thread(target=self._read_stdin, daemon=True, name="stdin").start()

        guide_app = web.Application()
        guide_app.router.add_get("/ws", self._ws_handler("guide"))
        guide_runner = web.AppRunner(guide_app, access_log=None)
        await guide_runner.setup()
        guide_site = web.TCPSite(guide_runner, "127.0.0.1", a.guide_port)
        await guide_site.start()

        ctx = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        ctx.load_cert_chain(a.cert, a.key)
        vessel_app = web.Application()
        vessel_app.router.add_get("/ws", self._ws_handler("vessel"))
        vessel_runner = web.AppRunner(vessel_app, access_log=None)
        await vessel_runner.setup()
        vessel_site = web.TCPSite(vessel_runner, "0.0.0.0", a.vessel_port, ssl_context=ctx)
        await vessel_site.start()

        self._set_live(self.session_token is not None)

        def port_of(runner):
            return runner.addresses[0][1]
        ready = {"guide_port": port_of(guide_runner), "vessel_port": port_of(vessel_runner),
                 "addrs": sorted(local_ips())}
        print("HIVESIGHT " + json.dumps(ready), flush=True)
        log.info("Guide page on 127.0.0.1:%d; Vessels on wss://%s:%d/ws", ready["guide_port"],
                 ",".join(ready["addrs"]) or "?", ready["vessel_port"])
        status = asyncio.create_task(self.status_task())
        await self.stopped.wait()
        status.cancel()
        await self.end_session()
        await guide_runner.cleanup()
        await vessel_runner.cleanup()


def local_ips():
    try:
        out = subprocess.run(["ip", "-4", "-o", "addr", "show"], capture_output=True,
                             text=True, timeout=2).stdout
        return [m.group(1) for m in re.finditer(r"inet (\d+\.\d+\.\d+\.\d+)", out)
                if not m.group(1).startswith(("127.", "172.17."))]
    except (OSError, subprocess.SubprocessError):
        return []


def source_name(dev):
    """A microphone's PulseAudio/PipeWire source name, for pulsesrc device=,
    or None for a monitor (what's playing, not a microphone). PipeWire's
    provider has node.name; PulseAudio's, the device's internal-name."""
    props = dev.get_properties()
    if props and props.get_string("device.class") == "monitor":
        return None
    name = props.get_string("node.name") or props.get_string("device.name") if props else None
    if not name and dev.find_property("internal-name"):
        name = dev.get_property("internal-name")
    if not name or name.endswith(".monitor"):
        return None
    return name


def list_devices():
    mon = Gst.DeviceMonitor()
    mon.add_filter("Video/Source", None)
    mon.add_filter("Audio/Source", None)
    mon.start()
    for dev in mon.get_devices():
        props = dev.get_properties()
        path = props.get_string("device.path") or props.get_string("api.v4l2.path") \
            if props else None
        print(f"\n== {dev.get_device_class()}: {dev.get_display_name()}"
              + (f"  [{path}]" if path else ""))
        if dev.get_device_class() == "Audio/Source":
            name = source_name(dev)
            print(f"   --mic {name}" if name else "   (a monitor, not a microphone)")
            continue
        caps = dev.get_caps()
        seen = set()
        for i in range(caps.get_size()):
            s = caps.get_structure(i)
            ok_w, w = s.get_int("width")
            ok_h, h = s.get_int("height")
            if not (ok_w and ok_h):
                continue
            fmt = "mjpeg" if s.get_name() == "image/jpeg" else s.get_string("format") or s.get_name()
            fr = s.to_string()
            fps = re.findall(r"(\d+)/1", fr.split("framerate=")[-1]) if "framerate" in fr else []
            key = (fmt, w, h)
            if key in seen:
                continue
            seen.add(key)
            print(f"   {fmt:6} {w}x{h}  fps: {','.join(sorted(set(fps), key=int)) or '?'}")
    mon.stop()


def devices_json():
    """Cameras (path, name, modes) and microphones (name, description)."""
    mon = Gst.DeviceMonitor()
    mon.add_filter("Video/Source", None)
    mon.add_filter("Audio/Source", None)
    mon.start()
    cameras, mics = [], []
    for dev in mon.get_devices():
        props = dev.get_properties()
        if dev.get_device_class() == "Audio/Source":
            name = source_name(dev)
            if name:
                mics.append({"name": name, "label": dev.get_display_name()})
            continue
        path = (props.get_string("device.path") or props.get_string("api.v4l2.path")) if props else None
        if not path:
            continue
        modes, seen = [], set()
        caps = dev.get_caps()
        for i in range(caps.get_size()):
            st = caps.get_structure(i)
            ok_w, w = st.get_int("width")
            ok_h, h = st.get_int("height")
            if not (ok_w and ok_h):
                continue
            fmt = "mjpeg" if st.get_name() == "image/jpeg" else "yuyv" \
                if st.get_string("format") == "YUY2" else None
            if fmt is None or (fmt, w, h) in seen:
                continue
            seen.add((fmt, w, h))
            fr = st.to_string()
            fps = sorted({int(x) for x in re.findall(r"(\d+)/1", fr.split("framerate=")[-1])}) \
                if "framerate" in fr else []
            modes.append({"format": fmt, "width": w, "height": h, "fps": fps})
        if path not in [c["path"] for c in cameras]:
            cameras.append({"path": path, "name": dev.get_display_name(), "modes": modes})
    mon.stop()
    return {"cameras": cameras, "mics": mics}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--device", default="/dev/video0", help="V4L2 camera device")
    ap.add_argument("--width", type=int, default=2560, help="full frame width (both eyes for SBS)")
    ap.add_argument("--height", type=int, default=720)
    ap.add_argument("--fps", type=int, default=30)
    ap.add_argument("--format", choices=["mjpeg", "yuyv"], default="mjpeg")
    ap.add_argument("--layout", choices=["sbs", "mono"], default="sbs",
                    help="sbs: left half = left eye; mono: same image to both eyes")
    ap.add_argument("--test-pattern", action="store_true", help="synthetic SBS source instead of a camera")
    ap.add_argument("--encoder", choices=["auto"] + ENCODER_ORDER, default="auto")
    ap.add_argument("--bitrate", type=int, default=8000, help="video kbit/s")
    ap.add_argument("--mic", default=None,
                    help="PulseAudio/PipeWire source name (default source if omitted), or @unit for the display "
                         "unit's microphone, sent by the Guide page")
    ap.add_argument("--no-audio", action="store_true")
    ap.add_argument("--fx-lib", default=None,
                    help="libdronelab_fx with the voice effects (default: the app bundle's lib/, then build/)")
    ap.add_argument("--test-tone", action="store_true",
                    help="replace the mic with a quiet 300 Hz tone (checks the voice path)")
    ap.add_argument("--guide-port", type=int, default=0,
                    help="the Guide page's port, on 127.0.0.1 (default: any free one)")
    ap.add_argument("--vessel-port", type=int, default=8443, help="the Vessels' TLS port")
    ap.add_argument("--cert", help="TLS certificate (PEM) for the Vessels' port")
    ap.add_argument("--key", help="its private key (PEM)")
    ap.add_argument("--guide-token", default="",
                    help="the Guide page's token, for running by hand (otherwise read from stdin)")
    ap.add_argument("--also-send", action="append", default=[], metavar="HOST",
                    help="always stream to HOST too (e.g. 127.0.0.1 for tools/preview.sh)")
    ap.add_argument("--media-dir", default=None,
                    help="folder of video files offered on the Guide page's Source panel (default ~/Videos)")
    ap.add_argument("--music-dir", default="~/Music",
                    help="folder of music offered on the Guide page's Sound panel (default ~/Music)")
    ap.add_argument("--file", default=None, help="start by playing this video file instead of the camera")
    ap.add_argument("--scenes", default=str(HERE / "scenes.json"))
    ap.add_argument("--list-devices", action="store_true")
    ap.add_argument("--list-devices-json", action="store_true",
                    help="cameras and microphones as one JSON line, for the Guide page")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(asctime)s %(levelname)-7s %(message)s", datefmt="%H:%M:%S")
    Gst.init(None)
    if args.list_devices:
        list_devices()
        return
    if args.list_devices_json:
        print(json.dumps(devices_json()))
        return
    if not (args.cert and args.key):
        ap.error("--cert and --key are needed: Vessels connect over TLS")

    args.media_dir_given = args.media_dir is not None
    if args.media_dir is None:
        args.media_dir = "~/Videos"
    if args.test_pattern and args.layout == "mono":
        args.layout = "sbs"
    sender = Sender(args)

    # GLib main loop (bus watches, timeouts) on its own thread; asyncio on main.
    glib_loop = GLib.MainLoop()
    threading.Thread(target=glib_loop.run, daemon=True, name="glib").start()
    try:
        asyncio.run(sender.run())
    except KeyboardInterrupt:
        pass
    finally:
        sender.switcher.stop_all()
        sender.music.shutdown()
        sender.mixer.stop()
        sender.video.stop()
        sender.media_pipe.stop()
        if sender.audio:
            sender.audio.stop()
        glib_loop.quit()


if __name__ == "__main__":
    sys.exit(main())
