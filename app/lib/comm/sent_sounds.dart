/// Sounds for others' units' speakers (core/app/sounds.h): what goes over
/// the server, made from a recording of ours (recorder.dart) or a sound
/// file picked.
///
/// A WAV file (our recordings are 48 kHz mono 16-bit WAVs) is coded here
/// as Opus, mono, [_bitrate], cut at [soundMaxMs]: about 60 KB for the 10
/// s. It's made loud first ([_loudened]): recordings come at HiveMind's
/// level, well under full scale, where the unit's player, at its 100%,
/// plays them as they are, far quieter than its voice effect, which drives
/// the speaker hard. Other files (MP3, FLAC, or a WAV that isn't 16-bit) go as they are,
/// if they're small enough: [soundMaxBytes], and what the server takes.
/// The unit plays [soundMaxMs] of any of them at most.
///
/// Over the server, a sound is a text with it in an image tag (as Mumble's
/// limit for such texts is the one for pictures), its type
/// audio/x-dronelab-opus for Opus packets, each after its length (1 byte),
/// else the file's own.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:opus_codec_dart/opus_dart.dart';
import 'package:opus_codec_dart/wrappers/opus_defines.dart' as od;

import 'audio_out.dart' show loadOpus;
import 'board_protocol.dart' show soundFile, soundMaxBytes, soundMaxMs, soundOpus;

/// A sound, ready to send: its bytes, and what they are ([soundOpus] or
/// [soundFile]).
class SentSound {
  final Uint8List bytes;
  final int kind;
  const SentSound(this.bytes, this.kind);
}

const _bitrate = 48000;
const _frameMs = 20;
const _opusType = 'x-dronelab-opus';

/// The rates Opus codes at; a WAV at any other is made 48 kHz first.
const _opusRates = [8000, 12000, 16000, 24000, 48000];

/// [file] (a WAV, MP3 or FLAC file's bytes) made into a sound to send, no
/// more than [maxBytes]; or why it can't be.
Future<(SentSound?, String?)> soundFor(Uint8List file, {int maxBytes = soundMaxBytes}) async {
  final most = maxBytes < soundMaxBytes ? maxBytes : soundMaxBytes;
  final wav = _readWav(file);
  if (wav != null) {
    final opus = await _codeOpus(wav.$1, wav.$2);
    if (opus.length > most) return (null, "That's too big to send, even made smaller");
    return (SentSound(opus, soundOpus), null);
  }
  if (!_isMp3(file) && !_isFlac(file) && !_isRiff(file)) return (null, "That isn't a WAV, MP3 or FLAC file");
  if (file.length > most) {
    return (null, 'That file is too big to send: ${most ~/ 1024} KB at most, unless it\'s a 16-bit WAV');
  }
  return (SentSound(file, soundFile), null);
}

bool _isRiff(Uint8List b) => b.length > 12 && ascii.decode(b.sublist(0, 4), allowInvalid: true) == 'RIFF';
bool _isFlac(Uint8List b) => b.length > 4 && ascii.decode(b.sublist(0, 4), allowInvalid: true) == 'fLaC';
bool _isMp3(Uint8List b) =>
    b.length > 3 &&
    ((b[0] == 0x49 && b[1] == 0x44 && b[2] == 0x33) ||     // "ID3"
        (b[0] == 0xFF && (b[1] & 0xE0) == 0xE0));          // a frame's sync

/// A 16-bit PCM WAV's samples, mixed to mono, and its rate; null for
/// anything else.
(Int16List, int)? _readWav(Uint8List b) {
  if (!_isRiff(b) || ascii.decode(b.sublist(8, 12), allowInvalid: true) != 'WAVE') return null;
  final d = ByteData.sublistView(b);
  int? format, channels, rate, bits;
  for (var at = 12; at + 8 <= b.length;) {
    final id = ascii.decode(b.sublist(at, at + 4), allowInvalid: true);
    final size = d.getUint32(at + 4, Endian.little);
    final body = at + 8;
    if (id == 'fmt ' && size >= 16 && body + 16 <= b.length) {
      format = d.getUint16(body, Endian.little);
      channels = d.getUint16(body + 2, Endian.little);
      rate = d.getUint32(body + 4, Endian.little);
      bits = d.getUint16(body + 14, Endian.little);
    } else if (id == 'data') {
      // PCM, or WAVE_FORMAT_EXTENSIBLE (which this takes as PCM)
      if ((format != 1 && format != 0xFFFE) || bits != 16 || channels == null || channels < 1 || rate == null) {
        return null;
      }
      final end = (body + size).clamp(body, b.length);
      final frames = (end - body) ~/ (2 * channels);
      final mono = Int16List(frames);
      for (var i = 0; i < frames; i++) {
        var sum = 0;
        for (var c = 0; c < channels; c++) {
          sum += d.getInt16(body + 2 * (i * channels + c), Endian.little);
        }
        mono[i] = sum ~/ channels;
      }
      return (mono, rate);
    }
    at = body + size + (size & 1);
  }
  return null;
}

/// Samples at [rate] made 48 kHz, in straight lines between them: enough
/// for the unit's small speaker.
Int16List _to48k(Int16List pcm, int rate) {
  final n = pcm.length * 48000 ~/ rate;
  final out = Int16List(n);
  for (var i = 0; i < n; i++) {
    final pos = i * rate / 48000;
    final j = pos.floor();
    final f = pos - j;
    final a = pcm[j < pcm.length ? j : pcm.length - 1];
    final b = pcm[j + 1 < pcm.length ? j + 1 : pcm.length - 1];
    out[i] = (a + (b - a) * f).round();
  }
  return out;
}

/// How loud a sound's made: its loud parts at this RMS, of full scale
/// (-10 dBFS), its peaks rounded off as the unit's voice effect does, and
/// raised by no more than [_mostGainDb].
const _loudRms = 0.316;
const _mostGainDb = 30.0;

/// [pcm] made loud: the RMS of its loudest 20 ms parts (the 90th
/// percentile, so a click doesn't count) brought to [_loudRms], through
/// tanh, which rounds off the peaks rather than clipping them. A sound
/// that's loud already is left as it is.
Int16List _loudened(Int16List pcm, int rate) {
  final frame = rate * _frameMs ~/ 1000;
  final levels = <double>[];
  for (var at = 0; at + frame <= pcm.length; at += frame) {
    var sum = 0.0;
    for (var i = at; i < at + frame; i++) {
      final x = pcm[i] / 32768.0;
      sum += x * x;
    }
    levels.add(math.sqrt(sum / frame));
  }
  if (levels.isEmpty) return pcm;
  levels.sort();
  final loud = levels[(levels.length * 0.9).floor().clamp(0, levels.length - 1)];
  if (loud < 1e-4) return pcm;    // silence
  final gain = math.min(_loudRms / loud, math.pow(10, _mostGainDb / 20).toDouble());
  if (gain <= 1.0) return pcm;
  final out = Int16List(pcm.length);
  for (var i = 0; i < pcm.length; i++) {
    final y = pcm[i] / 32768.0 * gain;
    final t = math.exp(2 * y);
    out[i] = ((t - 1) / (t + 1) * 32767).round();    // tanh
  }
  return out;
}

/// Opus packets, each after its length, of the first [soundMaxMs].
Future<Uint8List> _codeOpus(Int16List pcm, int rate) async {
  await loadOpus();
  if (!_opusRates.contains(rate)) {
    pcm = _to48k(pcm, rate);
    rate = 48000;
  }
  final frame = rate * _frameMs ~/ 1000;
  final most = rate * soundMaxMs ~/ 1000;
  final samples = pcm.length < most ? pcm.length : most;
  pcm = _loudened(Int16List.sublistView(pcm, 0, samples), rate);
  // Packets of at most 255 bytes, so each one's length fits in a byte
  final enc = BufferedOpusEncoder(
      sampleRate: rate, channels: 1, application: Application.audio, maxOutputBufferSizeBytes: 255);
  final out = BytesBuilder(copy: false);
  try {
    enc.encoderCtl(request: od.OPUS_SET_BITRATE_REQUEST, value: _bitrate);
    enc.encoderCtl(request: od.OPUS_SET_COMPLEXITY_REQUEST, value: 10);
    final input = enc.inputBuffer.buffer.asInt16List(enc.inputBuffer.offsetInBytes, frame);
    for (var at = 0, n = 0; at < samples; at += frame, n++) {
      final take = samples - at < frame ? samples - at : frame;
      input.setRange(0, take, pcm, at);
      if (take < frame) input.fillRange(take, frame, 0);    // the last, made up with silence
      enc.inputBufferIndex = frame * 2;
      final packet = enc.encode();
      out.addByte(packet.length);
      out.add(packet);
      if (n % 25 == 24) await Future<void>.delayed(Duration.zero);     // let the screen draw
    }
  } finally {
    enc.destroy();
  }
  return out.takeBytes();
}

/// What it is, as its type over the server.
String _typeOf(SentSound s) {
  if (s.kind == soundOpus) return _opusType;
  if (_isFlac(s.bytes)) return 'flac';
  if (_isRiff(s.bytes)) return 'wav';
  return 'mpeg';
}

/// A sound, as it goes in a server text.
String soundMessage(SentSound s) => '<img src="data:audio/${_typeOf(s)};base64,${base64Encode(s.bytes)}" />';

final _soundTag = RegExp(r'''<img[^>]*src\s*=\s*["']data:audio/([a-zA-Z0-9.+-]+);base64,([^"']+)["'][^>]*>''');

/// The sounds in a server text: what each is ([soundOpus] or [soundFile])
/// and its bytes.
List<(int, Uint8List)> soundsIn(String html) => [
      for (final m in _soundTag.allMatches(html))
        if (_decode(m.group(2)!) case final bytes?) (m.group(1) == _opusType ? soundOpus : soundFile, bytes),
    ];

Uint8List? _decode(String b64) {
  try {
    return base64Decode(b64.replaceAll(RegExp(r'\s'), ''));
  } catch (_) {
    return null;
  }
}
