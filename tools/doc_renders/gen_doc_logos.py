#!/usr/bin/env python3
"""
Draw KatCorp's logo for the display, imgs/katcorp.png, the first image it
shows on a new build, and the logos the documentation uses, in docs/images/:

  dronelab_banner.png   DroneLab's banner for the top of the README, a panel
                        with rounded corners and a green edge: the
                        startup logo's glitched green title in its brackets
                        (see tools/gen_logo.py), on a wide strip, with
                        KatCorp's mark and name
  katcorp_logo.png      KatCorp, the fictional company DroneLab is "from":
                        the cat (katcorp_cat.bmp, here) in a ring, with its
                        name and "Drone Systems Division"
  katcorp_mark.png      Just the cat in its ring, small, for page headings
  downloads/heading_*.png
                        The release notes' section headings, Downloads and
                        Release notes, in the banner's style, and the
                        Downloads section's subheadings for its groups,
                        with no background, and a _light version of each
                        for GitHub's light theme

It needs Pillow, and the same two fonts as tools/gen_logo.py, from Google
Fonts (SIL Open Font License), in the folder given with --fonts:

    Orbitron[wght].ttf          https://fonts.google.com/specimen/Orbitron
    ShareTechMono-Regular.ttf   https://fonts.google.com/specimen/Share+Tech+Mono

Usage:
    python3 tools/doc_renders/gen_doc_logos.py --fonts ~/fonts
"""

import argparse
import os
import random

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.join(HERE, "..", "..")
OUT = os.path.join(REPO, "docs", "images")

SS = 3                          # drawn at 3 times the size, then scaled down smoothly

GREEN = (51, 255, 51)           # the Terminal's phosphor, as in the startup logo
GREEN_BRIGHT = (190, 255, 190)
GREEN_MID = (20, 160, 20)
GREEN_DARK = (10, 90, 10)
PINK = (255, 64, 192)           # the cat, and the display's controls
PINK_BRIGHT = (255, 170, 230)
PINK_DARK = (110, 20, 80)


class Canvas:
    def __init__(self, w, h, mode="RGB"):
        self.w, self.h = w * SS, h * SS
        self.size = (self.w, self.h)
        self.img = Image.new(mode, self.size, (0, 0, 0, 0) if mode == "RGBA" else (0, 0, 0))

    def mask(self):
        return Image.new("L", self.size, 0)

    def text(self, text, font, pos, anchor="mm"):
        m = self.mask()
        ImageDraw.Draw(m).text(pos, text, font=font, fill=255, anchor=anchor)
        return m

    def paint(self, mask, color):
        layer = Image.new(self.img.mode, self.size, color + ((255,) if self.img.mode == "RGBA" else ()))
        if self.img.mode == "RGBA":
            self.img = Image.composite(layer, self.img, mask) if False else _over(self.img, layer, mask)
        else:
            self.img.paste(layer, (0, 0), mask)

    def glow(self, mask, color, radii, strengths):
        for radius, strength in zip(radii, strengths):
            blurred = mask.filter(ImageFilter.GaussianBlur(radius * SS))
            self.paint(blurred.point(lambda v: int(min(255, v * strength * 1.7))), color)

    def gradient(self, mask, stops):
        """Fill mask with colors from top to bottom of its own bounding box"""
        box = mask.getbbox()
        height = box[3] - box[1]
        layer = Image.new("RGB", self.size)
        draw = ImageDraw.Draw(layer)
        for y in range(height):
            t = y / max(1, height - 1)
            for (t0, c0), (t1, c1) in zip(stops, stops[1:]):
                if t0 <= t <= t1:
                    u = (t - t0) / (t1 - t0)
                    color = tuple(int(c0[i] + (c1[i] - c0[i]) * u) for i in range(3))
                    break
            draw.line([(0, box[1] + y), (self.w, box[1] + y)], fill=color)
        if self.img.mode == "RGBA":
            self.img = _over(self.img, layer.convert("RGBA"), mask)
        else:
            self.img.paste(layer, (0, 0), mask)

    def finish(self, scan=True):
        img = self.img.resize((self.w // SS, self.h // SS), Image.LANCZOS)
        if scan:
            img = scanlines(img)
        return img


def _over(base, layer, mask):
    """layer over base through mask, keeping base's transparency elsewhere"""
    layer = layer.copy()
    layer.putalpha(mask)
    return Image.alpha_composite(base, layer)


def scanlines(img, period=6, darkness=0.3):
    lines = Image.new("L", img.size, 0)
    draw = ImageDraw.Draw(lines)
    for y in range(0, img.size[1], period):
        draw.rectangle([0, y + period - 2, img.size[0], y + period - 1], fill=int(255 * darkness))
    if img.mode == "RGBA":
        alpha = img.getchannel("A")
        rgb = Image.composite(Image.new("RGB", img.size), img.convert("RGB"), lines)
        rgb.putalpha(alpha)
        return rgb
    return Image.composite(Image.new("RGB", img.size), img, lines)


def font(path, size, weight=None):
    f = ImageFont.truetype(path, int(size * SS))
    if weight is not None:
        f.set_variation_by_axes([weight])
    return f


def fit(c, text, path, width, weight=None):
    """The font at which text is width pixels wide (before SS)"""
    size = 100
    for _ in range(3):
        box = c.text(text, font(path, size, weight), (c.w // 2, c.h // 2)).getbbox()
        size *= width * SS / (box[2] - box[0])
    return font(path, size, weight)


def centered(mask, x, y):
    box = mask.getbbox()
    return ImageChops.offset(mask, int(x - (box[0] + box[2]) / 2), int(y - (box[1] + box[3]) / 2))


def glitch(img, top, bottom, rng, slices=4):
    out = img.copy()
    for _ in range(slices):
        y = rng.randint(top, bottom - 8 * SS)
        height = rng.randint(2, 6) * SS
        dx = rng.choice([-1, 1]) * rng.randint(4, 10) * SS
        band = img.crop((0, y, img.width, y + height))
        out.paste((0, 0, 0, 0) if img.mode == "RGBA" else (0, 0, 0), (0, y, img.width, y + height))
        out.paste(band, (dx, y))
    return out


def cat_mask(size):
    """The cat from katcorp_cat.bmp, smoothed, size pixels across"""
    src = Image.open(os.path.join(HERE, "katcorp_cat.bmp")).convert("RGB")
    # The cat is the pink pixels: much more red and blue than green
    m = Image.new("L", src.size, 0)
    px, mp = src.load(), m.load()
    for y in range(src.height):
        for x in range(src.width):
            r, g, b = px[x, y]
            mp[x, y] = 255 if r > 150 and b > 150 and g < 160 else 0
    m = m.crop(m.getbbox())
    scale = size / max(m.size)
    big = m.resize((round(m.width * scale), round(m.height * scale)), Image.LANCZOS)
    # Blur and threshold again, to round off the low-resolution steps
    big = big.filter(ImageFilter.GaussianBlur(size / 240))
    return big.point(lambda v: 255 if v > 128 else 0).filter(ImageFilter.GaussianBlur(0.6))


def circle(cx, cy, r):
    return [cx - r, cy - r, cx + r, cy + r]


def draw_mark(c, cx, cy, r):
    """The cat in a ring, glowing pink, on a black disc"""
    plate = c.mask()
    ImageDraw.Draw(plate).ellipse(circle(cx, cy, r * 1.04), fill=255)
    c.paint(plate, (0, 0, 0))
    ring = c.mask()
    ImageDraw.Draw(ring).ellipse(circle(cx, cy, r * 0.94), outline=255, width=max(2, int(r * 0.06)))
    cat = cat_mask(int(r * 1.1))
    cm = c.mask()
    cm.paste(cat, (int(cx - cat.width / 2), int(cy - cat.height / 2 + r * 0.04)))
    # The glow stays inside the plate, so it reads on a light page too
    glow = Canvas(1, 1)
    glow.size, glow.w, glow.h = c.size, c.w, c.h
    glow.img = Image.new("RGB", c.size)
    glow.glow(ring, PINK, (r / SS * 0.12, r / SS * 0.04), (0.5, 0.9))
    glow.glow(cm, PINK, (r / SS * 0.05,), (0.35,))
    if c.img.mode == "RGBA":
        c.img = _over(c.img, glow.img.convert("RGBA"), ImageChops.multiply(plate, glow.img.convert("L").point(lambda v: min(255, v * 3))))
    else:
        c.img.paste(glow.img, (0, 0), ImageChops.multiply(plate, glow.img.convert("L").point(lambda v: min(255, v * 3))))
    c.gradient(ring, [(0, PINK_BRIGHT), (0.5, PINK), (1, PINK_DARK)])
    c.gradient(cm, [(0, PINK_BRIGHT), (0.5, PINK), (1, (210, 40, 160))])


def banner(fonts):
    orbitron, mono = fonts
    rng = random.Random(7)
    c = Canvas(1280, 360)
    cx, cy = c.w // 2 + 60 * SS, c.h // 2 - 22 * SS

    title = centered(c.text("DRONELAB", fit(c, "DRONELAB", orbitron, 700, 900), (cx, cy)), cx, cy)
    tx0, ty0, tx1, ty1 = title.getbbox()
    c.glow(title, GREEN, (14, 6, 2), (0.35, 0.6, 0.9))
    c.paint(ImageChops.offset(title, -9 * SS, 0).point(lambda v: v // 3), GREEN_DARK)
    c.gradient(title, [(0, GREEN_BRIGHT), (0.5, GREEN), (1, GREEN_MID)])
    c.img = glitch(c.img, ty0, ty1, rng, slices=5)

    pad, arm, line = 22 * SS, 34 * SS, 4 * SS
    fx0, fy0, fx1, fy1 = tx0 - pad, ty0 - pad, tx1 + pad, ty1 + pad
    frame = c.mask()
    draw = ImageDraw.Draw(frame)
    for x, y, sx, sy in [(fx0, fy0, 1, 1), (fx1, fy0, -1, 1), (fx0, fy1, 1, -1), (fx1, fy1, -1, -1)]:
        draw.line([(x, y + sy * arm), (x, y), (x + sx * arm, y)], fill=255, width=line)
    mid = (fy0 + fy1) // 2
    for side, x in ((1, fx1),):
        points = [(x, mid), (x + side * 18 * SS, mid), (x + side * 30 * SS, mid + 12 * SS),
                  (x + side * 44 * SS, mid + 12 * SS)]
        draw.line(points, fill=255, width=2 * SS)
        end = points[-1]
        draw.ellipse([end[0] - 5 * SS, end[1] - 5 * SS, end[0] + 5 * SS, end[1] + 5 * SS], fill=255)
    c.glow(frame, GREEN, (8, 3), (0.5, 1.0))
    c.paint(frame, GREEN)

    small = font(mono, 18)
    c.paint(c.text("KATCORP // DRONE SYSTEMS DIVISION", small, (fx0, fy0 - 12 * SS), anchor="ls"), GREEN_MID)
    c.paint(c.text("UPGRADE AVAILABLE", small, (fx1, fy0 - 12 * SS), anchor="rs"), GREEN_MID)

    prompt = c.text("> HIVE CONNECTED_", font(mono, 30), (fx0, fy1 + 46 * SS), anchor="lm")
    c.glow(prompt, GREEN, (6, 2), (0.5, 1.0))
    c.paint(prompt, GREEN)

    # KatCorp's mark, on the left, joined to the brackets by a trace
    mr = 92 * SS
    mx = fx0 - 54 * SS - mr
    trace = c.mask()
    ImageDraw.Draw(trace).line([(mx + mr * 0.9, mid), (fx0 - 12 * SS, mid)], fill=255, width=2 * SS)
    c.glow(trace, PINK, (5,), (0.6,))
    c.paint(trace, PINK)
    img = c.finish()
    # The mark goes on after the scan lines, which would muddy the cat
    mark = Canvas(c.w // SS, c.h // SS)
    draw_mark(mark, mx, mid, mr)
    plate = mark.mask()
    ImageDraw.Draw(plate).ellipse(circle(mx, mid, mr * 1.04), fill=255)
    img.paste(mark.finish(scan=False), (0, 0), plate.resize(img.size, Image.LANCZOS))
    return img


def katcorp_logo(fonts):
    orbitron, mono = fonts
    c = Canvas(900, 300, "RGBA")
    plate = c.mask()
    ImageDraw.Draw(plate).rounded_rectangle([0, 0, c.w - 1, c.h - 1], radius=36 * SS, fill=255)
    c.paint(plate, (8, 6, 10))
    r = 115 * SS
    mx, my = 30 * SS + r, c.h // 2
    draw_mark(c, mx, my, r)
    x = mx + r + 40 * SS
    name = c.text("KATCORP", font(orbitron, 96, 900), (x, my - 12 * SS), anchor="ls")
    c.glow(name, PINK, (8, 3), (0.3, 0.7))
    c.gradient(name, [(0, PINK_BRIGHT), (0.6, PINK), (1, (200, 40, 150))])
    sub = c.text("DRONE SYSTEMS DIVISION", font(mono, 34), (x + 4 * SS, my + 40 * SS), anchor="ls")
    c.paint(sub, (235, 190, 225))
    return c.finish(scan=False)


def display_logo():
    """For the round display: the cat in a glowing ring, clear of the edge,
    where the voice ring glows"""
    size = 466
    c = Canvas(size, size)
    cx = cy = c.w // 2
    r = c.w // 2
    ring = c.mask()
    ImageDraw.Draw(ring).ellipse(circle(cx, cy, r * 0.86), outline=255, width=int(r * 0.035))
    c.glow(ring, PINK, (14, 5), (0.45, 0.9))
    c.gradient(ring, [(0, PINK_BRIGHT), (0.5, PINK), (1, PINK_DARK)])
    cat = cat_mask(int(r * 1.05))
    cm = c.mask()
    cm.paste(cat, (int(cx - cat.width / 2), int(cy - cat.height / 2 + r * 0.04)))
    c.glow(cm, PINK, (10, 4), (0.35, 0.6))
    c.gradient(cm, [(0, PINK_BRIGHT), (0.5, PINK), (1, (210, 40, 160))])
    return c.finish(scan=False)


def katcorp_mark():
    c = Canvas(160, 160, "RGBA")
    draw_mark(c, c.w // 2, c.h // 2, 74 * SS)
    return c.finish(scan=False)


# The release notes' section headings: name, title
HEADINGS = [
    ("heading_downloads", "DOWNLOADS"),
    ("heading_release_notes", "RELEASE NOTES"),
]

# The Downloads section's groups: name, title
SUBHEADINGS = [
    ("subheading_app", "COMPANION APP"),
    ("subheading_firmware", "DISPLAY UNIT FIRMWARE"),
    ("subheading_parts", "3D PRINTED PARTS"),
]


# Colours for the headings, which have no background of their own: a softer
# neon for GitHub's dark themes, and deeper greens that read on its light one
THEMES = {
    "dark": dict(glow=(45, 220, 70), glow_strength=0.75, stops=[(0, (120, 235, 130)), (0.5, (40, 205, 65)), (1, (18, 140, 40))],
                shadow=(12, 80, 20), line=(30, 170, 55)),
    "light": dict(glow=(40, 200, 70), glow_strength=0.45, stops=[(0, (20, 150, 50)), (0.5, (10, 125, 40)), (1, (5, 95, 30))],
                  shadow=(150, 220, 160), line=(20, 140, 50)),
}


def subheading(fonts, title, theme):
    """A group's heading in the Downloads section: the title, centred and
    smaller, between traces that end in dots"""
    orbitron, _ = fonts
    t = THEMES[theme]
    k = t["glow_strength"]
    c = Canvas(800, 80, "RGBA")
    cx, cy = c.w // 2, c.h // 2
    text = centered(c.text(title, font(orbitron, 30, 800), (cx, cy)), cx, cy)
    tx0, ty0, tx1, ty1 = text.getbbox()
    c.glow(text, t["glow"], (8, 3), (0.35 * k, 0.8 * k))
    c.gradient(text, t["stops"])
    lines = c.mask()
    draw = ImageDraw.Draw(lines)
    gap, dot = 22 * SS, 4 * SS
    for side, x in ((-1, tx0 - gap), (1, tx1 + gap)):
        end = cx + side * (c.w // 2 - 40 * SS)
        draw.line([(x, cy), (end, cy)], fill=255, width=2 * SS)
        draw.ellipse(circle(end, cy, dot), fill=255)
    c.glow(lines, t["glow"], (5,), (0.6 * k,))
    c.paint(lines, t["line"])
    return c.finish(scan=False)


def heading(fonts, title, theme):
    """A section heading for the release notes, as wide as the banner: the
    green title in brackets, with a trace off to the right"""
    orbitron, _ = fonts
    t = THEMES[theme]
    k = t["glow_strength"]
    rng = random.Random(title)
    c = Canvas(1280, 130, "RGBA")
    x0, cy = 96 * SS, 65 * SS
    text = c.text(title, font(orbitron, 62, 900), (x0, cy), anchor="lm")
    tx0, ty0, tx1, ty1 = text.getbbox()
    c.glow(text, t["glow"], (12, 5, 2), (0.35 * k, 0.6 * k, 0.9 * k))
    c.paint(ImageChops.offset(text, -7 * SS, 0).point(lambda v: v // 3), t["shadow"])
    c.gradient(text, t["stops"])
    c.img = glitch(c.img, ty0, ty1, rng, slices=3)

    pad, arm, line = 18 * SS, 24 * SS, 4 * SS
    fx0, fy0, fx1, fy1 = tx0 - pad, ty0 - pad, tx1 + pad, ty1 + pad
    frame = c.mask()
    draw = ImageDraw.Draw(frame)
    for x, y, sx, sy in [(fx0, fy0, 1, 1), (fx1, fy0, -1, 1), (fx0, fy1, 1, -1), (fx1, fy1, -1, -1)]:
        draw.line([(x, y + sy * arm), (x, y), (x + sx * arm, y)], fill=255, width=line)
    mid = (fy0 + fy1) // 2
    end = c.w - 70 * SS
    draw.line([(fx1 + 14 * SS, mid), (end - 44 * SS, mid), (end - 30 * SS, mid + 12 * SS), (end, mid + 12 * SS)],
              fill=255, width=2 * SS)
    draw.ellipse(circle(end, mid + 12 * SS, 5 * SS), fill=255)
    c.glow(frame, t["glow"], (8, 3), (0.5 * k, 1.0 * k))
    c.paint(frame, t["line"] if theme == "light" else GREEN)

    return c.finish(scan=False)


def panel(img):
    """The banner as a panel: rounded corners and a thin green border, so it
    sits as well on a light page as a dark one"""
    w, h = img.size
    r, line = 24 * SS, 2 * SS
    big = (w * SS, h * SS)
    shape = Image.new("L", big, 0)
    ImageDraw.Draw(shape).rounded_rectangle([0, 0, big[0] - 1, big[1] - 1], radius=r, fill=255)
    edge = Image.new("L", big, 0)
    ImageDraw.Draw(edge).rounded_rectangle([0, 0, big[0] - 1, big[1] - 1], radius=r, outline=255, width=line)
    out = img.convert("RGBA")
    border = Image.new("RGBA", img.size, GREEN_MID + (255,))
    out = Image.composite(border, out, edge.resize(img.size, Image.LANCZOS))
    out.putalpha(shape.resize(img.size, Image.LANCZOS))
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--fonts", required=True, help="folder with the two fonts")
    args = parser.parse_args()
    fonts = (os.path.join(args.fonts, "Orbitron[wght].ttf"), os.path.join(args.fonts, "ShareTechMono-Regular.ttf"))
    for name, img in (("dronelab_banner.png", panel(banner(fonts))), ("katcorp_logo.png", katcorp_logo(fonts)),
                      ("katcorp_mark.png", katcorp_mark()), ("../../imgs/katcorp.png", display_logo())):
        path = os.path.join(OUT, name)
        img.save(path, optimize=True)
        print(f"Wrote {os.path.normpath(path)}")
    for theme, suffix in (("dark", ""), ("light", "_light")):
        for name, title in SUBHEADINGS:
            path = os.path.join(OUT, "downloads", name + suffix + ".png")
            subheading(fonts, title, theme).save(path, optimize=True)
            print(f"Wrote {os.path.normpath(path)}")
        for name, title in HEADINGS:
            path = os.path.join(OUT, "downloads", name + suffix + ".png")
            heading(fonts, title, theme).save(path, optimize=True)
            print(f"Wrote {os.path.normpath(path)}")

if __name__ == "__main__":
    main()
