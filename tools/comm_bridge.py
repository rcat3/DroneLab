#!/usr/bin/env python3
"""Stand in for the phone on the comm channel: take the board's voice over
Bluetooth, and pass it on to a Mumble server, a speaker or a file.

Switch on Comm on the board (Settings, Comm page), then run one of:

    python3 tools/comm_bridge.py --play                     # hear it on this computer
    python3 tools/comm_bridge.py --wav comm.wav             # save it
    python3 tools/comm_bridge.py --mumble 192.168.15.200 --password secret --user Pup

They can be put together. The board is found by its service, or give its
name (the Comm page shows it) with --board DroneLab-ABCD.

While it runs, type a line and press Enter:

    (nothing)   talk, or stop talking: push to talk from here
    v           voice mode: the board talks when it hears you
    p           push to talk mode
    q           quit

The board sends Opus, which goes on to Mumble as it is, the way the phone
app will. Hearing it or saving it decodes it with libopus (the libopus0
package on Debian and Ubuntu). Needs bleak (pip install bleak), and for
--play, numpy and sounddevice.
"""

import argparse
import asyncio
import ctypes
import ctypes.util
import socket
import ssl
import struct
import sys
import time
import wave

from bleak import BleakClient, BleakScanner

SERVICE_UUID = "efe06e1b-a7ff-4823-bfbb-b3a82ea05849"
TO_PHONE_UUID = "efe06e1c-a7ff-4823-bfbb-b3a82ea05849"
FROM_PHONE_UUID = "efe06e1d-a7ff-4823-bfbb-b3a82ea05849"

MSG_SOUND = 0x01
MSG_STATUS = 0x02
MSG_TALK = 0x01
MSG_MODE = 0x02
FLAG_FIRST = 0x01
FLAG_LAST = 0x02
STATUS_SENDING = 0x01
STATUS_HEARD = 0x02
MODES = {0: "push to talk", 1: "voice"}

SAMPLE_RATE = 16000
FRAME = SAMPLE_RATE * 20 // 1000


# ----- Opus, for listening and saving -----

class OpusDecoder:
    def __init__(self, rate=SAMPLE_RATE):
        name = ctypes.util.find_library("opus") or "libopus.so.0"
        self.lib = ctypes.CDLL(name)
        self.lib.opus_decoder_create.restype = ctypes.c_void_p
        self.lib.opus_decoder_create.argtypes = [ctypes.c_int32, ctypes.c_int, ctypes.POINTER(ctypes.c_int)]
        self.lib.opus_decode.restype = ctypes.c_int
        self.lib.opus_decode.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int32,
                                         ctypes.POINTER(ctypes.c_int16), ctypes.c_int, ctypes.c_int]
        err = ctypes.c_int()
        self.dec = self.lib.opus_decoder_create(rate, 1, ctypes.byref(err))
        if not self.dec:
            raise RuntimeError(f"opus_decoder_create failed ({err.value})")
        self.max = rate * 120 // 1000
        self.buf = (ctypes.c_int16 * self.max)()

    def decode(self, packet):
        """One packet to 16-bit samples. None for a lost packet, which Opus fills in."""
        if packet is None:
            n = self.lib.opus_decode(self.dec, None, 0, self.buf, FRAME, 0)
        else:
            n = self.lib.opus_decode(self.dec, packet, len(packet), self.buf, self.max, 0)
        if n < 0:
            return b""
        return bytes(ctypes.string_at(self.buf, n * 2))


# ----- Mumble -----

def pb_varint(v):
    out = bytearray()
    while True:
        b = v & 0x7F
        v >>= 7
        if v:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def pb_field(number, value):
    """A protobuf field: ints as varints, str and bytes as length-delimited."""
    if isinstance(value, bool):
        value = int(value)
    if isinstance(value, int):
        return pb_varint(number << 3) + pb_varint(value)
    if isinstance(value, str):
        value = value.encode()
    return pb_varint((number << 3) | 2) + pb_varint(len(value)) + value


def pb_strings(data):
    """The string fields of a protobuf message, as {number: text}."""
    fields, i = {}, 0
    while i < len(data):
        key, shift = 0, 0
        while True:
            b = data[i]; i += 1
            key |= (b & 0x7F) << shift; shift += 7
            if not b & 0x80:
                break
        number, wire = key >> 3, key & 7
        if wire == 0:
            while data[i] & 0x80:
                i += 1
            i += 1
        elif wire == 2:
            length, shift = 0, 0
            while True:
                b = data[i]; i += 1
                length |= (b & 0x7F) << shift; shift += 7
                if not b & 0x80:
                    break
            fields[number] = data[i:i + length].decode(errors="replace")
            i += length
        elif wire == 1:
            i += 8
        elif wire == 5:
            i += 4
        else:
            break
    return fields


def mumble_varint(v):
    """Mumble's own variable-length integers, used in voice packets."""
    if v < 0x80:
        return bytes([v])
    if v < 0x4000:
        return bytes([0x80 | (v >> 8), v & 0xFF])
    if v < 0x200000:
        return bytes([0xC0 | (v >> 16), (v >> 8) & 0xFF, v & 0xFF])
    if v < 0x10000000:
        return bytes([0xE0 | (v >> 24), (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF])
    return bytes([0xF0]) + struct.pack(">I", v)


class Mumble:
    """Just enough of a Mumble client to talk: it logs in and sends Opus
    packets inside its TCP connection (no UDP), and ignores what others say."""

    VERSION, UDP_TUNNEL, AUTHENTICATE, PING, REJECT, SERVER_SYNC = 0, 1, 2, 3, 4, 5
    TEXT_MESSAGE = 11

    def __init__(self, host, port, user, password):
        self.host, self.port, self.user, self.password = host, port, user, password
        self.writer = None
        self.ready = False
        self.seq = 0            # in 10 ms frames, as Mumble counts
        self.last_board_seq = None

    async def connect(self):
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE     # the server's own certificate
        reader, self.writer = await asyncio.open_connection(self.host, self.port, ssl=ctx)
        self.writer.get_extra_info("socket").setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        # Version 1.4.0, so the server sends and expects voice in the older,
        # simpler format
        self.send(self.VERSION, pb_field(1, 0x010400) + pb_field(2, "comm_bridge") + pb_field(3, sys.platform))
        self.send(self.AUTHENTICATE, pb_field(1, self.user) + pb_field(2, self.password) + pb_field(5, True))
        asyncio.create_task(self.read_loop(reader))
        asyncio.create_task(self.ping_loop())

    def send(self, kind, payload):
        self.writer.write(struct.pack(">HI", kind, len(payload)) + payload)

    async def read_loop(self, reader):
        try:
            while True:
                kind, length = struct.unpack(">HI", await reader.readexactly(6))
                payload = await reader.readexactly(length)
                if kind == self.SERVER_SYNC:
                    self.ready = True
                    print(f"Mumble: joined {self.host} as {self.user}")
                elif kind == self.REJECT:
                    print(f"Mumble: turned away: {pb_strings(payload).get(2, 'no reason given')}")
                elif kind == self.TEXT_MESSAGE:
                    print(f"Mumble message: {pb_strings(payload).get(5, '')}")
        except (asyncio.IncompleteReadError, ConnectionError):
            print("Mumble: disconnected")
            self.ready = False

    async def ping_loop(self):
        while True:
            await asyncio.sleep(15)     # the server drops a client it hasn't heard from in 30 s
            self.send(self.PING, pb_field(1, int(time.time() * 1000)))

    def voice(self, board_seq, opus, last):
        if not self.ready:
            return
        # Keep the board's gaps, so listeners' decoders fill them in
        if self.last_board_seq is not None:
            self.seq += 2 * ((board_seq - self.last_board_seq) & 0xFFFF)
        self.last_board_seq = board_seq
        header = len(opus) | (0x2000 if last else 0)
        packet = bytes([4 << 5]) + mumble_varint(self.seq) + mumble_varint(header) + opus
        self.send(self.UDP_TUNNEL, packet)


# ----- The board -----

class Bridge:
    def __init__(self, args):
        self.args = args
        self.client = None
        self.talking = False
        self.status = None
        self.decoder = OpusDecoder() if (args.wav or args.play) else None
        self.wav = None
        self.stream = None
        self.mumble = None
        self.last_seq = None
        self.packets = 0
        self.lost = 0
        self.bytes = 0
        self.burst_start = None

    def on_notify(self, _char, data):
        data = bytes(data)
        if not data:
            return
        if data[0] == MSG_STATUS and len(data) >= 4:
            status = (data[2], data[3])
            if status != self.status:
                self.status = status
                flags = []
                if data[3] & STATUS_SENDING:
                    flags.append("sending")
                if data[3] & STATUS_HEARD:
                    flags.append("hears you")
                print(f"Board: {MODES.get(data[2], data[2])}, {', '.join(flags) or 'quiet'} (version {data[1]})")
        elif data[0] == MSG_SOUND and len(data) >= 4:
            seq = data[1] | (data[2] << 8)
            flags = data[3]
            opus = data[4:]
            if flags & FLAG_FIRST:
                self.burst_start = time.monotonic()
                self.packets = self.lost = self.bytes = 0
                self.last_seq = None
            if self.last_seq is not None:
                gap = (seq - self.last_seq - 1) & 0xFFFF
                self.lost += gap
                for _ in range(min(gap, 10)):
                    self.output(None)
            self.last_seq = seq
            if opus:
                self.packets += 1
                self.bytes += len(opus)
                self.output(opus)
            if self.mumble:
                self.mumble.voice(seq, opus, bool(flags & FLAG_LAST))
            if flags & FLAG_LAST and self.burst_start is not None:
                secs = time.monotonic() - self.burst_start
                kbps = self.bytes * 8 / max(self.packets * 0.02, 0.001) / 1000
                print(f"Transmission: {secs:.1f} s, {self.packets} packets, {self.lost} lost, {kbps:.0f} kb/s")

    def output(self, opus):
        if not self.decoder:
            return
        pcm = self.decoder.decode(opus)
        if self.wav:
            self.wav.writeframes(pcm)
        if self.stream:
            import numpy as np
            self.stream.write(np.frombuffer(pcm, dtype=np.int16))

    async def find_board(self):
        if self.args.board:
            print(f"Looking for {self.args.board}...")
            return await BleakScanner.find_device_by_name(self.args.board, timeout=20)
        print("Looking for a board with Comm on...")
        return await BleakScanner.find_device_by_filter(
            lambda d, ad: SERVICE_UUID in [u.lower() for u in ad.service_uuids], timeout=20)

    async def send(self, *msg):
        await self.client.write_gatt_char(FROM_PHONE_UUID, bytes(msg), response=False)

    async def keyboard(self):
        loop = asyncio.get_running_loop()
        while True:
            line = (await loop.run_in_executor(None, sys.stdin.readline))
            if line == "":
                return
            line = line.strip().lower()
            if line == "q":
                return
            if line == "v":
                await self.send(MSG_MODE, 1)
            elif line == "p":
                await self.send(MSG_MODE, 0)
            elif line == "":
                self.talking = not self.talking
                await self.send(MSG_TALK, 1 if self.talking else 0)
                print("Talking (Enter to stop)" if self.talking else "Stopped talking")

    async def run(self):
        if self.args.wav:
            self.wav = wave.open(self.args.wav, "wb")
            self.wav.setnchannels(1)
            self.wav.setsampwidth(2)
            self.wav.setframerate(SAMPLE_RATE)
        if self.args.play:
            import sounddevice as sd
            self.stream = sd.OutputStream(samplerate=SAMPLE_RATE, channels=1, dtype="int16", latency="low")
            self.stream.start()
        if self.args.mumble:
            host, _, port = self.args.mumble.partition(":")
            self.mumble = Mumble(host, int(port or 64738), self.args.user, self.args.password)
            await self.mumble.connect()

        device = await self.find_board()
        if device is None:
            print("No board found. Is Comm switched on, and the board close by?")
            return
        async with BleakClient(device) as client:
            self.client = client
            print(f"Connected to {device.name or device.address}, MTU {client.mtu_size}")
            await client.start_notify(TO_PHONE_UUID, self.on_notify)
            if self.args.mode:
                await self.send(MSG_MODE, 1 if self.args.mode == "voice" else 0)
            print("Enter: talk or stop.  v: voice mode.  p: push to talk.  q: quit.")
            await self.keyboard()
            if self.talking:
                await self.send(MSG_TALK, 0)
        if self.wav:
            self.wav.close()
            print(f"Saved {self.args.wav}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--board", help="the board's name, e.g. DroneLab-ABCD (default: the first one found)")
    parser.add_argument("--play", action="store_true", help="play the voice on this computer")
    parser.add_argument("--wav", help="save the voice to this file")
    parser.add_argument("--mumble", metavar="HOST[:PORT]", help="pass the voice on to this Mumble server")
    parser.add_argument("--user", default="comm_bridge", help="the name to join Mumble with")
    parser.add_argument("--password", default="", help="the Mumble server's password")
    parser.add_argument("--mode", choices=["ptt", "voice"], help="switch the board to this mode")
    args = parser.parse_args()
    try:
        asyncio.run(Bridge(args).run())
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
