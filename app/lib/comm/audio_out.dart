/// Plays the mixer to the phone's audio output (Bluetooth headphones, as
/// media). It keeps playing silence between voices: Bluetooth headphones take
/// a moment to wake up, which would cut off the start of what's said.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:opus_codec/opus_flutter.dart' as opus_flutter;
import 'package:opus_codec_dart/opus_dart.dart';

import 'jitter.dart';

const outputRate = 48000;
const _blockMs = 10;
const _block = outputRate * _blockMs ~/ 1000;
// Keep this much queued in the phone. The phone's own buffer comes on top.
const _queuedMs = 40;
const _thresholdMs = 20;
// On a computer, kept on top of the most its sound card takes at once
const _marginMs = 30;
const _mostAheadMs = 200;

bool _opusLoaded = false;

Future<void> loadOpus() async {
  if (_opusLoaded) return;
  initOpus(await opus_flutter.load());
  _opusLoaded = true;
}

class OpusVoiceDecoder implements VoiceDecoder {
  final SimpleOpusDecoder _decoder = SimpleOpusDecoder(sampleRate: outputRate, channels: 1);

  /// The most Opus makes up in one go.
  static const _maxLossMs = 120;

  @override
  Int16List decode(Uint8List? packet, {bool fec = false, int? lossMs}) {
    try {
      if (packet == null || fec) {
        // opus_dart's `loss` goes to Opus as the frame size, in samples,
        // despite saying it's in ms: asking for 20 got 20 samples, which Opus
        // turns down, and the sound came out missing. So it's in samples
        // here, and no more than Opus makes up at once: anything before the
        // last 20 ms is made up first, then that last part comes from this
        // packet's error correction.
        var ms = (lossMs ?? 20) - (lossMs ?? 20) % 10;
        if (ms <= 0) ms = 20;
        final parts = <Int16List>[];
        if (fec && ms > 20) {
          var made = ms - 20;
          while (made > 0) {
            final n = made > _maxLossMs ? _maxLossMs : made;
            parts.add(_decoder.decode(input: null, loss: outputRate * n ~/ 1000));
            made -= n;
          }
          ms = 20;
        }
        while (ms > 0) {
          final n = ms > _maxLossMs ? _maxLossMs : ms;
          parts.add(_decoder.decode(input: packet, fec: fec, loss: outputRate * n ~/ 1000));
          ms -= n;
        }
        if (parts.length == 1) return parts.first;
        final out = Int16List(parts.fold(0, (a, p) => a + p.length));
        var at = 0;
        for (final p in parts) {
          out.setAll(at, p);
          at += p.length;
        }
        return out;
      }
      return _decoder.decode(input: packet);
    } on OpusException {
      return Int16List(0);
    }
  }

  @override
  void dispose() => _decoder.destroy();
}

class AudioOut {
  final Mixer mixer;
  bool _running = false;
  int _clockMs = 0;

  AudioOut(this.mixer);

  Future<void>? _starting;

  /// Start playing. Called again while it's starting, it waits for the same
  /// start: the server and direct comms can both ask at once, and setting the
  /// player up twice leaves it silent.
  Future<void> start() {
    if (_running) return Future.value();
    return _starting ??= _start().whenComplete(() => _starting = null);
  }

  Future<void> _start() async {
    if (Platform.isLinux) return _startNative();
    await FlutterPcmSound.setLogLevel(LogLevel.error);
    await FlutterPcmSound.setup(
        sampleRate: outputRate,
        channelCount: 1,
        iosAudioCategory: IosAudioCategory.playback,
        iosAllowBackgroundAudio: true);
    await FlutterPcmSound.setFeedThreshold(outputRate * _thresholdMs ~/ 1000);
    FlutterPcmSound.setFeedCallback(_feed);
    _running = true;
    FlutterPcmSound.start();
  }

  void _feed(int remaining) {
    if (!_running) return;
    final want = outputRate * _queuedMs ~/ 1000 - remaining;
    final blocks = want <= 0 ? 1 : (want + _block - 1) ~/ _block;
    final out = Int16List(blocks * _block);
    for (var b = 0; b < blocks; b++) {
      // The mixer's idea of the time moves with what's been played.
      _clockMs = DateTime.now().millisecondsSinceEpoch;
      out.setRange(b * _block, (b + 1) * _block, mixer.pull(_block, _clockMs));
    }
    FlutterPcmSound.feed(PcmArrayInt16(bytes: out.buffer.asByteData()));
  }

  // On a computer: the mixer into native/audio_out.c's ring, kept ahead by
  // how much the ring holds, so the sound card's clock sets the pace. Ahead
  // by _queuedMs, or by the most the card's taken at once and _marginMs on
  // top, where a card takes big gulps: else each would empty the ring. It's
  // fed between the UI's frames, so the UI kept busy holds it up (the splash
  // left animating, once, made it choppy; a debug build's slow frames still
  // can): so it's also kept ahead by the longest it's been held up lately,
  // and _marginMs, up to _mostAheadMs, coming down by 1 ms a second after.
  // Tones don't wait on any of it: they go to the native side whole.
  _NativeAudio? _native;
  Timer? _nativeTimer;
  Int16List _pcm = Int16List(0);
  int _lastTickMs = 0;

  /// How it's kept up, on a computer: times the sound card ran dry, and the
  /// longest the timer that feeds it was held up, in ms (each 5 ms at best).
  int get underruns => _native?.underruns() ?? 0;

  /// The most the sound card's taken at once, in ms.
  int get burstMs => (_native?.burst() ?? 0) * 1000 ~/ outputRate;
  int longestTickMs = 0;
  double _heldUpMs = 0;     // lately, coming down slowly

  /// How far ahead it's kept just now, in ms.
  int aheadMs = _queuedMs;

  Future<void> _startNative() async {
    final n = _native ??= _NativeAudio.open();
    final failed = n.start(outputRate, outputRate, _blockMs);
    if (failed != 0) throw StateError('No sound out ($failed)');
    _running = true;
    mixer.toneSink = n.tone;
    mixer.stopToneSink = n.stopTones;
    _nativeTimer = Timer.periodic(const Duration(milliseconds: _blockMs ~/ 2), (_) {
      if (!_running) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (_lastTickMs != 0) {
        final gap = now - _lastTickMs;
        if (gap > longestTickMs) longestTickMs = gap;
        _heldUpMs = math.max(_heldUpMs - gap / 1000, (gap - _blockMs ~/ 2).toDouble());
      }
      _lastTickMs = now;
      final burstMs = n.burst() * 1000 ~/ outputRate;
      aheadMs = math.min(_mostAheadMs, math.max(_queuedMs, math.max(burstMs, _heldUpMs.round()) + _marginMs));
      final target = outputRate * aheadMs ~/ 1000;
      final want = target - n.queued();
      if (want <= 0) return;
      final blocks = (want + _block - 1) ~/ _block;
      if (_pcm.length < blocks * _block) _pcm = n.buffer(blocks * _block);
      for (var b = 0; b < blocks; b++) {
        _clockMs = DateTime.now().millisecondsSinceEpoch;
        _pcm.setRange(b * _block, (b + 1) * _block, mixer.pull(_block, _clockMs));
      }
      n.write(blocks * _block);
    });
  }

  Future<void> stop() async {
    await _starting;
    if (!_running) return;
    _running = false;
    if (_native != null) {
      mixer.toneSink = null;
      mixer.stopToneSink = null;
      _nativeTimer?.cancel();
      _nativeTimer = null;
      _native!.stop();
      return;
    }
    FlutterPcmSound.setFeedCallback(null);
    await FlutterPcmSound.release();
  }
}

/// native/audio_out.c, in the app's lib folder.
class _NativeAudio {
  final int Function(int, int, int) start;
  final int Function() queued;
  final int Function(Pointer<Int16>, int) _write;
  final void Function() stop;
  final int Function() underruns;
  final int Function() burst;
  final int Function(Pointer<Int16>, int) _tone;
  final void Function() stopTones;
  Pointer<Int16> _buffer = nullptr;

  _NativeAudio._(DynamicLibrary lib)
      : start = lib.lookupFunction<Int32 Function(Int32, Int32, Int32), int Function(int, int, int)>('dl_audio_start'),
        queued = lib.lookupFunction<Int32 Function(), int Function()>('dl_audio_queued'),
        _write = lib.lookupFunction<Int32 Function(Pointer<Int16>, Int32), int Function(Pointer<Int16>, int)>(
            'dl_audio_write'),
        stop = lib.lookupFunction<Void Function(), void Function()>('dl_audio_stop'),
        underruns = lib.lookupFunction<Int32 Function(), int Function()>('dl_audio_underruns'),
        burst = lib.lookupFunction<Int32 Function(), int Function()>('dl_audio_burst'),
        _tone = lib.lookupFunction<Int32 Function(Pointer<Int16>, Int32), int Function(Pointer<Int16>, int)>(
            'dl_audio_tone'),
        stopTones = lib.lookupFunction<Void Function(), void Function()>('dl_audio_tones_stop');

  factory _NativeAudio.open() {
    final dir = File(Platform.resolvedExecutable).parent.path;
    return _NativeAudio._(DynamicLibrary.open('$dir/lib/libdronelab_audio.so'));
  }

  /// A native buffer of [frames], seen from Dart: what [write] sends.
  Int16List buffer(int frames) {
    if (_buffer != nullptr) malloc.free(_buffer);
    _buffer = malloc<Int16>(frames);
    return _buffer.asTypedList(frames);
  }

  void write(int frames) => _write(_buffer, frames);

  /// Play [samples] as a tone, mixed in by the native side: false if it
  /// didn't take it.
  bool tone(Int16List samples) {
    if (samples.isEmpty) return true;
    final p = malloc<Int16>(samples.length);
    try {
      p.asTypedList(samples.length).setAll(0, samples);
      return _tone(p, samples.length) != 0;
    } finally {
      malloc.free(p);
    }
  }
}
