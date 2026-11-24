import 'dart:convert';
import 'dart:typed_data';

import 'package:dronelab/comm/avatars.dart';
import 'package:dronelab/comm/board_protocol.dart';
import 'package:dronelab/comm/conversations.dart';
import 'package:dronelab/comm/identity.dart';
import 'package:dronelab/comm/message_details.dart';
import 'package:dronelab/comm/patterns.dart';
import 'package:dronelab/comm/recorder.dart';
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
    expect([peer.id, peer.rssi, peer.talking, peer.name, peer.firmware], [1, -60, true, 'Pup', '']);
    final versioned = parseBoardMessage(Uint8List.fromList(
        [0x08, 1, 0, 0, 0, 0xC4, 2, 6, ...'v0.9.4'.codeUnits, 3, ...'1.2'.codeUnits, ...'Pup'.codeUnits])) as DirectPeer;
    expect([versioned.talking, versioned.firmware, versioned.app, versioned.name], [false, 'v0.9.4', '1.2', 'Pup']);
    final noPhone = parseBoardMessage(Uint8List.fromList(
        [0x08, 1, 0, 0, 0, 0xC4, 2, 6, ...'v0.9.4'.codeUnits, 0, ...'Pup'.codeUnits])) as DirectPeer;
    expect([noPhone.firmware, noPhone.app, noPhone.name], ['v0.9.4', '', 'Pup']);
    final key = List.generate(32, (i) => i + 1);
    final keyed = parseBoardMessage(Uint8List.fromList([0x08, 1, 0, 0, 0, 0xC4, 4, ...key, ...'Pup'.codeUnits]))
        as DirectPeer;
    expect([keyed.key, keyed.name], [key, 'Pup']);
    final h = parseBoardMessage(Uint8List.fromList([0x0F, 3, 0, 2, 3, ...'Pup'.codeUnits, ...key, ...'HI'.codeUnits]))
        as Heard;
    expect([h.direct, h.done, h.what, h.scope, h.from, h.key, h.textOf], [true, true, 0, 2, 'Pup', key, 'HI']);
    final av = parseBoardMessage(Uint8List.fromList([0x0D, 2, 0, 0, 0, 112, 3, 126, 0x1F, 0xF8])) as DirectAvatarPiece;
    expect([av.id, av.size, av.piece, av.pieces, av.pixels], [2, 112, 3, 126, [0x1F, 0xF8]]);
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
    final g = parseBoardMessage(Uint8List.fromList([0x09, 0xde, 0xad, 0xbe, 0xef, 0xC4, 3, 11, 1, ...'Pack'.codeUnits]))
        as DirectGroupHeard;
    expect([g.id, g.rssi, g.boards, g.channel, g.longRange, g.name], ['deadbeef', -60, 3, 11, true, 'Pack']);
  });

  test('recording messages', () {
    expect(recordMessage(true, speakerVoice: true, beep: true), [0x0A, 1, 3]);
    expect(recordMessage(false), [0x0A, 0, 0]);
    final r = parseBoardMessage(Uint8List.fromList([0x0A, 0x34, 0x12, 1, 7, 8])) as RecordedSound;
    expect([r.sound.seq, r.sound.first, r.sound.opus], [0x1234, true, [7, 8]]);
    final st = parseBoardMessage(Uint8List.fromList([0x02, 3, 0, 8])) as BoardStatus;
    expect(st.recording, isTrue);
    expect(st.battery, isNull);
    final charged = parseBoardMessage(Uint8List.fromList([0x02, 6, 0, 0, 0x80 | 82])) as BoardStatus;
    expect([charged.battery, charged.charging], [82, true]);
  });

  test('a WAV header for 48 kHz mono', () {
    final h = ByteData.sublistView(wavHeader(96000));
    expect(String.fromCharCodes(h.buffer.asUint8List(0, 4)), 'RIFF');
    expect(h.getUint32(24, Endian.little), 48000);
    expect(h.getUint32(40, Endian.little), 96000);
    expect(h.lengthInBytes, 44);
  });

  test('commands for others, as others.h', () async {
    final me = await Identity.fromSeed(List.generate(32, (i) => i));
    final key = me.publicKey;
    final cmd = OthersCommand.stopAll().withCounter(0x060504030201).withScope(OthersCommand.scopeOne);
    expect(cmd.body(key), [3, ...key, 1, 2, 3, 4, 5, 6, 2, 0x40]);
    expect(OthersCommand.setVibe(0x05, [25, 0, 7]).what, [0x41, 0x05, 20, 7, 100, 0, 0, 0]);
    expect(OthersCommand.setVibe(0xFF, [1, 2, 3, 4, 5, 6], speed: 1000, react: 2, builtIn: 'Wave').what,
        [0x41, 0x3F, 1, 2, 3, 4, 5, 6, 300 & 0xFF, 300 >> 8, 2, 1, ...utf8.encode('Wave')]);
    expect(OthersCommand.setVibe(0x02, [0, 9], hash: List.filled(8, 0xAB)).what,
        [0x41, 0x02, 9, 100, 0, 0, 2, ...List.filled(8, 0xAB)]);
    expect(describeCommand(OthersCommand.setVibe(0x05, [7, 0, 7]).what, mine: false), 'set your toys on V1+V3 to 7');
    expect(describeCommand(OthersCommand.setVibe(0x3F, List.filled(6, 7), builtIn: 'Pulse', speed: 150).what, mine: true),
        'set their toys to 7, playing Pulse at 150%');
    expect(describeCommand(OthersCommand.setVibe(0x03, [5, 9], react: 1).what, mine: false),
        'set your toys on V1+V2 to 5/9, reacting to voice');
    expect(OthersCommand.terminal('hi', append: false, show: true, size: 3).what, [0x10, 2, 3, ...utf8.encode('hi')]);
    // The longest fit, signed
    final long = OthersCommand.terminal('x' * 500).body(key).length + OthersCommand.signatureLength;
    expect(long, othersCommandMax);
    expect(OthersCommand.sendText('y' * OthersCommand.textMax), hasLength(1));
    expect(OthersCommand.sendText('y' * OthersCommand.textMax).first.what[0], OthersCommand.text);
    // Longer, in parts, each fitting, cut only between characters
    final long2 = 'abc😀' * 100;   // 700 bytes
    final parts = OthersCommand.sendText(long2, id: 0x1234);
    expect(parts.length, OthersCommand.partsMax);
    for (var i = 0; i < parts.length; i++) {
      final w = parts[i].what;
      expect(w.sublist(0, 5), [OthersCommand.textPart, 0x34, 0x12, i, parts.length]);
      expect(parts[i].body(key).length + OthersCommand.signatureLength, lessThanOrEqualTo(othersCommandMax));
      utf8.decode(w.sublist(5));   // whole characters: throws if not
    }
    final joined = utf8.decode([for (final p in parts) ...p.what.sublist(5)]);
    expect(long2.startsWith(joined), isTrue);
    expect(utf8.encode(joined).length, greaterThan(OthersCommand.partsMax * (OthersCommand.partMax - 4)));

    // Signed for one person, it's only good for them
    final theirs = List.filled(32, 9);
    final body = cmd.body(key);
    final sig = await me.sign(OthersCommand.signedPart(OthersCommand.contextOne(theirs), body));
    final read = ReadCommand.parse(Uint8List.fromList([...body, ...sig]))!;
    expect([read.key, read.counter, read.scope], [key, 0x060504030201, OthersCommand.scopeOne]);
    expect(await Identity.verify(read.key, OthersCommand.signedPart(OthersCommand.contextOne(theirs), read.body),
        read.signature), isTrue);
    expect(await Identity.verify(read.key, OthersCommand.signedPart(OthersCommand.contextOne(key), read.body),
        read.signature), isFalse);

    expect(commandFromServer('Ann', body), [0x0B, 1, 3, ...utf8.encode('Ann'), ...body]);
    expect(commandToDirect(const [], body), [0x0B, 0, 0, ...body]);
    expect(commandToDirect(const [0x11223344], body), [0x0B, 0, 1, 0x44, 0x33, 0x22, 0x11, ...body]);
  });

  test('a long text from its parts, with gaps for those that never came', () {
    final key = Uint8List(32);
    final first = Heard(true, true, Heard.textPart, 0, 'Ann', key, Uint8List(0));
    final p = PartialText(first, 5)
      ..parts[0] = Uint8List.fromList(utf8.encode('one '))
      ..parts[2] = Uint8List.fromList(utf8.encode('three '))
      ..parts[4] = Uint8List.fromList(utf8.encode('five'));
    expect(p.text().textOf, 'one ${PartialText.missing}three ${PartialText.missing}five');
    p.parts.remove(4);
    p.parts.remove(2);
    expect(p.text().textOf, 'one ${PartialText.missing}');   // one gap for a run
    expect([p.text().what, p.text().from, p.text().direct], [Heard.text, 'Ann', true]);
  });

  test('packed repeated fields', () {
    final m = ProtoMessage.parse((ProtoWriter()..packed(2, [5, 300])).toBytes());
    expect(m.bytes(2), [5, 0xAC, 0x02]);
  });

  test('who talking goes to, the pairs, and what the board says of talking', () {
    final key = Uint8List.fromList(List.generate(32, (i) => i));
    final m = talkToMessage(TalkTo.person, key: key, onServer: true, name: 'Unit 7');
    expect(m.sublist(0, 3), [0x13, 2, 1]);
    expect(m.sublist(3, 35), key);
    expect(utf8.decode(m.sublist(35)), 'Unit 7');
    expect(talkToMessage(TalkTo.direct, name: 'Open channel').sublist(0, 3), [0x13, 1, 0]);

    final pairs = [for (var i = 0; i < 9; i++) (Uint8List(32)..[0] = i, Uint8List(16)..[0] = 100 + i)];
    final msgs = pairsMessages(pairs, 244);
    expect(msgs.length, 2);   // 5 to a message
    expect(msgs.first.sublist(0, 2), [0x14, 1]);
    expect(msgs[1][1], 0);
    expect(msgs.first[2 + 48], 1);   // the second's key
    expect(msgs.first[2 + 32], 100);  // the first's shared key
    expect(pairsMessages(const [], 244).single, [0x14, 1]);

    final t = parseBoardMessage(Uint8List.fromList([0x13, 2, 4])) as Talked;
    expect(t.what, Talked.refused);
    expect(t.alone, isTrue);
    expect(t.byVoice, isFalse);
    final d = parseBoardMessage(Uint8List.fromList([0x07, 1, 0, 0, 0, 5, 0, 4, 9])) as DirectSound;
    expect(d.alone, isTrue);
  });

  test('voice whispered to us is told apart', () {
    final out = BytesBuilder()
      ..addByte((voiceTypeOpus << 5) | IncomingVoice.whisperedToUs);
    writeMumbleVarint(out, 7);
    writeMumbleVarint(out, 3);
    writeMumbleVarint(out, 1);
    out.addByte(0x42);
    final v = decodeVoice(out.toBytes())!;
    expect(v.session, 7);
    expect(v.alone, isTrue);
    expect(encodeVoice(seq: 1, opus: Uint8List(1), target: 1)[0] & 0x1F, 1);
  });

  test('a copy of a command heard over direct comms, and a text\'s details kept', () {
    final msg = Uint8List.fromList([
      0x15, 1, 2, 3, 4, 5, 6, 7, 8,     // the sender's key's first 8 bytes
      0x10, 0x20, 0x30, 0x40, 0x50, 0x60,   // the command's counter
      0x01, 0x02, 0x00, 0x00,           // the broadcast's
      0xBA, 1, 186,                     // -70 dBm, relayed once, 186 bytes
    ]);
    final c = parseBoardMessage(msg) as HeardCopy;
    expect(c.keyId, '0102030405060708');
    expect(c.counter, 0x605040302010);
    expect(c.broadcast, 0x0201);
    expect(c.rssi, -70);
    expect(c.hops, 1);
    expect(c.bytes, 186);

    final d = MessageDetails(OthersCommand.scopeChannel, [
      MessageRoute(MessageRoute.direct, 1000,
          channel: 'Hive',
          bytes: 12,
          radio: const DirectChannelInfo('Hive', 'a1b2c3d4', true, 11, true, 'Unit 1'),
          sends: 3,
          packets: [
            RadioPacket(0, 42, 186, [const RadioCopy(7, -70, 0, 186, 1000), const RadioCopy(7, -80, 1, 186, 1010)]),
            RadioPacket(1, null, 0),
          ]),
      MessageRoute(MessageRoute.server, 1500, channel: 'Root', bytes: 40, host: 'example:64738'),
    ]);
    final back = MessageDetails.fromJson(jsonDecode(jsonEncode(d.toJson())) as Map<String, dynamic>);
    expect(back.scope, OthersCommand.scopeChannel);
    expect(back.routes.length, 2);
    final r = back.routes.first;
    expect(r.radio!.frequency, 11);
    expect(r.packets.first.copies.length, 2);
    expect(r.packets.first.sendsHeard, 1);    // one send, and a relay of it
    expect(r.packets[1].counter, isNull);
    expect(r.lastCopyMs, 1010);
    expect(back.routes[1].host, 'example:64738');
    expect(directFrameBytes(40 + 30 + 64, targets: 1), 15 + 2 + 4 + 134 + 8);
  });

  test("an Opus packet's length, from its first bytes", () {
    expect(opusPacketMs(Uint8List.fromList([0x48])), 20);     // SILK wideband, 20 ms
    expect(opusPacketMs(Uint8List.fromList([0x40])), 10);     // SILK wideband, 10 ms
    expect(opusPacketMs(Uint8List.fromList([0xF8])), 20);     // CELT fullband, 20 ms
    expect(opusPacketMs(Uint8List.fromList([0xF0])), 10);     // CELT fullband, 10 ms
    expect(opusPacketMs(Uint8List.fromList([0xF9])), 40);     // two 20 ms frames
    expect(opusPacketMs(Uint8List.fromList([0xF3, 0x03])), 30);   // three 10 ms frames
    expect(directVoiceMessage(Uint8List.fromList([1, 2]), first: true), [0x16, 0, 0, 1, 1, 2]);
  });

  test("a text's details as first kept, a map for each copy, still read", () {
    final old = {
      'v': 'direct', 't': 1000, 's': 3,
      'p': [
        {'p': 0, 'c': 42, 'n': 186, 'x': [{'b': 7, 'r': -70, 'h': 0, 'n': 186, 't': 1000}, {'b': 7, 'r': -80, 'h': 1, 'n': 186, 't': 1010}]}
      ],
    };
    final r = MessageRoute.fromJson(old);
    expect(r.packets.first.copies.length, 2);
    expect(r.packets.first.copies[1].rssi, -80);
    expect(r.lastCopyMs, 1010);
    // And kept the new way, smaller, the same when read back
    final again = MessageRoute.fromJson(jsonDecode(jsonEncode(r.toJson())) as Map<String, dynamic>);
    expect(again.packets.first.copies[1].broadcast, 7);
    expect(again.packets.first.copies[1].atMs, 1010);
    expect(again.packets.first.copies[1].bytes, 186);
    expect(jsonEncode(r.toJson()).length, lessThan(jsonEncode(old).length));
  });

  test('custom patterns, as patterns.h', () {
    final p = VibePattern('A', [PatternBlock(100, 1, [20, 0, 5])]);
    final def = p.encode();
    expect(def, [1, 1, 0x41, 1, 100, 0, 1, 3, 0, 0x14, 0x14]);
    final back = VibePattern.decode(def)!;
    expect(back.name, 'A');
    expect(back.blocks.single.levels, [20, 0, 5]);
    expect(VibePattern.decode([...def, 0]), isNull);
    // Two rows, the longest that fits, in six parts
    final rows = VibePattern('Two', [
      PatternBlock(100, 1, List.generate(489, (i) => i % 21)),
      PatternBlock(200, 2, List.generate(489, (i) => 20 - i % 21)),
    ]);
    expect(rows.fits, isTrue);
    final parts = OthersCommand.patternParts(rows.encode(), rows.hash);
    expect(parts, hasLength(6));
    expect(parts.every((c) => c.what.length <= OthersCommand.whatMax), isTrue);
    expect(parts.first.what.sublist(1, 9), rows.hash);
    expect(VibePattern.decode(rows.encode())!.blocks[1].levels, rows.blocks[1].levels);
    expect(rows.level(1, 200), 19 / 20);
    expect(rows.level(2, 0), isNull);
    // Lovense's format, both ways
    final l = VibePattern.fromLovense('V:1;F:v,r;S:200#5,10;6,11;20,0;')!;
    expect(l.blocks.map((b) => b.rows), [1, 2]);
    expect(l.blocks[1].levels, [10, 11, 0]);
    expect(l.toLovense(), 'V:1;F:v1,v2;S:200#5,10;6,11;20,0;');
    expect(VibePattern.fromLovense('V:1;F:v;S:100#0;4;8;')!.blocks.single.rows, 0);
  });
}
