/// Photos in text conversations, over the server only: Mumble's text
/// messages take HTML, and a picture goes in one as an <img> with its JPEG
/// inline (a data: URI), as Mumble's own apps send and show them. Over
/// direct comms a message is far too small for one.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

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
