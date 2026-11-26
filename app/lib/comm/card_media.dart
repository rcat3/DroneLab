/// Pictures and sounds made ready to save to the unit's SD card
/// (core/app/storage_save.h): what they're saved as, and under what name.
///
/// A picture is shrunk to fit the screen (so the unit has less to decode)
/// and saved as a JPEG, except a GIF, which is kept as it is to play, and
/// a PNG with see-through parts, which is kept a PNG. A sound is a WAV, MP3
/// or FLAC file as it is, except a WAV that's stereo or too big, which is
/// mixed down to mono and, if it has to be, to a lower rate.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'board_protocol.dart' show storageNameMax, storagePictureMaxBytes, storageSoundMaxBytes;
import 'photos.dart' show displayGifSide, displayPictureSide;

/// What's ready to send: the bytes, the extension they go by (no dot), or
/// why they can't be.
typedef CardFile = ({Uint8List? bytes, String ext, String? why});

CardFile _no(String why) => (bytes: null, ext: '', why: why);

bool _isGif(Uint8List b) => b.length > 10 && b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46;

/// [picture] made for the card. [flatten] makes it a JPEG whatever it is (a
/// cropped one). Slow: run it off the UI's isolate.
CardFile pictureForCard((Uint8List, bool) pictureAndFlatten) {
  final (picture, flatten) = pictureAndFlatten;
  if (_isGif(picture)) {
    final w = picture[6] | (picture[7] << 8), h = picture[8] | (picture[9] << 8);
    if (w > displayGifSide || h > displayGifSide) {
      return _no('That GIF is too big for the unit: $displayGifSide px across at most');
    }
    if (picture.length > storagePictureMaxBytes) {
      return _no('That GIF is too big for the unit: ${storagePictureMaxBytes ~/ (1024 * 1024)} MB at most');
    }
    return (bytes: picture, ext: 'gif', why: null);
  }
  final decoded = img.decodeImage(picture);
  if (decoded == null) return _no("That isn't a picture the app can read");
  final upright = img.bakeOrientation(decoded);
  final big = math.max(upright.width, upright.height);
  final sized = big > displayPictureSide
      ? img.copyResize(upright,
          width: upright.width >= upright.height ? displayPictureSide : null,
          height: upright.height > upright.width ? displayPictureSide : null,
          interpolation: img.Interpolation.average)
      : upright;
  if (!flatten && sized.hasAlpha && _isPng(picture)) {
    // See-through parts: the original, if it's small enough as it is
    final bytes = big <= displayPictureSide && picture.length <= storagePictureMaxBytes
        ? picture
        : Uint8List.fromList(img.encodePng(sized));
    return bytes.length <= storagePictureMaxBytes
        ? (bytes: bytes, ext: 'png', why: null)
        : _no('That picture is too big for the unit');
  }
  for (final quality in const [90, 80, 68, 55]) {
    final jpeg = img.encodeJpg(sized, quality: quality);
    if (jpeg.length <= storagePictureMaxBytes) return (bytes: Uint8List.fromList(jpeg), ext: 'jpg', why: null);
  }
  return _no('That picture is too big for the unit');
}

bool _isPng(Uint8List b) => b.length > 8 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47;

// ----- Sounds -----

bool _isRiff(Uint8List b) => b.length > 12 && ascii.decode(b.sublist(0, 4), allowInvalid: true) == 'RIFF';
bool _isFlac(Uint8List b) => b.length > 4 && ascii.decode(b.sublist(0, 4), allowInvalid: true) == 'fLaC';
bool _isMp3(Uint8List b) =>
    b.length > 3 &&
    ((b[0] == 0x49 && b[1] == 0x44 && b[2] == 0x33) || (b[0] == 0xFF && (b[1] & 0xE0) == 0xE0));

/// A 16-bit PCM WAV: its channels and rate, and where its samples are.
({int channels, int rate, int start, int end})? _wav16(Uint8List b) {
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
      if ((format != 1 && format != 0xFFFE) || bits != 16 || channels == null || channels < 1 || rate == null) {
        return null;
      }
      return (channels: channels, rate: rate, start: body, end: (body + size).clamp(body, b.length));
    }
    at = body + size + (size & 1);
  }
  return null;
}

Uint8List _wavFile(Int16List mono, int rate) {
  final bytes = mono.length * 2;
  final out = ByteData(44 + bytes);
  void tag(int at, String s) {
    for (var i = 0; i < 4; i++) {
      out.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  out.setUint32(4, 36 + bytes, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  out.setUint32(16, 16, Endian.little);
  out.setUint16(20, 1, Endian.little);
  out.setUint16(22, 1, Endian.little);
  out.setUint32(24, rate, Endian.little);
  out.setUint32(28, rate * 2, Endian.little);
  out.setUint16(32, 2, Endian.little);
  out.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  out.setUint32(40, bytes, Endian.little);
  for (var i = 0; i < mono.length; i++) {
    out.setInt16(44 + 2 * i, mono[i], Endian.little);
  }
  return out.buffer.asUint8List();
}

/// [file] (a WAV, MP3 or FLAC file) made for the card, called [name] (its
/// own name, any folder or extension taken off). Slow for a long WAV: run it
/// off the UI's isolate.
CardFile soundForCard(Uint8List file) {
  final most = storageSoundMaxBytes;
  final wav = _wav16(file);
  if (wav != null) {
    if (wav.channels == 1 && file.length <= most) return (bytes: file, ext: 'wav', why: null);
    // Mixed to mono, then to a lower rate (every other sample, averaged) till it fits
    final d = ByteData.sublistView(file);
    final frames = (wav.end - wav.start) ~/ (2 * wav.channels);
    var pcm = Int16List(frames);
    for (var i = 0; i < frames; i++) {
      var sum = 0;
      for (var c = 0; c < wav.channels; c++) {
        sum += d.getInt16(wav.start + 2 * (i * wav.channels + c), Endian.little);
      }
      pcm[i] = sum ~/ wav.channels;
    }
    var rate = wav.rate;
    while (44 + pcm.length * 2 > most && rate >= 16000) {
      final half = Int16List(pcm.length ~/ 2);
      for (var i = 0; i < half.length; i++) {
        half[i] = (pcm[2 * i] + pcm[2 * i + 1]) ~/ 2;
      }
      pcm = half;
      rate ~/= 2;
    }
    if (44 + pcm.length * 2 > most) return _no('That sound is too long for the unit, even made smaller');
    return (bytes: _wavFile(pcm, rate), ext: 'wav', why: null);
  }
  final ext = _isMp3(file) ? 'mp3' : _isFlac(file) ? 'flac' : _isRiff(file) ? 'wav' : null;
  if (ext == null) return _no("That isn't a WAV, MP3 or FLAC file");
  if (file.length > most) {
    return _no('That file is too big for the unit: ${most ~/ (1024 * 1024)} MB at most');
  }
  return (bytes: file, ext: ext, why: null);
}

/// A file name the unit takes (ASCII, no odd characters, with the extension
/// [ext]) from what the picker gave: the name's stem, cleaned, cut to fit.
String cardFileName(String stem, String ext) {
  var s = stem.replaceAll(RegExp(r'[^A-Za-z0-9 _()\-]'), '_').replaceAll(RegExp(r'_+'), '_').trim();
  s = s.replaceAll(RegExp(r'^[._ ]+'), '');
  if (s.isEmpty) s = 'saved';
  final room = storageNameMax - ext.length - 1;
  if (s.length > room) s = s.substring(0, room).trim();
  return '$s.$ext';
}

/// [name] made one the unit hasn't got ("cat (2).jpg"), given the names it
/// has (compared without regard to case).
String freeCardName(String name, Iterable<String> taken) {
  final lower = {for (final t in taken) t.toLowerCase()};
  if (!lower.contains(name.toLowerCase())) return name;
  final dot = name.lastIndexOf('.');
  final stem = name.substring(0, dot), ext = name.substring(dot);
  for (var n = 2; n < 100; n++) {
    var suffix = ' ($n)';
    var s = stem;
    final room = storageNameMax - ext.length - suffix.length;
    if (s.length > room) s = s.substring(0, room).trim();
    final candidate = '$s$suffix$ext';
    if (!lower.contains(candidate.toLowerCase())) return candidate;
  }
  return name;
}
