#!/usr/bin/env python3
"""Read the battery log back from a board, over USB.

The boards log their battery all the time, and learn their own discharge
curve from a run that goes from full to flat. This reads the log, to see it,
or to make the default curve for a board model: charge the battery until the
charger stops, unplug USB, and leave the board running until it switches off
or stops responding. Then, within ten minutes of plugging it back in (after
that, the next run's log replaces it), run, for example:

    tools/battery_log.py rp2350
    tools/battery_log.py esp32 --port /dev/ttyACM0

It prints the log, and writes it to battery_log.csv (--csv to change). It also
prints the discharge curve it shows, as a table for the board's
rcat_hal_battery_curve: the board draws about the same all the time, so the
share of the run left is the share of the charge left. It finds the run the
same way the board does (see core/app/battery_log.c).

The RP2040 and RP2350 boards are read with picotool, which restarts the board
to read it. The ESP32 boards are read with esptool, from ESP-IDF's
environment. --file reads a log saved earlier instead.
"""

import argparse
import os
import shutil
import struct
import subprocess
import sys
import tempfile

LOG_SIZE = 4096
LOG_MAGIC = 0x474F4C42
LOG_VERSIONS = (1, 2)
FLAG_CHARGING = 0x01
FLAG_GAUGE = 0x02

# Where each board keeps its log: the RP boards in the sector before the
# settings, at the end of flash (see platforms/pico/boards/touch_lcd_1_28/
# hal_board.c), and the ESP32 boards in the batlog partition.
SECTOR = 4096
PICO_LOG = {
    "rp2040": 0x10000000 + 2 * 1024 * 1024 - 2 * SECTOR,
    "rp2350": 0x10000000 + 4 * 1024 * 1024 - 2 * SECTOR,
}
ESP_LOG = 0xE12000


def read_pico(board, path):
    start = PICO_LOG[board]
    subprocess.run(["picotool", "save", "-r", hex(start), hex(start + LOG_SIZE), "-f", path], check=True)


def read_esp(port, path):
    tool = shutil.which("esptool.py") or shutil.which("esptool")
    cmd = [tool] if tool else [sys.executable, "-m", "esptool"]
    if port:
        cmd += ["-p", port]
    cmd += ["--chip", "esp32s3", "read_flash", hex(ESP_LOG), hex(LOG_SIZE), path]
    subprocess.run(cmd, check=True)


def parse(data):
    magic, version, interval, count, _, sequence = struct.unpack_from("<IHHHHI", data, 0)
    if magic != LOG_MAGIC:
        sys.exit("There's no battery log on the board. Start one from its Battery Log settings page.")
    if version not in LOG_VERSIONS:
        sys.exit(f"The log is version {version}, and this reads versions {LOG_VERSIONS}.")
    entries = []
    for i in range((LOG_SIZE - 16) // 4 if version >= 2 else count):
        mv, gauge, flags = struct.unpack_from("<HBB", data, 16 + 4 * i)
        if version >= 2 and mv == 0xFFFF:
            break
        entries.append((mv / 1000.0, gauge if flags & FLAG_GAUGE else None, bool(flags & FLAG_CHARGING)))
    return interval, entries


# What makes a run, as core/app/battery_log.c finds it. Near empty, the
# board's 3.3 V supply can't keep up, and the reading stops following the
# battery: it sits flat until the board stops.
FLAT_MV = 5         # within this of the lowest
MIN_FLAT = 10       # for at least this many entries
RISE_MV = 8         # a rise of more than this between entries is charging


def find_run(entries):
    """(start, end, flat): the run from full to flat, as entries[start:end],
    and how many entries it sat flat for after it."""
    mv = [round(v * 1000) for v, _, _ in entries]
    charging = [c for _, _, c in entries]
    low = min(range(len(mv)), key=lambda i: (mv[i], i))
    flat = 0
    while flat < low and mv[low - flat - 1] <= mv[low] + FLAT_MV:
        flat += 1
    end = low - flat if flat + 1 >= MIN_FLAT else low + 1
    start = end - 1
    while start > 0 and not charging[start] and not charging[start - 1] and mv[start] <= mv[start - 1] + RISE_MV:
        start -= 1
    while start + 1 < end and mv[start] <= mv[start + 1]:
        start += 1
    if flat + 1 < MIN_FLAT:
        return start, end, 0
    after = low + 1     # still flat after its lowest
    while after < len(mv) and abs(mv[after] - mv[low]) <= FLAT_MV:
        after += 1
    return start, end, after - end


def curve(entries):
    """[volts, percent] every 5%, from 100% at the start to 0% at the end."""
    n = len(entries)
    points = []
    for percent in range(100, -1, -5):
        # Entry i is the average over the i-th interval, so its middle is at
        # (i + 0.5) / n of the run.
        t = (100 - percent) / 100 * n - 0.5
        i = min(max(int(t), 0), n - 1)
        j = min(i + 1, n - 1)
        f = min(max(t - i, 0.0), 1.0)
        points.append((entries[i][0] + f * (entries[j][0] - entries[i][0]), percent))
    return points


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("board", choices=["rp2040", "rp2350", "esp32"], nargs="?",
                        help="the board to read it from")
    parser.add_argument("--port", help="the ESP32 board's serial port")
    parser.add_argument("--file", help="read a log saved earlier, instead of a board")
    parser.add_argument("--save", help="also keep the raw log in this file")
    parser.add_argument("--csv", default="battery_log.csv", help="where to write the log as CSV")
    args = parser.parse_args()

    if args.file:
        with open(args.file, "rb") as f:
            data = f.read()
    else:
        if not args.board:
            parser.error("say which board to read, or give --file")
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "battery_log.bin")
            if args.board == "esp32":
                read_esp(args.port, path)
            else:
                read_pico(args.board, path)
            with open(path, "rb") as f:
                data = f.read()
        if args.save:
            with open(args.save, "wb") as f:
                f.write(data)

    interval, entries = parse(data)
    if not entries:
        sys.exit("The log was started, but has nothing in it yet: it records once a minute.")

    with open(args.csv, "w") as f:
        f.write("minutes,volts,gauge_percent,charging\n")
        for i, (volts, gauge, charging) in enumerate(entries):
            f.write(f"{(i + 1) * interval / 60:g},{volts:.3f},{'' if gauge is None else gauge},{int(charging)}\n")

    minutes = len(entries) * interval / 60
    print(f"{len(entries)} readings, one every {interval / 60:g} min, over {minutes // 60:.0f} h {minutes % 60:02.0f} min")
    print(f"Started at {entries[0][0]:.3f} V, ended at {entries[-1][0]:.3f} V")
    if any(c for _, _, c in entries):
        print("It was charging for some of it, so the curve below is off: unplug USB before starting the log.")
    print(f"Wrote {args.csv}")
    print()
    start, end, flat = find_run(entries)
    if start > 0:
        print(f"The run starts {start * interval / 60:g} min in, after it was last charging.")
    if flat:
        print(f"For {flat * interval / 60:g} min at the end, the reading sat at about {entries[end][0]:.3f} V, as the")
        print("board's supply couldn't keep up. The curve ends where that starts, so 0% leaves that time in hand.")
    else:
        print("It didn't end flat, so it may not have run all the way down.")
    entries = entries[start:end]
    print()
    print("The curve, for the board's rcat_hal_battery_curve:")
    points = curve(entries)
    for k in range(0, len(points), 5):
        print("    " + " ".join(f"{{ {v:.3f}f, {p} }}," for v, p in points[k:k + 5]))


if __name__ == "__main__":
    main()
