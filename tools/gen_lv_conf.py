#!/usr/bin/env python3
"""
Generate the lv_conf.h files for each platform from the LVGL submodule's
lv_conf_template.h, with this project's settings applied.

Run it after moving the LVGL submodule to a new version:
    python3 tools/gen_lv_conf.py
"""

import os
import re
import sys

REPO = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
TEMPLATE = os.path.join(REPO, "third_party", "lvgl", "lv_conf_template.h")

# Settings for every platform
COMMON = {
    "LV_USE_STDLIB_MALLOC": ("LV_STDLIB_CLIB", "C library malloc (can use PSRAM on the ESP32)"),
    "LV_DEF_REFR_PERIOD": ("10", "refresh often, for smooth swiping"),
    "LV_USE_GIF": ("1", "animated GIFs"),
}

# The images and sounds every platform reads (the SD card on the ESP32)
FILES = {
    "LV_USE_FS_STDIO": ("1", "SD card files, drive letter S"),
    "LV_FS_STDIO_LETTER": ("'S'", None),
    "LV_USE_LODEPNG": ("1", "PNG"),
    "LV_USE_BMP": ("1", "BMP"),
    "LV_USE_LIBJPEG_TURBO": ("1", "JPEG, including progressive JPEG"),
    # Pictures others send, decoded from memory (pictures.c)
    "LV_USE_FS_MEMFS": ("1", "files in memory, drive letter M"),
    "LV_FS_MEMFS_LETTER": ("'M'", None),
}

PLATFORMS = {
    "esp-idf": {
        # LVGL's memory from PSRAM, leaving internal RAM for DMA, WiFi and
        # Bluetooth (see the board's lvgl_mem.c)
        "LV_USE_STDLIB_MALLOC": ("LV_STDLIB_CUSTOM", "PSRAM first (the board's lvgl_mem.c)"),
        "LV_FONT_MONTSERRAT_24": ("1", "for larger screens"),
        "LV_FONT_MONTSERRAT_32": ("1", "for the firmware update screen"),
        **FILES,
        # For joining the phone remote's hotspot
        "LV_USE_QRCODE": ("1", "QR codes"),
    },
    # The virtual unit, on a computer (platforms/host): the same as the
    # boards, with the C library's memory and LVGL's warnings on the terminal
    "host": {
        "LV_FONT_MONTSERRAT_24": ("1", "for larger screens"),
        "LV_FONT_MONTSERRAT_32": ("1", "for the firmware update screen"),
        **FILES,
        "LV_USE_QRCODE": ("1", "QR codes"),
        "LV_USE_LOG": ("1", "warnings, printed on the terminal"),
        "LV_LOG_PRINTF": ("1", None),
    },
}

# What each platform's display does with the picture
FLUSH_NOTES = {
    "esp-idf": "The RGB565 byte swap the panels need is done in the display flush callback.",
    "host": "The window's flush callback turns the RGB565 picture into the screen's pixels.",
}


def generate(platform, settings):
    with open(TEMPLATE) as f:
        text = f.read()

    version = re.search(r"Configuration file for (v[\d.]+)", text).group(1)
    text, n = re.subn(r'^#if 0 /\* Set this to "1" to enable content \*/',
                      '#if 1 /* Set this to "1" to enable content */', text, count=1, flags=re.M)
    assert n == 1, "couldn't find the enable switch"

    notes = []
    for name, (value, note) in {**COMMON, **settings}.items():
        text, n = re.subn(rf"^(\s*#define {name}\s+)\S.*?(\s*(/\*.*)?)$",
                          lambda m: m.group(1) + value + m.group(2), text, count=1, flags=re.M)
        if n != 1:
            sys.exit(f"{name} isn't in the template")
        if note:
            notes.append(f" *   {name} = {value}: {note}")

    header = (f"/**\n * @file lv_conf.h\n"
              f" * LVGL configuration for the {platform} platform, generated from the LVGL\n"
              f" * {version} lv_conf_template.h by tools/gen_lv_conf.py. Edit that script\n"
              f" * rather than this file. Changes from the template:\n"
              + "\n".join(notes) + "\n"
              f" * {FLUSH_NOTES[platform]}\n */\n\n")
    out = os.path.join(REPO, "platforms", platform, "config", "lv_conf.h")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w") as f:
        f.write(header + text)
    print(f"{out}: {version}")


def main():
    for platform, settings in PLATFORMS.items():
        generate(platform, settings)


if __name__ == "__main__":
    main()
