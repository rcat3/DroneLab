#!/usr/bin/env python3
"""
Draw the README's How it works diagram, docs/images/how_it_works.jpg, and the
Features page's tiles for the features with no screen of their own.

The units in it are the speaker housing rendered from its design
(diagram_unit.scad), with screenshots from docs/images/screens/ on their
displays. The rest is diagram/how_it_works.html, which headless Chrome turns
into the picture. It needs OpenSCAD, Google Chrome, Python 3 with Pillow and
NumPy, and the same two fonts as gen_doc_logos.py, in the folder given with
--fonts:

    Orbitron[wght].ttf          https://fonts.google.com/specimen/Orbitron
    ShareTechMono-Regular.ttf   https://fonts.google.com/specimen/Share+Tech+Mono

    python3 tools/doc_renders/make_diagram.py --fonts ~/fonts
"""

import argparse
import os
import shutil
import subprocess
import tempfile

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
SCREENS = os.path.join(REPO, "docs", "images", "screens")
OUT = os.path.join(REPO, "docs", "images", "how_it_works.jpg")

# The unit in the middle, and the three in the hive
UNITS = {
    "unit_main": "images_katcorp",
    "unit_hive1": "comm_status",
    "unit_hive2": "terminal",
    "unit_hive3": "visualizer_kitt",
}

# Round tiles for the Features page, for the features with no screen of their
# own, written to docs/images/screens/feature_<name>.png (diagram/tile.html)
TILES = ["remote", "voice_lab"]

SIZE = (1600, 900)      # CSS pixels
SCALE = 1.5             # and the picture's pixels per CSS pixel


def render_unit(tmp):
    """The housing from the front, as RGBA, and the mask of its glass.

    OpenSCAD can't render a transparent background, so it's rendered on a
    dark background and a light one, and the difference between them gives
    each pixel's opacity."""
    paths = {}
    for scheme, name in (("Tomorrow Night", "dark"), ("Tomorrow", "light")):
        paths[name] = os.path.join(tmp, f"unit_{name}.png")
        subprocess.run(["openscad", "-D", 'part="none"', "--camera=0,-15,0,0,0,0,330",
                        "--projection=o", "--imgsize=1200,1200", f"--colorscheme={scheme}",
                        "-o", paths[name], os.path.join(HERE, "diagram_unit.scad")],
                       check=True, capture_output=True)
    d = np.asarray(Image.open(paths["dark"]).convert("RGB")).astype(float)
    l = np.asarray(Image.open(paths["light"]).convert("RGB")).astype(float)
    bd, bl = d[0, 0], l[0, 0]
    a = 1 - np.clip((l - d).sum(2) / (bl - bd).sum(), 0, 1)
    fg = np.where(a[..., None] > 0.01, (d - (1 - a[..., None]) * bd) / np.maximum(a[..., None], 0.01), 0)
    unit = Image.fromarray(np.dstack([np.clip(fg, 0, 255), a * 255]).astype(np.uint8))
    # The glass is magenta
    glass = (d[..., 0] > 120) & (d[..., 2] > 120) & (d[..., 1] < 90)
    mask = Image.fromarray((glass * 255).astype(np.uint8)).filter(ImageFilter.MaxFilter(3))
    box = unit.getbbox()
    return unit.crop(box), mask.crop(box)


def with_screen(unit, mask, screen):
    """The unit with a screenshot on its display"""
    x0, y0, x1, y1 = mask.getbbox()
    shot = Image.open(os.path.join(SCREENS, screen + ".png")).convert("RGBA")
    shot = shot.resize((x1 - x0, y1 - y0), Image.LANCZOS)
    glass = Image.new("RGBA", unit.size, (6, 6, 8, 255))
    glass.alpha_composite(shot, (x0, y0))
    out = unit.copy()
    out.paste(glass, (0, 0), mask)
    return out


def screenshot(tmp, fonts, template, fragment, size, scale):
    """Headless Chrome's picture of a page in diagram/, with @FONTS@ and
    @ASSETS@ filled in"""
    html = open(os.path.join(HERE, "diagram", template)).read()
    html = html.replace("@FONTS@", "file://" + fonts).replace("@ASSETS@", "file://" + tmp)
    page = os.path.join(tmp, template)
    with open(page, "w") as f:
        f.write(html)
    shot = os.path.join(tmp, "shot.png")
    chrome = shutil.which("google-chrome") or shutil.which("chromium") or "google-chrome"
    subprocess.run([chrome, "--headless", "--disable-gpu", "--hide-scrollbars",
                    "--allow-file-access-from-files", f"--window-size={size[0]},{size[1]}",
                    f"--force-device-scale-factor={scale}", "--virtual-time-budget=3000",
                    f"--screenshot={shot}", "file://" + page + fragment],
                   check=True, capture_output=True)
    return shot


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--fonts", required=True, help="folder with the two fonts")
    args = parser.parse_args()
    fonts = os.path.abspath(os.path.expanduser(args.fonts))

    with tempfile.TemporaryDirectory() as tmp:
        unit, mask = render_unit(tmp)
        for name, screen in UNITS.items():
            with_screen(unit, mask, screen).save(os.path.join(tmp, name + ".png"))

        shot = screenshot(tmp, fonts, "how_it_works.html", "", SIZE, SCALE)
        Image.open(shot).convert("RGB").save(OUT, quality=92, subsampling=0, optimize=True, progressive=True)
        print("Wrote", OUT)

        # The round tiles, cut round and with a transparent outside like the screenshots
        for name in TILES:
            shot = screenshot(tmp, fonts, "tile.html", "#" + name, (466, 466), 1)
            tile = Image.open(shot).convert("RGBA")
            ring = Image.new("L", (466 * 4, 466 * 4), 0)
            ImageDraw.Draw(ring).ellipse((0, 0, 466 * 4 - 1, 466 * 4 - 1), fill=255)
            tile.putalpha(ring.resize((466, 466), Image.LANCZOS))
            path = os.path.join(SCREENS, f"feature_{name}.png")
            tile.save(path, optimize=True)
            print("Wrote", path)


if __name__ == "__main__":
    main()
