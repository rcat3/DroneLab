/// The board's comm channel over Bluetooth LE, as in core/app/comm.h.
///
/// Board to phone, notified on [toPhoneUuid]:
///   sound   [0x01][seq LE16][flags][opus]   flags: 1 first, 2 last (no opus)
///   status  [0x02][version][mode][flags]([battery])
///           flags: 1 sending, 2 hears the voice, 4 the talk button is connected, 8 recording,
///           16 someone talking in another direct comms group nearby
///           battery: percent, 0x80 while charging, 0xFF not known (commVersion 6)
///   recorded [0x0A][seq LE16][flags][opus]  as sound, while recording
/// Phone to board, written to [fromPhoneUuid]:
///   talk    [0x01][0 or 1]
///   mode    [0x02][mode]
///   record  [0x0A][1 start, 0 stop][flags: 1 the speaker's voice, 2 a sync beep]
///   server  [0x04][flags][others in the channel][own avatar slot][channel name]
///           flags: 1 connected, 2 connecting, 4 voice over UDP
///   hearing [0x05] then for each talking, in the order they started:
///           [avatar slot][how they're heard: 0 the server, 1 direct][name]["\n"]
///   avatar  [0x06][slot][flags][piece of the picture, RGB565 LE]
///           flags: 1 the first piece, 2 the last, 4 asks for an ack
///   command [0x0B][1][name length][name][command]   from someone on the server
///           [0x0B][0][boards][their ids, LE32 each][command]   to send over direct
///           comms, to those boards (none for all of them); see [OthersCommand]
/// and back from the board:
///   avatar ack [0x06][slot][flags][bytes received, LE32]
///           flags: 1 it's all there, 2 the right size
///   direct sound [0x07][sender LE32][seq LE16][flags][opus]
///           another board's voice, heard over direct comms (core/app/direct.h)
///   direct peer [0x08][id LE32][rssi][flags: 1 talking, 2 versions follow]
///           ([firmware length][firmware][app length][app])[name]
///           a board heard over direct comms, every couple of seconds
///   message [0x0C][flags: 1 over direct, 2 for the app only][name length][name][text]
///           a message for the Terminal, from someone the wearer allows
///   direct caps [0x17][id LE32][capabilities]   what a board heard over direct
///           comms lets others control (capabilities.dart), after its 0x08
///   direct avatar [0x0D][id LE32][size][piece][pieces][pixels, RGB565 LE]
///           a piece of a board's avatar heard over direct comms, 100 pixels a piece
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

import 'capabilities.dart';

const serviceUuid = 'efe06e1b-a7ff-4823-bfbb-b3a82ea05849';
const toPhoneUuid = 'efe06e1c-a7ff-4823-bfbb-b3a82ea05849';
const fromPhoneUuid = 'efe06e1d-a7ff-4823-bfbb-b3a82ea05849';

/// The board's message versions (COMM_VERSION in comm.h), in its status:
///   1  sound, status, talk and mode
///   2  the phone remote's requests, GET /version, pairing with a code, and
///      the status's talk button bit
///   3  server and hearing, for the board's Comm screen
///   4  commands for others (Vibe toys and the Terminal)
const commVersion = 3;
const commVersionCommands = 4;
const commVersionRemote = 2;
const commVersionPeerFirmware = 5;
const commVersionMessages = 6;
const commVersionUpdate = 7;     // updating the firmware from the app, and status bit 5
const commVersionHeard = 8;      // what others send the board, passed on as it comes (0x0F)
const commVersionMuted = 9;      // who's muted here, whose commands the board ignores (0x10)
const commVersionKeys = 10;     // commands signed by their sender's key; the wearer's key (0x11)
const commVersionTalkTo = 11;   // who talking goes to (0x13), pairs' keys (0x14), and transmissions told (0x13)
const commVersionCopies = 12;
const commVersionCaps = 14;     // what other boards' wearers let others control (0x17)   // each copy of a command heard over direct comms, and how it came (0x15)
const commVersionDirectVoice = 13;  // voice from the phone for the board to send over direct comms (0x16)
const commVersionPhoneMic = 15;  // the phone's mic in place of the board's (0x18), its talk button held (0x18)
const commVersionRules = 16;    // the wearer's rules from the app (0x10), in place of who's muted
const commVersionPatterns = 17; // Vibe toys set as a whole (0x41), custom patterns in parts (0x45)
const commVersionFavourites = 18;   // the wearer's favourite patterns (0x19), /api/state's "favs"
const commVersionPictures = 20; // Display commands: words and pictures for a while (others.h 0x10, 0x12), pictures from the phone (0x1A)
const commVersionSounds = 21;   // sounds others play from the speaker (others.h 0x13), sounds from the phone (0x1B)
const commVersionFollow = 19;   // the wearer's own Vibe commands, for their toys to follow along (0x0B's bit 1)

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
const _msgRecord = 0x0A;
const _msgCommand = 0x0B;
const _msgHeard = 0x0F;
const _msgRules = 0x10;
const _msgFavourites = 0x19;
const _msgPicture = 0x1A;     // both ways: a picture for the screen, in pieces, and the ack
const _msgSentSound = 0x1B;
const _msgLevel = 0x1C;       // to the board: send the voice's level; from it, the level   // both ways: a sound for the speaker, in pieces, and the ack, as a picture's
const _msgIdentity = 0x11;
const _msgBinding = 0x12;
const _msgTalkTo = 0x13;      // to the board: who talking goes to
const _msgTalked = 0x13;      // from it: a transmission started, ended or was refused
const _msgPairs = 0x14;
const _msgCopy = 0x15;        // from the board: a copy of a command heard over direct comms
const _msgDirectVoice = 0x16; // to it: voice for it to send over direct comms
const _msgDirectCaps = 0x17;  // from it: what a board's wearer lets others control
const _msgMic = 0x18;         // to it: which mic talks, its or the phone's
const _msgTalkHeld = 0x18;    // from it: its talk button or screen held, for the phone's mic
const _msgDirectAvatar = 0x0D;
const _msgUpdate = 0x0E;

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
  final bool recording;
  final int? battery;       // percent, null if not known
  final bool charging;
  final bool otherVoice;    // someone's talking in another direct comms group nearby
  final bool otherFirmware; // boards with another version of direct comms nearby, which can't be heard
  final int? directId;      // the board's own id over direct comms (commVersion 10)
  BoardStatus(this.version, this.mode, this.sending, this.hearsVoice, this.buttonConnected,
      [this.recording = false, this.battery, this.charging = false, this.otherVoice = false,
      this.otherFirmware = false, this.directId]);
}

/// The board's voice while recording: as [BoardSound], kept apart from it.
class RecordedSound {
  final BoardSound sound;
  RecordedSound(this.sound);
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
  final bool alone;         // for us alone, sealed with our pair's key (commVersion 11)
  DirectSound(this.sender, this.seq, this.first, this.last, this.opus, [this.alone = false]);
}

/// A transmission of ours started, ended, or was refused as nobody would
/// hear it (commVersion 11).
class Talked {
  static const started = 0, ended = 1, refused = 2;
  final int what;
  final bool byVoice;       // voice mode started it, not a button
  final bool direct;        // it goes over direct comms
  final bool alone;         // to one person alone
  Talked(this.what, this.byVoice, this.direct, this.alone);
}

class DirectPeer {
  final int id;
  final int rssi;
  final bool talking;
  final String name;
  final String firmware;    // its version, '' if it didn't say
  final String app;         // its phone's app's version, '' for none
  final Uint8List? key;     // its wearer's public key, as its hello says
  DirectPeer(this.id, this.rssi, this.talking, this.name, [this.firmware = '', this.app = '', this.key]);
}

/// What a board heard over direct comms lets others control, as its hello
/// says (commVersion 14).
class DirectCaps {
  final int id;
  final Capabilities caps;
  DirectCaps(this.id, this.caps);
}

/// A piece of a board's avatar, heard over direct comms: [size] pixels
/// square, RGB565, 100 pixels a piece.
class DirectAvatarPiece {
  final int id;
  final int size;
  final int piece;
  final int pieces;
  final Uint8List pixels;
  DirectAvatarPiece(this.id, this.size, this.piece, this.pieces, this.pixels);
}

/// What someone sent the board, passed on as it came (commVersion 8): a
/// text, or a command for its display or Vibe toys, done or not.
class Heard {
  static const text = 0, display = 1, vibe = 2, textPart = 3, call = 4, invite = 5, reaction = 6, sound = 7;    // comm_heard_t
  final bool direct;        // heard over direct comms, not the server
  final bool done;          // a command: taken, by the permission for its kind
  final int what;
  final int scope;          // who it was for (OthersCommand.scope*)
  final String from;
  final Uint8List key;      // who it's from: their public key
  final Uint8List data;     // the text, or the command from what to do on
  final int? counter;       // the sender's counter for it: its id, as reactions name it
  /// A text put back together from parts: each part's counter, in order,
  /// null for one that never came.
  final List<int?>? parts;
  Heard(this.direct, this.done, this.what, this.scope, this.from, this.key, this.data, [this.counter, this.parts]);

  String get textOf => utf8.decode(data, allowMalformed: true);
}

/// A copy of a command heard over direct comms, the first included, and how
/// it came (commVersion 12): for a text's details. The sender boards send
/// each a few times, and another board may pass one on (relay).
class HeardCopy {
  final String keyId;       // the sender's key's first 8 bytes, as Identity.idOf
  final int counter;        // the command's, as Heard's
  final int broadcast;      // the sending board's counter for the broadcast: the same when relayed
  final int rssi;           // dBm, from the last board it came from
  final int hops;           // times it was passed on
  final int bytes;          // its length on the air
  HeardCopy(this.keyId, this.counter, this.broadcast, this.rssi, this.hops, this.bytes);
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
  if (data.length == 2 && data[0] == _msgTalkHeld) return TalkHeld(data[1] != 0);
  if (data.length == 2 && data[0] == _msgLevel) return VoiceLevel(data[1].toSigned(8).toDouble());
  if (data.length >= 3 && data[0] == _msgTalked) {
    return Talked(data[1], data[2] & 1 != 0, data[2] & 2 != 0, data[2] & 4 != 0);
  }
  if (data.length < 4) return null;
  switch (data[0]) {
    case _msgSound:
      return BoardSound(data[1] | (data[2] << 8), data[3] & 1 != 0, data[3] & 2 != 0,
          Uint8List.sublistView(data, 4));
    case _msgStatus:
      final mode = data[2] < BoardMode.values.length ? BoardMode.values[data[2]] : BoardMode.pushToTalk;
      final charge = data.length >= 5 && data[4] != 0xFF ? data[4] : null;
      return BoardStatus(data[1], mode, data[3] & 1 != 0, data[3] & 2 != 0, data[3] & 4 != 0, data[3] & 8 != 0,
          charge == null ? null : charge & 0x7F, charge != null && charge & 0x80 != 0, data[3] & 16 != 0,
          data[3] & 32 != 0, data.length >= 9 ? data[5] | (data[6] << 8) | (data[7] << 16) | (data[8] << 24) : null);
    case _msgRecord:
      return RecordedSound(BoardSound(data[1] | (data[2] << 8), data[3] & 1 != 0, data[3] & 2 != 0,
          Uint8List.sublistView(data, 4)));
  }
  int le32(int at) => data[at] | (data[at + 1] << 8) | (data[at + 2] << 16) | (data[at + 3] << 24);
  if (data[0] == _msgDirectSound && data.length >= 8) {
    return DirectSound(le32(1), data[5] | (data[6] << 8), data[7] & 1 != 0, data[7] & 2 != 0,
        Uint8List.sublistView(data, 8), data[7] & 4 != 0);
  }
  if (data[0] == _msgDirectPeer && data.length >= 7) {
    var at = 7;
    Uint8List? key;
    if (data[6] & 4 != 0 && at + 32 <= data.length) {
      key = Uint8List.fromList(data.sublist(at, at + 32));
      at += 32;
    }
    final versions = ['', ''];
    for (var i = 0; i < 2 && data[6] & 2 != 0 && at < data.length && at + 1 + data[at] <= data.length; i++) {
      versions[i] = utf8.decode(data.sublist(at + 1, at + 1 + data[at]), allowMalformed: true);
      at += 1 + data[at];
    }
    return DirectPeer(le32(1), data[5].toSigned(8), data[6] & 1 != 0,
        utf8.decode(data.sublist(at), allowMalformed: true), versions[0], versions[1], key);
  }
  if (data[0] == _msgDirectCaps && data.length >= 6) {
    final caps = Capabilities.decode(Uint8List.sublistView(data, 5));
    if (caps != null) return DirectCaps(le32(1), caps);
  }
  if (data[0] == _msgDirectAvatar && data.length >= 8) {
    return DirectAvatarPiece(le32(1), data[5], data[6], data[7], Uint8List.sublistView(data, 8));
  }
  if (data[0] == _msgHeard && data.length >= 5 && data.length >= 5 + data[4] + 32) {
    final at = 5 + data[4];
    // Its counter, after the key, from firmware that sends it (flag 4)
    final counted = data[1] & 4 != 0 && data.length >= at + 32 + 6;
    var counter = 0;
    for (var i = 5; counted && i >= 0; i--) {
      counter = (counter << 8) | data[at + 32 + i];
    }
    return Heard(data[1] & 1 != 0, data[1] & 2 != 0, data[2], data[3],
        utf8.decode(data.sublist(5, at), allowMalformed: true), Uint8List.fromList(data.sublist(at, at + 32)),
        Uint8List.sublistView(data, at + 32 + (counted ? 6 : 0)), counted ? counter : null);
  }
  if (data[0] == _msgCopy && data.length >= 22) {
    var counter = 0;
    for (var i = 5; i >= 0; i--) {
      counter = (counter << 8) | data[9 + i];
    }
    return HeardCopy(data.sublist(1, 9).map((b) => b.toRadixString(16).padLeft(2, '0')).join(), counter, le32(15),
        data[19].toSigned(8), data[20], data[21]);
  }
  if (data[0] == _msgDirectGroup && data.length >= 9) {
    final id = data.sublist(1, 5).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return DirectGroupHeard(id, data[5].toSigned(8), data[6], data[7], data[8] & 1 != 0,
        utf8.decode(data.sublist(9), allowMalformed: true));
  }
  if (data[0] == _msgUpdate && data.length >= 7) {
    return UpdateAck(data[1] & 1 != 0, data[1] & 2 != 0, data[2],
        data[3] | (data[4] << 8) | (data[5] << 16) | (data[6] << 24), data[1] & 4 != 0);
  }
  if ((data[0] == _msgPicture || data[0] == _msgSentSound) && data.length >= 6) {
    return PictureAck(data[1] & 1 != 0, data[1] & 2 != 0, le32(2), sound: data[0] == _msgSentSound);
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

/// Which mic talks (commVersion 15): with the phone's, the board's talk
/// button and screen say so ([TalkHeld]) in place of talking, and there's
/// no voice mode. The board goes back to its own when the phone goes.
/// [sending] and [refused] (just now) are the phone mic's, for the
/// board's screen to show as its own.
Uint8List micMessage({required bool phone, bool sending = false, bool refused = false}) =>
    Uint8List.fromList([_msgMic, (phone ? 1 : 0) | (sending ? 2 : 0) | (refused ? 4 : 0)]);

/// The board's talk button or screen held, or let go, while the phone's mic
/// talks: sent again each second while held.
class TalkHeld {
  final bool held;
  const TalkHeld(this.held);
}

/// A packet of voice for the board to send over direct comms as its own
/// (commVersion 13), paced by us: for the developer options' voice auto
/// responder. At most [directVoiceMax] bytes of Opus.
Uint8List directVoiceMessage(Uint8List opus, {bool first = false, bool last = false}) =>
    Uint8List.fromList([_msgDirectVoice, 0, 0, (first ? 1 : 0) | (last ? 2 : 0), ...opus]);
const directVoiceMax = 160;

/// How long an Opus packet plays, in ms, from its first bytes (RFC 6716,
/// 3.1), or 20 if it can't be told.
int opusPacketMs(Uint8List p) {
  if (p.isEmpty) return 0;
  final config = p[0] >> 3;
  final frame10 = config < 12
      ? const [10, 20, 40, 60][config % 4] * 10      // SILK, in tenths of a ms
      : config < 16
          ? const [10, 20][config % 2] * 10           // hybrid
          : const [25, 50, 100, 200][config % 4];     // CELT
  final frames = switch (p[0] & 3) {
    0 => 1,
    1 || 2 => 2,
    _ => p.length > 1 ? p[1] & 0x3F : 1,
  };
  final ms = frame10 * frames ~/ 10;
  return ms > 0 ? ms : 20;
}

/// Who talking goes to (commVersion 11), as comm_to_t.
enum TalkTo { server, direct, person }

/// Who talking goes to: the server's channel, the direct group, or one
/// person, by their key, and whether they're on the server; with the name
/// for the board to show.
Uint8List talkToMessage(TalkTo to, {Uint8List? key, bool onServer = false, String name = ''}) =>
    Uint8List.fromList([
      _msgTalkTo,
      to.index,
      onServer ? 1 : 0,
      if (to == TalkTo.person) ...key!,
      ..._cut(utf8.encode(name), hearingNameMax),
    ]);

/// The pairs' keys, for talking to one alone over direct comms: each their
/// public key (32) and the key we share (16), in as many messages as it
/// takes; none, one message that starts the list afresh.
List<Uint8List> pairsMessages(List<(Uint8List, Uint8List)> pairs, int maxWrite) {
  const entry = 48;
  final per = ((maxWrite - 2) ~/ entry).clamp(1, 16);
  final out = <Uint8List>[];
  var at = 0;
  do {
    final n = (pairs.length - at).clamp(0, per);
    out.add(Uint8List.fromList([
      _msgPairs,
      at == 0 ? 1 : 0,
      for (final (their, key) in pairs.sublist(at, at + n)) ...[...their, ...key],
    ]));
    at += n;
  } while (at < pairs.length);
  return out;
}
Uint8List modeMessage(BoardMode mode) => Uint8List.fromList([_msgMode, mode.index]);
/// Start or stop recording: through the speaker's effect, with [preset]
/// in place of the wearer's own for as long as it records (commVersion
/// 22), and a sync beep to start if [beep]. With [speakerOnly], it doesn't
/// record: the speaker's effect is held at [preset], or let go, while the
/// phone's mic records.
Uint8List recordMessage(bool on, {int? preset, bool beep = false, bool speakerOnly = false}) => Uint8List.fromList([
      _msgRecord,
      on ? 1 : 0,
      1 | (beep ? 2 : 0) | (speakerOnly ? 4 : 0),
      if (on && preset != null && preset >= 0) preset,
    ]);

/// Have the board send the voice's level for the next 5 s, or stop
/// (commVersion 22).
Uint8List levelMessage(bool on) => Uint8List.fromList([_msgLevel, on ? 1 : 0]);

/// The board's voice, how loud, as it's sent or recorded: the loudest of
/// the last 100 ms, in dB of full scale (-60 to 0).
class VoiceLevel {
  final double db;
  const VoiceLevel(this.db);
}

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

/// A picture for the board's screen (core/app/pictures.h), [kind] a
/// [pictureJpeg] or [pictureGif], with its SHA-256, cut into messages of up
/// to [maxWrite] bytes: the start, its pieces, every [window]th asking for
/// an ack, then the end, which always does (commVersion 20).
const pictureJpeg = 0, pictureGif = 1;
const pictureMaxBytes = 256 * 1024;     // PICTURES_MAX_BYTES

List<Uint8List> pictureMessages(Uint8List bytes, int kind, List<int> hash, int maxWrite, {int window = 8}) =>
    _mediaMessages(_msgPicture, bytes, kind, hash, maxWrite, window);

/// A sound for the board's speaker (core/app/sounds.h), [kind] a
/// [soundOpus] or [soundFile], in messages as a picture's (commVersion 21).
const soundOpus = 0, soundFile = 1;
const soundMaxBytes = 96 * 1024;    // SOUNDS_MAX_BYTES
const soundMaxMs = 10000;           // AUDIO_SENT_MAX_MS: the most of it that plays

List<Uint8List> soundMessages(Uint8List bytes, int kind, List<int> hash, int maxWrite, {int window = 8}) =>
    _mediaMessages(_msgSentSound, bytes, kind, hash, maxWrite, window);

List<Uint8List> _mediaMessages(int op, Uint8List bytes, int kind, List<int> hash, int maxWrite, int window) {
  final n = bytes.length;
  final out = <Uint8List>[
    Uint8List.fromList([op, 1 | 4, n & 0xFF, (n >> 8) & 0xFF, (n >> 16) & 0xFF, (n >> 24) & 0xFF, kind, ...hash]),
  ];
  final room = maxWrite - 2;
  for (var at = 0, i = 1; at < n; at += room, i++) {
    final end = at + room < n ? at + room : n;
    out.add(Uint8List.fromList([op, i % window == 0 ? 4 : 0, ...Uint8List.sublistView(bytes, at, end)]));
  }
  out.add(Uint8List.fromList([op, 2]));
  return out;
}

/// The board's answer to a picture's pieces: [done] for the end's, [ok] all's
/// well (for the end: it's here, and came to its hash), and how much of it's
/// come.
class PictureAck {
  final bool done;
  final bool ok;
  final int received;
  final bool sound;     // a sound's pieces' (0x1B), not a picture's
  PictureAck(this.done, this.ok, this.received, {this.sound = false});
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

/// A command for others' boards (core/app/others.h), the same over the
/// server and over direct comms: the version, our public key, a counter
/// (our clock in ms, always more than our last), who it's for, then what to
/// do, signed with our identity key (identity.dart) for where it's sent
/// ([contextEveryone] and so on), so it can't be taken anywhere else. Each
/// board only does it if its wearer has allowed us, and only once, by our
/// key and the counter. HiveMind Control's, by area: Vibe toys, by
/// channel (V1 to V6, a bit for each in a byte, V1 the lowest), and the
/// Display unit's screen, words on its Terminal and pictures, and its
/// speaker, sounds; and texts and the like, for the app.
class OthersCommand {
  static const version = 3;
  static const message = 0x10;
  static const clear = 0x11;
  static const picture = 0x12;
  static const sound = 0x13;
  static const text = 0x20;
  static const textPart = 0x21;
  static const call = 0x30;
  static const invite = 0x31;
  static const reaction = 0x32;
  static const vibeStop = 0x40;
  static const vibeSet = 0x41;
  static const vibePart = 0x45;

  /// A picture's from: one sent, by its SHA-256, or one built into the
  /// firmware, by its name.
  static const pictureSent = 0, pictureBuiltIn = 1;

  /// A set's pattern's kind: none (a steady level), a built-in one by its
  /// name, or a custom one by its hash.
  static const patternNone = 0, patternBuiltIn = 1, patternCustom = 2;

  /// Who it's for, as the receivers see it: everyone who can hear us, the
  /// channel it goes on, or them alone.
  static const scopeEveryone = 0, scopeChannel = 1, scopeOne = 2;

  /// Vibe toys' channels, V1 to V6 (TOYS_CHANNELS), and all of them.
  static const vibeChannels = 6, allChannels = (1 << vibeChannels) - 1;

  /// The levels commands give, 0 to this, scaled to each output's own range.
  static const levelTop = 20;

  /// The longest a pattern's name can be, in bytes.
  static const nameMax = 24;

  /// The longest a message for the Terminal, and a text, can be, in bytes
  /// (OTHERS_WHAT_MAX, less what goes before them).
  static const messageMax = whatMax - 5;
  static const textMax = whatMax - 1;

  /// A longer text goes in parts, each this long at most, and no more than
  /// [partsMax] of them (so they all fit in the board's queue).
  static const partMax = whatMax - 5;
  static const partsMax = 6;

  /// The longest a text can be typed, in bytes of UTF-8: what's sure to go
  /// in [partsMax] parts, as a part's never cut in the middle of a
  /// character, which can leave up to 3 bytes of one unused.
  static const longTextBytes = partsMax * (partMax - 3);

  static const keyLength = 32, signatureLength = 64;
  static const headerLength = 40;     // OTHERS_HEADER_LEN
  static const whatMax = 117;         // OTHERS_WHAT_MAX
  static const _signedPrefix = 'dronelab-command\n';

  /// What to do and its arguments.
  final Uint8List what;
  final int counter;
  final int scope;
  const OthersCommand._(this.what, [this.counter = 0, this.scope = scopeEveryone]);

  static OthersCommand _make(List<int> what) => OthersCommand._(Uint8List.fromList(what));

  /// The same, numbered (counted from our clock, by the controller).
  OthersCommand withCounter(int c) => OthersCommand._(what, c, scope);

  /// The same, for [scope].
  OthersCommand withScope(int s) => OthersCommand._(what, counter, s);

  /// The command but its signature, from [key].
  Uint8List body(List<int> key) => Uint8List.fromList([
        version,
        ...key,
        for (var i = 0; i < 6; i++) (counter >> (8 * i)) & 0xFF,
        scope,
        ...what,
      ]);

  /// What it's sent in, signed with it but not sent (others.h).
  static List<int> contextEveryone() => [0x45];                          // 'E'
  static List<int> contextDirectChannel(List<int> groupId) => [0x43, ...groupId];  // 'C'
  static List<int> contextServerChannel(List<int> serverFingerprint, int channel) =>
      [0x53, ...serverFingerprint, channel & 0xFF, (channel >> 8) & 0xFF, (channel >> 16) & 0xFF, (channel >> 24) & 0xFF];
  static List<int> contextOne(List<int> theirKey) => [0x4F, ...theirKey];  // 'O'

  /// What's signed: the prefix, the context, then the command but its
  /// signature.
  static List<int> signedPart(List<int> context, List<int> body) =>
      [...utf8.encode(_signedPrefix), ...context, ...body];

  /// Stop every channel, and any reaction.
  static OthersCommand stopAll() => _make([vibeStop]);

  /// Set [channels] (a bit for each) as a whole: a level for each, from
  /// [levels] (V1's first, 0 to 20), how fast their pattern plays (25 to
  /// 300%), the reaction (reactive_mode_t: 0 none, 1 voice, 2 moving, 3
  /// still, 4 motion, 5 tilt), and the pattern: a built-in one by its name,
  /// a custom one by its hash (sent first, in [patternParts]), or none. A
  /// channel already playing the pattern keeps its place in it; a pattern
  /// with rows drives them in turn, its first row the lowest channel.
  static OthersCommand setVibe(int channels, List<int> levels,
      {int speed = 100, int react = 0, String? builtIn, List<int>? hash}) {
    final mask = channels & allChannels;
    final s = speed.clamp(25, 300);
    return _make([
      vibeSet,
      mask,
      for (var c = 0; c < vibeChannels; c++)
        if (mask & (1 << c) != 0) (c < levels.length ? levels[c] : 0).clamp(0, levelTop),
      s & 0xFF,
      s >> 8,
      react & 0xFF,
      if (hash != null) ...[patternCustom, ...hash]
      else if (builtIn != null) ...[patternBuiltIn, ..._cut(utf8.encode(builtIn), nameMax)]
      else patternNone,
    ]);
  }

  /// A custom pattern's definition (patterns.dart), in parts, each with
  /// its hash, sent before the set that plays it.
  static List<OthersCommand> patternParts(List<int> definition, List<int> hash) {
    const room = 106;   // PATTERNS_PART_MAX
    final count = (definition.length + room - 1) ~/ room;
    return [
      for (var i = 0; i < count; i++)
        _make([
          vibePart,
          ...hash,
          i,
          count,
          ...definition.sublist(i * room, (i + 1) * room > definition.length ? definition.length : (i + 1) * room),
        ]),
    ];
  }

  /// Words for their display's Terminal, as they are: added on a line of
  /// their own ([append]) or in place of what's there, at a letter size (0
  /// Auto, 1 to 6 for 8 to 48 px), brought on screen for [seconds], or with
  /// 0 until they move on, after which it goes back to what it was showing.
  static OthersCommand words(String text, {bool append = true, int size = 0, int seconds = 0}) => _make([
        message,
        append ? 1 : 0,
        size.clamp(0, 6),
        seconds.clamp(0, 0xFFFF) & 0xFF,
        seconds.clamp(0, 0xFFFF) >> 8,
        ..._cut(utf8.encode(text), messageMax),
      ]);

  /// A picture on their display, for [seconds] as [words]: one sent, by its
  /// SHA-256 (sent over the server, beside the command), or one built into
  /// the firmware, by its name.
  static OthersCommand showPicture({List<int>? hash, String? builtIn, int seconds = 0}) => _make([
        picture,
        seconds.clamp(0, 0xFFFF) & 0xFF,
        seconds.clamp(0, 0xFFFF) >> 8,
        if (hash != null) ...[pictureSent, ...hash] else ...[pictureBuiltIn, ..._cut(utf8.encode(builtIn ?? ''), 23)],
      ]);

  /// A sound from their unit's speaker, by its SHA-256: sent over the
  /// server, beside the command, as a picture is. Played once, and kept on
  /// their unit for them to play again. [visualizer] is 0 for nothing, or 1
  /// and up for a style from [soundVisualizers] (its index + 1), shown on
  /// their display while it plays.
  static OthersCommand playSound(List<int> hash, {int visualizer = 0}) => _make([sound, visualizer, ...hash]);

  /// The Sound Visualizer styles a sent sound can show, in the order of
  /// visualizers[] in core/ui/feature_visualizer.c: it must match.
  static const soundVisualizers = ['KITT', 'Terrain', 'Scope', 'Halo', 'Aurora', 'Orbit', 'Ripples'];

  /// Empty their Terminal, and take off what we put on their display: it
  /// goes back to what it was showing.
  static OthersCommand clearDisplay() => _make([clear]);

  /// A reaction to a message, by its id (8 bytes, messageRef): an emoji,
  /// or none to take ours back.
  static OthersCommand reactTo(List<int> ref, String emoji) => _make([reaction, ...ref, ..._cut(utf8.encode(emoji), 32)]);

  /// An invitation to a direct channel, sealed for them (invites.dart).
  static OthersCommand inviteTo(Uint8List sealed) => _make([invite, ...sealed]);

  /// A call's signal (calls.dart): what (CallOp) and the call's id.
  static OthersCommand callSignal(int op, int id) =>
      _make([call, op & 0xFF, id & 0xFF, (id >> 8) & 0xFF, (id >> 16) & 0xFF, (id >> 24) & 0xFF]);

  /// A text, for their app (over direct comms: the server has its own): in
  /// one command, or if it's too long for one, in parts, with [id] the same
  /// in each, for their app to put back together.
  static List<OthersCommand> sendText(String message, {int id = 0}) {
    final bytes = utf8.encode(message);
    if (bytes.length <= textMax) return [_make([text, ...bytes])];
    final parts = <List<int>>[];
    var at = 0;
    while (at < bytes.length && parts.length < partsMax) {
      var end = at + partMax < bytes.length ? at + partMax : bytes.length;
      // Not in the middle of a character
      while (end < bytes.length && end > at && bytes[end] & 0xC0 == 0x80) {
        end--;
      }
      parts.add(bytes.sublist(at, end));
      at = end;
    }
    return [
      for (var i = 0; i < parts.length; i++) _make([textPart, id & 0xFF, (id >> 8) & 0xFF, i, parts.length, ...parts[i]])
    ];
  }
}

/// A command as it came, read: who it's from, and the rest.
class ReadCommand {
  final Uint8List key;
  final int counter;
  final int scope;
  final Uint8List body;         // all but the signature
  final Uint8List signature;
  ReadCommand(this.key, this.counter, this.scope, this.body, this.signature);

  /// One signed, as sent; null if it isn't one.
  static ReadCommand? parse(Uint8List cmd) {
    const h = OthersCommand.headerLength, s = OthersCommand.signatureLength;
    if (cmd.length < h + 1 + s || cmd.length > othersCommandMax || cmd[0] != OthersCommand.version) return null;
    var counter = 0;
    for (var i = 5; i >= 0; i--) {
      counter = (counter << 8) | cmd[33 + i];
    }
    return ReadCommand(Uint8List.sublistView(cmd, 1, 33), counter, cmd[39], Uint8List.sublistView(cmd, 0, cmd.length - s),
        Uint8List.sublistView(cmd, cmd.length - s));
  }
}

/// The longest command the board takes (OTHERS_CMD_MAX), and the most
/// boards one sent over direct comms can be for (DIRECT_COMMAND_TARGETS).
const othersCommandMax = OthersCommand.headerLength + OthersCommand.whatMax + OthersCommand.signatureLength;
const directCommandTargets = 1;

/// The wearer's rules (rules.dart, core/app/rules.h), in pieces that fit
/// in [maxWrite] bytes: the first starts the document afresh, the last
/// ends it.
List<Uint8List> rulesMessages(Uint8List doc, int maxWrite) {
  final room = (maxWrite - 2).clamp(16, 240);
  final pieces = <Uint8List>[];
  for (var at = 0; at < doc.length || at == 0; at += room) {
    final end = (at + room).clamp(0, doc.length);
    final flags = (at == 0 ? 0x01 : 0) | (end >= doc.length ? 0x02 : 0);
    pieces.add(Uint8List.fromList([_msgRules, flags, ...doc.sublist(at, end)]));
    if (doc.isEmpty) break;
  }
  return pieces;
}

/// The wearer's favourite patterns' document (PatternLibrary
/// .favouritesDocument), in pieces that fit in [maxWrite] bytes, as the
/// rules go.
List<Uint8List> favouritesMessages(Uint8List doc, int maxWrite) =>
    [for (final r in rulesMessages(doc, maxWrite)) Uint8List.fromList([_msgFavourites, ...r.sublist(1)])];

/// Who the wearer is: their public key, for commands to them alone.
Uint8List identityMessage(List<int> key) => Uint8List.fromList([_msgIdentity, ...key]);

/// What the wearer signs to say the board's theirs (its direct comms id,
/// as the status gives it), and the message that gives the board the
/// signature.
List<int> boardBindingSigned(int directId) => [
      ...utf8.encode('dronelab-board\n'),
      directId & 0xFF, (directId >> 8) & 0xFF, (directId >> 16) & 0xFF, (directId >> 24) & 0xFF,
    ];
Uint8List bindingMessage(List<int> signature) => Uint8List.fromList([_msgBinding, ...signature]);

/// A command from [from] on the server, for the board: without its
/// signature, which we've checked.
Uint8List commandFromServer(String from, List<int> cmd) {
  final name = _cut(utf8.encode(from), hearingNameMax);
  return Uint8List.fromList([_msgCommand, 1, name.length, ...name, ...cmd]);
}

/// What we send others' Vibe toys, for the board's own to follow along:
/// what to do on alone, as the wearer's, so the rules don't come into it.
Uint8List commandOwn(List<int> what) => Uint8List.fromList([_msgCommand, 2, ...what]);

/// A command for the board to send over direct comms, to the boards with
/// these ids, or to all of them with none.
Uint8List commandToDirect(List<int> boards, List<int> cmd) {
  final ids = <int>[for (final id in boards) ...[id & 0xFF, (id >> 8) & 0xFF, (id >> 16) & 0xFF, (id >> 24) & 0xFF]];
  return Uint8List.fromList([_msgCommand, 0, boards.length, ...ids, ...cmd]);
}

/// The board's answer to the firmware coming from the app (commVersion 7).
class UpdateAck {
  final bool done;      // the end's been dealt with
  final bool ok;        // all's well
  final bool installing;    // it's all here, and the board's installing it
  final int result;     // what went wrong (updater.h's update_result_t), 0 for nothing
  final int received;   // how much of the firmware's come
  UpdateAck(this.done, this.ok, this.result, this.received, [this.installing = false]);
}

/// Why an update went wrong, from [UpdateAck.result].
String updateProblem(int result) => switch (result) {
      1 => "That firmware isn't for this unit",
      2 => "That firmware doesn't fit the unit",
      3 => 'The battery is too low. Charge it to 20% or more first',
      4 => "The unit couldn't start the update",
      5 => 'The update was interrupted',
      6 => "The unit couldn't write the firmware",
      7 => 'Not all of the firmware arrived',
      8 => 'The firmware was damaged on the way',
      _ => 'The update failed',
    };

/// The start of an update: the firmware's length, the board it's for, and
/// its version, for the board's screen.
Uint8List updateStartMessage(int length, String board, String version) {
  final text = utf8.encode('$board\n$version');
  return Uint8List.fromList([_msgUpdate, 0x01, ..._le32(length), ...text]);
}

/// A piece of the firmware, at [offset]; [ack] asks the board to say how
/// far it's got.
Uint8List updateDataMessage(int offset, Uint8List data, {bool ack = false}) =>
    Uint8List.fromList([_msgUpdate, ack ? 0x04 : 0x00, ..._le32(offset), ...data]);

/// The end: the board checks it and restarts into it.
Uint8List updateEndMessage() => Uint8List.fromList([_msgUpdate, 0x02]);

List<int> _le32(int v) => [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];

/// A long text coming in parts (OthersCommand.textPart).
class PartialText {
  /// Shown where parts never came.
  static const missing = '…(part missing)…';

  final Heard first;
  final int count;
  int? firstCounter;      // the first part's counter: the text's id
  final Map<int, Uint8List> parts = {};
  final Map<int, int?> counters = {};     // each part's counter, for its details
  Object? timer;      // the controller's, to show it if the rest don't come
  PartialText(this.first, this.count);

  /// What's come, in order, marking each run of parts that hasn't.
  Heard text() {
    final out = StringBuffer();
    var gap = false;
    for (var i = 0; i < count; i++) {
      final p = parts[i];
      if (p == null) {
        if (!gap) out.write(missing);
        gap = true;
      } else {
        out.write(utf8.decode(p, allowMalformed: true));
        gap = false;
      }
    }
    final h = first;
    return Heard(h.direct, true, Heard.text, h.scope, h.from, h.key, Uint8List.fromList(utf8.encode(out.toString())),
        firstCounter, [for (var i = 0; i < count; i++) parts.containsKey(i) ? counters[i] : null]);
  }
}
