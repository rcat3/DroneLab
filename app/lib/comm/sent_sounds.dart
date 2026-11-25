/// Sounds for others' units' speakers (core/app/sounds.h): what goes over
/// the server, made from a recording of ours (recorder.dart) or a sound
/// file picked.
///
/// A WAV file (our recordings are 48 kHz mono 16-bit WAVs) is coded here
/// as Opus, mono, [_bitrate], cut at [soundMaxMs]: about 60 KB for the 10
/// s. It's made loud first ([_loudened]): recordings come at HiveMind's
/// level, well under full scale, where the unit's player, at its 100%,
/// plays them as they are, far quieter than its voice effect, which drives
/// the speaker hard. Other files (MP3, FLAC, or a WAV that isn't 16-bit)
/// go as they are, if they're small enough: [soundMaxBytes], and what the
/// server takes. The unit plays [soundMaxMs] of any of them at most.
///
/// Over the server, a sound is a text with a picture: a small speaker, a
/// real PNG, with the sound in a chunk of its own ([_chunk]), which picture
/// viewers leave alone. Plain Mumble shows the speaker and a line saying
/// what it is; DroneLab takes the sound out. In a picture, as Mumble's limit
/// for a text with one is the one for pictures, far more than for words.
/// The chunk is what the sound is ([soundOpus], Opus packets each after
/// its length, 1 byte; or [soundFile]), then its bytes.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
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

/// The PNG chunk the sound goes in: "dlSn", ancillary (a viewer may skip
/// it), private, and safe to copy, by the case of its letters.
const _chunk = 'dlSn';

/// The line beside it, for plain Mumble.
const _caption = '🔊 A sound for DroneLab units';

/// A sound, as it goes in a server text: in the speaker picture, and the
/// line beside it.
String soundMessage(SentSound s) {
  final png = _withChunk(_speakerPng, _chunk, Uint8List.fromList([s.kind, ...s.bytes]));
  return '<img src="data:image/png;base64,${base64Encode(png)}" /> $_caption';
}

final _pngTag = RegExp(r'''<img[^>]*src\s*=\s*["']data:image/png;base64,([^"']+)["'][^>]*>''');

/// The sounds in a server text: what each is ([soundOpus] or [soundFile])
/// and its bytes, from the pictures that carry one.
List<(int, Uint8List)> soundsIn(String html) {
  final out = <(int, Uint8List)>[];
  for (final m in _pngTag.allMatches(html)) {
    final png = _decode(m.group(1)!);
    final data = png == null ? null : _chunkOf(png, _chunk);
    if (data == null || data.length < 2 || data[0] > soundFile) continue;
    out.add((data[0], Uint8List.sublistView(data, 1)));
  }
  return out;
}

Uint8List? _decode(String b64) {
  try {
    return base64Decode(b64.replaceAll(RegExp(r'\s'), ''));
  } catch (_) {
    return null;
  }
}

// ----- The picture -----

const _pngSignature = 8;

/// A speaker with sound coming from it, 48 px, pink on clear: made once.
final Uint8List _speakerPng = () {
  const size = 48;
  final im = img.Image(width: size, height: size, numChannels: 4);
  final pink = img.ColorRgba8(0xFF, 0x40, 0xC0, 0xFF);
  img.fillRect(im, x1: 6, y1: 18, x2: 15, y2: 30, color: pink);
  img.fillPolygon(im,
      vertices: [img.Point(15, 18), img.Point(27, 8), img.Point(27, 40), img.Point(15, 30)], color: pink);
  // The sound: two arcs, thick, opening to the right
  for (final r in [8.0, 15.0]) {
    for (var a = -50.0; a <= 50.0; a += 1) {
      final t = a * math.pi / 180;
      for (var w = -1.5; w <= 1.5; w += 0.5) {
        final x = (27 + (r + w) * math.cos(t)).round(), y = (24 + (r + w) * math.sin(t)).round();
        if (x >= 0 && x < size && y >= 0 && y < size) im.setPixel(x, y, pink);
      }
    }
  }
  return img.encodePng(im);
}();

/// [png] with a chunk of [type] and [data] put in before its end (IEND).
Uint8List _withChunk(Uint8List png, String type, Uint8List data) {
  final end = png.length - 12;    // IEND: its length, type and CRC, no data
  final typeBytes = ascii.encode(type);
  final chunk = BytesBuilder(copy: false)
    ..add((ByteData(4)..setUint32(0, data.length)).buffer.asUint8List())
    ..add(typeBytes)
    ..add(data)
    ..add((ByteData(4)..setUint32(0, _crc32([...typeBytes, ...data]))).buffer.asUint8List());
  return Uint8List.fromList([...png.sublist(0, end), ...chunk.takeBytes(), ...png.sublist(end)]);
}

/// The data of [png]'s first chunk of [type], if its CRC's right; null
/// for none.
Uint8List? _chunkOf(Uint8List png, String type) {
  if (png.length < _pngSignature + 12 || png[1] != 0x50 || png[2] != 0x4E || png[3] != 0x47) return null;
  final d = ByteData.sublistView(png);
  for (var at = _pngSignature; at + 12 <= png.length;) {
    final len = d.getUint32(at);
    if (at + 12 + len > png.length) return null;
    final t = ascii.decode(png.sublist(at + 4, at + 8), allowInvalid: true);
    if (t == type) {
      final body = Uint8List.sublistView(png, at + 8, at + 8 + len);
      final crc = d.getUint32(at + 8 + len);
      return crc == _crc32(Uint8List.sublistView(png, at + 4, at + 8 + len)) ? body : null;
    }
    if (t == 'IEND') return null;
    at += 12 + len;
  }
  return null;
}

final List<int> _crcTable = List.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

/// PNG's CRC-32.
int _crc32(List<int> bytes) {
  var c = 0xFFFFFFFF;
  for (final b in bytes) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
  }
  return c ^ 0xFFFFFFFF;
}
