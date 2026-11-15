/// The board's comm channel over Bluetooth LE, as in core/app/comm.h.
///
/// Board to phone, notified on [toPhoneUuid]:
///   sound   [0x01][seq LE16][flags][opus]   flags: 1 first, 2 last (no opus)
///   status  [0x02][version][mode][flags]    flags: 1 sending, 2 hears the voice,
///                                           4 the talk button is connected
/// Phone to board, written to [fromPhoneUuid]:
///   talk    [0x01][0 or 1]
///   mode    [0x02][mode]
///   server  [0x04][flags][others in the channel][own avatar slot][channel name]
///           flags: 1 connected, 2 connecting, 4 voice over UDP
///   hearing [0x05] then for each talking, in the order they started:
///           [avatar slot][how they're heard: 0 the server, 1 direct][name]["\n"]
///   avatar  [0x06][slot][flags][piece of the picture, RGB565 LE]
///           flags: 1 the first piece, 2 the last, 4 asks for an ack
/// and back from the board:
///   avatar ack [0x06][slot][flags][bytes received, LE32]
///           flags: 1 it's all there, 2 the right size
///   direct sound [0x07][sender LE32][seq LE16][flags][opus]
///           another board's voice, heard over direct comms (core/app/direct.h)
///   direct peer [0x08][id LE32][rssi][flags: 1 talking][name]
///           a board heard over direct comms, every couple of seconds
///   direct group [0x09][group id, 4 bytes][rssi][boards][channel][flags: 1 Long Range][name]
///           a group heard about over direct comms, from its beacons
/// Both ways, the phone remote's requests and their answers, in pieces:
///   request [0x03][id][flags][piece of "METHOD /api/...\n" + body]
///   answer  [0x03][id][flags][piece of "200\n" + JSON, "304\n" or "404\n"]
///           flags: 1 the first piece, 2 the last
/// The link has to be paired (the board shows a code) before any of it works.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart' show HMac, PBKDF2KeyDerivator, Pbkdf2Parameters, SHA256Digest;

const serviceUuid = 'efe06e1b-a7ff-4823-bfbb-b3a82ea05849';
const toPhoneUuid = 'efe06e1c-a7ff-4823-bfbb-b3a82ea05849';
const fromPhoneUuid = 'efe06e1d-a7ff-4823-bfbb-b3a82ea05849';

/// The board's message versions (COMM_VERSION in comm.h), in its status:
///   1  sound, status, talk and mode
///   2  the phone remote's requests, GET /version, pairing with a code, and
///      the status's talk button bit
///   3  server and hearing, for the board's Comm screen
const commVersion = 3;
const commVersionRemote = 2;

/// The board's sound: 20 ms Opus packets of 16 kHz mono.
const boardSampleRate = 16000;
const boardFrameMs = 20;

const _msgSound = 0x01;
const _msgStatus = 0x02;
const _msgTalk = 0x01;
const _msgMode = 0x02;
const _msgRequest = 0x03;
const _msgServer = 0x04;
const _msgHearing = 0x05;
const _msgAvatar = 0x06;
const _msgDirectSound = 0x07;
const _msgDirectPeer = 0x08;
const _msgDirectGroup = 0x09;

/// No avatar, in a slot.
const avatarNone = 0xFF;

/// The longest message the board takes from the phone: 64 before
/// commVersion 3, and then 244, if the MTU's big enough.
const boardMaxWrite = 64;
const boardMaxWriteV3 = 244;

enum BoardMode { pushToTalk, voice }

class BoardSound {
  final int seq;            // counts packets, wrapping at 65536
  final bool first;
  final bool last;
  final Uint8List opus;     // empty on the end-of-transmission packet
  BoardSound(this.seq, this.first, this.last, this.opus);
}

class BoardStatus {
  final int version;
  final BoardMode mode;
  final bool sending;
  final bool hearsVoice;
  final bool buttonConnected;
  BoardStatus(this.version, this.mode, this.sending, this.hearsVoice, this.buttonConnected);
}

class AvatarAck {
  final int slot;
  final bool done;
  final bool ok;
  final int received;
  AvatarAck(this.slot, this.done, this.ok, this.received);
}

class DirectSound {
  final int sender;
  final int seq;            // counts packets, wrapping at 65536
  final bool first;
  final bool last;
  final Uint8List opus;
  DirectSound(this.sender, this.seq, this.first, this.last, this.opus);
}

class DirectPeer {
  final int id;
  final int rssi;
  final bool talking;
  final String name;
  DirectPeer(this.id, this.rssi, this.talking, this.name);
}

class DirectGroupHeard {
  final String id;          // 8 hex digits
  final int rssi;
  final int boards;
  final int channel;
  final bool longRange;
  final String name;
  DirectGroupHeard(this.id, this.rssi, this.boards, this.channel, this.longRange, this.name);
}

class AnswerPiece {
  final int id;
  final bool first;
  final bool last;
  final Uint8List data;
  AnswerPiece(this.id, this.first, this.last, this.data);
}

/// A notification from the board: a [BoardSound], a [BoardStatus], an
/// [AnswerPiece], an [AvatarAck], or null.
Object? parseBoardMessage(Uint8List data) {
  if (data.length < 4) return null;
  switch (data[0]) {
    case _msgSound:
      return BoardSound(data[1] | (data[2] << 8), data[3] & 1 != 0, data[3] & 2 != 0,
          Uint8List.sublistView(data, 4));
    case _msgStatus:
      final mode = data[2] < BoardMode.values.length ? BoardMode.values[data[2]] : BoardMode.pushToTalk;
      return BoardStatus(data[1], mode, data[3] & 1 != 0, data[3] & 2 != 0, data[3] & 4 != 0);
  }
  int le32(int at) => data[at] | (data[at + 1] << 8) | (data[at + 2] << 16) | (data[at + 3] << 24);
  if (data[0] == _msgDirectSound && data.length >= 8) {
    return DirectSound(le32(1), data[5] | (data[6] << 8), data[7] & 1 != 0, data[7] & 2 != 0,
        Uint8List.sublistView(data, 8));
  }
  if (data[0] == _msgDirectPeer && data.length >= 7) {
    return DirectPeer(le32(1), data[5].toSigned(8), data[6] & 1 != 0,
        utf8.decode(data.sublist(7), allowMalformed: true));
  }
  if (data[0] == _msgDirectGroup && data.length >= 9) {
    final id = data.sublist(1, 5).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return DirectGroupHeard(id, data[5].toSigned(8), data[6], data[7], data[8] & 1 != 0,
        utf8.decode(data.sublist(9), allowMalformed: true));
  }
  if (data[0] == _msgAvatar && data.length >= 7) {
    final got = data[3] | (data[4] << 8) | (data[5] << 16) | (data[6] << 24);
    return AvatarAck(data[1], data[2] & 1 != 0, data[2] & 2 != 0, got);
  }
  if (data[0] == _msgRequest && data.length >= 3) {
    return AnswerPiece(data[1], data[2] & 1 != 0, data[2] & 2 != 0, Uint8List.sublistView(data, 3));
  }
  return null;
}

/// A request, cut into messages small enough for the board.
List<Uint8List> requestMessages(int id, Uint8List request, [int maxWrite = boardMaxWrite]) {
  final room = maxWrite - 3;
  final out = <Uint8List>[];
  var at = 0;
  do {
    final n = (request.length - at).clamp(0, room);
    final flags = (at == 0 ? 1 : 0) | (at + n == request.length ? 2 : 0);
    out.add(Uint8List.fromList([_msgRequest, id & 0xFF, flags, ...request.sublist(at, at + n)]));
    at += n;
  } while (at < request.length);
  return out;
}

Uint8List talkMessage(bool talk) => Uint8List.fromList([_msgTalk, talk ? 1 : 0]);
Uint8List modeMessage(BoardMode mode) => Uint8List.fromList([_msgMode, mode.index]);

enum ServerLink { off, connecting, connected }

/// Cut UTF-8 down to [max] bytes, without cutting a character in two.
List<int> _cut(List<int> bytes, int max) {
  if (bytes.length <= max) return bytes;
  var n = max;
  while (n > 0 && (bytes[n] & 0xC0) == 0x80) {
    n--;
  }
  return bytes.sublist(0, n);
}

/// How the server's doing, for the board's Comm screen.
Uint8List serverMessage(ServerLink link,
    {bool udp = false, int others = 0, String channel = '', int ownAvatar = avatarNone}) {
  final flags = (link == ServerLink.connected ? 1 : 0) | (link == ServerLink.connecting ? 2 : 0) | (udp ? 4 : 0);
  return Uint8List.fromList([
    _msgServer,
    flags,
    others.clamp(0, 255),
    ownAvatar & 0xFF,
    ..._cut(utf8.encode(channel), boardMaxWrite - 4)
  ]);
}

class Talker {
  final String name;
  final int avatar;   // its slot, or [avatarNone]
  final bool direct;  // heard over direct comms, not the server
  const Talker(this.name, [this.avatar = avatarNone, this.direct = false]);
}

/// The longest name the board's sent (it keeps up to 23 bytes), and how
/// many it shows.
const hearingNameMax = 20;
const hearingMaxNames = 4;

/// Who's talking, for the board's Comm screen, in the order they started:
/// as many as fit, then "+2" and the like for the rest.
Uint8List hearingMessage(List<Talker> talkers) {
  final out = <int>[_msgHearing];
  List<int> more(int n) => [avatarNone, 0, ...utf8.encode('+$n\n')];
  for (var i = 0; i < talkers.length; i++) {
    final name = _cut(utf8.encode(talkers[i].name.replaceAll('\n', ' ')), hearingNameMax);
    final rest = talkers.length - i - 1;
    if (i == hearingMaxNames - 1 && rest > 0) {
      out.addAll(more(rest + 1));
      break;
    }
    // Leave room for the "+n" of those after it
    final need = 2 + name.length + 1 + (rest > 0 ? more(rest).length : 0);
    if (out.length + need > boardMaxWrite) {
      out.addAll(more(talkers.length - i));
      break;
    }
    out.add(talkers[i].avatar & 0xFF);
    out.add(talkers[i].direct ? 1 : 0);
    out.addAll(name);
    out.add(0x0A);
  }
  return Uint8List.fromList(out);
}

/// An avatar, [rgb565] (size x size pixels, little endian), cut into
/// messages of up to [maxWrite] bytes for [slot]. Every [window]th asks the
/// board to say it's got them, as does the last.
List<Uint8List> avatarMessages(int slot, Uint8List rgb565, int maxWrite, {int window = 8}) {
  final room = maxWrite - 3;
  final out = <Uint8List>[];
  for (var at = 0; at < rgb565.length; at += room) {
    final n = (rgb565.length - at).clamp(0, room);
    final last = at + n == rgb565.length;
    final ack = last || (out.length + 1) % window == 0;
    final flags = (at == 0 ? 1 : 0) | (last ? 2 : 0) | (ack ? 4 : 0);
    out.add(Uint8List.fromList([_msgAvatar, slot, flags, ...Uint8List.sublistView(rgb565, at, at + n)]));
  }
  return out;
}

/// A direct comms group's key, from its name and passphrase, as 32 hex
/// digits for the board (POST /api/comm?key=): PBKDF2-HMAC-SHA256, the salt
/// "dronelab-direct\n" and the name, [directKeyRounds] rounds, 16 bytes, as
/// direct_key() on the board. Slow on purpose: run it off the UI's isolate.
const directKeyRounds = 20000;

String directKey((String, String) groupAndPassphrase) {
  final (group, passphrase) = groupAndPassphrase;
  final kdf = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
    ..init(Pbkdf2Parameters(Uint8List.fromList(utf8.encode('dronelab-direct\n$group')), directKeyRounds, 16));
  return _hex(kdf.process(Uint8List.fromList(utf8.encode(passphrase))));
}

/// A group's id, from its key: the first 4 bytes of the key's SHA-256, as
/// the board works it out and says in its beacons.
String directGroupId(String keyHex) {
  final key = [for (var i = 0; i < keyHex.length; i += 2) int.parse(keyHex.substring(i, i + 2), radix: 16)];
  return sha256.convert(key).toString().substring(0, 8);
}

String _hex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// FNV-1a, 32 bits: how the board tells whether the app's copy of the
/// remote's page is the same as its own.
int fnv1a(List<int> bytes) {
  var h = 0x811c9dc5;
  for (final b in bytes) {
    h = ((h ^ b) * 0x01000193) & 0xFFFFFFFF;
  }
  return h;
}
