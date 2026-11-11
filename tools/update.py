#!/usr/bin/env python3
"""Update an ESP32 board's firmware over WiFi.

On the board, go to Settings, Firmware Update, and switch it on. It shows a
six digit code, and the hotspot's name and password. Join the hotspot from
this computer, then run, for example:

    tools/update.py build-s3-146/dronelab.bin 123456

It checks the firmware is for the board, sends it, and the board restarts into
it. If the new firmware doesn't start properly, the board goes back to the old
one the next time it's restarted.

This has nothing to do with the phone remote's page, and only works while the
board's Firmware Update page has updates switched on.
"""

import argparse
import http.client
import os
import re
import sys

BOARD_ADDRESS = "192.168.4.1"   # RCAT_HAL_HOTSPOT_ADDRESS in core/include/hal.h
UPDATE_PORT = 8070              # UPDATE_PORT in core/app/updater.h
MARKER = re.compile(rb"rcat-board:([A-Za-z0-9_]+)\0")
CHUNK = 16 * 1024


def request(host, method, path, code, headers=None, body=None, timeout=30):
    conn = http.client.HTTPConnection(host, UPDATE_PORT, timeout=timeout)
    all_headers = {"X-Update-Code": code}
    all_headers.update(headers or {})
    try:
        conn.request(method, path, body=body, headers=all_headers)
        response = conn.getresponse()
        return response.status, response.read().decode(errors="replace").strip()
    except OSError as e:
        sys.exit(f"Couldn't reach the board at {host}:{UPDATE_PORT} ({e}). Is this computer on its hotspot, "
                 "and are updates switched on on its Firmware Update page?")
    finally:
        conn.close()


class Progress:
    """The firmware, read in pieces, showing how far it's got."""

    def __init__(self, data):
        self.data = data
        self.sent = 0

    def __iter__(self):
        while self.sent < len(self.data):
            piece = self.data[self.sent:self.sent + CHUNK]
            self.sent += len(piece)
            print(f"\rSending  {self.sent * 100 // len(self.data):3d}%", end="", flush=True)
            yield piece
        print()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("firmware", help="the .bin file, e.g. build-s3-146/dronelab.bin")
    parser.add_argument("code", help="the code on the board's Firmware Update page")
    parser.add_argument("--host", default=BOARD_ADDRESS, help="the board's address")
    args = parser.parse_args()

    with open(args.firmware, "rb") as f:
        data = f.read()
    if not data or data[0] != 0xE9:
        sys.exit(f"{args.firmware} isn't an ESP32 firmware image. Use the .bin from the build folder.")
    boards = set(m.group(1).decode() for m in MARKER.finditer(data))
    if len(boards) != 1:
        sys.exit(f"Can't tell which board {args.firmware} is for. Was it built from this version of the code?")
    firmware_board = boards.pop()

    status, text = request(args.host, "GET", "/info", args.code, timeout=10)
    if status != 200:
        sys.exit(f"The board said: {text}")
    info = dict(line.partition("=")[::2] for line in text.splitlines())
    board = info.get("board", "")
    if board != firmware_board:
        sys.exit(f"The firmware is for {firmware_board}, but the board is {board}.")
    battery, min_battery = int(info.get("battery", -1)), int(info.get("min_battery", 0))
    if 0 <= battery < min_battery:
        sys.exit(f"The board's battery is at {battery}%, and it needs {min_battery}% to update. Charge it first.")

    print(f"Updating the {board} with {os.path.basename(args.firmware)}, {len(data) / 1024 / 1024:.1f} MB")
    status, text = request(args.host, "POST", "/update", args.code,
                           headers={"X-Update-Board": firmware_board, "Content-Length": str(len(data)),
                                    "Content-Type": "application/octet-stream"},
                           body=Progress(data), timeout=60)
    print(text)
    sys.exit(0 if status == 200 else 1)


if __name__ == "__main__":
    main()
