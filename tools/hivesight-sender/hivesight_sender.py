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

from dynamics import Dynamics  # noqa: E402
from voicefx import SpectralVoice  # noqa: E402
import media  # noqa: E402

HERE = Path(__file__).resolve().parent
log = logging.getLogger("hivesight")

VIDEO_PORT, AUDIO_PORT, MEDIA_PORT = 5004, 5006, 5008
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
    },
    "mix": {
        "master": 1.0, "voice_vol": 0.9, "voice_pan": 0.0, "autopan_hz": 0.0,
        "beats_vol": 0.25, "noise_vol": 0.0, "media_vol": 1.0, "jitter_ms": 40,
    },
    "beats": {"on": True, "carrier_hz": 200.0, "beat_hz": 6.0, "glide_s": 4.0},
    "fx": {
        "fade": 1.0, "fade_s": 1.5, "delay_ms": 0, "swap": False, "mirror": False,
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
    # Words drawn into the Vessel's view. Guide-only: the Guide page times
    # the cues (text, then seq, which counts up on every cue so the same
    # phrase can be cued twice) and each cue carries its own fade_s. Not part
    # of scenes: a scene is a look, and a phrase shouldn't come back with it.
    "words": {
        "text": "", "seq": 0, "mode": "still", "size": 0.12, "depth": 0.0,
        "opacity": 1.0, "hue": 0.0, "sat": 0.0, "speed": 0.5, "fade_s": 1.0,
    },
    # Guide preview: the phone mirrors back what it shows and plays.
    # Switched off automatically when the last Guide page disconnects.
    "preview": {"video": False, "audio": False, "fps": 10},
    # Video source: the live camera (or test pattern) or a file from --media-dir.
    # av_offset_ms > 0 delays the file's video to line up with the phone's
    # later-arriving audio (jitter buffer + Bluetooth); < 0 delays the audio.
    "media": {"source": "camera", "file": "", "paused": False, "at_end": "loop",
              "av_offset_ms": 150},
    "video": {"bitrate_kbps": 8000},
    "stream": {},
}

# Settings saved with a scene (calibration and encoder settings are not).
SCENE_SECTIONS = ("voice", "mix", "beats", "fx", "spiral", "photic")


def get_path(tree, path):
    node = tree
    for key in path.split("."):
        node = node[key]
    return node


def set_path(tree, path, value):
    *parents, leaf = path.split(".")
    node = tree
    for key in parents:
        node = node[key]
    if leaf not in node:
        raise KeyError(path)
    old = node[leaf]
    # Coerce to the existing type so a slider's "0.5" string can't sneak in.
    if isinstance(old, bool):
        value = bool(value)
    elif isinstance(old, str):
        value = str(value)[:600]
    elif isinstance(old, (int, float)) and not isinstance(value, bool):
        value = type(old)(float(value)) if isinstance(old, float) else int(round(float(value)))
    node[leaf] = value
    return value


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


def parse_level_db(structure_str: str):
    """Extract per-channel RMS dB from a 'level' message (GValueArray is awkward in PyGObject)."""
    m = re.search(r"rms=\(double\)\{([^}]*)\}", structure_str) or \
        re.search(r"rms=\(GValueArray\)<([^>]*)>", structure_str)
    if not m:
        return None
    vals = [float(v.strip().replace("(double)", "")) for v in m.group(1).split(",") if v.strip()]
    return max(vals) if vals else None


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

    def __init__(self, name, build_desc, on_built=None, on_level=None, on_eos=None, on_error=None):
        self.name = name
        self.on_error = on_error
        # Off, it isn't built at all (the camera and mic are let go), and
        # start() just stops it
        self.enabled = True
        self.build_desc = build_desc
        self.on_built = on_built
        self.on_level = on_level
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
        elif t == Gst.MessageType.ELEMENT and self.on_level:
            s = msg.get_structure()
            if s and s.get_name() == "level":
                db = parse_level_db(s.to_string())
                if db is not None:
                    self.on_level(db)


# --------------------------------------------------------------------------
# The sender
# --------------------------------------------------------------------------
class Sender:
    def __init__(self, args):
        self.args = args
        self.loop: asyncio.AbstractEventLoop | None = None
        self.state = copy.deepcopy(DEFAULT_STATE)
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
        self.media_info: media.MediaInfo | None = None
        self._media_list: list[str] = []
        self._media_list_t = 0.0
        self.last_keyframe = 0.0
        self.video_packets = 0
        self.media_generation = 0
        self.mic_level_db = -100.0
        self.dynamics: Dynamics | None = None

        self.encoder = pick_encoder(args.encoder)
        log.info("video encoder: %s", self.encoder)
        self._set_camera_stream_state()
        self.state["video"]["bitrate_kbps"] = args.bitrate
        self.apply_preset_values(self.state["voice"]["preset"])

        self.video = GstPipeline("video", self.video_desc, on_built=self._attach_video_clients,
                                 on_eos=lambda: GLib.idle_add(self._on_file_eos),
                                 on_error=self._on_video_error)
        if args.file:
            self._select_file_sync(args.file)
        self.audio = GstPipeline("audio", self.audio_desc, on_built=self._attach_audio_clients,
                                 on_level=self._on_mic_level) if not args.no_audio else None
        self._audio_structure = self._audio_structure_key()
        # The camera and mic run only while there's a session (or --also-send)
        for p in (self.video, self.audio):
            if p:
                p.enabled = False

    # ---------------- pipelines ----------------
    def video_desc(self):
        if self.state["media"]["source"] == "file" and self.media_info:
            return self.file_desc(self.media_info)
        a = self.args
        w, h, fps = a.width, a.height, a.fps
        gop = fps * 2
        if a.test_pattern:
            # Two moving-ball sources composited side by side, labelled per eye.
            hw = w // 2
            src_head = (f"compositor name=comp background=black sink_1::xpos={hw} ! "
                        f"video/x-raw,width={w},height={h},framerate={fps}/1 ! videoconvert ! ")
            extra = "".join(
                f" videotestsrc is-live=true pattern=ball ! "
                f"video/x-raw,width={hw},height={h},framerate={fps}/1 ! "
                f"textoverlay text={label} font-desc=\"Sans 36\" valignment=top ! "
                f"timeoverlay font-desc=\"Sans 28\" ! comp.sink_{i}"
                for i, label in enumerate(("LEFT", "RIGHT")))
        else:
            if a.format == "mjpeg":
                caps = f"image/jpeg,width={w},height={h},framerate={fps}/1"
                dec = "jpegdec ! "
            else:
                caps = f"video/x-raw,format=YUY2,width={w},height={h},framerate={fps}/1"
                dec = ""
            src_head = (f"v4l2src device={a.device} do-timestamp=true ! {caps} ! {dec}"
                        "videoconvert ! ")
            extra = ""
        vbr = self.state["video"]["bitrate_kbps"]
        # Force 4:2:0 into the encoder. Without this, sources like the compositor
        # negotiate Y444 and NVENC emits "High 4:4:4", which phone hardware
        # decoders reject outright.
        yuv = "I420" if self.encoder == "openh264" else "NV12"
        return (
            f"{src_head}video/x-raw,format={yuv} ! queue max-size-buffers=1 leaky=downstream ! "
            f"{encoder_desc(self.encoder, vbr, gop)} ! "
            "h264parse config-interval=-1 ! "
            "rtph264pay name=pay pt=96 mtu=1200 config-interval=-1 aggregate-mode=zero-latency ! "
            f"multiudpsink name=sink sync=false async=false qos-dscp={VIDEO_DSCP} buffer-size=4194304"
            f"{extra}"
        )

    def _av_offsets_ns(self):
        off = int(self.state["media"]["av_offset_ms"] * Gst.MSECOND)
        return (off, 0) if off >= 0 else (0, -off)  # (video sink, media-audio sink)

    def file_desc(self, mi: "media.MediaInfo"):
        """Play a file in real time: decode, re-encode for the phone, and send its
        soundtrack on the media port. Sinks sync to the clock (that is what paces
        playback) and the queues block rather than drop. Unlike the live camera
        path, the sinks preroll (async=true): flushing seeks (and looping) then
        get a fresh base time; without that, playback runs flat out after a seek."""
        w, h = mi.encode_size
        fps = mi.nominal_fps
        vbr = self.state["video"]["bitrate_kbps"]
        yuv = "I420" if self.encoder == "openh264" else "NV12"
        v_off, a_off = self._av_offsets_ns()
        big_q = "queue max-size-time=2000000000 max-size-buffers=0 max-size-bytes=0"
        desc = (
            f'uridecodebin uri="{mi.path.resolve().as_uri()}" name=dec '
            f"dec. ! video/x-raw ! {big_q} ! videoconvert ! videoscale ! "
            f"video/x-raw,width={w},height={h},pixel-aspect-ratio=1/1 ! videoconvert ! "
            f"video/x-raw,format={yuv} ! queue max-size-buffers=3 ! "
            f"{encoder_desc(self.encoder, vbr, fps * 2)} ! h264parse config-interval=-1 ! "
            "rtph264pay name=pay pt=96 mtu=1200 config-interval=-1 aggregate-mode=zero-latency ! "
            f"multiudpsink name=sink sync=true ts-offset={v_off} "
            f"qos-dscp={VIDEO_DSCP} buffer-size=4194304"
        )
        if mi.has_audio:
            desc += (
                f" dec. ! audio/x-raw ! {big_q} ! audioconvert ! audioresample ! "
                "audio/x-raw,format=S16BE,rate=48000,channels=2 ! "
                "rtpL16pay name=mpay pt=98 max-ptime=10000000 min-ptime=10000000 ! "
                f"multiudpsink name=msink sync=true ts-offset={a_off} "
                f"qos-dscp={AUDIO_DSCP}"
            )
        return desc

    # ---------------- media source control ----------------
    def _set_camera_stream_state(self):
        a = self.args
        self.state["stream"] = {
            "layout": "sbs" if a.test_pattern else a.layout,
            "width": a.width, "height": a.height, "fps": a.fps,
            "encoder": self.encoder, "source": "test pattern" if a.test_pattern else a.device,
        }

    def _set_file_stream_state(self, mi: "media.MediaInfo", name: str):
        w, h = mi.encode_size
        self.state["stream"] = {
            "layout": media.guess_layout(name, mi.width, mi.height),
            "width": w, "height": h, "fps": mi.nominal_fps,
            "encoder": self.encoder, "source": f"file: {name}",
        }

    def media_files(self):
        if time.monotonic() - self._media_list_t > 5:
            self._media_list = media.list_media(self.media_dir)
            self._media_list_t = time.monotonic()
        return self._media_list

    def _select_file_sync(self, name_or_path: str):
        p = Path(name_or_path).expanduser()
        if p.is_absolute() or p.exists():
            p = p.resolve()
            if not self.args.media_dir_given:
                self.media_dir = p.parent
            name = str(p.relative_to(self.media_dir)) if p.is_relative_to(self.media_dir) else p.name
        else:
            name = name_or_path
            p = media.resolve(self.media_dir, name)
            if p is None:
                raise FileNotFoundError(name_or_path)
        mi = media.probe(p)
        self.media_info = mi
        self.state["media"].update(source="file", file=name, paused=False)
        self._set_file_stream_state(mi, name)
        log.info("playing %s (%dx%d @ %.2f fps, %s, audio: %s, layout guess: %s)",
                 name, mi.width, mi.height, mi.fps, media.fmt_time(mi.duration_s),
                 "yes" if mi.has_audio else "no", self.state["stream"]["layout"])

    async def play_file(self, name: str):
        p = media.resolve(self.media_dir, name)
        if p is None:
            await self.notify(f"not found in media folder: {name}")
            return
        try:
            await asyncio.get_running_loop().run_in_executor(None, self._select_file_sync, name)
        except Exception as e:  # unreadable / no video stream
            log.warning("can't play %s: %s", name, e)
            await self.notify(f"can't play {name}: {e}")
            return
        GLib.idle_add(lambda: (self.video.start(), False)[1])
        GLib.timeout_add(400, lambda: (self.force_keyframe(), False)[1])
        self.media_generation += 1
        asyncio.create_task(self._file_watchdog(name, self.media_generation))
        await self.broadcast({"type": "state", "state": self.state})

    async def use_camera(self):
        self.media_generation += 1
        self.media_info = None
        self.state["media"].update(source="camera", file="", paused=False)
        self._set_camera_stream_state()
        GLib.idle_add(lambda: (self.video.start(), False)[1])
        GLib.timeout_add(400, lambda: (self.force_keyframe(), False)[1])
        await self.broadcast({"type": "state", "state": self.state})

    async def set_capture(self, msg):
        """A new camera, mode, microphone or media folder, without stopping:
        the video is rebuilt if the camera is on, and the voice if the
        microphone changed. Vessels stay connected."""
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
        except (TypeError, ValueError):
            await self.notify("bad camera settings")
            return
        log.info("capture: %s %s %dx%d@%d %s, mic %s", "test pattern" if a.test_pattern else a.device,
                 a.format, a.width, a.height, a.fps, a.layout, a.mic or "default")
        if self.state["media"]["source"] == "camera":
            await self.use_camera()
        if self.audio and a.mic != old_mic:
            GLib.idle_add(lambda: (self.audio.start(), False)[1])
        await self.broadcast(self.summary(), roles={"guide"})

    def seek(self, seconds: float):
        p = self.video.pipeline
        if p is None or self.state["media"]["source"] != "file":
            return
        p.seek_simple(Gst.Format.TIME, Gst.SeekFlags.FLUSH | Gst.SeekFlags.ACCURATE,
                      int(max(0.0, seconds) * Gst.SECOND))
        GLib.timeout_add(150, lambda: (self.force_keyframe(), False)[1])

    def media_position(self):
        p = self.video.pipeline
        if p is None or self.state["media"]["source"] != "file":
            return 0.0
        ok, pos = p.query_position(Gst.Format.TIME)
        return pos / Gst.SECOND if ok and pos >= 0 else 0.0

    def apply_media_settings(self):
        m = self.state["media"]
        p = self.video.pipeline
        if p is None or m["source"] != "file":
            return
        p.set_state(Gst.State.PAUSED if m["paused"] else Gst.State.PLAYING)
        if not m["paused"]:
            GLib.timeout_add(100, lambda: (self.force_keyframe(), False)[1])
        v_off, a_off = self._av_offsets_ns()
        if self.video.get("sink"):
            self.video.get("sink").set_property("ts-offset", v_off)
        if self.video.get("msink"):
            self.video.get("msink").set_property("ts-offset", a_off)

    def _on_file_eos(self):
        if self.state["media"]["source"] != "file":
            return False
        action = self.state["media"]["at_end"]
        if action == "loop":
            self.seek(0.0)
        elif action == "camera" and self.loop:
            asyncio.run_coroutine_threadsafe(self.use_camera(), self.loop)
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

    def _audio_structure_key(self):
        v = self.state["voice"]
        return (abs(v["pitch"] - 1.0) > 1e-3, bool(v["denoise"]))

    def audio_desc(self):
        v = self.state["voice"]
        use_pitch, denoise = self._audio_structure_key()
        mic = f"device={self.args.mic} " if self.args.mic else ""
        if self.args.test_tone:
            src = ("audiotestsrc is-live=true wave=sine freq=300 volume=0.012 "
                   "samplesperbuffer=240")
        else:
            src = f"pulsesrc {mic}buffer-time=20000 latency-time=5000 do-timestamp=true"
        chain = [
            src,
            "audio/x-raw,rate=48000,channels=1",
            "audioconvert",
        ]
        if denoise:
            chain += ["audio/x-raw,format=S16LE,rate=48000,channels=1",
                      "webrtcdsp echo-cancel=false noise-suppression=true noise-suppression-level=high "
                      "gain-control=false high-pass-filter=false",
                      "audioconvert"]
        chain += [
            "audio/x-raw,format=F32LE,rate=48000,channels=1",
            "audiocheblimit name=hp mode=high-pass poles=4",
            "audiocheblimit name=lp mode=low-pass poles=4",
            # Gain, gate, compressor and limiter run in Python (dynamics.py):
            # out through appsink, back in through appsrc, same thread.
            "appsink name=dyn_in emit-signals=true sync=false max-buffers=8 drop=true",
        ]
        chain_b = [
            "appsrc name=dyn_out is-live=true format=time do-timestamp=false "
            f"caps=audio/x-raw,format=F32LE,rate=48000,channels=1,layout=interleaved",
        ]
        if use_pitch:
            chain_b += ["pitch name=pitch", "audioconvert",
                        "audio/x-raw,format=F32LE,rate=48000,channels=1"]
        chain_b += [
            "audioecho name=echo max-delay=2000000000",
            "freeverb name=reverb",
            "level name=meter interval=100000000 post-messages=true",
            "audioconvert",
            "audio/x-raw,format=S16BE,rate=48000,channels=2",
            "rtpL16pay name=pay pt=97 max-ptime=5000000 min-ptime=5000000",
            f"multiudpsink name=sink sync=false async=false qos-dscp={AUDIO_DSCP}",
        ]
        return " ! ".join(chain) + "  " + " ! ".join(chain_b)

    def _attach_video_clients(self, pipeline):
        dec = pipeline.get_by_name("dec")
        if dec is not None:
            dec.connect("autoplug-select", _autoplug_select)
        pay = pipeline.get_by_name("pay")
        if pay is not None:
            pay.get_static_pad("src").add_probe(Gst.PadProbeType.BUFFER, self._count_video)
        sink = pipeline.get_by_name("sink")
        msink = pipeline.get_by_name("msink")
        for host, vport, _, mport in self.destinations:
            sink.emit("add", host, vport)
            if msink:
                msink.emit("add", host, mport)

    def _attach_audio_clients(self, pipeline):
        sink = pipeline.get_by_name("sink")
        for host, _, aport, _ in self.destinations:
            sink.emit("add", host, aport)
        self.dynamics = Dynamics()
        self.voicefx = SpectralVoice()
        dyn_out = pipeline.get_by_name("dyn_out")
        pipeline.get_by_name("dyn_in").connect("new-sample", self._on_voice_block, dyn_out)
        self.apply_voice(pipeline)

    def _on_voice_block(self, appsink, appsrc):
        """Streaming thread: run one mic buffer through the dynamics stage."""
        sample = appsink.emit("pull-sample")
        if sample is None:
            return Gst.FlowReturn.EOS
        buf = sample.get_buffer()
        ok, info = buf.map(Gst.MapFlags.READ)
        if not ok:
            return Gst.FlowReturn.OK
        x = np.frombuffer(info.data, dtype=np.float32).copy()
        buf.unmap(info)
        v = self.state["voice"]
        y = self.dynamics.process(x, float(v["gain_db"]), float(v["gate_db"]),
                                  float(v["comp_ratio"]), bool(v["mute"]))
        y = self.voicefx.process(y, str(v["fx_mode"]), float(v["shift_pitch"]),
                                 float(v["shift_formant"]), float(v["robot_hz"]),
                                 float(v["robot_noise"]))
        out = Gst.Buffer.new_wrapped(y.tobytes())
        out.pts, out.dts, out.duration = buf.pts, buf.dts, buf.duration
        appsrc.emit("push-buffer", out)
        return Gst.FlowReturn.OK

    def apply_voice(self, pipeline=None):
        if self.audio is None:
            return
        if pipeline is None:
            if self._audio_structure_key() != self._audio_structure:
                self._audio_structure = self._audio_structure_key()
                log.info("voice chain structure changed; rebuilding audio pipeline")
                GLib.idle_add(lambda: (self.audio.start(), False)[1])
                return
            pipeline = self.audio.pipeline
            if pipeline is None:
                return
        v = self.state["voice"]
        g = pipeline.get_by_name
        g("hp").set_property("cutoff", float(max(10, v["highpass_hz"])))
        g("lp").set_property("cutoff", float(min(23000, max(200, v["lowpass_hz"]))))
        if g("pitch"):
            g("pitch").set_property("pitch", float(v["pitch"]))
        echo = g("echo")
        echo.set_property("delay", int(max(1, v["echo_ms"]) * Gst.MSECOND))
        echo.set_property("feedback", float(min(0.95, v["echo_feedback"])))
        echo.set_property("intensity", float(v["echo_mix"]))
        rev = g("reverb")
        rev.set_property("room-size", float(v["reverb_room"]))
        rev.set_property("damping", float(v["reverb_damp"]))
        rev.set_property("level", float(v["reverb_mix"]))

    def apply_preset_values(self, name):
        p = self.presets.get(name)
        if not p:
            return False
        for k, val in p.items():
            if k in self.state["voice"]:
                self.state["voice"][k] = val
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
                                 (self.video, "msink", mport)):
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
                                 (self.video, "msink", mport)):
                if pl and pl.get(el):
                    pl.get(el).emit("remove", host, port)
            return False
        GLib.idle_add(do)

    def _count_video(self, _pad, _info):
        self.video_packets += 1
        return Gst.PadProbeReturn.OK

    async def _file_watchdog(self, name: str, generation: int):
        """If a file produces no video within a few seconds, say so and fall back."""
        start = self.video_packets
        await asyncio.sleep(6)
        if (self.media_generation == generation and self.state["media"]["source"] == "file"
                and not self.state["media"]["paused"] and self.video_packets == start):
            log.warning("no video from %s after 6 s; returning to the camera", name)
            await self.notify(f"{name}: no picture after 6 s (unsupported format?) — back to camera")
            await self.use_camera()

    def _on_mic_level(self, db):
        self.mic_level_db = db

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

    def summary(self):
        return {
            "type": "clients",
            "clients": [
                {"id": i["id"], "role": i.get("role"), "name": i.get("name"), "addr": i["addr"],
                 "key": i.get("key", ""), "sig": i.get("sig", ""), "allow": i.get("allow", {}),
                 "stats": i.get("stats")}
                for i in self.clients.values() if i.get("role")
            ],
            "session": {"on": self.session_token is not None, "expires": self.session_expires},
            "scenes": sorted(self.scenes),
            "presets": list(self.presets),
            "mic_db": round(self.dynamics.in_db, 1) if self.dynamics else -100.0,
            "out_db": round(self.mic_level_db, 1),
            "gate_open": bool(self.dynamics and self.dynamics.gate_open),
            "media": {
                "dir": str(self.media_dir), "files": self.media_files(),
                "position": round(self.media_position(), 2),
                "duration": round(self.media_info.duration_s, 2) if self.media_info else 0.0,
                "has_audio": bool(self.media_info and self.media_info.has_audio),
            },
        }

    async def handle_set(self, path, value):
        try:
            value = set_path(self.state, path, value)
        except (KeyError, TypeError, ValueError) as e:
            log.warning("bad set %s=%r (%s)", path, value, e)
            return
        section = path.split(".")[0]
        if section == "voice":
            if path == "voice.preset":
                self.apply_preset_values(value)
                GLib.idle_add(lambda: (self.apply_voice(), False)[1])
                await self.broadcast({"type": "state", "state": self.state})
                return
            GLib.idle_add(lambda: (self.apply_voice(), False)[1])
        elif path == "video.bitrate_kbps":
            GLib.idle_add(lambda: (self.apply_bitrate(), False)[1])
        elif section == "media":
            GLib.idle_add(lambda: (self.apply_media_settings(), False)[1])
        await self.broadcast({"type": "set", "path": path, "value": value})

    # Messages each role may send. Vessels only report; the Guide page drives.
    VESSEL_MESSAGES = {"hello", "ping", "stats", "keyframe", "left"}

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
            await self.broadcast({"type": "state", "state": self.state}, exclude=ws)
            await self.broadcast(self.summary(), roles={"guide"})
        elif t == "set":
            await self.handle_set(msg["path"], msg["value"])
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
            await self.play_file(str(msg["file"]))
        elif t == "media_camera":
            await self.use_camera()
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
            GLib.idle_add(lambda: (self.apply_voice(), False)[1])
            await self.broadcast({"type": "state", "state": self.state})
        elif t == "scene_delete" and msg.get("name") in self.scenes:
            del self.scenes[msg["name"]]
            self.scenes_path.write_text(json.dumps(self.scenes, indent=2))
            await self.broadcast(self.summary(), roles={"guide"})

    def _set_live(self, on: bool):
        """Run the camera and mic, or let them go (their lights go out)."""
        on = on or bool(self.args.also_send)
        for p in (self.video, self.audio):
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
        if dev.get_device_class() == "Audio/Source" and props:
            print(f"   --mic {props.get_string('device.name') or props.get_string('node.name')}")
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
            name = props.get_string("node.name") or props.get_string("device.name") if props else None
            if name and not name.endswith(".monitor"):
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
    ap.add_argument("--mic", default=None, help="PulseAudio/PipeWire source name (default source if omitted)")
    ap.add_argument("--no-audio", action="store_true")
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
        sender.video.stop()
        if sender.audio:
            sender.audio.stop()
        glib_loop.quit()


if __name__ == "__main__":
    sys.exit(main())
