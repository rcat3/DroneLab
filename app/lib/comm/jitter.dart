/// Turns the others' voice packets into one stream of sound for the
/// headphones.
///
/// Each speaker gets a jitter buffer: packets are decoded as they come, and
/// the sound waits until there's [targetMs] of it before it plays, to ride
/// out packets that arrive unevenly. It doesn't grow: if more than
/// [targetMs] + [maxExtraMs] builds up, as when a burst arrives after a
/// stall, the oldest is dropped, so the delay stays put. Lost packets are
/// filled in by Opus, from the next packet's error correction if it has it.
///
/// The mixer adds everyone together, softly limited, a block at a time, as
/// the headphones ask for it.
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// Decodes one speaker's packets. [lossMs] with [fec] asks for the sound
/// before [packet], from its error correction; a null packet asks Opus to
/// make up [lossMs] of sound.
abstract class VoiceDecoder {
  Int16List decode(Uint8List? packet, {bool fec = false, int? lossMs});
  void dispose() {}
}

typedef DecoderFactory = VoiceDecoder Function();

class Speaker {
  final int session;
  final int sampleRate;
  final VoiceDecoder _decoder;
  final int targetSamples;
  final int maxSamples;

  final List<Int16List> _chunks = [];
  int _offset = 0;        // into _chunks.first
  int queued = 0;         // samples waiting

  int? _expectedSeq;      // in 10 ms frames
  bool _ended = true;     // the last transmission has finished arriving
  bool _playing = false;
  int _lastPacketMs = 0;
  int lastSoundMs = 0;    // when it last played something, for "talking"

  // Counted for the screen and for tuning
  int packets = 0;
  int lost = 0;
  int underruns = 0;
  int dropped = 0;        // samples dropped to keep the delay down

  Speaker(this.session, this.sampleRate, this._decoder, {int targetMs = 60, int maxExtraMs = 120})
      : targetSamples = sampleRate * targetMs ~/ 1000,
        maxSamples = sampleRate * (targetMs + maxExtraMs) ~/ 1000;

  int get _samplesPerSeq => sampleRate ~/ 100;

  void receive(int seq, Uint8List opus, bool last, int nowMs) {
    // After a pause, a new transmission starts wherever its seq is.
    final fresh = _ended || _expectedSeq == null || nowMs - _lastPacketMs > 1000;
    _lastPacketMs = nowMs;
    if (fresh) {
      _expectedSeq = seq;
      _ended = false;
    }
    final expected = _expectedSeq!;
    if (!fresh && seq < expected) {
      return; // late or repeated
    }
    if (opus.isNotEmpty) {
      packets++;
      final gap = seq - expected;
      if (gap > 0 && gap <= 20) {
        // Lost up to 200 ms: get it back from this packet's error correction
        lost += (gap + 1) ~/ 2;
        _add(_decoder.decode(opus, fec: true, lossMs: gap * 10));
      } else if (gap > 20) {
        _expectedSeq = seq; // too long: carry on from here
      }
      final pcm = _decoder.decode(opus);
      _add(pcm);
      _expectedSeq = seq + math.max(1, pcm.length ~/ _samplesPerSeq);
    }
    if (last) _ended = true;
    _trim();
  }

  void _add(Int16List pcm) {
    if (pcm.isEmpty) return;
    _chunks.add(pcm);
    queued += pcm.length;
  }

  void _trim() {
    if (queued <= maxSamples) return;
    var drop = queued - targetSamples;
    dropped += drop;
    while (drop > 0 && _chunks.isNotEmpty) {
      final left = _chunks.first.length - _offset;
      if (left <= drop) {
        drop -= left;
        queued -= left;
        _chunks.removeAt(0);
        _offset = 0;
      } else {
        _offset += drop;
        queued -= drop;
        drop = 0;
      }
    }
  }

  /// Adds [out].length samples of this speaker into [out], if it's playing.
  /// Returns false if it had nothing to play.
  bool mixInto(Int32List out, int nowMs) {
    if (!_playing) {
      if (queued >= targetSamples || (_ended && queued > 0)) {
        _playing = true;
      } else {
        return false;
      }
    }
    var i = 0;
    while (i < out.length && _chunks.isNotEmpty) {
      final chunk = _chunks.first;
      final n = math.min(out.length - i, chunk.length - _offset);
      for (var k = 0; k < n; k++) {
        out[i + k] += chunk[_offset + k];
      }
      i += n;
      _offset += n;
      queued -= n;
      if (_offset == chunk.length) {
        _chunks.removeAt(0);
        _offset = 0;
      }
    }
    if (i < out.length) {
      // Ran out: wait for enough again, unless that was the end
      _playing = false;
      if (!_ended) underruns++;
    }
    if (i > 0) lastSoundMs = nowMs;
    return i > 0;
  }

  /// True while it's been heard in the last moment, for the screen.
  bool talking(int nowMs) => nowMs - lastSoundMs < 250;

  /// Nothing has come for a while and it's all been played.
  bool idle(int nowMs) => queued == 0 && nowMs - _lastPacketMs > 30000;

  void dispose() => _decoder.dispose();
}

class Mixer {
  final int sampleRate;
  final DecoderFactory newDecoder;
  int targetMs;
  final Map<int, Speaker> speakers = {};
  double volume = 1.0;

  Mixer({required this.sampleRate, required this.newDecoder, this.targetMs = 60});

  void receive(int session, int seq, Uint8List opus, bool last, int nowMs) {
    final s = speakers.putIfAbsent(
        session, () => Speaker(session, sampleRate, newDecoder(), targetMs: targetMs));
    s.receive(seq, opus, last, nowMs);
  }

  void remove(int session) => speakers.remove(session)?.dispose();

  /// The next [count] samples of everyone together.
  Int16List pull(int count, int nowMs) {
    final sum = Int32List(count);
    var any = false;
    for (final s in speakers.values) {
      if (s.mixInto(sum, nowMs)) any = true;
    }
    final out = Int16List(count);
    if (!any) return out;
    final v = volume;
    for (var i = 0; i < count; i++) {
      var x = sum[i] * v / 32768.0;
      // Soft limit above about -3 dB, for when two talk at once
      final a = x.abs();
      if (a > 0.7) {
        x = x.sign * (0.7 + 0.3 * _tanh((a - 0.7) / 0.3));
      }
      out[i] = (x * 32767).round().clamp(-32768, 32767);
    }
    speakers.removeWhere((_, s) {
      final gone = s.idle(nowMs);
      if (gone) s.dispose();
      return gone;
    });
    return out;
  }

  Set<int> talking(int nowMs) => {
        for (final s in speakers.values)
          if (s.talking(nowMs)) s.session
      };

  static double _tanh(double x) {
    final e = math.exp(2 * x);
    return (e - 1) / (e + 1);
  }
}
