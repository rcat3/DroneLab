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

  test('a packet come too late holds back more, and steady talk brings it back', () {
    final s = Speaker(1, 48000, _MakesUp(), targetMs: 60);
    final out = Int32List(960);     // 20 ms a pull
    expect(s.heldMs, 60);
    // Three packets, played; then nothing for a while, so it makes up
    // sound, and the next packet comes after its time
    for (var i = 0; i < 3; i++) {
      s.receive(i * 2, p(i + 1), false, i * 20);
    }
    for (var t = 60; t <= 140; t += 20) {
      out.fillRange(0, out.length, 0);
      s.mixInto(out, t);
    }
    expect(s.concealed, greaterThan(0));
    s.receive(6, p(4), false, 160);     // its sound was made up already
    expect(s.late, 1);
    expect(s.heldMs, 80);
    // Another in the same stall doesn't grow it again
    s.receive(8, p(5), false, 170);
    expect(s.heldMs, 80);
    // Steady for a while: the next transmission holds back a little less
    s.receive(10, p(6), true, 200);
    s.receive(100, p(7), false, 200 + Speaker.steadyMs + 2000);
    expect(s.heldMs, 70);
  });
}

/// As FakeDecoder, but makes up silence when nothing came.
class _MakesUp extends FakeDecoder {
  @override
  Int16List decode(Uint8List? packet, {bool fec = false, int? lossMs}) =>
      packet == null && !fec ? Int16List(48 * (lossMs ?? 20)) : super.decode(packet, fec: fec, lossMs: lossMs);
}
