/// Recording the board's voice, after its effect, to WAV files on the phone,
/// for videos and the like.
///
/// The board sends what it hears the whole time it records, as Opus packets
/// (core/app/comm.h, 0x0A). They're decoded as they come, lost ones made up
/// from the next one's error correction, and written straight to the file,
/// 48 kHz mono, 16-bit: what video editors expect.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'audio_out.dart';
import 'board_protocol.dart';
import 'jitter.dart';

/// A recording on the phone.
class Recording {
  final File file;
  final DateTime when;
  final Duration length;
  Recording(this.file, this.when, this.length);

  String get name => file.uri.pathSegments.last.replaceAll('.wav', '');
}

const _wavHeader = 44;

/// Where recordings are kept: the app's own files, shared from there.
Future<Directory> recordingsDir() async {
  final dir = Directory('${(await getApplicationDocumentsDirectory()).path}/Recordings');
  await dir.create(recursive: true);
  return dir;
}

/// The recordings, newest first.
Future<List<Recording>> listRecordings() async {
  final dir = await recordingsDir();
  final out = <Recording>[];
  await for (final f in dir.list()) {
    if (f is! File || !f.path.endsWith('.wav')) continue;
    final stat = await f.stat();
    final samples = ((stat.size - _wavHeader) ~/ 2).clamp(0, 1 << 40);
    out.add(Recording(f, stat.modified, Duration(milliseconds: samples * 1000 ~/ outputRate)));
  }
  out.sort((a, b) => b.when.compareTo(a.when));
  return out;
}

/// The samples of a recording made here, to play back.
Future<Int16List> readRecording(File file) async {
  final bytes = await file.readAsBytes();
  if (bytes.length <= _wavHeader) return Int16List(0);
  return Int16List.sublistView(Uint8List.fromList(bytes.sublist(_wavHeader)));
}

/// A WAV header for [dataBytes] of 16-bit mono at [outputRate].
Uint8List wavHeader(int dataBytes) {
  final h = ByteData(_wavHeader);
  void tag(int at, String s) {
    for (var i = 0; i < 4; i++) {
      h.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  h.setUint32(4, 36 + dataBytes, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  h.setUint32(16, 16, Endian.little);
  h.setUint16(20, 1, Endian.little);              // PCM
  h.setUint16(22, 1, Endian.little);              // mono
  h.setUint32(24, outputRate, Endian.little);
  h.setUint32(28, outputRate * 2, Endian.little);
  h.setUint16(32, 2, Endian.little);
  h.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  h.setUint32(40, dataBytes, Endian.little);
  return h.buffer.asUint8List();
}

/// One recording as it's made.
class Recorder {
  final RandomAccessFile _file;
  final File file;
  final VoiceDecoder _decoder;
  int _bytes = 0;
  int? _lastSeq;
  int lost = 0;               // packets made up

  Recorder._(this.file, this._file, this._decoder);

  /// Start a new file, named for when it starts.
  static Future<Recorder> start(VoiceDecoder decoder) async {
    final dir = await recordingsDir();
    final t = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final name = 'DroneLab ${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}.${two(t.minute)}.${two(t.second)}';
    final file = File('${dir.path}/$name.wav');
    final raf = await file.open(mode: FileMode.write);
    await raf.writeFrom(wavHeader(0));    // filled in at the end
    return Recorder._(file, raf, decoder);
  }

  Duration get length => Duration(milliseconds: (_bytes ~/ 2) * 1000 ~/ outputRate);

  /// A packet from the board. Packets come in order; any that went missing
  /// are made up first, from this one's error correction.
  void add(BoardSound s) {
    final last = _lastSeq;
    if (last != null && !s.first) {
      final gap = ((s.seq - last) & 0xFFFF) - 1;
      if (gap > 0 && gap < 50 && s.opus.isNotEmpty) {
        lost += gap;
        _write(_decoder.decode(s.opus, fec: true, lossMs: gap * boardFrameMs));
      }
    }
    _lastSeq = s.seq;
    if (s.opus.isNotEmpty) _write(_decoder.decode(s.opus));
  }

  void _write(Int16List pcm) {
    if (pcm.isEmpty) return;
    final bytes = pcm.buffer.asUint8List(pcm.offsetInBytes, pcm.lengthInBytes);
    _file.writeFromSync(bytes);
    _bytes += bytes.length;
  }

  /// Finish the file, with its lengths in the header.
  Future<File> finish() async {
    await _file.setPosition(0);
    await _file.writeFrom(wavHeader(_bytes));
    await _file.close();
    _decoder.dispose();
    return file;
  }
}
