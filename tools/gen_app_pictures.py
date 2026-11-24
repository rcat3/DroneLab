#!/usr/bin/env python3
"""The pictures built into the firmware, for the app to offer others'
displays (HiveMind Control's Display, by name, so they work over direct comms
too): reads core/media/image_list.c, and writes a thumbnail of each to
app/assets/pictures/<name>.png (a GIF's first frame) and the list to
app/lib/comm/built_in_pictures.dart.

Run it after changing image_list.c or imgs/:
    python3 tools/gen_app_pictures.py
"""
import os
import re
import sys

from PIL import Image

REPO = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
LIST = os.path.join(REPO, "core", "media", "image_list.c")
IMGS = os.path.join(REPO, "imgs")
OUT_DIR = os.path.join(REPO, "app", "assets", "pictures")
OUT_DART = os.path.join(REPO, "app", "lib", "comm", "built_in_pictures.dart")
THUMB = 160


def built_in():
    """The names in the list, in order, but those inside #if
    RCAT_LARGE_IMAGES: the 1.75" board leaves them out (it keeps them for the
    SD card), so another unit mightn't have them."""
    text = open(LIST).read()
    body = text[text.index("builtin_images[] = {"):]
    body = re.sub(r"#if RCAT_LARGE_IMAGES.*?#endif", "", body, flags=re.S)
    return re.findall(r"IMAGE\((\w+)\s*,\s*(true|false)\)", body)


def source(name):
    for f in os.listdir(IMGS):
        stem, _ = os.path.splitext(f)
        if re.sub(r"[^A-Za-z0-9_]", "_", stem) == name:
            return os.path.join(IMGS, f)
    sys.exit(f"no picture in imgs/ for {name}")


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    names = []
    for name, gif in built_in():
        im = Image.open(source(name))
        im.seek(0)
        im = im.convert("RGBA")
        im.thumbnail((THUMB, THUMB), Image.LANCZOS)
        square = Image.new("RGBA", (THUMB, THUMB), (0, 0, 0, 255))
        square.alpha_composite(im, ((THUMB - im.width) // 2, (THUMB - im.height) // 2))
        square.convert("RGB").save(os.path.join(OUT_DIR, name + ".png"), optimize=True)
        names.append((name, gif == "true"))
    with open(OUT_DART, "w") as f:
        f.write("// Made by tools/gen_app_pictures.py from core/media/image_list.c: don't edit.\n\n")
        f.write("/// A picture built into the unit's firmware, by its name, with its\n")
        f.write("/// thumbnail in assets/pictures/.\n")
        f.write("class BuiltInPicture {\n  final String name;\n  final bool animated;\n")
        f.write("  const BuiltInPicture(this.name, this.animated);\n\n")
        f.write("  String get thumbnail => 'assets/pictures/$name.png';\n}\n\n")
        f.write("const builtInPictures = [\n")
        for name, gif in names:
            f.write(f"  BuiltInPicture('{name}', {'true' if gif else 'false'}),\n")
        f.write("];\n")
    print(f"{len(names)} pictures: {', '.join(n for n, _ in names)}")


if __name__ == "__main__":
    main()
