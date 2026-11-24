/// Photos in text conversations, over the server only: Mumble's text
/// messages take HTML, and a picture goes in one as an <img> with its JPEG
/// inline (a data: URI), as Mumble's own apps send and show them. Over
/// direct comms a message is far too small for one.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'board_protocol.dart' show pictureGif, pictureJpeg, pictureMaxBytes;

/// [photo] (any picture) as a JPEG small enough that its message, in
/// base64, is no longer than [maxChars]: shrunk and squeezed till it is.
/// Null if it isn't a picture, or won't go that small. Slow: run it off the
/// UI's isolate.
Uint8List? shrinkPhoto((Uint8List, int) photoAndMax) {
  final (photo, maxChars) = photoAndMax;
  final decoded = img.decodeImage(photo);
  if (decoded == null) return null;
  final upright = img.bakeOrientation(decoded);
  // What the base64 may take, less the tag round it
  final room = maxChars <= 0 ? 1 << 20 : ((maxChars - 64) * 3) ~/ 4;
  for (final side in const [1280, 1024, 800, 640, 480, 360]) {
    final big = upright.width > upright.height ? upright.width : upright.height;
    final sized = big > side
        ? img.copyResize(upright,
            width: upright.width >= upright.height ? side : null,
            height: upright.height > upright.width ? side : null,
            interpolation: img.Interpolation.average)
        : upright;
    for (final quality in const [82, 70, 58, 46]) {
      final jpeg = img.encodeJpg(sized, quality: quality);
      if (jpeg.length <= room) return jpeg;
    }
  }
  return null;
}

/// The longest side of a picture for someone's display: the biggest unit's
/// screen, 466 px across.
const displayPictureSide = 466;

/// The biggest a GIF can be each way, as it isn't made smaller: the unit
/// keeps a frame of it, 2 bytes a pixel, for each it has.
const displayGifSide = 640;

/// [picture] (any picture) made for others' displays, and what it is
/// ([pictureJpeg] or [pictureGif], board_protocol.dart): a GIF as it is, a
/// still one as a JPEG no bigger than the screen; either small enough for
/// the unit, and for a message no longer than [maxChars] in base64. Null if
/// it isn't a picture, or won't go that small. Slow: run it off the UI's
/// isolate.
(Uint8List, int)? displayPicture((Uint8List, int) pictureAndMax) {
  final (picture, maxChars) = pictureAndMax;
  final room = min(pictureMaxBytes, maxChars <= 0 ? 1 << 20 : ((maxChars - 96) * 3) ~/ 4);
  final gif = picture.length > 10 && picture[0] == 0x47 && picture[1] == 0x49 && picture[2] == 0x46;     // "GIF"
  if (gif) {
    // Played as it is, its frames as big as it says: kept within what the
    // unit has room for
    final w = picture[6] | (picture[7] << 8), h = picture[8] | (picture[9] << 8);
    return picture.length <= room && w <= displayGifSide && h <= displayGifSide ? (picture, pictureGif) : null;
  }
  final decoded = img.decodeImage(picture);
  if (decoded == null) return null;
  final upright = img.bakeOrientation(decoded);
  final big = max(upright.width, upright.height);
  final sized = big > displayPictureSide
      ? img.copyResize(upright,
          width: upright.width >= upright.height ? displayPictureSide : null,
          height: upright.height > upright.width ? displayPictureSide : null,
          interpolation: img.Interpolation.average)
      : upright;
  for (final quality in const [85, 72, 60, 48]) {
    final jpeg = img.encodeJpg(sized, quality: quality);
    if (jpeg.length <= room) return (jpeg, pictureJpeg);
  }
  return null;
}

/// The square at [x], [y], [side] pixels cut from an RGBA picture
/// (avatarToCrop, avatars.dart), scaled to fill the display:
/// [displayPictureSide] square, bigger or smaller as it takes, as a PNG for
/// [displayPicture] to make a JPEG of. Slow: run it off the UI's isolate.
Uint8List displayCut(({int width, int height, Uint8List rgba, int x, int y, int side}) job) {
  final im = img.Image.fromBytes(
      width: job.width, height: job.height, bytes: job.rgba.buffer, bytesOffset: job.rgba.offsetInBytes, numChannels: 4);
  final cut = img.copyCrop(im, x: job.x, y: job.y, width: job.side, height: job.side);
  final sized = job.side == displayPictureSide
      ? cut
      : img.copyResize(cut,
          width: displayPictureSide,
          height: displayPictureSide,
          interpolation: job.side > displayPictureSide ? img.Interpolation.average : img.Interpolation.cubic);
  return img.encodePng(sized);
}

/// The message for a photo: its JPEG, inline.
String photoMessage(Uint8List jpeg) => '<img src="data:image/jpeg;base64,${base64Encode(jpeg)}" />';

final _imgTag = RegExp(r'''<img[^>]*src\s*=\s*["']data:image/([a-zA-Z]+);base64,([^"']+)["'][^>]*>''',
    caseSensitive: false);

/// The pictures in a message, with their kind ('jpeg', 'png' and so on),
/// and the message without them.
(List<(String, Uint8List)>, String) photosIn(String html) {
  final photos = <(String, Uint8List)>[];
  for (final m in _imgTag.allMatches(html)) {
    try {
      final ext = m.group(1)!.toLowerCase();
      photos.add((ext == 'jpg' ? 'jpeg' : ext, base64Decode(m.group(2)!.replaceAll(RegExp(r'\s'), ''))));
    } catch (_) {}
  }
  return (photos, html.replaceAll(_imgTag, ''));
}
