/// The board's comm channel over Bluetooth LE, as in core/app/comm.h.
///
/// Board to phone, notified on [toPhoneUuid]:
///   sound   [0x01][seq LE16][flags][opus]   flags: 1 first, 2 last (no opus)
///   status  [0x02][version][mode][flags]    flags: 1 sending, 2 hears the voice
/// Phone to board, written to [fromPhoneUuid]:
///   talk    [0x01][0 or 1]
///   mode    [0x02][mode]
library;

import 'dart:typed_data';

const serviceUuid = 'efe06e1b-a7ff-4823-bfbb-b3a82ea05849';
const toPhoneUuid = 'efe06e1c-a7ff-4823-bfbb-b3a82ea05849';
const fromPhoneUuid = 'efe06e1d-a7ff-4823-bfbb-b3a82ea05849';

const commVersion = 1;

/// The board's sound: 20 ms Opus packets of 16 kHz mono.
const boardSampleRate = 16000;
const boardFrameMs = 20;

const _msgSound = 0x01;
const _msgStatus = 0x02;
const _msgTalk = 0x01;
const _msgMode = 0x02;

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
  BoardStatus(this.version, this.mode, this.sending, this.hearsVoice);
}

/// A notification from the board: a [BoardSound], a [BoardStatus], or null.
Object? parseBoardMessage(Uint8List data) {
  if (data.length < 4) return null;
  switch (data[0]) {
    case _msgSound:
      return BoardSound(data[1] | (data[2] << 8), data[3] & 1 != 0, data[3] & 2 != 0,
          Uint8List.sublistView(data, 4));
    case _msgStatus:
      final mode = data[2] < BoardMode.values.length ? BoardMode.values[data[2]] : BoardMode.pushToTalk;
      return BoardStatus(data[1], mode, data[3] & 1 != 0, data[3] & 2 != 0);
  }
  return null;
}

Uint8List talkMessage(bool talk) => Uint8List.fromList([_msgTalk, talk ? 1 : 0]);
Uint8List modeMessage(BoardMode mode) => Uint8List.fromList([_msgMode, mode.index]);
