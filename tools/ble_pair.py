#!/usr/bin/env python3
"""Pair this computer with a DroneLab board, over Bluetooth, for
tools/ble_record.py and tools/comm_bridge.py. Linux (BlueZ); on Windows and
macOS, pair it in the system's Bluetooth settings instead.

    python3 tools/ble_pair.py
    python3 tools/ble_pair.py --board DroneLab-ABCD

First, on the board: Settings, Paired Phones, Pair a phone (a new phone or
computer can only pair for a couple of minutes after that), and disconnect
the app on your phone, so the board's free.

It finds the boards nearby, pairs with the one you pick, asks you for the
6-digit code the board shows, and disconnects at the end, so the board's
free for the next thing. It does once what can otherwise be done in
bluetoothctl by hand:

    agent KeyboardDisplay, default-agent, scan on, pair <address>,
    the code, disconnect <address>

Needs bleak (pip install bleak), to find the boards.
"""

import argparse
import asyncio
import os
import pty
import re
import select
import subprocess
import sys
import time

from bleak import BleakScanner

SERVICE_UUID = "efe06e1b-a7ff-4823-bfbb-b3a82ea05849"
ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]|\x01|\x02")


async def find_boards(seconds):
    """The boards advertising nearby, strongest first, as (address, name, rssi)."""
    found = {}

    def seen(device, ad):
        if SERVICE_UUID in [u.lower() for u in ad.service_uuids]:
            found[device.address] = (device.address, device.name or ad.local_name or device.address, ad.rssi)

    async with BleakScanner(seen):
        await asyncio.sleep(seconds)
    return sorted(found.values(), key=lambda b: -b[2])


class Bluetoothctl:
    """bluetoothctl, driven as if typed into, so its pairing agent asks for
    the code here."""

    def __init__(self):
        self.master, slave = pty.openpty()
        self.proc = subprocess.Popen(["bluetoothctl"], stdin=slave, stdout=slave, stderr=slave, close_fds=True)
        os.close(slave)
        self.text = ""

    def send(self, line):
        os.write(self.master, (line + "\n").encode())

    def read(self, timeout):
        """What it says over the next while, or until it's quiet."""
        end = time.monotonic() + timeout
        got = ""
        while time.monotonic() < end:
            ready, _, _ = select.select([self.master], [], [], 0.2)
            if not ready:
                if got:
                    break
                continue
            try:
                chunk = os.read(self.master, 4096).decode(errors="replace")
            except OSError:
                break
            got += ANSI.sub("", chunk)
        self.text += got
        return got

    def wait_for(self, patterns, timeout):
        """Read until one of patterns turns up: which, or None."""
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            self.read(0.5)
            for p in patterns:
                if p in self.text:
                    return p
        return None

    def close(self):
        try:
            self.send("quit")
            self.proc.wait(timeout=3)
        except Exception:
            self.proc.kill()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--board", help="the board's name, e.g. DroneLab-ABCD (default: pick from those found)")
    args = parser.parse_args()
    if sys.platform != "linux":
        print("This is for Linux. On Windows and macOS, pair the board in the system's Bluetooth settings.")
        return 1

    input("On the board: Settings, Paired Phones, Pair a phone. Disconnect the app on your phone.\n"
          "Then press Enter here... ")
    print("Looking for boards...")
    boards = asyncio.run(find_boards(8))
    if args.board:
        boards = [b for b in boards if b[1] == args.board]
    if not boards:
        print("No board found. Is the Phone App on, and the app on your phone disconnected?")
        return 1
    if len(boards) == 1:
        address, name, _ = boards[0]
    else:
        for i, (address, name, rssi) in enumerate(boards, 1):
            print(f"  {i}. {name} ({address}), {rssi} dBm")
        pick = input("Which one? ")
        if not pick.isdigit() or not 1 <= int(pick) <= len(boards):
            return 1
        address, name, _ = boards[int(pick) - 1]

    print(f"Pairing with {name} ({address})...")
    ctl = Bluetoothctl()
    try:
        ctl.read(1)
        for line in ("agent KeyboardDisplay", "default-agent"):
            ctl.send(line)
            ctl.read(1)
        ctl.send(f"remove {address}")      # any old pairing, which the board's likely forgotten
        ctl.read(2)
        ctl.send("scan on")
        ctl.wait_for([address], 10)
        ctl.send("scan off")
        ctl.read(1)
        ctl.text = ""
        ctl.send(f"pair {address}")
        got = ctl.wait_for(["Enter passkey", "Failed to pair", "not available"], 30)
        if got != "Enter passkey":
            print("The board didn't ask for a code. Is pairing open on the board (Pair a phone)?")
            if got:
                print(f"bluetoothctl said: {got}")
            return 1
        code = input("Type the code the board shows: ").strip().replace(" ", "")
        ctl.text = ""
        ctl.send(code)
        got = ctl.wait_for(["Pairing successful", "Failed to pair", "AuthenticationFailed", "AuthenticationCanceled"],
                           30)
        if got != "Pairing successful":
            print(f"Pairing didn't work ({got or 'no answer'}). Was the code right? Try again.")
            return 1
        ctl.send(f"trust {address}")
        ctl.read(1)
        ctl.send(f"disconnect {address}")   # so the board's free, and advertising again
        ctl.read(2)
        print(f"Paired with {name}. tools/ble_record.py can use it now.")
        return 0
    finally:
        ctl.close()


if __name__ == "__main__":
    sys.exit(main())
