"""The sender's switcher, end to end without a phone: the sender runs with a
test pattern, a Guide client (this file) sends it commands, and what comes
out is read back: the video decoded from the RTP the sender sends to
127.0.0.1, the media sound likewise. Needs GStreamer (gi), PIL, aiohttp."""
from __future__ import annotations

import asyncio
import glob
import json
import os
import shutil
import subprocess
import tempfile
import time
import wave
from pathlib import Path

import numpy as np

SENDER = Path(__file__).resolve().parent.parent
GUIDE_PORT, VESSEL_PORT = 18544, 18543


class Guide:
    def __init__(self):
        self.sum = {}
        self.state = {}
        self.notices = []
        self.next_jpeg = b""

    async def connect(self):
        import aiohttp
        self.s = aiohttp.ClientSession()
        self.ws = await self.s.ws_connect(f"http://127.0.0.1:{GUIDE_PORT}/ws")
        await self.ws.send_str(json.dumps({"type": "hello", "role": "guide", "token": "tok"}))
        self.task = asyncio.create_task(self._rx(aiohttp))

    async def _rx(self, aiohttp):
        async for m in self.ws:
            if m.type == aiohttp.WSMsgType.BINARY and m.data[:1] == b"\x02":
                self.next_jpeg = m.data[1:]      # what's cued, small
                continue
            if m.type != aiohttp.WSMsgType.TEXT:
                continue
            j = json.loads(m.data)
            if j.get("type") == "clients":
                self.sum = j
            elif j.get("type") == "state":
                self.state = j["state"]
            elif j.get("type") == "set":
                sec, k = j["path"].split(".")
                self.state.setdefault(sec, {})[k] = j["value"]
            elif j.get("type") == "notice":
                self.notices.append(j["text"])

    async def send(self, **m):
        await self.ws.send_str(json.dumps(m))

    async def set(self, path, v):
        await self.send(type="set", path=path, value=v)

    async def close(self):
        await self.ws.close()
        await self.s.close()


def make_media(d: Path):
    """A 10 s film with sound, a picture, two tones."""
    from PIL import Image, ImageDraw
    (d / "media").mkdir()
    (d / "music").mkdir()
    subprocess.run(
        ["gst-launch-1.0", "-q", "-e", "videotestsrc", "num-buffers=300", "pattern=smpte", "!",
         "video/x-raw,width=640,height=360,framerate=30/1", "!", "x264enc", "tune=zerolatency", "!", "h264parse",
         "!", "matroskamux", "name=m", "!", "filesink", f"location={d}/media/film.mkv",
         "audiotestsrc", "num-buffers=470", "wave=sine", "freq=440", "samplesperbuffer=1024", "!",
         "audioconvert", "!", "opusenc", "!", "m."], check=True, capture_output=True)
    im = Image.new("RGB", (1600, 900), (30, 60, 200))
    dr = ImageDraw.Draw(im)
    dr.rectangle((100, 100, 700, 400), fill=(240, 200, 40))
    im.save(d / "media" / "pic.png")
    tall = Image.new("RGB", (900, 1600), (220, 30, 30))      # a portrait photo: red above, blue below
    ImageDraw.Draw(tall).rectangle((0, 800, 900, 1600), fill=(30, 30, 220))
    tall.save(d / "media" / "tall.png")
    for name, f in (("a.wav", 330), ("b.wav", 660)):
        subprocess.run(
            ["gst-launch-1.0", "-q", "-e", "audiotestsrc", "num-buffers=1000", "wave=sine", f"freq={f}",
             "samplesperbuffer=1024", "!", "audioconvert", "!", "audio/x-raw,rate=48000,channels=2", "!",
             "wavenc", "!", "filesink", f"location={d}/music/{name}"], check=True, capture_output=True)


def left_mean(path):
    from PIL import Image
    im = np.asarray(Image.open(path).convert("RGB").resize((64, 18))).astype(float)
    return im[:, 4:28].mean(axis=(0, 1))


def right_mean(path):
    from PIL import Image
    im = np.asarray(Image.open(path).convert("RGB").resize((64, 18))).astype(float)
    return im[:, 36:60].mean(axis=(0, 1))


async def scenario(check, d: Path):
    log = open(d / "sender.log", "w")
    snd = subprocess.Popen(
        ["/usr/bin/python3", "-u", "hivesight_sender.py", "--cert", str(d / "c.pem"), "--key", str(d / "k.pem"),
         "--test-pattern", "--also-send", "127.0.0.1", "--vessel-port", str(VESSEL_PORT),
         "--guide-port", str(GUIDE_PORT), "--scenes", str(d / "scenes.json"), "--no-audio",
         "--media-dir", str(d / "media"), "--music-dir", str(d / "music")],
        cwd=SENDER, stdin=subprocess.PIPE, stdout=log, stderr=subprocess.STDOUT)
    snd.stdin.write(b'{"guide_token":"tok"}\n')
    snd.stdin.flush()
    rx = arx = None
    g = Guide()
    try:
        await asyncio.sleep(4)
        for f in glob.glob(str(d / "f_*.jpg")):
            os.unlink(f)
        rx = subprocess.Popen(
            ["gst-launch-1.0", "-q", "udpsrc", "port=5004",
             "caps=application/x-rtp,media=video,encoding-name=H264,payload=96,clock-rate=90000", "!",
             "rtpjitterbuffer", "latency=50", "!", "rtph264depay", "!", "h264parse", "!", "avdec_h264", "!",
             "videorate", "!", "video/x-raw,framerate=10/1", "!", "videoconvert", "!", "jpegenc", "!",
             "multifilesink", f"location={d}/f_%05d.jpg"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        arx = subprocess.Popen(
            ["gst-launch-1.0", "-q", "udpsrc", "port=5008",
             "caps=application/x-rtp,media=audio,encoding-name=L16,clock-rate=48000,channels=2,payload=98", "!",
             "rtpjitterbuffer", "latency=30", "!", "rtpL16depay", "!", "audioconvert", "!", "wavenc", "!",
             "filesink", f"location={d}/rx.wav"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        await g.connect()
        await asyncio.sleep(1)

        def frames():
            return sorted(glob.glob(str(d / "f_*.jpg")))

        await g.send(type="session", token="x" * 24, expires=time.time() + 600)
        await asyncio.sleep(2)
        check("the program stream starts with the test pattern", len(frames()) > 10 and
              g.state["stream"]["source"] == "test pattern" and g.state["stream"]["layout"] == "sbs",
              f"{len(frames())} frames, stream {g.state['stream']}")

        # A cut to red, then a fade to blue: out to black, then in on the new one
        await g.set("switch.effect", "cut")
        await g.send(type="take", spec={"kind": "color", "rgb": 0xFF0000})
        await asyncio.sleep(2)
        red = left_mean(frames()[-1])
        check("a cut puts a colour on", red[0] > 180 and red[2] < 60, f"left eye {red.round()}")
        await g.set("switch.effect", "fade")
        await g.set("switch.secs", 2.0)
        i0 = len(frames())
        await g.send(type="take", spec={"kind": "color", "rgb": 0x0000FF})
        await asyncio.sleep(5)
        seq = [left_mean(f) for f in frames()[i0:]]
        dark = min(range(len(seq)), key=lambda i: seq[i].sum())
        before, after = seq[:dark], seq[dark:]
        check("a fade goes to black", seq[dark].sum() < 120, f"darkest {seq[dark].round()}")
        check("a fade never shows the new picture before black",
              all(s[2] < 60 for s in before) and all(s[0] < 60 for s in after),
              "blue stays out while red goes, red stays out while blue comes")
        check("a fade ends on the new picture", seq[-1][2] > 180 and seq[-1][0] < 60, f"{seq[-1].round()}")

        # A dissolve: straight across, never passing through black
        await g.set("switch.effect", "cut")
        await g.send(type="take", spec={"kind": "color", "rgb": 0xFF0000})
        await asyncio.sleep(2)
        await g.set("switch.effect", "dissolve")
        i0 = len(frames())
        await g.send(type="take", spec={"kind": "color", "rgb": 0x0000FF})
        await asyncio.sleep(4)
        seq = [left_mean(f) for f in frames()[i0:]]
        mid = [s for s in seq if 60 < s[0] < 180 and s[2] > 40]
        check("a dissolve mixes the two", len(mid) >= 3, f"{len(mid)} frames with both showing")
        check("a dissolve doesn't pass through black", min(s.sum() for s in seq) > 150,
              f"darkest {min(s.sum() for s in seq):.0f}")

        # What's cued is looked at before it goes on
        import io
        from PIL import Image

        def seen():
            return np.asarray(Image.open(io.BytesIO(g.next_jpeg)).convert("RGB")).astype(float)[:, :100].mean(axis=(0, 1))

        await g.send(type="cue", spec={"kind": "color", "rgb": 0x00FF00})
        await asyncio.sleep(1.5)
        c = seen()
        check("a cued colour can be looked at", c[1] > 180 and c[0] < 70 and c[2] < 70, f"{c.round()}")
        await g.send(type="cue", spec={"kind": "image", "file": "pic.png"})
        await asyncio.sleep(1.5)
        c = seen()
        check("a cued image can be looked at", c[2] > 130 and c[1] < 140, f"{c.round()}")
        await g.send(type="cue", spec={"kind": "file", "file": "film.mkv"})
        await asyncio.sleep(2.5)
        check("a cued film shows its first picture, and the program is untouched",
              len(g.next_jpeg) > 1000 and g.sum["media"]["position"] == 0.0 and g.state["media"]["source"] == "color",
              f"{len(g.next_jpeg)} bytes of picture")
        await g.send(type="cue", spec={"kind": "camera"})
        await asyncio.sleep(1.5)
        check("a cued camera shows live", len(g.next_jpeg) > 1000, f"{len(g.next_jpeg)} bytes")
        await g.send(type="cue", spec=None)
        await asyncio.sleep(1)
        check("nothing cued, nothing to look at", g.next_jpeg == b"" or len(g.next_jpeg) == 0, f"{len(g.next_jpeg)} bytes")

        check("the Guide is told the effects and kinds of source there are",
              [e["id"] for e in g.sum["switch"]["effects"]] == ["cut", "fade", "dissolve"] and
              set(g.sum["switch"]["kinds"]) == {"camera", "color", "file", "image"},
              f"{[e['id'] for e in g.sum['switch']['effects']]}, {g.sum['switch']['kinds']}")

        # A portrait photo: the same in both eyes unless it's said to be a pair
        await g.set("switch.effect", "cut")
        await g.send(type="take", spec={"kind": "image", "file": "tall.png"})
        await asyncio.sleep(2.5)
        lm, rm = left_mean(frames()[-1]), right_mean(frames()[-1])
        check("a photo is the same in both eyes (not split top and bottom)",
              np.allclose(lm, rm, atol=12) and lm[0] > 25 and lm[2] > 25, f"left {lm.round()} right {rm.round()}")
        await g.set("image.layout", "tb")
        await asyncio.sleep(1.5)
        lm, rm = left_mean(frames()[-1]), right_mean(frames()[-1])
        check("as a top and bottom pair, the top is the left eye's", lm[0] > 100 and lm[2] < 60 and rm[2] > 100 and rm[0] < 60,
              f"left {lm.round()} right {rm.round()}")
        await g.set("image.layout", "mono")
        await g.set("image.fit", "fill")
        await asyncio.sleep(1.5)
        fl = left_mean(frames()[-1])
        check("fill covers the eye (the middle of the photo, both colours)", fl[0] > 80 and fl[2] > 80, f"{fl.round()}")
        await g.set("image.fit", "fit")

        # A film: its pictures and sound; pause keeps the stream going on its last picture
        await g.set("switch.effect", "cut")
        await g.send(type="media_play", file="film.mkv")
        await asyncio.sleep(3)
        m = g.sum["media"]
        check("a film plays", g.state["media"]["source"] == "file" and 1.5 < m["position"] < 4.5
              and abs(m["duration"] - 10) < 0.5 and m["has_audio"], f"{m['position']} of {m['duration']} s")
        check("its sound is in the mix", g.sum["music"]["level_db"] > -40, f"{g.sum['music']['level_db']} dB")
        n = len(frames())
        await g.set("media.paused", True)
        await asyncio.sleep(1.5)
        n1 = len(frames())
        a = left_mean(frames()[-1])
        p1 = g.sum["media"]["position"]
        await asyncio.sleep(1.5)
        check("paused, the stream carries on with the last picture",
              len(frames()) - n1 >= 10 and np.allclose(a, left_mean(frames()[-1]), atol=3),
              f"{len(frames()) - n} frames while paused")
        check("paused, the film's time stands still", abs(g.sum["media"]["position"] - p1) < 0.1,
              f"{p1} then {g.sum['media']['position']}")
        await g.set("media.paused", False)
        await g.send(type="media_seek", pos=7.0)
        await asyncio.sleep(1.5)
        check("seeking works", 7.0 <= g.sum["media"]["position"] < 9.5, f"{g.sum['media']['position']} s")

        # A film put aside carries on from where it was, unless it's told to start again
        await g.send(type="media_seek", pos=3.0)
        await asyncio.sleep(1.0)
        await g.send(type="take", spec={"kind": "color", "rgb": 0x0000FF})
        await asyncio.sleep(1.5)
        left = g.sum["switch"]["resume"].get("film.mkv", 0)
        check("a film off air is remembered", 3.0 <= left < 6.0, f"{g.sum['switch']['resume']}")
        await g.send(type="take", spec={"kind": "file", "file": "film.mkv"})
        await asyncio.sleep(2.5)
        check("and goes on from there, not from the start", g.state["media"]["file"] == "film.mkv" and
              left + 1.0 <= g.sum["media"]["position"] < left + 5.0, f"left at {left} s, now {g.sum['media']['position']} s")
        await g.send(type="take", spec={"kind": "color", "rgb": 0x0000FF})
        await asyncio.sleep(1.5)
        await g.send(type="resume_clear", file="film.mkv")
        await asyncio.sleep(0.5)
        await g.send(type="take", spec={"kind": "file", "file": "film.mkv"})
        await asyncio.sleep(2.5)
        check("told to start again, it does", g.sum["media"]["position"] < 4.0 and g.state["media"]["file"] == "film.mkv",
              f"{g.sum['media']['position']} s")
        await g.send(type="media_seek", pos=3.0)
        await asyncio.sleep(1.0)

        # The queue, and Next
        await g.send(type="queue_add", spec={"kind": "image", "file": "pic.png"})
        await g.send(type="queue_add", spec={"kind": "color", "rgb": 0x00FF00})
        await g.send(type="queue_add", spec={"kind": "bogus"})
        await asyncio.sleep(0.8)
        check("things queue up, and bad ones are refused", len(g.sum["switch"]["queue"]) == 2,
              f"{g.sum['switch']['queue']}")
        await g.send(type="next")
        await asyncio.sleep(2.5)
        check("Next puts the first one on", g.state["media"]["source"] == "image" and
              g.state["media"]["file"] == "pic.png" and len(g.sum["switch"]["queue"]) == 1,
              f"{g.state['media']['source']}, {len(g.sum['switch']['queue'])} left")
        blue = left_mean(frames()[-1])
        check("an image shows", blue[2] > 130 and blue[0] < 120, f"{blue.round()}")
        await g.set("image.zoom", 8.0)
        await g.set("image.x", 1.0)
        await g.set("image.y", 1.0)
        await asyncio.sleep(1.5)
        z = left_mean(frames()[-1])
        check("an image zooms and moves (the yellow box is out of the way)", z[2] > 150 and z[0] < 90, f"{z.round()}")
        await g.send(type="next")
        await asyncio.sleep(2.5)
        green = left_mean(frames()[-1])
        check("Next goes on to a colour, and the queue empties",
              green[1] > 180 and green[0] < 60 and g.sum["switch"]["queue"] == [], f"{green.round()}")
        await g.set("color.rgb", 0xFFFF00)
        await asyncio.sleep(1.2)
        y = left_mean(frames()[-1])
        check("a colour on air changes as it's set", y[0] > 180 and y[1] > 180 and y[2] < 60, f"{y.round()}")

        # Music: queue, crossfade, pause
        await g.set("music.xfade_s", 3.0)
        await g.send(type="music_play", file="a.wav")
        await g.send(type="music_add", file="b.wav")
        await asyncio.sleep(2)
        check("music plays with a queue", g.sum["music"]["current"]["name"] == "a.wav" and
              g.sum["music"]["queue"] == ["b.wav"], f"{g.sum['music']['current']}")
        await asyncio.sleep(3)
        await g.send(type="music_next")
        await asyncio.sleep(6)
        check("Next crossfades into the next track", g.sum["music"]["current"]["name"] == "b.wav" and
              g.sum["music"]["queue"] == [], f"{g.sum['music']['current']}")
        await g.send(type="music_pause", paused=True)
        await asyncio.sleep(0.5)
        p = g.sum["music"]["current"]["position"]
        await asyncio.sleep(1.2)
        check("music pauses", abs(g.sum["music"]["current"]["position"] - p) < 0.1, f"{p} s")
        await g.send(type="music_stop")
        await asyncio.sleep(3)
        check("music stops", g.sum["music"]["current"] is None, "nothing playing")
    finally:
        await g.close()
        for p in (rx, arx, snd):
            if p and p.poll() is None:
                p.terminate()
        for p in (rx, arx, snd):
            if p:
                try:
                    p.wait(6)
                except subprocess.TimeoutExpired:
                    p.kill()
    # What went out as sound: 330 Hz, then 660 Hz, the one fading into the other over 3 s
    try:
        w = wave.open(str(d / "rx.wav"))
        raw = np.frombuffer(w.readframes(w.getnframes()), np.int16).reshape(-1, 2).astype(float) / 32768
        seg = 4800
        a, b = [], []
        for k in range(0, len(raw) - seg, 4800):
            x = raw[k:k + seg, 0]
            sp = np.abs(np.fft.rfft(x * np.hanning(seg)))
            fr = np.fft.rfftfreq(seg, 1 / 48000)
            a.append(sp[(fr > 300) & (fr < 360)].max())
            b.append(sp[(fr > 630) & (fr < 690)].max())
        a, b = np.array(a), np.array(b)
        both = int(((a > 0.15 * a.max()) & (b > 0.15 * b.max())).sum())
        check("the tracks crossfade (both heard together for about the fade time)", 15 <= both <= 45,
              f"both audible for {both / 10:.1f} s")
    except Exception as e:      # no sound came out at all
        check("the tracks crossfade", False, f"no usable sound: {e}")


def run(check):
    for mod in ("gi", "PIL", "aiohttp"):
        try:
            __import__(mod)
        except ImportError:
            check("switcher tests", False, f"{mod} missing")
            return
    d = Path(tempfile.mkdtemp(prefix="hivesight-switcher-"))
    try:
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", str(d / "k.pem"),
                        "-out", str(d / "c.pem"), "-days", "2", "-subj", "/CN=test"], check=True, capture_output=True)
        make_media(d)
        asyncio.run(scenario(check, d))
    finally:
        shutil.rmtree(d, ignore_errors=True)
