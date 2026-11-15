#!/usr/bin/env python3
"""Record the board's voice effect on this computer over Bluetooth, as the
DroneLab app's Record tab does, for videos and the like. The computer stays
on its own network: there's no hotspot to join, as with the Voice Lab.

Switch on the Phone App on the board (Settings), then:

    python3 tools/ble_record.py                     # record until Enter
    python3 tools/ble_record.py --beep --take intro # a sync beep, to intro.wav
    python3 tools/ble_record.py --play              # hear it while it records
    python3 tools/ble_record.py --device "CABLE Input" --no-record
                                                    # a microphone for video calls

It records the speaker's voice effect, or with --comm-voice the comm voice
(if the board has one of its own). Files are 48 kHz mono WAVs, named for
when they start unless --take names them, and never written over. With
--beep, the board beeps as it starts and the same beep is in the recording,
for lining it up with video. The board's comms stop while it records.

The board talks to one phone or computer at a time: disconnect the app
first (or the board isn't found: it stops advertising while it's connected).

The computer has to be paired with the board once, as a phone does, with the
code the board shows. On Linux, tools/ble_pair.py does it. On Windows and
macOS, pair it in the system's Bluetooth settings, which ask for the code.
After that it connects by itself.

Played to a virtual audio cable (--device, see --list-devices), the board's
voice can be a video call's microphone, as with the Voice Lab: VB-Audio
Virtual Cable on Windows and macOS, or a PipeWire/PulseAudio null sink on
Linux.

Needs bleak (pip install bleak) and libopus (the libopus0 package on Debian
and Ubuntu; it comes with opus from Homebrew on macOS), and for --play or
--device, numpy and sounddevice.
"""

import argparse
import asyncio
import ctypes
import ctypes.util
import os
import sys
import threading
import time
import wave

from bleak import BleakClient, BleakScanner

SERVICE_UUID = "efe06e1b-a7ff-4823-bfbb-b3a82ea05849"
TO_PHONE_UUID = "efe06e1c-a7ff-4823-bfbb-b3a82ea05849"
FROM_PHONE_UUID = "efe06e1d-a7ff-4823-bfbb-b3a82ea05849"

MSG_STATUS = 0x02
MSG_RECORD = 0x0A           # both ways: start or stop, and what's recorded (core/app/comm.h)
RECORD_SPEAKER = 0x01
RECORD_BEEP = 0x02
FLAG_FIRST = 0x01
FLAG_LAST = 0x02
STATUS_RECORDING = 0x08

RATE = 48000                # what's saved: what video editors expect
PACKET = RATE * 20 // 1000  # samples in a 20 ms packet


class OpusDecoder:
    """libopus, through ctypes, at RATE."""

    def __init__(self):
        name = ctypes.util.find_library("opus") or "libopus.so.0"
        self.lib = ctypes.CDLL(name)
        self.lib.opus_decoder_create.restype = ctypes.c_void_p
        self.lib.opus_decoder_create.argtypes = [ctypes.c_int32, ctypes.c_int, ctypes.POINTER(ctypes.c_int)]
        self.lib.opus_decode.restype = ctypes.c_int
        self.lib.opus_decode.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int32,
                                         ctypes.POINTER(ctypes.c_int16), ctypes.c_int, ctypes.c_int]
        err = ctypes.c_int()
        self.dec = self.lib.opus_decoder_create(RATE, 1, ctypes.byref(err))
        if not self.dec:
            raise RuntimeError(f"opus_decoder_create failed ({err.value})")
        self.buf = (ctypes.c_int16 * (RATE * 120 // 1000))()

    def _decode(self, packet, frames, fec):
        n = self.lib.opus_decode(self.dec, packet, len(packet) if packet else 0, self.buf, frames, 1 if fec else 0)
        return bytes(ctypes.string_at(self.buf, n * 2)) if n > 0 else b""

    def decode(self, packet):
        return self._decode(packet, RATE * 120 // 1000, False)

    def lost(self, count, next_packet):
        """count packets that didn't come: all but the last made up by Opus,
        and the last from next_packet's error correction."""
        out = b""
        for _ in range(count - 1):
            out += self._decode(None, PACKET, False)
        return out + self._decode(next_packet, PACKET, True)


class Player:
    """Plays what comes as it comes, keeping a little in hand to ride out
    Bluetooth's bursts."""

    def __init__(self, device, latency_ms=100):
        import numpy as np
        import sounddevice as sd
        self.np = np
        self.target = RATE * latency_ms // 1000
        self.buffer = np.zeros(0, dtype=np.int16)
        self.lock = threading.Lock()
        self.priming = True
        self.stream = sd.OutputStream(samplerate=RATE, channels=1, dtype="int16", callback=self._callback,
                                      device=device)
        self.stream.start()

    def add(self, pcm):
        with self.lock:
            self.buffer = self.np.concatenate([self.buffer, self.np.frombuffer(pcm, dtype=self.np.int16)])
            if len(self.buffer) > 3 * self.target:
                self.buffer = self.buffer[-self.target:]    # fallen behind: skip ahead

    def _callback(self, out, frames, time_info, status):
        with self.lock:
            if self.priming and len(self.buffer) >= self.target:
                self.priming = False
            if self.priming or len(self.buffer) < frames:
                out.fill(0)
                self.priming = True
                return
            out[:, 0] = self.buffer[:frames]
            self.buffer = self.buffer[frames:]

    def close(self):
        self.stream.stop()
        self.stream.close()


def paired_boards():
    """The DroneLab boards this computer's paired with, as (address, name),
    from bluetoothctl (Linux)."""
    import subprocess
    out = ""
    for cmd in (["bluetoothctl", "devices", "Paired"], ["bluetoothctl", "paired-devices"]):
        try:
            out = subprocess.run(cmd, capture_output=True, text=True, timeout=5).stdout
        except (OSError, subprocess.SubprocessError):
            continue
        if "Device " in out:
            break
    boards = []
    for line in out.splitlines():
        parts = line.split(" ", 2)
        if len(parts) == 3 and parts[0] == "Device" and parts[2].startswith("DroneLab-"):
            boards.append((parts[1], parts[2]))
    return boards


def unique_path(path):
    """path, or path with -2, -3... before the extension if it's taken, so a
    good take is never written over."""
    if not os.path.exists(path):
        return path
    base, ext = os.path.splitext(path)
    n = 2
    while os.path.exists(f"{base}-{n}{ext}"):
        n += 1
    return f"{base}-{n}{ext}"


class Recorder:
    def __init__(self, args):
        self.args = args
        self.decoder = OpusDecoder()
        self.wav = None
        self.path = None
        self.player = None
        self.samples = 0
        self.lost = 0
        self.last_seq = None
        self.recording = False      # as the board says
        self.client = None

    def on_notify(self, _, data):
        if len(data) < 4:
            return
        if data[0] == MSG_STATUS:
            self.recording = bool(data[3] & STATUS_RECORDING)
            return
        if data[0] != MSG_RECORD:
            return
        seq, flags, opus = data[1] | (data[2] << 8), data[3], bytes(data[4:])
        pcm = b""
        if self.last_seq is not None and not flags & FLAG_FIRST and opus:
            gap = ((seq - self.last_seq) & 0xFFFF) - 1
            if 0 < gap < 50:
                self.lost += gap
                pcm += self.decoder.lost(gap, opus)
        self.last_seq = seq
        if opus:
            pcm += self.decoder.decode(opus)
        if not pcm:
            return
        if self.path and not self.wav:
            # Made once there's something to put in it
            self.wav = wave.open(self.path, "wb")
            self.wav.setnchannels(1)
            self.wav.setsampwidth(2)
            self.wav.setframerate(RATE)
        if self.wav:
            self.wav.writeframes(pcm)
        if self.player:
            self.player.add(pcm)
        self.samples += len(pcm) // 2

    async def find_board(self):
        """The board: as it advertises, or else one this computer's paired
        with, freed if this computer's still connected to it, which keeps it
        from advertising (as just after pairing)."""
        if self.args.board and ":" in self.args.board:
            return self.args.board
        if self.args.board:
            print(f"Looking for {self.args.board}...")
            found = await BleakScanner.find_device_by_name(self.args.board, timeout=10)
        else:
            print("Looking for a board with the Phone App on...")
            found = await BleakScanner.find_device_by_filter(
                lambda d, ad: SERVICE_UUID in [u.lower() for u in ad.service_uuids], timeout=10)
        if found:
            return found
        for address, name in paired_boards():
            if not self.args.board or name == self.args.board:
                # Paired, but not advertising: most likely this computer's
                # still connected from before (as after pairing), which
                # keeps it quiet. Let that go, and look again.
                print(f"{name} is paired with this computer: freeing it and looking again...")
                import subprocess
                subprocess.run(["bluetoothctl", "disconnect", address], capture_output=True, timeout=10)
                return await BleakScanner.find_device_by_address(address, timeout=10)
        return None

    async def send(self, *msg):
        """Write to the board. It only takes writes from a computer that's
        paired with it: from one that isn't, the write waits for pairing, so
        it's given up after a while."""
        await asyncio.wait_for(self.client.write_gatt_char(FROM_PHONE_UUID, bytes(msg), response=True), 8)

    async def wait_for_enter(self):
        loop = asyncio.get_running_loop()
        stop = loop.create_future()

        def read():
            sys.stdin.readline()
            loop.call_soon_threadsafe(lambda: stop.done() or stop.set_result(None))

        threading.Thread(target=read, daemon=True).start()
        end = time.monotonic() + self.args.seconds if self.args.seconds else None
        while not stop.done():
            if end and time.monotonic() >= end:
                break
            if not self.client.is_connected:
                print("\nThe board went away")
                break
            secs = self.samples // RATE
            print(f"\r{'Recording' if self.path else 'Playing'} {secs // 60}:{secs % 60:02d}"
                  f"{f', {self.lost} lost and made up' if self.lost else ''}   ", end="", flush=True)
            await asyncio.sleep(0.25)
        print()

    async def run(self):
        if not self.args.no_record:
            name = self.args.take or time.strftime("DroneLab %Y-%m-%d %H.%M.%S")
            if not name.lower().endswith(".wav"):
                name += ".wav"
            self.path = unique_path(os.path.join(self.args.dir, name))
        if self.args.play or self.args.device is not None:
            device = self.args.device
            if device is not None and device.isdigit():
                device = int(device)
            self.player = Player(device)

        try:
            await self.record()
        finally:
            # Finished whatever happens, Ctrl+C included, so the file's whole
            if self.wav:
                self.wav.close()
                secs = self.samples // RATE
                print(f"Saved {self.path} ({secs // 60}:{secs % 60:02d})")
            elif self.path:
                print("Nothing was recorded, so nothing was saved")
            if self.player:
                self.player.close()

    async def record(self):
        device = await self.find_board()
        if device is None:
            print("No board found. Is the Phone App on, the app on the phone disconnected (or it's taken\n"
                  "the board), and this computer paired with it? tools/ble_pair.py pairs it.")
            return
        async with BleakClient(device, timeout=20) as client:
            self.client = client
            print(f"Connected to {getattr(device, 'name', None) or getattr(device, 'address', device)}")
            await client.start_notify(TO_PHONE_UUID, self.on_notify)
            flags = (0 if self.args.comm_voice else RECORD_SPEAKER) | (RECORD_BEEP if self.args.beep else 0)
            try:
                await self.send(MSG_RECORD, 1, flags)
            except Exception as e:
                print(f"The board didn't take the request to record ({type(e).__name__}). Is this computer paired\n"
                      "with it? It has to be, with the code the board shows: see the top of this script.")
                return
            print("Press Enter to stop." if not self.args.seconds else f"Recording for {self.args.seconds} s.")
            try:
                await self.wait_for_enter()
            finally:
                # Stop it, if the board can be told; it stops by itself when
                # the computer goes, anyway
                if client.is_connected:
                    try:
                        await self.send(MSG_RECORD, 0, 0)
                        await asyncio.sleep(0.3)   # the last few packets
                    except BaseException:
                        pass


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--board", help="the board's name, e.g. DroneLab-ABCD, or its address "
                        "(default: the first one found)")
    parser.add_argument("--comm-voice", action="store_true",
                        help="record the comm voice, not the speaker's voice effect")
    parser.add_argument("--beep", action="store_true", help="a sync beep to start, on the speaker and in the file")
    parser.add_argument("--take", metavar="NAME", help="the file's name (default: when it starts)")
    parser.add_argument("--dir", default=".", help="where to save it (default: here)")
    parser.add_argument("--seconds", type=float, help="stop after this long (default: on Enter)")
    parser.add_argument("--play", action="store_true", help="hear it on this computer as it records")
    parser.add_argument("--device", help="play it to this sound device, by number or name (see --list-devices)")
    parser.add_argument("--no-record", action="store_true", help="don't save a file: just play it")
    parser.add_argument("--list-devices", action="store_true", help="list the sound devices, and stop")
    args = parser.parse_args()
    if args.list_devices:
        import sounddevice as sd
        print(sd.query_devices())
        return
    if args.no_record and not args.play and args.device is None:
        parser.error("--no-record needs --play or --device")
    try:
        asyncio.run(Recorder(args).run())
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
