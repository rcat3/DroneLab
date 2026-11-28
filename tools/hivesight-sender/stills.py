"""Still images as the Vessel's picture: an image placed in each eye with a
zoom and a position, as a program frame (both eyes side by side, I420).
No GStreamer: the frame is made once whenever the zoom or position changes."""
from __future__ import annotations

from pathlib import Path

import numpy as np
from PIL import Image

IMAGE_EXTS = {".png", ".jpg", ".jpeg", ".webp", ".bmp", ".gif", ".tif", ".tiff"}
MAX_SIDE = 6000     # bigger images are shrunk on loading


def load(path: Path) -> Image.Image:
    im = Image.open(path)
    im.seek(0)      # a GIF's first frame
    im = im.convert("RGB")
    if max(im.size) > MAX_SIDE:
        s = MAX_SIDE / max(im.size)
        im = im.resize((max(1, int(im.width * s)), max(1, int(im.height * s))), Image.LANCZOS)
    return im


def eye_regions(layout: str, w: int, h: int):
    """The part of a w x h source each eye sees, as (x, y, w, h), and whether
    it's stretched to fill the eye (the half layouts are squeezed)."""
    if layout in ("sbs", "hsbs"):
        half = w // 2
        return (0, 0, half, h), (half, 0, half, h), layout == "hsbs"
    if layout in ("tb", "htb"):
        half = h // 2
        return (0, 0, w, half), (0, half, w, half), layout == "htb"
    return (0, 0, w, h), (0, 0, w, h), False


def render_eye(im: Image.Image, region, stretch: bool, eye_w: int, eye_h: int,
               zoom: float, px: float, py: float) -> Image.Image:
    """One eye: [region] of [im] fitted into the eye (zoom 1: all of it
    showing), magnified by [zoom] about the middle, and moved by [px], [py]
    in -1..1: at either end the picture's edge is at the eye's."""
    x0, y0, rw, rh = region
    zoom = max(0.05, min(zoom, 40.0))
    if stretch:
        sx, sy = eye_w / rw * zoom, eye_h / rh * zoom
    else:
        sx = sy = min(eye_w / rw, eye_h / rh) * zoom
    dw, dh = rw * sx, rh * sy                    # the region as drawn
    # Where its top left lands in the eye: centred, then moved
    tx = (eye_w - dw) / 2 + max(-1.0, min(px, 1.0)) * abs(dw - eye_w) / 2
    ty = (eye_h - dh) / 2 + max(-1.0, min(py, 1.0)) * abs(dh - eye_h) / 2
    out = Image.new("RGB", (eye_w, eye_h))
    # The part of the eye the picture covers, and what of the source is under it
    cx0, cy0 = max(0, int(np.floor(tx))), max(0, int(np.floor(ty)))
    cx1, cy1 = min(eye_w, int(np.ceil(tx + dw))), min(eye_h, int(np.ceil(ty + dh)))
    if cx1 <= cx0 or cy1 <= cy0:
        return out
    ux0, uy0 = x0 + (cx0 - tx) / sx, y0 + (cy0 - ty) / sy
    ux1, uy1 = x0 + (cx1 - tx) / sx, y0 + (cy1 - ty) / sy
    ux0, uy0 = max(x0, ux0), max(y0, uy0)
    ux1, uy1 = min(x0 + rw, ux1), min(y0 + rh, uy1)
    if ux1 - ux0 < 1e-3 or uy1 - uy0 < 1e-3:
        return out
    part = im.resize((cx1 - cx0, cy1 - cy0), Image.BILINEAR if zoom > 1 else Image.LANCZOS,
                     box=(ux0, uy0, ux1, uy1))
    out.paste(part, (cx0, cy0))
    return out


def render_program(im: Image.Image, layout: str, eye_w: int, eye_h: int,
                   zoom: float = 1.0, px: float = 0.0, py: float = 0.0) -> np.ndarray:
    """RGB program frame (eye_h x 2 eye_w x 3, uint8) with the image in both eyes."""
    left, right, stretch = eye_regions(layout, im.width, im.height)
    frame = Image.new("RGB", (eye_w * 2, eye_h))
    frame.paste(render_eye(im, left, stretch, eye_w, eye_h, zoom, px, py), (0, 0))
    if right == left:
        frame.paste(frame.crop((0, 0, eye_w, eye_h)), (eye_w, 0))
    else:
        frame.paste(render_eye(im, right, stretch, eye_w, eye_h, zoom, px, py), (eye_w, 0))
    return np.asarray(frame)


def solid(rgb: int, w: int, h: int) -> np.ndarray:
    a = np.empty((h, w, 3), np.uint8)
    a[..., 0], a[..., 1], a[..., 2] = (rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255
    return a


def to_i420(rgb: np.ndarray) -> bytes:
    """BT.601 limited-range I420 (what the encoder takes) from an RGB frame
    with even sides."""
    f = rgb.astype(np.float32)
    r, g, b = f[..., 0], f[..., 1], f[..., 2]
    y = 16 + 0.257 * r + 0.504 * g + 0.098 * b
    u = 128 - 0.148 * r - 0.291 * g + 0.439 * b
    v = 128 + 0.439 * r - 0.368 * g - 0.071 * b
    h, w = y.shape

    def half(c):
        return c.reshape(h // 2, 2, w // 2, 2).mean(axis=(1, 3))

    out = np.concatenate([np.clip(y, 0, 255).astype(np.uint8).ravel(),
                          np.clip(half(u), 0, 255).astype(np.uint8).ravel(),
                          np.clip(half(v), 0, 255).astype(np.uint8).ravel()])
    return out.tobytes()


def i420_to_jpeg(data, w: int, h: int, step: int = 4, quality: int = 70) -> bytes:
    """A small JPEG of an I420 frame (every [step]th pixel), for the Guide's look at it."""
    import io
    buf = np.frombuffer(data, np.uint8)
    y = buf[: w * h].reshape(h, w)[::step, ::step].astype(np.float32)
    cw, ch = w // 2, h // 2
    u = buf[w * h: w * h + cw * ch].reshape(ch, cw)
    v = buf[w * h + cw * ch: w * h + 2 * cw * ch].reshape(ch, cw)
    s2 = max(1, step // 2)
    u = np.repeat(np.repeat(u[::s2, ::s2], 1, axis=0), 1, axis=1).astype(np.float32)[: y.shape[0], : y.shape[1]]
    v = v[::s2, ::s2].astype(np.float32)[: y.shape[0], : y.shape[1]]
    yy = (y - 16) * 1.164
    r = yy + 1.596 * (v - 128)
    g = yy - 0.392 * (u - 128) - 0.813 * (v - 128)
    b = yy + 2.017 * (u - 128)
    rgb = np.clip(np.stack([r, g, b], axis=-1), 0, 255).astype(np.uint8)
    out = io.BytesIO()
    Image.fromarray(rgb).save(out, "JPEG", quality=quality)
    return out.getvalue()
