/// Plays the mixer to the phone's audio output (Bluetooth headphones, as
/// media). It keeps playing silence between voices: Bluetooth headphones take
/// a moment to wake up, which would cut off the start of what's said.
library;

import 'dart:typed_data';

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

bool _opusLoaded = false;

Future<void> loadOpus() async {
  if (_opusLoaded) return;
  initOpus(await opus_flutter.load());
  _opusLoaded = true;
}

class OpusVoiceDecoder implements VoiceDecoder {
  final SimpleOpusDecoder _decoder = SimpleOpusDecoder(sampleRate: outputRate, channels: 1);

  @override
  Int16List decode(Uint8List? packet, {bool fec = false, int? lossMs}) {
    try {
      return _decoder.decode(input: packet, fec: fec, loss: lossMs);
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

  Future<void> start() async {
    if (_running) return;
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

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    FlutterPcmSound.setFeedCallback(null);
    await FlutterPcmSound.release();
  }
}
