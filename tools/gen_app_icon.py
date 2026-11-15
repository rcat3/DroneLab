#!/usr/bin/env python3
"""
Draw the DroneLab app's icon, from the logo (see gen_logo.py): "DL" in the
logo's phosphor green, glowing and glitched, inside its targeting brackets,
on black with scan lines. The whole word is too wide to read at icon size.

It writes, into app/:
- Android's adaptive icon: a foreground with the picture, on a black
  background, and a one-color version for themed icons
- Android's plain icons, for older phones
- the iPhone's icons

It needs Pillow and the logo's fonts (see gen_logo.py):

    python3 tools/gen_app_icon.py --fonts ~/fonts
"""

import argparse
import json
import os
import random

from PIL import Image, ImageDraw

import gen_logo as logo
from gen_logo import CANVAS, CENTER, SS

APP = os.path.join(os.path.dirname(__file__), "..", "app")
RES = os.path.join(APP, "android", "app", "src", "main", "res")
IOS_ICONS = os.path.join(APP, "ios", "Runner", "Assets.xcassets", "AppIcon.appiconset")

TEXT = "DL"
# Android's icon sizes in pixels at each density: plain icons are 48 dp, the
# adaptive icon's layers 108 dp, of which the middle 66 dp is always shown.
DENSITIES = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}


def draw(fill):
    """The picture on the 480 canvas (drawn at SS times), with the brackets
    taking up fill of its width."""
    rng = random.Random(3)
    img = Image.new("RGB", CANVAS)
    box = 480 * fill                # the brackets' width, in the 480 picture
    text = logo.centered(logo.text_mask(TEXT, logo.fit_font(TEXT, FONT, box * 0.74, 900), CENTER),
                         CENTER[0], CENTER[1])
    tx0, ty0, tx1, ty1 = text.getbbox()
    logo.glow(img, text, logo.GREEN, (box * 0.04, box * 0.016), (0.35, 0.6))
    logo.gradient(img, text, [(0, logo.GREEN_BRIGHT), (0.5, logo.GREEN), (1, logo.GREEN_MID)])
    # One glitched slice, as in the logo, thin and low enough that the
    # letters still read
    out = img.copy()
    for _ in range(1):
        y = ty0 + int((ty1 - ty0) * 0.68)
        height = int(box * 0.025 * SS)
        dx = rng.choice([-1, 1]) * int(box * 0.03 * SS)
        band = img.crop((0, y, CANVAS[0], y + height))
        out.paste((0, 0, 0), (0, y, CANVAS[0], y + height))
        out.paste(band, (dx, y))
    img = out

    # Square brackets around it
    half = box * SS / 2
    fx0, fy0, fx1, fy1 = CENTER[0] - half, CENTER[1] - half, CENTER[0] + half, CENTER[1] + half
    arm, line = box * 0.2 * SS, max(2, int(box * 0.045 * SS))
    frame = Image.new("L", CANVAS, 0)
    d = ImageDraw.Draw(frame)
    for x, y, sx, sy in [(fx0, fy0, 1, 1), (fx1, fy0, -1, 1), (fx0, fy1, 1, -1), (fx1, fy1, -1, -1)]:
        d.line([(x, y + sy * arm), (x, y), (x + sx * arm, y)], fill=255, width=line, joint="curve")
    logo.glow(img, frame, logo.GREEN, (box * 0.03, box * 0.012), (0.5, 1.0))
    logo.paint(img, frame, logo.GREEN)
    return img


def finish(img, size):
    """Scaled to size, with scan lines about as far apart as the logo's."""
    img = img.resize((size, size), Image.LANCZOS)
    period = max(3, round(size / 80))
    return logo.scanlines(img, period=period, darkness=0.25) if size >= 96 else img


def to_layer(img):
    """A picture on black as a transparent layer: how bright it is becomes how
    opaque, so the glow fades into whatever's behind."""
    rgba = Image.new("RGBA", img.size)
    px, out = img.load(), rgba.load()
    for y in range(img.size[1]):
        for x in range(img.size[0]):
            r, g, b = px[x, y]
            a = max(r, g, b)
            out[x, y] = (0, 0, 0, 0) if a == 0 else (r * 255 // a, g * 255 // a, b * 255 // a, a)
    return rgba


def main():
    global FONT
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--fonts", required=True, help="folder with the logo's fonts")
    args = parser.parse_args()
    FONT = os.path.join(args.fonts, "Orbitron[wght].ttf")

    full = draw(0.72)           # the plain and iPhone icons: the whole square shows
    # The adaptive icon: the brackets' corners kept inside the 66 dp circle
    # in the middle of its 108, which round icons show
    layer = draw(0.42)

    for name, scale in DENSITIES.items():
        folder = os.path.join(RES, f"mipmap-{name}")
        finish(full, round(48 * scale)).save(os.path.join(folder, "ic_launcher.png"), optimize=True)
        fg = to_layer(finish(layer, round(108 * scale)))
        fg.save(os.path.join(folder, "ic_launcher_foreground.png"), optimize=True)
        mono = Image.new("RGBA", fg.size, (255, 255, 255, 0))
        mono.putalpha(fg.getchannel("A"))
        mono.save(os.path.join(folder, "ic_launcher_monochrome.png"), optimize=True)

    os.makedirs(os.path.join(RES, "mipmap-anydpi-v26"), exist_ok=True)
    with open(os.path.join(RES, "mipmap-anydpi-v26", "ic_launcher.xml"), "w") as f:
        f.write('<?xml version="1.0" encoding="utf-8"?>\n'
                '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
                '    <background android:drawable="@color/ic_launcher_background" />\n'
                '    <foreground android:drawable="@mipmap/ic_launcher_foreground" />\n'
                '    <monochrome android:drawable="@mipmap/ic_launcher_monochrome" />\n'
                '</adaptive-icon>\n')
    with open(os.path.join(RES, "values", "ic_launcher_background.xml"), "w") as f:
        f.write('<?xml version="1.0" encoding="utf-8"?>\n<resources>\n'
                '    <color name="ic_launcher_background">#000000</color>\n</resources>\n')

    # The iPhone's, all from one at 1024, which can't have transparency
    master = finish(full, 1024)
    with open(os.path.join(IOS_ICONS, "Contents.json")) as f:
        images = json.load(f)["images"]
    for image in images:
        points = float(image["size"].split("x")[0])
        size = round(points * int(image["scale"][0]))
        icon = master if size == 1024 else finish(full, size)
        icon.save(os.path.join(IOS_ICONS, image["filename"]), optimize=True)
    print(f"Wrote {len(DENSITIES) * 3 + 2} Android files and {len(images)} iPhone icons")


if __name__ == "__main__":
    main()
