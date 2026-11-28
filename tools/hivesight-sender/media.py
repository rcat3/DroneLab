"""Media-file helpers: listing, probing, and guessing the stereo layout."""
from __future__ import annotations

import json
import math
import subprocess
import sys
from dataclasses import asdict, dataclass
from pathlib import Path

import gi

gi.require_version("Gst", "1.0")
gi.require_version("GstPbutils", "1.0")
from gi.repository import Gst, GstPbutils  # noqa: E402

VIDEO_EXTS = {".mp4", ".mkv", ".mov", ".webm", ".avi", ".m4v", ".ts", ".mts", ".m2ts", ".wmv", ".flv", ".mpg", ".mpeg"}

# Largest frame we'll encode; bigger files are scaled down (keeping aspect).
MAX_W, MAX_H = 2560, 1440

# Layouts understood by the phone:
#   mono  - one image, shown to both eyes
#   sbs   - full side-by-side (each eye is half the width at its true aspect)
#   hsbs  - half side-by-side (each eye squeezed horizontally to half width)
#   tb    - full top-bottom (left eye on top)
#   htb   - half top-bottom (each eye squeezed vertically)
LAYOUTS = ("mono", "sbs", "hsbs", "tb", "htb")


@dataclass
class MediaInfo:
    path: Path
    width: int
    height: int
    fps: float
    duration_s: float
    has_audio: bool

    @property
    def nominal_fps(self) -> int:
        """Frame rate for encoder settings. Variable-frame-rate files (CCTV, phones)
        can report nonsense like 1000 fps; clamp so keyframe spacing stays sane."""
        return int(min(60, max(1, round(self.fps))))

    @property
    def encode_size(self) -> tuple[int, int]:
        s = min(1.0, MAX_W / self.width, MAX_H / self.height)
        w = int(self.width * s) // 2 * 2
        h = int(self.height * s) // 2 * 2
        return max(w, 2), max(h, 2)


def list_media(folder: Path) -> list[str]:
    if not folder.is_dir():
        return []
    return sorted(
        (str(p.relative_to(folder)) for p in folder.rglob("*")
         if p.is_file() and p.suffix.lower() in VIDEO_EXTS and not p.name.startswith(".")),
        key=str.lower)


def list_images(folder: Path) -> list[str]:
    import stills
    if not folder.is_dir():
        return []
    return sorted(
        (str(p.relative_to(folder)) for p in folder.rglob("*")
         if p.is_file() and p.suffix.lower() in stills.IMAGE_EXTS and not p.name.startswith(".")),
        key=str.lower)


def resolve(folder: Path, name: str) -> Path | None:
    """Resolve a console-supplied name, refusing anything outside the media folder."""
    try:
        p = (folder / name).resolve(strict=True)
        if not Path(name).is_absolute():        # a file picked from anywhere is the Guide's to play
            p.relative_to(folder.resolve())
    except (OSError, ValueError):
        return None
    return p if p.is_file() else None


def probe(path: Path, timeout_s: int = 8) -> MediaInfo:
    """Probe in a child process. GstDiscoverer's synchronous mode iterates the
    default GLib main context, which deadlocks the sender's GLib loop thread if
    called while that loop is running, so it is kept out of the sender process."""
    out = subprocess.run([sys.executable, __file__, str(path)], capture_output=True, text=True,
                         timeout=timeout_s + 5)
    if out.returncode != 0:
        raise ValueError((out.stderr.strip().splitlines() or ["probe failed"])[-1])
    d = json.loads(out.stdout)
    d["path"] = Path(d["path"])
    return MediaInfo(**d)


def _probe_here(path: Path, timeout_s: int = 8) -> MediaInfo:
    d = GstPbutils.Discoverer.new(timeout_s * Gst.SECOND)
    info = d.discover_uri(path.resolve().as_uri())
    vids = info.get_video_streams()
    if not vids:
        raise ValueError(f"{path.name}: no video stream")
    v = vids[0]
    num, den = v.get_framerate_num(), v.get_framerate_denom()
    fps = num / den if num and den else 30.0
    dur = info.get_duration()
    return MediaInfo(
        path=path, width=v.get_width(), height=v.get_height(), fps=fps,
        duration_s=dur / Gst.SECOND if dur and dur != Gst.CLOCK_TIME_NONE else 0.0,
        has_audio=bool(info.get_audio_streams()),
    )


def guess_layout(name: str, width: int, height: int) -> str:
    n = name.lower().replace("_", "-").replace(".", "-").replace(" ", "-")
    tags = set(n.split("-"))
    aspect = width / height if height else 1.0
    if tags & {"hsbs", "halfsbs", "h-sbs"} or "half-sbs" in n:
        return "hsbs"
    if tags & {"htb", "hou", "halfou", "halftb"} or "half-ou" in n or "half-tb" in n:
        return "htb"
    if tags & {"sbs", "lr", "3d", "sidebyside"} or "side-by-side" in n:
        return "sbs" if aspect >= 2.5 else "hsbs"
    if tags & {"tb", "ou", "overunder", "topbottom"} or "over-under" in n or "top-bottom" in n:
        return "tb" if aspect < 1.2 else "htb"
    if aspect >= 3.0:      # two 16:9 eyes next to each other
        return "sbs"
    if aspect <= 0.95:     # two 16:9 eyes stacked
        return "tb"
    return "mono"


def fmt_time(s: float) -> str:
    if not s or math.isnan(s):
        return "0:00"
    s = int(s)
    return f"{s // 3600}:{s // 60 % 60:02d}:{s % 60:02d}" if s >= 3600 else f"{s // 60}:{s % 60:02d}"


if __name__ == "__main__":
    Gst.init(None)
    info = asdict(_probe_here(Path(sys.argv[1])))
    info["path"] = str(info["path"])
    print(json.dumps(info))
