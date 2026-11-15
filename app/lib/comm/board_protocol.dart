/// The board's comm channel over Bluetooth LE, as in core/app/comm.h.
///
/// Board to phone, notified on [toPhoneUuid]:
///   sound   [0x01][seq LE16][flags][opus]   flags: 1 first, 2 last (no opus)
///   status  [0x02][version][mode][flags]    flags: 1 sending, 2 hears the voice,
///                                           4 the talk button is connected
/// Phone to board, written to [fromPhoneUuid]:
///   talk    [0x01][0 or 1]
///   mode    [0x02][mode]
/// Both ways, the phone remote's requests and their answers, in pieces:
///   request [0x03][id][flags][piece of "METHOD /api/...\n" + body]
///   answer  [0x03][id][flags][piece of "200\n" + JSON, "304\n" or "404\n"]
///           flags: 1 the first piece, 2 the last
/// The link has to be paired (the board shows a code) before any of it works.
library;

import 'dart:typed_data';

const serviceUuid = 'efe06e1b-a7ff-4823-bfbb-b3a82ea05849';
const toPhoneUuid = 'efe06e1c-a7ff-4823-bfbb-b3a82ea05849';
const fromPhoneUuid = 'efe06e1d-a7ff-4823-bfbb-b3a82ea05849';

/// The board's message versions (COMM_VERSION in comm.h), in its status:
///   1  sound, status, talk and mode
///   2  the phone remote's requests, GET /version, pairing with a code, and
///      the status's talk button bit
const commVersion = 2;
const commVersionRemote = 2;

/// The board's sound: 20 ms Opus packets of 16 kHz mono.
const boardSampleRate = 16000;
const boardFrameMs = 20;

const _msgSound = 0x01;
const _msgStatus = 0x02;
const _msgTalk = 0x01;
const _msgMode = 0x02;
const _msgRequest = 0x03;

/// The longest message the board takes from the phone.
const boardMaxWrite = 64;

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

class AnswerPiece {
  final int id;
  final bool first;
  final bool last;
  final Uint8List data;
  AnswerPiece(this.id, this.first, this.last, this.data);
}

/// A notification from the board: a [BoardSound], a [BoardStatus], an
/// [AnswerPiece], or null.
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
  if (data[0] == _msgRequest && data.length >= 3) {
    return AnswerPiece(data[1], data[2] & 1 != 0, data[2] & 2 != 0, Uint8List.sublistView(data, 3));
  }
  return null;
}

/// A request, cut into messages small enough for the board.
List<Uint8List> requestMessages(int id, Uint8List request) {
  const room = boardMaxWrite - 3;
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

/// FNV-1a, 32 bits: how the board tells whether the app's copy of the
/// remote's page is the same as its own.
int fnv1a(List<int> bytes) {
  var h = 0x811c9dc5;
  for (final b in bytes) {
    h = ((h ^ b) * 0x01000193) & 0xFFFFFFFF;
  }
  return h;
}
