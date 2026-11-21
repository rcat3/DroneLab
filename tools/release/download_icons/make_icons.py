#!/usr/bin/env python3
"""Draw the download buttons for the release notes.

Draws an SVG for each download and renders it with Inkscape to
docs/images/downloads/<name>.png, which the release notes show (GitHub's
release notes need a full URL to an image, and a PNG shows the same
everywhere). The printed parts' buttons show their housing rendered from its
design, as in the How it works diagram, so it needs OpenSCAD, NumPy and
Pillow too. Run it again after changing a button or a housing:

    tools/release/download_icons/make_icons.py

To add a platform, add a glyph function and an entry to BUTTONS, and the
button to tools/release/release_notes.sh.

It also draws download_latest.png, the wide Download button at the end of the
README's Get a unit section, which links to releases/latest. Give names to
draw just those buttons:

    tools/release/download_icons/make_icons.py download_latest
"""

import base64
import io
import pathlib
import shutil
import subprocess
import sys
import tempfile

from PIL import Image, ImageFilter

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parents[2]
OUT = REPO / "docs" / "images" / "downloads"
sys.path.insert(0, str(REPO / "tools" / "doc_renders"))
import make_diagram  # noqa: E402  (the housings, rendered as in How it works)

W, H = 180, 210          # the card, in SVG units; rendered at 2x
SCALE = 2

BG = "#0b0f0c"
GREEN = "#39ff6a"
PINK = "#ff4fc3"
TEXT = "#ffffff"
SUB = "#a8c9b0"
FONT = "Ubuntu, 'Liberation Sans', sans-serif"


def phone(cx, cy, colour=GREEN, badge=None):
    """A phone, with the app's talk button on its screen, and a badge beside
    it if given."""
    s = f'''
  <g transform="translate({cx} {cy})">
    <rect x="-24" y="-44" width="48" height="88" rx="9" fill="{BG}" stroke="{colour}" stroke-width="4"/>
    <rect x="-7" y="-38" width="14" height="3" rx="1.5" fill="{colour}"/>
    <circle cx="0" cy="4" r="14" fill="none" stroke="{PINK}" stroke-width="3.5"/>
    <circle cx="0" cy="4" r="6" fill="{PINK}"/>
    <rect x="-14" y="26" width="28" height="4" rx="2" fill="{colour}" fill-opacity="0.6"/>
  </g>'''
    if badge:
        s += f'''
  <rect x="{cx + 6}" y="{cy + 18}" width="52" height="20" rx="10" fill="{BG}" stroke="{colour}" stroke-width="2"/>
  <text x="{cx + 32}" y="{cy + 32.5}" font-family="{FONT}" font-size="12.5" font-weight="bold" fill="{colour}" text-anchor="middle">{badge}</text>'''
    return s


def linux_pc(cx, cy):
    """A monitor with a terminal's prompt on it."""
    return f'''
  <g transform="translate({cx} {cy})">
    <rect x="-48" y="-40" width="96" height="66" rx="6" fill="{BG}" stroke="{GREEN}" stroke-width="4"/>
    <rect x="-8" y="26" width="16" height="10" fill="{GREEN}"/>
    <rect x="-24" y="36" width="48" height="5" rx="2.5" fill="{GREEN}"/>
    <path d="M -30 -20 L -16 -8 L -30 4" stroke="{GREEN}" stroke-width="5" fill="none"
          stroke-linecap="round" stroke-linejoin="round"/>
    <rect x="-8" y="2" width="22" height="5" rx="1.5" fill="{PINK}"/>
  </g>'''


def raspberry_pi(cx, cy):
    """A single-board computer: the board, its pin header, chip and ports."""
    pins = "".join(
        f'<circle cx="{-38 + i * 6.4}" cy="{-27 + r * 6}" r="1.9" fill="#f2c94c"/>'
        for i in range(12) for r in range(2))
    return f'''
  <g transform="translate({cx} {cy})">
    <rect x="-48" y="-36" width="96" height="66" rx="7" fill="#1f8a4c" stroke="{GREEN}" stroke-width="2.5"/>
    {pins}
    <rect x="-22" y="-10" width="28" height="28" rx="2" fill="#2b2b2b"/>
    <text x="-8" y="9" font-family="{FONT}" font-size="9" font-weight="bold" fill="#9a9a9a" text-anchor="middle">ARM</text>
    <rect x="22" y="-14" width="34" height="14" rx="1.5" fill="#cfd4d8"/>
    <rect x="22" y="6" width="34" height="14" rx="1.5" fill="#cfd4d8"/>
    <circle cx="-38" cy="20" r="3" fill="none" stroke="#f2c94c" stroke-width="1.5"/>
    <circle cx="38" cy="-28" r="3" fill="none" stroke="#f2c94c" stroke-width="1.5"/>
  </g>'''


def display_unit(cx, cy):
    """The round display unit, with the DroneLab cat on its screen and an
    arrow into it."""
    return f'''
  <g transform="translate({cx} {cy})">
    <circle r="44" fill="#111" stroke="{PINK}" stroke-width="4"/>
    <circle r="36" fill="#000" stroke="{PINK}" stroke-opacity="0.35" stroke-width="2"/>
    <path d="M -20 -20 L -9 -11 L 9 -11 L 20 -20 L 17 2 L 0 20 L -17 2 Z" fill="{PINK}"/>
    <path d="M -12 -2 L -4 0 L -9 4 Z M 12 -2 L 4 0 L 9 4 Z" fill="#000"/>
    <path d="M -3 10 L 3 10 L 0 13 Z" fill="#000"/>
    <g transform="translate(34 32)">
      <circle r="13" fill="{GREEN}"/>
      <path d="M 0 -7 L 0 4 M -5 0 L 0 5 L 5 0" stroke="{BG}" stroke-width="3" fill="none"
            stroke-linecap="round" stroke-linejoin="round"/>
    </g>
  </g>'''


def housing(cx, cy, scad, centre, height):
    """A printed housing from the front, rendered from its design with the
    KatCorp cat on its display and a pink glow, as in How it works."""
    with tempfile.TemporaryDirectory() as tmp:
        unit, mask = make_diagram.render_unit(tmp, scad, centre)
        unit = make_diagram.with_screen(unit, mask, "images_katcorp")
    pad = unit.height // 8
    out = Image.new("RGBA", (unit.width + 2 * pad, unit.height + 2 * pad))
    glow = Image.new("RGBA", out.size, (255, 64, 192, 0))
    alpha = Image.new("L", out.size)
    alpha.paste(unit.getchannel("A"), (pad, pad))
    glow.putalpha(alpha.filter(ImageFilter.GaussianBlur(pad / 3)).point(lambda a: a * 0.55))
    out.alpha_composite(glow)
    out.alpha_composite(unit, (pad, pad))
    h = height * SCALE * 2 * (out.height / unit.height)
    out = out.resize((round(out.width * h / out.height), round(h)), Image.LANCZOS)
    png = io.BytesIO()
    out.save(png, "PNG")
    w, h = out.width / (SCALE * 2), out.height / (SCALE * 2)
    href = "data:image/png;base64," + base64.b64encode(png.getvalue()).decode()
    return f'''
  <image x="{cx - w / 2}" y="{cy - h / 2}" width="{w}" height="{h}" xlink:href="{href}"/>'''


# name, glyph, title, subtitle, the bar's label
BUTTONS = [
    ("android", lambda: phone(90, 70), "Android", "Most phones", "Download"),
    ("android-older", lambda: phone(78, 70, "#8fd9ac", "32-bit"), "Android", "Older phones", "Download"),
    ("linux-x64", lambda: linux_pc(90, 70), "Linux PC", "Laptop or desktop", "Download"),
    ("linux-arm64", lambda: raspberry_pi(90, 72), "Raspberry Pi", "Pi 4 or 5, 64-bit", "Download"),
    ("firmware-1-75", lambda: display_unit(90, 70), "Firmware", "1.75\" Display Unit", "Install"),
    ("parts-speaker", lambda: housing(90, 68, "diagram_unit.scad", "0,-15,0", 104), "Speaker", "3D printed parts", "Download"),
    ("parts-low-profile", lambda: housing(90, 68, "diagram_unit_low_profile.scad", "0,0,0", 92), "Low-profile", "3D printed parts", "Download"),
]


def card(glyph, title, subtitle, label):
    x = W / 2 - 3.6 * len(label) - 6     # the arrow, just before the label
    return f'''<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="{W}" height="{H}" viewBox="0 0 {W} {H}">
  <defs>
    <radialGradient id="bg" cx="90" cy="70" r="125" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#7a5a9c"/>
      <stop offset="0.38" stop-color="#3a2650"/>
      <stop offset="0.75" stop-color="#14101c"/>
      <stop offset="1" stop-color="{BG}"/>
    </radialGradient>
  </defs>
  <rect x="2" y="2" width="{W - 4}" height="{H - 4}" rx="18" fill="url(#bg)" stroke="{GREEN}" stroke-opacity="0.55" stroke-width="2"/>
{glyph}
  <text x="{W / 2}" y="146" font-family="{FONT}" font-size="21" font-weight="bold" fill="{TEXT}" text-anchor="middle">{title}</text>
  <text x="{W / 2}" y="166" font-family="{FONT}" font-size="13" fill="{SUB}" text-anchor="middle">{subtitle.replace('"', '&quot;')}</text>
  <rect x="34" y="177" width="{W - 68}" height="22" rx="11" fill="{GREEN}"/>
  <text x="{W / 2 + 8}" y="192.5" font-family="{FONT}" font-size="13" font-weight="bold" fill="{BG}" text-anchor="middle">{label}</text>
  <path d="M {x} 182 L {x} 192 M {x - 4.5} 188 L {x} 192.5 L {x + 4.5} 188" stroke="{BG}" stroke-width="2.2" fill="none"
        stroke-linecap="round" stroke-linejoin="round"/>
</svg>
'''


WIDE_W, WIDE_H = 520, 104   # the README's Download button


def wide_button():
    """The README's Download button: a wide card in the same colours, with a
    download arrow, and what the latest release has."""
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{WIDE_W}" height="{WIDE_H}" viewBox="0 0 {WIDE_W} {WIDE_H}">
  <defs>
    <radialGradient id="bg" cx="70" cy="52" r="330" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#7a5a9c"/>
      <stop offset="0.3" stop-color="#3a2650"/>
      <stop offset="0.7" stop-color="#14101c"/>
      <stop offset="1" stop-color="{BG}"/>
    </radialGradient>
  </defs>
  <rect x="2" y="2" width="{WIDE_W - 4}" height="{WIDE_H - 4}" rx="18" fill="url(#bg)" stroke="{GREEN}" stroke-opacity="0.7" stroke-width="2.5"/>
  <g transform="translate(66 52)">
    <circle r="32" fill="{GREEN}"/>
    <path d="M 0 -17 L 0 9 M -11 -2 L 0 10 L 11 -2 M -14 18 L 14 18" stroke="{BG}" stroke-width="5.5" fill="none"
          stroke-linecap="round" stroke-linejoin="round"/>
  </g>
  <text x="120" y="52" font-family="{FONT}" font-size="36" font-weight="bold" letter-spacing="2" fill="{TEXT}">DOWNLOAD</text>
  <text x="121" y="78" font-family="{FONT}" font-size="15" fill="{SUB}">App, firmware and 3D printed parts</text>
  <rect x="{WIDE_W - 136}" y="36" width="112" height="32" rx="16" fill="none" stroke="{PINK}" stroke-width="2.5"/>
  <text x="{WIDE_W - 80}" y="57" font-family="{FONT}" font-size="14" font-weight="bold" fill="{PINK}" text-anchor="middle">Latest release</text>
</svg>
'''


def render(tmp, name, svg_text, width):
    svg = tmp / f"{name}.svg"
    svg.write_text(svg_text)
    png = OUT / f"{name}.png"
    subprocess.run(["inkscape", str(svg), "--export-type=png", f"--export-filename={png}",
                    f"--export-width={width * SCALE}"], check=True, capture_output=True)
    print(png.relative_to(REPO))


def main():
    only = set(sys.argv[1:])
    OUT.mkdir(parents=True, exist_ok=True)
    tmp = pathlib.Path(tempfile.mkdtemp())
    for name, glyph, title, subtitle, label in BUTTONS:
        if not only or name in only:
            render(tmp, name, card(glyph(), title, subtitle, label), W)
    if not only or "download_latest" in only:
        render(tmp, "download_latest", wide_button(), WIDE_W)
    shutil.rmtree(tmp)


if __name__ == "__main__":
    main()
