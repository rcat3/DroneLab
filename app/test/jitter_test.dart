import 'dart:typed_data';

import 'package:dronelab/comm/jitter.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every packet is 20 ms of one value, the packet's first byte, so the
/// tests can see which packet each sample came from.
class FakeDecoder implements VoiceDecoder {
  final List<String> calls = [];
  @override
  Int16List decode(Uint8List? packet, {bool fec = false, int? lossMs}) {
    if (fec) {
      calls.add('fec $lossMs');
      return Int16List(48 * lossMs!)..fillRange(0, 48 * lossMs, -1);
    }
    calls.add('decode ${packet![0]}');
    return Int16List(960)..fillRange(0, 960, packet[0] * 100);
  }

  @override
  void dispose() {}
}

Uint8List p(int v) => Uint8List.fromList([v]);

void main() {
  test('waits for the target before playing, then plays in order', () {
    final dec = FakeDecoder();
    final s = Speaker(1, 48000, dec, targetMs: 60);
    final out = Int32List(480);
    s.receive(10, p(1), false, 0);
    s.receive(12, p(2), false, 20);
    expect(s.mixInto(out, 20), isFalse, reason: '40 ms is less than the target');
    s.receive(14, p(3), false, 40);
    expect(s.mixInto(out, 40), isTrue);
    expect(out[0], 100);
  });

  test('a lost packet comes back from error correction', () {
    final dec = FakeDecoder();
    final s = Speaker(1, 48000, dec);
    s.receive(0, p(1), false, 0);
    s.receive(4, p(3), false, 40); // 2 is lost
    expect(dec.calls, ['decode 1', 'fec 20', 'decode 3']);
    expect(s.lost, 1);
    expect(s.queued, 960 * 3);
  });

  test("the delay doesn't grow after a burst", () {
    final s = Speaker(1, 48000, FakeDecoder(), targetMs: 60, maxExtraMs: 120);
    for (var i = 0; i < 20; i++) {
      s.receive(i * 2, p(i + 1), false, 0); // 400 ms all at once
    }
    expect(s.queued, lessThanOrEqualTo(48 * 180));
    expect(s.dropped, greaterThan(0));
  });

  test('the end of a transmission plays out, and the next starts fresh', () {
    final s = Speaker(1, 48000, FakeDecoder(), targetMs: 60);
    s.receive(0, p(1), false, 0);
    s.receive(2, Uint8List(0), true, 20); // just the terminator
    final out = Int32List(960);
    expect(s.mixInto(out, 20), isTrue, reason: 'plays without waiting for the target');
    expect(s.queued, 0);
    // A new transmission with a lower seq, as after a reconnect
    s.receive(0, p(5), false, 5000);
    expect(s.queued, 960);
  });

  test('the mixer adds speakers and limits softly', () {
    final m = Mixer(sampleRate: 48000, newDecoder: FakeDecoder.new, targetMs: 20);
    m.receive(1, 0, p(200), true, 0); // 20000 each
    m.receive(2, 0, p(200), true, 0);
    final out = m.pull(480, 0);
    expect(out[0], greaterThan(20000));
    expect(out[0], lessThan(32767));
    expect(m.talking(0), {1, 2});
  });

  test('tones play over the voices, and then stop', () {
    final m = Mixer(sampleRate: 48000, newDecoder: FakeDecoder.new, targetMs: 20);
    final chirp = m.chirp(rising: true);
    expect(chirp.length, 48 * 140);
    expect(chirp.first, 0, reason: 'faded in');
    m.playTone(chirp);
    var heard = 0;
    for (var i = 0; i < 20; i++) {
      final out = m.pull(480, 0);
      if (out.any((s) => s != 0)) heard++;
    }
    expect(heard, 14, reason: '140 ms of tone, in 10 ms blocks');
  });
}
