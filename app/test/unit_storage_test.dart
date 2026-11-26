import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dronelab/comm/board_link.dart';
import 'package:dronelab/comm/board_protocol.dart';
import 'package:dronelab/comm/card_media.dart';
import 'package:dronelab/comm/unit_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// A unit that takes files as core/app/storage_save.c does: in order, a piece
/// that isn't where it's got to is left out, the hash checked at the end.
class _FakeUnit extends BoardLink {
  final acks = StreamController<StorageAck>.broadcast(sync: true);
  final received = BytesBuilder();
  List<int>? hash;
  String? savedName;
  int? kind;
  int length = 0;
  bool open = false;
  int pieces = 0;
  int dropEvery = 0;       // lose every nth piece on the way
  bool dropAcks = false;   // even one that asks for an ack
  int refuseWith = 0;      // a result to refuse the start with
  bool? hashOk;
  int aborted = 0;

  _FakeUnit() {
    state = BoardState.connected;
    status = BoardStatus(commVersionStorage, BoardMode.pushToTalk, false, false, false);
  }

  @override
  int get maxWrite => 100;

  @override
  Stream<StorageAck> get storageAcks => acks.stream;

  @override
  Future<bool> sendFast(Uint8List msg, {int tries = 20, Duration wait = const Duration(milliseconds: 20)}) async {
    expect(msg[0], 0x1D);
    expect(msg.length, lessThanOrEqualTo(maxWrite));
    final flags = msg[1];
    if (flags & 8 != 0) {
      open = false;
      aborted++;
    } else if (msg.length < 7 && flags == 4) {
      acks.add(StorageAck(false, open, received.length, 0));     // a keep-alive
    } else if (flags & 1 != 0) {
      kind = msg[2];
      length = msg[3] | (msg[4] << 8) | (msg[5] << 16) | (msg[6] << 24);
      hash = msg.sublist(7, 39);
      savedName = String.fromCharCodes(msg.sublist(39));
      received.clear();
      open = refuseWith == 0;
      acks.add(StorageAck(false, open, 0, refuseWith));
    } else if (flags & 2 != 0) {
      final ok = open && received.length == length && sha256.convert(received.toBytes()).bytes.toString() == hash.toString();
      hashOk = ok;
      open = false;
      acks.add(StorageAck(true, ok, received.length, ok ? 0 : StorageResult.badHash));
    } else {
      pieces++;
      if (dropEvery > 0 && pieces % dropEvery == 0 && (flags & 4 == 0 || dropAcks)) return true;      // lost
      final at = msg[2] | (msg[3] << 8) | (msg[4] << 16) | (msg[5] << 24);
      if (at == received.length) received.add(msg.sublist(6));
      if (flags & 4 != 0) acks.add(StorageAck(false, open, received.length, 0));
    }
    return true;
  }
}

void main() {
  test('storage messages are laid out as the unit reads them', () {
    final hash = List<int>.generate(32, (i) => i);
    final start = storageStart(storageSound, 0x010203, hash, 'a b.mp3');
    expect(start.sublist(0, 7), [0x1D, 5, 1, 3, 2, 1, 0]);
    expect(start.sublist(7, 39), hash);
    expect(String.fromCharCodes(start.sublist(39)), 'a b.mp3');
    final bytes = Uint8List.fromList(List.generate(300, (i) => i & 0xFF));
    final piece = storagePiece(bytes, 256, 100, ack: true);
    expect(piece.sublist(0, 6), [0x1D, 4, 0, 1, 0, 0]);
    expect(piece.length, 6 + 44);
    expect(storageEnd(), [0x1D, 6]);
    final ack = parseBoardMessage(Uint8List.fromList([0x1D, 3, 0x10, 0x20, 0, 0, 4])) as StorageAck;
    expect(ack.done, isTrue);
    expect(ack.ok, isTrue);
    expect(ack.received, 0x2010);
    expect(ack.result, StorageResult.noRoom);
  });

  test('a file goes across, and comes to its hash', () async {
    final unit = _FakeUnit();
    final saver = UnitStorage(unit, voiceBusy: () => false);
    final bytes = Uint8List.fromList(List.generate(5000, (i) => i * 31 & 0xFF));
    saver.enqueue(SaveJob(storageSound, 'a.wav', bytes));
    while (saver.active) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(saver.lastError, isNull);
    expect(saver.saved, 1);
    expect(unit.savedName, 'a.wav');
    expect(unit.hashOk, isTrue);
    expect(unit.received.toBytes(), bytes);
  });

  test('pieces that are lost go again, from where the unit has got to', () async {
    final unit = _FakeUnit()..dropEvery = 13;
    final saver = UnitStorage(unit, voiceBusy: () => false);
    final bytes = Uint8List.fromList(List.generate(20000, (i) => i * 7 & 0xFF));
    saver.enqueue(SaveJob(storageSound, 'long.mp3', bytes));
    while (saver.active) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(saver.lastError, isNull);
    expect(unit.hashOk, isTrue);
    expect(unit.received.toBytes(), bytes);
  });

  test('a lost ask is asked again after a wait', () async {
    final unit = _FakeUnit()
      ..dropEvery = 7
      ..dropAcks = true;
    final saver = UnitStorage(unit, voiceBusy: () => false, ackWait: const Duration(milliseconds: 50));
    final bytes = Uint8List.fromList(List.generate(3000, (i) => i * 5 & 0xFF));
    saver.enqueue(SaveJob(storageSound, 'lossy.mp3', bytes));
    while (saver.active) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(saver.lastError, isNull);
    expect(unit.received.toBytes(), bytes);
  });

  test('a refusal is told, and what waits is dropped', () async {
    final unit = _FakeUnit()..refuseWith = StorageResult.exists;
    final saver = UnitStorage(unit, voiceBusy: () => false);
    saver.enqueue(SaveJob(storagePicture, 'cat.jpg', Uint8List(100)));
    saver.enqueue(SaveJob(storagePicture, 'dog.jpg', Uint8List(100)));
    while (saver.active) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(saver.saved, 0);
    expect(saver.lastError, StorageResult.text(StorageResult.exists));
    expect(unit.savedName, 'cat.jpg');
    expect(unit.aborted, 1);
  });

  test('it waits while voice is on', () async {
    final unit = _FakeUnit();
    var busy = true;
    final saver = UnitStorage(unit, voiceBusy: () => busy);
    saver.enqueue(SaveJob(storageSound, 'a.wav', Uint8List(1000)));
    await Future<void>.delayed(const Duration(milliseconds: 800));
    expect(saver.paused, isTrue);
    expect(unit.received.length, 0);
    busy = false;
    while (saver.active) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(unit.hashOk, isTrue);
  });

  test('cancelling stops it', () async {
    final unit = _FakeUnit();
    var busy = true;
    final saver = UnitStorage(unit, voiceBusy: () => busy);
    saver.enqueue(SaveJob(storageSound, 'a.wav', Uint8List(1000)));
    await Future<void>.delayed(const Duration(milliseconds: 400));
    saver.cancel();
    while (saver.active) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(saver.saved, 0);
    expect(saver.lastError, isNull);
    expect(unit.aborted, 1);
  });

  test('names are made ones the unit takes, and kept apart', () {
    expect(cardFileName('My cat ☺ pic', 'jpg'), 'My cat _ pic.jpg');
    expect(cardFileName('..', 'png'), 'saved.png');
    expect(cardFileName('x' * 100, 'gif').length, storageNameMax);
    expect(freeCardName('cat.jpg', ['dog.jpg']), 'cat.jpg');
    expect(freeCardName('cat.jpg', ['CAT.jpg']), 'cat (2).jpg');
    expect(freeCardName('cat.jpg', ['cat.jpg', 'cat (2).jpg']), 'cat (3).jpg');
  });

  test('a big picture is made screen sized, a GIF is left, a see-through PNG stays one', () {
    final photo = img.Image(width: 1600, height: 1200);
    final jpeg = pictureForCard((Uint8List.fromList(img.encodeJpg(photo)), false));
    expect(jpeg.ext, 'jpg');
    final out = img.decodeJpg(jpeg.bytes!)!;
    expect(out.width, 466);
    expect(out.height, 350);

    final gif = Uint8List.fromList([0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 100, 0, 100, 0, 0, 0]);
    expect(pictureForCard((gif, false)).bytes, gif);
    final huge = Uint8List.fromList([0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0, 4, 100, 0, 0, 0]);
    expect(pictureForCard((huge, false)).bytes, isNull);

    final clear = img.Image(width: 64, height: 64, numChannels: 4);
    final png = Uint8List.fromList(img.encodePng(clear));
    expect(pictureForCard((png, false)).ext, 'png');
    expect(pictureForCard((png, true)).ext, 'jpg');
    expect(pictureForCard((Uint8List(10), false)).why, isNotNull);
  });

  test('a stereo WAV is mixed to mono, and a long one lowered, to fit', () {
    Uint8List wav(int channels, int rate, int frames) {
      final data = ByteData(frames * channels * 2);
      for (var i = 0; i < frames * channels; i++) {
        data.setInt16(2 * i, (i % 100) * 100, Endian.little);
      }
      final h = ByteData(44);
      void tag(int at, String s) {
        for (var i = 0; i < 4; i++) {
          h.setUint8(at + i, s.codeUnitAt(i));
        }
      }

      tag(0, 'RIFF');
      h.setUint32(4, 36 + data.lengthInBytes, Endian.little);
      tag(8, 'WAVE');
      tag(12, 'fmt ');
      h.setUint32(16, 16, Endian.little);
      h.setUint16(20, 1, Endian.little);
      h.setUint16(22, channels, Endian.little);
      h.setUint32(24, rate, Endian.little);
      h.setUint32(28, rate * channels * 2, Endian.little);
      h.setUint16(32, channels * 2, Endian.little);
      h.setUint16(34, 16, Endian.little);
      tag(36, 'data');
      h.setUint32(40, data.lengthInBytes, Endian.little);
      return Uint8List.fromList([...h.buffer.asUint8List(), ...data.buffer.asUint8List()]);
    }

    final mono = wav(1, 44100, 1000);
    expect(soundForCard(mono).bytes, mono);
    final stereo = soundForCard(wav(2, 44100, 1000));
    expect(stereo.bytes!.length, 44 + 2000);
    // Four minutes of 48 kHz stereo is far over 3 MB; mono at 24 kHz, too, so the rate comes down more
    final long = soundForCard(wav(2, 48000, 48000 * 100));
    expect(long.bytes, isNotNull);
    expect(long.bytes!.length, lessThanOrEqualTo(storageSoundMaxBytes));
    expect(soundForCard(Uint8List(100)).why, isNotNull);
  });
}
