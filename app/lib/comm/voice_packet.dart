/// Mumble's voice packets, in the older format (before Mumble 1.5) that the
/// server uses with clients that say they're 1.4. They travel inside the TCP
/// connection as UDPTunnel messages, so no UDP is needed.
///
/// From a client:  [type << 5 | target] [varint seq] [opus header] [opus]
/// From the server: [type << 5 | target] [varint session] [varint seq] [opus header] [opus]
///
/// The opus header is a varint of the packet's length, with 0x2000 set on
/// the last packet of a transmission. seq counts in 10 ms frames.
library;

import 'dart:typed_data';

const int voiceTypeOpus = 4;
const int opusTerminator = 0x2000;

/// Mumble's own variable-length integers (not protobuf's).
void writeMumbleVarint(BytesBuilder out, int v) {
  if (v < 0) throw ArgumentError('negative varints are not needed here');
  if (v < 0x80) {
    out.addByte(v);
  } else if (v < 0x4000) {
    out.add([0x80 | (v >> 8), v & 0xFF]);
  } else if (v < 0x200000) {
    out.add([0xC0 | (v >> 16), (v >> 8) & 0xFF, v & 0xFF]);
  } else if (v < 0x10000000) {
    out.add([0xE0 | (v >> 24), (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF]);
  } else if (v <= 0xFFFFFFFF) {
    out.add([0xF0, (v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF]);
  } else {
    out.addByte(0xF4);
    for (var shift = 56; shift >= 0; shift -= 8) {
      out.addByte((v >> shift) & 0xFF);
    }
  }
}

class _Reader {
  final Uint8List data;
  int i;
  _Reader(this.data, this.i);

  int byte() {
    if (i >= data.length) throw const FormatException('voice packet: truncated');
    return data[i++];
  }

  int varint() {
    final b = byte();
    if (b & 0x80 == 0) return b;
    if (b & 0xC0 == 0x80) return ((b & 0x3F) << 8) | byte();
    if (b & 0xE0 == 0xC0) return ((b & 0x1F) << 16) | (byte() << 8) | byte();
    if (b & 0xF0 == 0xE0) return ((b & 0x0F) << 24) | (byte() << 16) | (byte() << 8) | byte();
    switch (b & 0xFC) {
      case 0xF0:
        return (byte() << 24) | (byte() << 16) | (byte() << 8) | byte();
      case 0xF4:
        var v = 0;
        for (var k = 0; k < 8; k++) {
          v = (v << 8) | byte();
        }
        return v;
      case 0xF8:
        return -varint();
      default: // 0xFC
        return ~(b & 0x03);
    }
  }
}

/// Our voice, to the server.
Uint8List encodeVoice({required int seq, required Uint8List opus, bool last = false, int target = 0}) {
  final out = BytesBuilder();
  out.addByte((voiceTypeOpus << 5) | (target & 0x1F));
  writeMumbleVarint(out, seq);
  writeMumbleVarint(out, opus.length | (last ? opusTerminator : 0));
  out.add(opus);
  return out.toBytes();
}

class IncomingVoice {
  final int session;
  final int seq;
  final Uint8List opus;   // empty on a bare terminator
  final bool last;
  IncomingVoice(this.session, this.seq, this.opus, this.last);
}

/// Someone else's voice, from the server. Null for anything but Opus.
IncomingVoice? decodeVoice(Uint8List data) {
  if (data.isEmpty) return null;
  final type = data[0] >> 5;
  if (type != voiceTypeOpus) return null;
  final r = _Reader(data, 1);
  final session = r.varint();
  final seq = r.varint();
  final header = r.varint();
  final len = header & 0x1FFF;
  if (r.i + len > data.length) throw const FormatException('voice packet: truncated opus');
  final opus = Uint8List.sublistView(data, r.i, r.i + len);
  return IncomingVoice(session, seq, opus, header & opusTerminator != 0);
}

/// Reads a Mumble varint from the start of data, for tests.
int readMumbleVarint(Uint8List data) => _Reader(data, 0).varint();
