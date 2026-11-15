import 'dart:typed_data';

import 'package:dronelab/comm/board_protocol.dart';
import 'package:dronelab/comm/protobuf.dart';
import 'package:dronelab/comm/voice_packet.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('protobuf fields round trip', () {
    final bytes = (ProtoWriter()
          ..int_(1, 0x010400)
          ..string(3, 'Pup')
          ..bool_(5, true)
          ..int_(7, 1 << 40))
        .toBytes();
    final m = ProtoMessage.parse(bytes);
    expect(m.int_(1), 0x010400);
    expect(m.string(3), 'Pup');
    expect(m.bool_(5), isTrue);
    expect(m.int_(7), 1 << 40);
    expect(m.has(2), isFalse);
  });

  test('Mumble varints', () {
    for (final v in [0, 1, 0x7F, 0x80, 0x3FFF, 0x4000, 0x1FFFFF, 0x200000, 0xFFFFFFF, 0x10000000, 0xFFFFFFFF]) {
      final b = BytesBuilder();
      writeMumbleVarint(b, v);
      expect(readMumbleVarint(b.toBytes()), v, reason: 'value $v');
    }
  });

  test('voice from the server', () {
    // What the server sends: our client format with the speaker's session after the header byte
    final ours = encodeVoice(seq: 1234, opus: Uint8List.fromList([1, 2, 3]), last: true);
    final b = BytesBuilder()
      ..addByte(ours[0])
      ..add([0x80 | (300 >> 8), 300 & 0xFF]) // session 300
      ..add(ours.sublist(1));
    final v = decodeVoice(b.toBytes())!;
    expect(v.session, 300);
    expect(v.seq, 1234);
    expect(v.opus, [1, 2, 3]);
    expect(v.last, isTrue);
  });

  test('board messages', () {
    final sound = parseBoardMessage(Uint8List.fromList([1, 0x34, 0x12, 1, 9, 8])) as BoardSound;
    expect(sound.seq, 0x1234);
    expect(sound.first, isTrue);
    expect(sound.last, isFalse);
    expect(sound.opus, [9, 8]);
    final status = parseBoardMessage(Uint8List.fromList([2, 1, 1, 7])) as BoardStatus;
    expect(status.mode, BoardMode.voice);
    expect(status.sending, isTrue);
    expect(status.hearsVoice, isTrue);
    expect(status.buttonConnected, isTrue);
    expect(talkMessage(true), [1, 1]);
    expect(modeMessage(BoardMode.pushToTalk), [2, 0]);
  });
}
