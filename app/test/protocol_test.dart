import 'dart:convert';
import 'dart:typed_data';

import 'package:dronelab/comm/avatars.dart';
import 'package:dronelab/comm/board_protocol.dart';
import 'package:image/image.dart' as img;
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

  test("the remote's requests and answers", () {
    final request = Uint8List.fromList(List.generate(130, (i) => i));
    final msgs = requestMessages(7, request);
    expect(msgs.length, 3); // 61 + 61 + 8
    expect(msgs.every((m) => m.length <= boardMaxWrite), isTrue);
    expect(msgs.map((m) => m[2]).toList(), [1, 0, 2]);
    expect(msgs.expand((m) => m.sublist(3)).toList(), request);
    expect(requestMessages(1, Uint8List.fromList([65]))[0], [3, 1, 3, 65]);
    final piece = parseBoardMessage(Uint8List.fromList([3, 7, 3, 0x32, 0x30, 0x30, 10])) as AnswerPiece;
    expect(piece.id, 7);
    expect(piece.first && piece.last, isTrue);
    expect(String.fromCharCodes(piece.data), '200\n');
  });

  test("the page's hash matches the board's", () {
    // FNV-1a test vectors
    expect(fnv1a([]), 0x811c9dc5);
    expect(fnv1a('a'.codeUnits), 0xe40c292c);
    expect(fnv1a('foobar'.codeUnits), 0xbf9cf968);
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

  test('server message', () {
    final m = serverMessage(ServerLink.connected, udp: true, others: 3, channel: 'Root', ownAvatar: 2);
    expect(m, [0x04, 1 | 4, 3, 2, ...'Root'.codeUnits]);
    expect(serverMessage(ServerLink.connecting), [0x04, 2, 0, avatarNone]);
    expect(serverMessage(ServerLink.connected, channel: 'x' * 100).length, boardMaxWrite);
  });

  String names(Uint8List m) {
    // [slot]name\n... as "slot:name|"
    final out = StringBuffer();
    var i = 1;
    while (i < m.length) {
      final slot = m[i++];
      final direct = m[i++];
      if (direct == 1) out.write('*');
      final end = m.indexOf(0x0A, i);
      out.write('$slot:${utf8.decode(m.sublist(i, end))}|');
      i = end + 1;
    }
    return out.toString();
  }

  test('hearing message fits, and counts the rest', () {
    expect(hearingMessage([]), [0x05]);
    expect(names(hearingMessage(const [Talker('Pup', 1), Talker('Drone7', avatarNone, true)])), '1:Pup|*255:Drone7|');
    final many = hearingMessage([for (final n in 'abcdef'.split('')) Talker(n, 0)]);
    expect(names(many), '0:a|0:b|0:c|255:+3|');
    final long = hearingMessage([for (final c in 'ABCD'.split('')) Talker(c * 30, 3)]);
    expect(long.length, lessThanOrEqualTo(boardMaxWrite));
    expect(long.length, lessThanOrEqualTo(boardMaxWrite));
    expect(names(long).split('|').last, '');
    // Not cut inside a character
    expect(names(hearingMessage(const [Talker('ééééééééééééé')])), '255:éééééééééé|');
  });

  test('avatar pieces fit, ask for acks, and add up', () {
    final rgb = Uint8List.fromList(List.generate(112 * 112 * 2, (i) => i & 0xFF));
    final pieces = avatarMessages(5, rgb, 244, window: 8);
    expect(pieces.every((p) => p.length <= 244 && p[0] == 0x06 && p[1] == 5), isTrue);
    expect(pieces.first[2] & 1, 1);
    expect(pieces.last[2] & 6, 6);
    expect(pieces[7][2] & 4, 4);
    expect(pieces[6][2] & 4, 0);
    expect(pieces.fold<int>(0, (n, p) => n + p.length - 3), rgb.length);
    final ack = parseBoardMessage(Uint8List.fromList([0x06, 5, 3, 0x00, 0x62, 0, 0])) as AvatarAck;
    expect([ack.slot, ack.done, ack.ok, ack.received], [5, true, true, 0x6200]);
  });

  test('a picture becomes RGB565 for the board', () {
    final im = img.Image(width: 40, height: 20);
    img.fill(im, color: img.ColorRgb8(255, 0, 0));
    final out = avatarRgb565(img.encodePng(im), 8)!;
    expect(out.length, 8 * 8 * 2);
    expect(out[0] | (out[1] << 8), 0xF800);
  });

  test('direct comms messages from the board', () {
    final sound = parseBoardMessage(Uint8List.fromList([0x07, 0x78, 0x56, 0x34, 0x12, 0x34, 0x12, 1, 9, 8])) as DirectSound;
    expect([sound.sender, sound.seq, sound.first, sound.last, sound.opus], [0x12345678, 0x1234, true, false, [9, 8]]);
    final peer = parseBoardMessage(Uint8List.fromList([0x08, 1, 0, 0, 0, 0xC4, 1, ...'Pup'.codeUnits])) as DirectPeer;
    expect([peer.id, peer.rssi, peer.talking, peer.name], [1, -60, true, 'Pup']);
  });

  test('a direct group key is the same for the same name and passphrase', () {
    final k = directKey(('Pack', 'woof woof'));
    expect(k, hasLength(32));
    expect(k, directKey(('Pack', 'woof woof')));
    expect(k, isNot(directKey(('Pack', 'woof'))));
    expect(k, isNot(directKey(('Pack2', 'woof woof'))));
    // As the board makes it (direct_key), for its echo test group
    // Standard PBKDF2, as mbedtls makes it on the board (worked out with Python's hashlib)
    expect(directKey(('Echo Test', 'dronelab')), 'a7e1ccc952f49e4b7696b6fecffcd502');
    expect(directGroupId(directKey(('Echo Test', 'dronelab'))), 'b1fbe3b4');
  });

  test('a heard group from the board', () {
    final g = parseBoardMessage(Uint8List.fromList([0x09, 0xde, 0xad, 0xbe, 0xef, 0xC4, 3, ...'Pack'.codeUnits]))
        as DirectGroupHeard;
    expect([g.id, g.rssi, g.boards, g.name], ['deadbeef', -60, 3, 'Pack']);
  });
}

