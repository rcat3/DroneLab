#!/usr/bin/env python3
"""Take screenshots of a board over USB, for the documentation.

The board has to run firmware built with the development console:

    idf.py -C platforms/esp-idf -B build-s3-175-console \\
        -DBOARD=waveshare_esp32s3_touch_amoled_1_75 -DRCAT_SERIAL_CONSOLE=1 build flash

(see core/app/console.h). This steps through the pages with the phone
remote's API (core/app/remote.h) and saves each as a PNG, cut to the round
screen, with the corners transparent.

    tools/screenshots.py --port /dev/ttyACM0 shot out.png
    tools/screenshots.py --port /dev/ttyACM0 api GET /api/info
    tools/screenshots.py --port /dev/ttyACM0 show Visualizer 0 vis.png
    tools/screenshots.py --port /dev/ttyACM0 docs docs/images/screens

"docs" takes the set of pictures the documentation uses (see DOC_SHOTS).
It needs pyserial and Pillow.
"""

import argparse
import base64
import json
import sys
import time
import zlib

import serial
from PIL import Image, ImageDraw


class Board:
    def __init__(self, port):
        # DTR stays high: DTR low with RTS high restarts the board
        self.ser = serial.Serial()
        self.ser.port = port
        self.ser.baudrate = 115200
        self.ser.timeout = 0.5
        self.ser.dtr = True
        self.ser.rts = True
        self.ser.open()
        self.info = None
        time.sleep(0.2)
        self.ser.reset_input_buffer()

    def _lines(self, timeout):
        """Lines from the board until timeout seconds pass with nothing new"""
        end = time.time() + timeout
        buf = b""
        while time.time() < end:
            chunk = self.ser.read(65536)
            if chunk:
                buf += chunk
                end = time.time() + timeout
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    yield line.decode("utf-8", "replace").rstrip("\r")

    def send(self, text):
        self.ser.write(text.encode() + b"\n")

    def api(self, method, target, body=""):
        # Now and then a line from the board arrives garbled, so a GET is
        # asked again; a POST isn't, as it may have been done already
        for _ in range(3 if method == "GET" else 1):
            self.send(f"api {method} {target} {body}".rstrip())
            for line in self._lines(5):
                if line.startswith("CONSOLE: "):
                    answer = line[len("CONSOLE: "):]
                    if answer == "-1":
                        raise RuntimeError(f"{method} {target}: no such request")
                    try:
                        return json.loads(answer)
                    except ValueError:
                        break
        raise RuntimeError(f"{method} {target}: no answer")

    def _shot_line(self, text, lines):
        """The line's number and bytes, or None if it didn't arrive whole"""
        try:
            n, crc, data = text.split(" ")
            n = int(n)
            data = base64.b64decode(data, validate=True)
        except ValueError:
            return None
        if n >= len(lines) or zlib.crc32(data) != int(crc, 16):
            return None
        return n, data

    def shot(self):
        self.send("shot")
        w = h = None
        lines = []
        for line in self._lines(5):
            if not line.startswith("SHOT: "):
                continue
            text = line[len("SHOT: "):]
            if text.startswith("BEGIN"):
                _, w, h, count = text.split()
                w, h = int(w), int(h)
                lines = [None] * int(count)
            elif text == "END":
                break
            elif text == "FAILED":
                raise RuntimeError("the board couldn't take a picture")
            elif w is not None:
                got = self._shot_line(text, lines)
                if got:
                    lines[got[0]] = got[1]
        if w is None:
            raise RuntimeError("no picture")
        # Ask again for any that didn't arrive whole
        for tries in range(5):
            missing = [i for i, d in enumerate(lines) if d is None]
            if not missing:
                break
            for i in missing:
                self.send(f"line {i}")
                for line in self._lines(1):
                    if line.startswith("SHOT: "):
                        got = self._shot_line(line[len("SHOT: "):], lines)
                        if got:
                            lines[got[0]] = got[1]
                        break
        raw = b"".join(d or b"" for d in lines)
        if len(raw) != w * h * 2:
            raise RuntimeError("the picture didn't arrive whole")
        return Image.frombytes("RGB", (w, h), raw, "raw", "BGR;16")

    def feature(self, name):
        if self.info is None:
            self.info = self.api("GET", "/api/info")
        info = self.info
        for i, (fname, pages) in enumerate(info["features"]):
            if fname.lower() == name.lower():
                return i, pages
        raise RuntimeError(f"no feature {name}: {[f for f, _ in info['features']]}")

    def show(self, name, page=0, settle=1.0):
        f, _ = self.feature(name)
        self.api("POST", f"/api/show?f={f}&p={page}")
        time.sleep(settle)


def round_cut(img):
    """The screen is round: make the corners transparent"""
    img = img.convert("RGBA")
    scale = 4
    mask = Image.new("L", (img.width * scale, img.height * scale), 0)
    ImageDraw.Draw(mask).ellipse((0, 0, mask.width - 1, mask.height - 1), fill=255)
    img.putalpha(mask.resize(img.size, Image.LANCZOS))
    return img


def save(img, path):
    round_cut(img).save(path)
    print(f"saved {path}")


# The documentation's screenshots, in docs/images/screens/. Each is
# (file name, feature, page), taken after the steps before it.
TERMINAL_LINES = ["KATCORP DRONE SYSTEMS", "UNIT 0451 ONLINE", "AWAITING ORDERS"]


def doc_shots(board, out):
    import os
    os.makedirs(out, exist_ok=True)
    before = board.api("GET", "/api/state")

    def take(name, feature=None, page=0, settle=2.5):
        if feature is not None:
            board.show(feature, page, settle=0)
        # Long enough for the dots along the edges to fade
        time.sleep(settle)
        save(board.shot(), os.path.join(out, name + ".png"))

    info = board.api("GET", "/api/info")
    images = dict(info["features"])["Images"]

    take("images_katcorp", "Images", images.index("katcorp"))
    take("images_hal9000", "Images", images.index("hal9000"))

    # Something for the visualizers to show: a track on the speaker
    tracks = board.api("GET", "/api/tracks")["tracks"]
    track = next((i for i, t in enumerate(tracks) if "Roboto" in t), 0)
    board.api("POST", f"/api/sound?t={track}&v=100")
    time.sleep(1)
    board.api("POST", "/api/sound?seek=75000")
    for i, name in enumerate(info["visualizers"]):
        board.api("POST", f"/api/vis?v={i}&show=1")
        take("visualizer_" + name.lower(), settle=3)
    take("sound_player", "Sound", 0)
    board.api("POST", "/api/sound?play=0")

    take("voice_effect", "Voice", 0)
    take("voice_effect_volume", "Voice", 1)
    take("comm_status", "HiveMind", 0)
    take("comm_setup", "HiveMind", 1)
    # 24 px letters, which keep the words whole; a line at a time, as the
    # console takes a line at a time
    board.api("POST", "/api/termsize?s=3")
    for i, text in enumerate(TERMINAL_LINES):
        board.api("POST", f"/api/message?show=1&append={int(i > 0)}", text)
    take("terminal", settle=12)     # long enough for it to finish typing
    # Better with a device connected (on the Devices page, or the remote)
    if board.api("GET", "/api/state")["devices"]:
        board.api("POST", "/api/level?d=0&m=0&v=8")
    take("lovense_control", "Lovense", 0)
    take("lovense_devices", "Lovense", 1)
    board.api("POST", "/api/play?d=-1&p=0")
    take("lovense_patterns", "Lovense", 2)
    board.api("POST", "/api/stop")
    board.api("POST", "/api/react?m=1")
    take("lovense_react", "Lovense", 3)
    board.api("POST", "/api/stop")
    take("settings_level", "Settings", info["features"][-1][1].index("Level"))
    # Rotation at 180 degrees, as the housings need
    board.api("POST", "/api/display?rot=2")
    take("settings_rotation", "Settings", info["features"][-1][1].index("Rotation"))
    board.api("POST", f"/api/display?rot={before['display']['rotation']}")

    # Put things back as they were
    board.api("POST", "/api/clear")
    board.api("POST", f"/api/termsize?s={before['term_size']}")
    snd = before["sound"]
    # Not the track: choosing one plays it
    board.api("POST", f"/api/sound?play=0&v={snd['volume']}")
    board.api("POST", f"/api/vis?v={before['vis']}")
    f, p = before["screen"]
    board.api("POST", f"/api/show?f={f}&p={p}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", default="/dev/ttyACM0")
    ap.add_argument("command", choices=["shot", "api", "show", "docs"])
    ap.add_argument("args", nargs="*")
    a = ap.parse_args()
    board = Board(a.port)
    if a.command == "shot":
        save(board.shot(), a.args[0] if a.args else "shot.png")
    elif a.command == "api":
        print(json.dumps(board.api(a.args[0], a.args[1], " ".join(a.args[2:])), indent=1))
    elif a.command == "show":
        board.show(a.args[0], int(a.args[1]) if len(a.args) > 1 else 0)
        if len(a.args) > 2:
            save(board.shot(), a.args[2])
    elif a.command == "docs":
        doc_shots(board, a.args[0] if a.args else "docs/images/screens")


if __name__ == "__main__":
    sys.exit(main())
