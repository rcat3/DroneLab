/// Turns the others' voice packets into one stream of sound for the
/// headphones.
///
/// Each speaker gets a jitter buffer: packets are decoded as they come, and
/// the sound waits until there's [targetMs] of it before it plays, to ride
/// out packets that arrive unevenly. It doesn't grow: if more than
/// [targetMs] + [maxExtraMs] builds up, as when a burst arrives after a
/// stall, the oldest is dropped, so the delay stays put. Lost packets are
/// filled in by Opus, from the next packet's error correction if it has it.
/// If it runs dry partway through, Opus makes up what's missing, for up to
/// [Speaker.maxConcealMs], rather than going quiet and waiting for the whole
/// [targetMs] again; what comes late after that is dropped.
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
  /// What it holds back before playing, and the most before it drops some
  /// to catch up. It adapts: a packet come too late (its sound already
  /// made up) holds back [growMs] more, up to [mostExtraMs] over
  /// [baseSamples]; steady for [steadyMs], it comes back down by [shrinkMs]
  /// as a transmission starts, so the delay never jumps mid-word. Voices
  /// that come evenly (the phone's mic) stay at the least; a unit's, which
  /// come in bursts (its encoder and Bluetooth), get what they need.
  final int baseSamples;
  int targetSamples;
  final int _extraSamples;
  int get maxSamples => targetSamples + _extraSamples;
  int get heldMs => targetSamples * 1000 ~/ sampleRate;

  static const growMs = 20;
  static const shrinkMs = 10;
  static const mostExtraMs = 160;
  static const steadyMs = 15000;
  // When one last came late, and it last grew and shrank: long ago at first
  static const _longAgo = -1 << 40;
  int _lateAtMs = _longAgo;
  int _grewAtMs = _longAgo;
  int _shrankAtMs = _longAgo;

  final List<Int16List> _chunks = [];
  int _offset = 0;        // into _chunks.first
  int queued = 0;         // samples waiting

  int? _expectedSeq;      // in 10 ms frames
  int _newestSeq = -1;    // the newest come, to tell late from repeated
  bool _ended = true;     // the last transmission has finished arriving
  bool _playing = false;
  int _lastPacketMs = 0;
  int lastSoundMs = 0;    // when it last played something, for "talking"

  // Counted for the screen and for tuning
  int packets = 0;
  int lost = 0;
  int underruns = 0;
  int dropped = 0;        // samples dropped to keep the delay down
  int concealed = 0;      // 10 ms frames made up while it ran dry
  int late = 0;           // packets come after their sound was made up, and left out

  /// How long Opus makes up sound for while nothing comes, before it stops
  /// and waits for the buffer to fill again.
  static const maxConcealMs = 100;
  int _concealRun = 0;    // ms made up since the last real packet

  Speaker(this.session, this.sampleRate, this._decoder, {int targetMs = 60, int maxExtraMs = 120})
      : baseSamples = sampleRate * targetMs ~/ 1000,
        targetSamples = sampleRate * targetMs ~/ 1000,
        _extraSamples = sampleRate * maxExtraMs ~/ 1000;

  /// A packet came too late: hold back more, once for each stall.
  void _grow(int nowMs) {
    _lateAtMs = nowMs;
    if (nowMs - _grewAtMs < 500) return;
    _grewAtMs = nowMs;
    final most = baseSamples + sampleRate * mostExtraMs ~/ 1000;
    targetSamples = math.min(most, targetSamples + sampleRate * growMs ~/ 1000);
  }

  /// As a transmission starts: steady a while, hold back a little less.
  void _maybeShrink(int nowMs) {
    if (targetSamples <= baseSamples || nowMs - _lateAtMs < steadyMs || nowMs - _shrankAtMs < steadyMs) return;
    _shrankAtMs = nowMs;
    targetSamples = math.max(baseSamples, targetSamples - sampleRate * shrinkMs ~/ 1000);
  }

  int get _samplesPerSeq => sampleRate ~/ 100;

  void receive(int seq, Uint8List opus, bool last, int nowMs) {
    // After a pause, a new transmission starts wherever its seq is.
    final fresh = _ended || _expectedSeq == null || nowMs - _lastPacketMs > 1000;
    _lastPacketMs = nowMs;
    if (fresh) {
      _expectedSeq = seq;
      _newestSeq = seq - 1;
      _ended = false;
      _maybeShrink(nowMs);
    }
    final expected = _expectedSeq!;
    if (!fresh && seq < expected) {
      // Late (its time's been made up already) or repeated (direct sends
      // each twice): only the late are counted, as the newest seen came before
      if (seq > _newestSeq) {
        late++;
        _grow(nowMs);
      }
      _newestSeq = math.max(_newestSeq, seq);
      return;
    }
    _newestSeq = math.max(_newestSeq, seq);
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
      _concealRun = 0;
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
    // Ran dry partway through: make up a little rather than go quiet
    while (i < out.length && !_ended && _expectedSeq != null && _concealRun < maxConcealMs) {
      final pcm = _decoder.decode(null, lossMs: 20);
      if (pcm.isEmpty) break;
      _concealRun += 20;
      concealed += 2;
      _expectedSeq = _expectedSeq! + 2;
      final n = math.min(out.length - i, pcm.length);
      for (var k = 0; k < n; k++) {
        out[i + k] += pcm[k];
      }
      if (n < pcm.length) {
        _add(Int16List.sublistView(pcm, n));    // the rest, for next time
      }
      i += n;
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

  // Tones for the wearer, like the start and stop of talking, played over
  // whatever's playing
  final List<Int16List> _tones = [];
  int _toneAt = 0;

  /// Where tones go instead, if it takes them (true): a computer's sound
  /// out, which mixes them in itself, so they don't wait on the app to be
  /// fed through. Given them at [volume].
  bool Function(Int16List)? toneSink;
  void Function()? stopToneSink;

  void playTone(Int16List samples) {
    if (hushed) return;
    final sink = toneSink;
    if (sink != null) {
      final v = volume;
      if (sink(v == 1.0 ? samples : Int16List.fromList([for (final x in samples) (x * v).round()]))) return;
    }
    _tones.add(samples);
  }

  /// Stop what [playTone] is playing, and drop the rest.
  void stopTones() {
    _tones.clear();
    _toneAt = 0;
    stopToneSink?.call();
  }

  /// Two short notes, rising or falling, faded at their ends so they don't
  /// click.
  Int16List chirp({required bool rising, double level = 0.25}) {
    const noteMs = 70;
    final n = sampleRate * noteMs ~/ 1000;
    final fade = sampleRate * 5 ~/ 1000;
    final notes = rising ? const [660.0, 990.0] : const [990.0, 660.0];
    final out = Int16List(n * notes.length);
    for (var k = 0; k < notes.length; k++) {
      for (var i = 0; i < n; i++) {
        final edge = math.min(i, n - 1 - i);
        final env = edge >= fade ? 1.0 : edge / fade;
        out[k * n + i] = (math.sin(2 * math.pi * notes[k] * i / sampleRate) * env * level * 32767).round();
      }
    }
    return out;
  }

  /// Talking refused, as nobody would hear it: a low buzz, as a radio's
  /// "talk prohibit", hard to mistake for the chirps.
  Int16List refusedTone({double level = 0.22}) {
    const ms = 400, hz = 320.0;
    final n = sampleRate * ms ~/ 1000;
    final fade = sampleRate * 8 ~/ 1000;
    final out = Int16List(n);
    for (var i = 0; i < n; i++) {
      final edge = math.min(i, n - 1 - i);
      final env = edge >= fade ? 1.0 : edge / fade;
      final t = 2 * math.pi * hz * i / sampleRate;
      // Odd harmonics, for a buzz rather than a beep
      final v = math.sin(t) + math.sin(3 * t) / 3 + math.sin(5 * t) / 5;
      out[i] = (v * 0.8 * env * level * 32767).round();
    }
    return out;
  }

  Mixer({required this.sampleRate, required this.newDecoder, this.targetMs = 60});

  /// [extraMs] waits that much longer for this speaker's voice, for one that
  /// comes less evenly (direct comms' repeats can come 40 ms late).
  /// Nothing's played while this is on (a HiveSight Vessel's view is open):
  /// voices and tones are dropped, not kept for later.
  bool hushed = false;

  void receive(int session, int seq, Uint8List opus, bool last, int nowMs, {int extraMs = 0}) {
    if (hushed) return;
    final s = speakers.putIfAbsent(session, () {
      final sp = Speaker(session, sampleRate, newDecoder(), targetMs: targetMs + extraMs);
      // What it learned last time, so a bursty voice doesn't break up
      // again at the start of each conversation
      final held = _learned[session];
      if (held != null) {
        sp.targetSamples = held.clamp(sp.baseSamples, sp.baseSamples + sampleRate * Speaker.mostExtraMs ~/ 1000);
      }
      return sp;
    });
    s.receive(seq, opus, last, nowMs);
  }

  /// How much each voice held back, kept after its speaker goes idle.
  final Map<int, int> _learned = {};

  void remove(int session) => speakers.remove(session)?.dispose();

  /// The next [count] samples of everyone together.
  Int16List pull(int count, int nowMs) {
    final sum = Int32List(count);
    var any = false;
    for (final s in speakers.values) {
      if (s.mixInto(sum, nowMs)) any = true;
    }
    var i = 0;
    while (i < count && _tones.isNotEmpty) {
      final tone = _tones.first;
      final n = math.min(count - i, tone.length - _toneAt);
      for (var k = 0; k < n; k++) {
        sum[i + k] += tone[_toneAt + k];
      }
      i += n;
      _toneAt += n;
      any = true;
      if (_toneAt == tone.length) {
        _tones.removeAt(0);
        _toneAt = 0;
      }
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
      if (gone) {
        _learned[s.session] = s.targetSamples;
        s.dispose();
      }
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
