#!/usr/bin/env python3
"""Render the sender's built-in 3D logo loops, builtin/katcorp.mp4 and
builtin/dronelab.mp4: each logo extruded into a slab, turning once about its
upright axis (with a slow nod), lit from one side, lit edges blooming, drawn
for both eyes (side by side, 2560x720, a real stereo pair: two cameras turned
in on the logo) and encoded as H.264. The Guide plays them like any film.

Needs numpy, numba, Pillow, OpenCV and ffmpeg (with libx264), and the two
fonts tools/gen_logo.py uses, in the folder given with --fonts.

    python3 tools/hivesight-sender/make_logo_loops.py --fonts ~/fonts [katcorp|dronelab]

The loops are committed, so this only needs running to change a logo."""
from __future__ import annotations

import argparse
import math
import subprocess
import sys
from pathlib import Path

import cv2
import numpy as np
from numba import njit, prange
from PIL import Image, ImageDraw, ImageFont

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "doc_renders"))
import gen_doc_logos as docs  # noqa: E402  (the cat)

EYE_W, EYE_H, FPS = 1280, 720, 30
SECONDS = 12
SS = 2                          # drawn at twice the size, then scaled down
ART_W, ART_H = 2000, 700        # the logo's picture, in texels
SLAB = 70.0                     # how thick it is, in the same units
CAM_D = 4500.0                  # the cameras' distance
EYE_OFFSET = 110.0              # each camera's distance from the middle
SHOW = 0.72                     # the logo's width as a part of the eye's

PINK, PINK_HI, PINK_LO = (255, 64, 192), (255, 170, 230), (210, 40, 160)
GREEN, GREEN_HI, GREEN_LO = (51, 255, 51), (190, 255, 190), (20, 160, 20)


# ------------------------------------------------------------------ the art
def gradient(mask: Image.Image, stops) -> Image.Image:
    """RGBA: [mask] painted with colours from the top of its box to the bottom."""
    box = mask.getbbox()
    out = np.zeros((mask.height, mask.width, 3), np.float32)
    ys = np.arange(mask.height, dtype=np.float32)
    t = np.clip((ys - box[1]) / max(1, box[3] - box[1]), 0, 1)
    for k in range(3):
        out[:, :, k] = np.interp(t, [s[0] for s in stops], [s[1][k] for s in stops])[:, None]
    img = Image.fromarray(out.astype(np.uint8)).convert("RGBA")
    img.putalpha(mask)
    return img


def text_mask(size, text, font, xy, anchor):
    m = Image.new("L", size, 0)
    ImageDraw.Draw(m).text(xy, text, font=font, fill=255, anchor=anchor)
    return m


def katcorp(fonts: Path) -> Image.Image:
    w, h = ART_W * SS, ART_H * SS
    art = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    r, cx, cy = 300 * SS, 350 * SS, h // 2
    ring = Image.new("L", (w, h), 0)
    ImageDraw.Draw(ring).ellipse([cx - r, cy - r, cx + r, cy + r], outline=255, width=34 * SS)
    cat = docs.cat_mask(int(r * 1.12))
    cm = Image.new("L", (w, h), 0)
    cm.paste(cat, (int(cx - cat.width / 2), int(cy - cat.height / 2 + r * 0.04)))
    for m in (ring, cm):
        art.alpha_composite(gradient(m, [(0, PINK_HI), (0.5, PINK), (1, PINK_LO)]))
    orb = ImageFont.truetype(str(fonts / "Orbitron[wght].ttf"), 300 * SS)
    orb.set_variation_by_axes([900])
    x = cx + r + 90 * SS
    # Scale it to fill the width that's left
    k = (w - x - 40 * SS) / orb.getlength("KATCORP")
    orb = ImageFont.truetype(str(fonts / "Orbitron[wght].ttf"), int(300 * SS * k))
    orb.set_variation_by_axes([900])
    name = text_mask((w, h), "KATCORP", orb, (x, cy - 10 * SS), "ls")
    art.alpha_composite(gradient(name, [(0, PINK_HI), (0.6, PINK), (1, PINK_LO)]))
    mono = ImageFont.truetype(str(fonts / "ShareTechMono-Regular.ttf"), int(112 * SS * k))
    sub = text_mask((w, h), "DRONE SYSTEMS DIVISION", mono, (x + 6 * SS, cy + 125 * SS * k), "ls")
    # Thin letters need weight to stand as a slab
    sub = sub.filter(__import__("PIL.ImageFilter", fromlist=["MaxFilter"]).MaxFilter(5))
    art.alpha_composite(gradient(sub, [(0, (240, 200, 230)), (1, (235, 190, 225))]))
    return art.resize((ART_W, ART_H), Image.LANCZOS)


def dronelab(fonts: Path) -> Image.Image:
    w, h = ART_W * SS, ART_H * SS
    art = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    orb = ImageFont.truetype(str(fonts / "Orbitron[wght].ttf"), 300 * SS)
    orb.set_variation_by_axes([900])
    k = 1380 * SS / orb.getlength("DRONELAB")
    orb = ImageFont.truetype(str(fonts / "Orbitron[wght].ttf"), int(300 * SS * k))
    orb.set_variation_by_axes([900])
    title = text_mask((w, h), "DRONELAB", orb, (w // 2, h // 2 - 40 * SS), "mm")
    art.alpha_composite(gradient(title, [(0, GREEN_HI), (0.5, GREEN), (1, GREEN_LO)]))
    x0, y0, x1, y1 = title.getbbox()
    pad, arm, line = 50 * SS, 120 * SS, 26 * SS
    fx0, fy0, fx1, fy1 = x0 - pad, y0 - pad, x1 + pad, y1 + pad
    frame = Image.new("L", (w, h), 0)
    d = ImageDraw.Draw(frame)
    for x, y, sx, sy in [(fx0, fy0, 1, 1), (fx1, fy0, -1, 1), (fx0, fy1, 1, -1), (fx1, fy1, -1, -1)]:
        d.line([(x, y + sy * arm), (x, y), (x + sx * arm, y)], fill=255, width=line, joint="curve")
    mid = (fy0 + fy1) // 2
    for side, x in ((-1, fx0), (1, fx1)):
        pts = [(x, mid), (x + side * 70 * SS, mid), (x + side * 120 * SS, mid + 50 * SS),
               (x + side * 170 * SS, mid + 50 * SS)]
        d.line(pts, fill=255, width=16 * SS)
        ex, ey = pts[-1]
        d.ellipse([ex - 24 * SS, ey - 24 * SS, ex + 24 * SS, ey + 24 * SS], fill=255)
    art.alpha_composite(gradient(frame, [(0, GREEN), (1, GREEN_LO)]))
    mono = ImageFont.truetype(str(fonts / "ShareTechMono-Regular.ttf"), 120 * SS)
    prompt = text_mask((w, h), "> SYSTEM ONLINE", mono, (w // 2, fy1 + 130 * SS), "mm")
    prompt = prompt.filter(__import__("PIL.ImageFilter", fromlist=["MaxFilter"]).MaxFilter(5))
    art.alpha_composite(gradient(prompt, [(0, GREEN_HI), (1, GREEN)]))
    return art.resize((ART_W, ART_H), Image.LANCZOS)


ARTS = {"katcorp": katcorp, "dronelab": dronelab}


# ------------------------------------------------------------- the renderer
@njit(parallel=True, fastmath=True, cache=True)
def render(out, tex, alpha, soft, R, ex, cam_d, f, slab, light):
    """One eye of the slab (its picture [tex], shape [alpha]) turned by [R]
    (logo to world), seen from a camera at x = [ex] turned to face the middle."""
    H, W = out.shape[0], out.shape[1]
    ha, wa = alpha.shape
    phi = math.atan2(-ex, cam_d)
    cph, sph = math.cos(phi), math.sin(phi)
    half = slab / 2.0
    # The camera's position, in the logo's own space (R is a rotation: its inverse is its transpose)
    ox, oy, oz = ex, 0.0, -cam_d
    lx = R[0, 0] * ox + R[1, 0] * oy + R[2, 0] * oz
    ly = R[0, 1] * ox + R[1, 1] * oy + R[2, 1] * oz
    lz = R[0, 2] * ox + R[1, 2] * oy + R[2, 2] * oz
    for i in prange(H):
        for j in range(W):
            a = (j - W / 2.0 + 0.5) / f
            b = -(i - H / 2.0 + 0.5) / f
            dx, dy, dz = a * cph + sph, b, -a * sph + cph
            ux = R[0, 0] * dx + R[1, 0] * dy + R[2, 0] * dz
            uy = R[0, 1] * dx + R[1, 1] * dy + R[2, 1] * dz
            uz = R[0, 2] * dx + R[1, 2] * dy + R[2, 2] * dz
            if abs(uz) < 1e-9:
                continue
            t0, t1 = (-half - lz) / uz, (half - lz) / uz
            tin, tout = min(t0, t1), max(t0, t1)
            px, py = lx + ux * tin, ly + uy * tin
            tx, ty = int(px + wa / 2.0), int(ha / 2.0 - py)
            hit = False
            face = False
            if 0 <= tx < wa and 0 <= ty < ha and alpha[ty, tx] > 0.5:
                hit, face = True, True
            else:
                sp = math.sqrt(ux * ux + uy * uy)
                if sp > 1e-9:
                    dt = 0.6 / sp
                    s = tin + dt
                    while s < tout:
                        qx, qy = lx + ux * s, ly + uy * s
                        tx, ty = int(qx + wa / 2.0), int(ha / 2.0 - qy)
                        if 0 <= tx < wa and 0 <= ty < ha and alpha[ty, tx] > 0.5:
                            hit = True
                            break
                        s += dt
            if not hit:
                continue
            if face:
                nz = -1.0 if uz > 0 else 1.0       # the face the ray came through
                nx, ny = 0.0, 0.0
            else:
                x0, x1 = max(0, tx - 3), min(wa - 1, tx + 3)
                y0, y1 = max(0, ty - 3), min(ha - 1, ty + 3)
                gx = soft[ty, x1] - soft[ty, x0]
                gy = soft[y1, tx] - soft[y0, tx]
                nx, ny, nz = -gx, gy, 0.0
                ln = math.sqrt(nx * nx + ny * ny)
                if ln < 1e-6:
                    nx, ny = -ux, -uy
                    ln = math.sqrt(nx * nx + ny * ny) + 1e-9
                nx, ny = nx / ln, ny / ln
            # Into the world, to light it
            wx = R[0, 0] * nx + R[0, 1] * ny + R[0, 2] * nz
            wy = R[1, 0] * nx + R[1, 1] * ny + R[1, 2] * nz
            wz = R[2, 0] * nx + R[2, 1] * ny + R[2, 2] * nz
            vl = math.sqrt(dx * dx + dy * dy + dz * dz)
            vx, vy, vz = -dx / vl, -dy / vl, -dz / vl
            if wx * vx + wy * vy + wz * vz < 0:
                wx, wy, wz = -wx, -wy, -wz
            diff = max(0.0, wx * light[0] + wy * light[1] + wz * light[2])
            hx, hy, hz = light[0] + vx, light[1] + vy, light[2] + vz
            hl = math.sqrt(hx * hx + hy * hy + hz * hz) + 1e-9
            spec = max(0.0, (wx * hx + wy * hy + wz * hz) / hl) ** 40
            shade = 0.28 + 0.85 * diff
            if not face:
                shade *= 0.8
            elif uz < 0:
                shade *= 0.8                       # the back
            for k in range(3):
                v = tex[ty, tx, k] * shade + 255.0 * spec * (0.35 if face else 0.15)
                out[i, j, k] = min(255.0, v)


def rotation(theta: float, nod: float) -> np.ndarray:
    cy, sy, cx, sx = math.cos(theta), math.sin(theta), math.cos(nod), math.sin(nod)
    ry = np.array([[cy, 0, sy], [0, 1, 0], [-sy, 0, cy]])
    rx = np.array([[1, 0, 0], [0, cx, -sx], [0, sx, cx]])
    return (ry @ rx).astype(np.float64)


def make(name: str, fonts: Path, out_dir: Path, frames: int | None = None):
    art = ARTS[name](fonts)
    a = np.asarray(art, np.float32)
    tex = np.ascontiguousarray(a[..., :3])
    alpha = np.ascontiguousarray(a[..., 3] / 255.0)
    soft = cv2.GaussianBlur(alpha, (0, 0), 2.5)
    f = EYE_W * SHOW * CAM_D / ART_W * SS
    light = np.array([-0.35, 0.45, -0.82])
    light /= np.linalg.norm(light)
    n = frames or SECONDS * FPS
    out_dir.mkdir(exist_ok=True)
    path = out_dir / f"{name}.mp4"
    ff = subprocess.Popen(
        ["ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{EYE_W * 2}x{EYE_H}",
         "-r", str(FPS), "-i", "-", "-c:v", "libx264", "-preset", "slow", "-crf", "18", "-pix_fmt", "yuv420p",
         "-g", str(FPS), "-movflags", "+faststart", str(path)], stdin=subprocess.PIPE)
    buf = np.zeros((EYE_H * SS, EYE_W * SS, 3), np.float32)
    for k in range(n):
        th = 2 * math.pi * k / n
        R = rotation(th, 0.14 * math.sin(2 * th + 1.0))
        eyes = []
        for ex in (-EYE_OFFSET, EYE_OFFSET):
            buf[:] = 0
            render(buf, tex, alpha, soft, R, ex, CAM_D, f, SLAB, light)
            lit = cv2.GaussianBlur(buf, (0, 0), 14 * SS)
            img = np.minimum(buf + 0.45 * lit, 255.0)
            eyes.append(cv2.resize(img, (EYE_W, EYE_H), interpolation=cv2.INTER_AREA))
        frame = np.concatenate(eyes, axis=1).astype(np.uint8)
        ff.stdin.write(frame.tobytes())
        if k % 30 == 0:
            print(f"{name}: {k}/{n}", flush=True)
    ff.stdin.close()
    ff.wait()
    print(f"wrote {path} ({path.stat().st_size // 1024} KB)")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--fonts", required=True, type=Path)
    p.add_argument("--frames", type=int, help="fewer frames, for a try")
    p.add_argument("--out", type=Path, default=HERE / "builtin")
    p.add_argument("--art", action="store_true", help="just save the flat pictures")
    p.add_argument("names", nargs="*", choices=[*ARTS, []] if False else None)
    a = p.parse_args()
    for name in a.names or ARTS:
        if a.art:
            ARTS[name](a.fonts).save(a.out / f"{name}_art.png")
        else:
            make(name, a.fonts, a.out, a.frames)


if __name__ == "__main__":
    main()
