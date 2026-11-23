/// Avatars: everyone's picture, from their Mumble avatar ("texture"), shown
/// on the board's Comm screen while they talk.
///
/// The board keeps a few in slots (core/app/comm.h, 0x06). The app works out
/// which slot each picture is in, converts it to the board's size, sends the
/// ones it doesn't have yet, and forgets them all when the board's link drops
/// (the board starts afresh then too).
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import 'board_link.dart';
import 'board_protocol.dart';

/// Our own picture, for Mumble: square, [size] pixels, JPEG. Null if it
/// isn't a picture.
Uint8List? avatarForMumble(Uint8List picture, {int size = 256}) {
  final im = _square(picture, size);
  return im == null ? null : img.encodeJpg(im, quality: 85);
}

/// A picture, cut square from the middle and scaled to [size], on black
/// where it's see-through.
img.Image? _square(Uint8List picture, int size) {
  final im = img.decodeImage(picture);
  if (im == null) return null;
  final side = math.min(im.width, im.height);
  final cropped = img.copyCrop(im, x: (im.width - side) ~/ 2, y: (im.height - side) ~/ 2, width: side, height: side);
  final scaled = img.copyResize(cropped, width: size, height: size, interpolation: img.Interpolation.average);
  return scaled.hasAlpha ? img.compositeImage(img.Image(width: size, height: size), scaled) : scaled;
}

/// The largest a picture to crop is kept, on its longer side: plenty for
/// the [avatarForMumble] it becomes, and quick to show and cut.
const avatarCropMax = 2048;

/// A picture to crop, upright as it was taken, RGBA, at most
/// [avatarCropMax] on its longer side. Null if it isn't a picture.
({int width, int height, Uint8List rgba})? avatarToCrop(Uint8List picture) {
  var im = img.decodeImage(picture);
  if (im == null) return null;
  im = img.bakeOrientation(im);
  if (math.max(im.width, im.height) > avatarCropMax) {
    im = im.width >= im.height
        ? img.copyResize(im, width: avatarCropMax, interpolation: img.Interpolation.average)
        : img.copyResize(im, height: avatarCropMax, interpolation: img.Interpolation.average);
  }
  im = im.convert(format: img.Format.uint8, numChannels: 4, alpha: 255);
  return (width: im.width, height: im.height, rgba: im.getBytes(order: img.ChannelOrder.rgba));
}

/// The square at [x], [y], [side] pixels cut from an [avatarToCrop]
/// picture, scaled down to at most [size], as a PNG.
Uint8List avatarCut(({int width, int height, Uint8List rgba, int x, int y, int side, int size}) job) {
  final im = img.Image.fromBytes(width: job.width, height: job.height, bytes: job.rgba.buffer, bytesOffset: job.rgba.offsetInBytes, numChannels: 4);
  var cut = img.copyCrop(im, x: job.x, y: job.y, width: job.side, height: job.side);
  if (job.side > job.size) {
    cut = img.copyResize(cut, width: job.size, height: job.size, interpolation: img.Interpolation.average);
  }
  return img.encodePng(cut);
}

/// A picture for the board: [size] pixels square, RGB565, little endian.
Uint8List? avatarRgb565(Uint8List picture, int size) {
  final im = _square(picture, size);
  if (im == null) return null;
  final out = Uint8List(size * size * 2);
  var i = 0;
  for (final p in im) {
    final v = ((p.r.toInt() >> 3) << 11) | ((p.g.toInt() >> 2) << 5) | (p.b.toInt() >> 3);
    out[i++] = v & 0xFF;
    out[i++] = v >> 8;
  }
  return out;
}

Uint8List? _convert((Uint8List, int) job) => avatarRgb565(job.$1, job.$2);

/// What a picture's known by: the same picture is only sent once.
String avatarKey(Uint8List picture) => sha1.convert(picture).toString();

class BoardAvatars {
  final BoardLink board;

  /// Called when a picture's arrived on the board, so the messages that
  /// name its slot can be sent.
  final VoidCallback onChanged;

  BoardAvatars(this.board, this.onChanged);

  static const _window = 8;               // pieces between acks
  static const _ackTimeout = Duration(seconds: 3);
  static const _retryAfterMs = 15000;     // a picture that didn't go, tried again after this

  int _size = 0;
  int _slots = 0;
  final Map<String, int> _slotOf = {};    // on the board, all there
  final Map<int, int> _lastUsed = {};     // slot: when it was last wanted
  final List<(String, Uint8List)> _queue = [];
  final Set<String> _failed = {};         // not a picture
  final Map<String, int> _didntGo = {};   // sent, but it didn't go: when, to try again later
  String? _sending;
  bool _pumping = false;
  int _generation = 0;                    // goes up as the board's forgotten

  /// The board's link changed: start afresh if it's a different one.
  void update() {
    final ready = board.state == BoardState.connected && board.avatarSize > 0;
    final size = ready ? board.avatarSize : 0;
    final slots = ready ? math.min(board.avatarSlots, avatarNone) : 0;
    if (size != _size || slots != _slots) {
      _size = size;
      _slots = slots;
      _slotOf.clear();
      _lastUsed.clear();
      _queue.clear();
      _failed.clear();
      _didntGo.clear();
      _generation++;
    }
  }

  bool get active => _size > 0 && _slots > 0;

  /// The slot [picture] is in on the board, or [avatarNone]: then it's sent,
  /// soon if [soon], and [onChanged] says when it's there.
  int slotFor(Uint8List? picture, {bool soon = false}) {
    if (picture == null || !active) return avatarNone;
    final key = avatarKey(picture);
    final slot = _slotOf[key];
    if (slot != null) {
      _lastUsed[slot] = DateTime.now().millisecondsSinceEpoch;
      return slot;
    }
    if (_failed.contains(key) || key == _sending) return avatarNone;
    final didnt = _didntGo[key];
    if (didnt != null) {
      if (DateTime.now().millisecondsSinceEpoch - didnt < _retryAfterMs) return avatarNone;
      _didntGo.remove(key);
    }
    final at = _queue.indexWhere((q) => q.$1 == key);
    if (at >= 0) {
      if (soon && at > 0) _queue.insert(0, _queue.removeAt(at));
    } else if (soon) {
      _queue.insert(0, (key, picture));
    } else {
      _queue.add((key, picture));
    }
    _pump();
    return avatarNone;
  }

  /// Send what's queued, one picture at a time. [onChanged] asks for more
  /// as each arrives, which mustn't start a second round alongside: two
  /// pictures sent at once into the same slot both fail.
  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      await _pumpQueue();
    } finally {
      _pumping = false;
    }
  }

  Future<void> _pumpQueue() async {
    while (_queue.isNotEmpty && active) {
      final (key, picture) = _queue.removeAt(0);
      final generation = _generation;
      _sending = key;
      final rgb = await compute(_convert, (picture, _size));
      var ok = false;
      int? slot;
      if (rgb != null && generation == _generation) {
        slot = _freeSlot();
        _slotOf.removeWhere((_, s) => s == slot);
        ok = await _send(slot, rgb, generation);
      }
      _sending = null;
      if (generation != _generation) continue;    // the board's gone meanwhile
      if (ok && slot != null) {
        _slotOf[key] = slot;
        _lastUsed[slot] = DateTime.now().millisecondsSinceEpoch;
        onChanged();
      } else if (rgb == null) {
        _failed.add(key);
      } else {
        _didntGo[key] = DateTime.now().millisecondsSinceEpoch;
      }
    }
  }

  /// A slot nobody's in, or else the one that's gone longest unused.
  int _freeSlot() {
    final used = _slotOf.values.toSet();
    for (var s = 0; s < _slots; s++) {
      if (!used.contains(s)) return s;
    }
    var oldest = 0;
    for (var s = 1; s < _slots; s++) {
      if ((_lastUsed[s] ?? 0) < (_lastUsed[oldest] ?? 0)) oldest = s;
    }
    return oldest;
  }

  Future<bool> _send(int slot, Uint8List rgb, int generation) async {
    final pieces = avatarMessages(slot, rgb, board.maxWrite, window: _window);
    var sent = 0;
    for (var i = 0; i < pieces.length; i++) {
      if (generation != _generation) return false;
      final piece = pieces[i];
      sent += piece.length - 3;
      final wantsAck = piece[2] & 4 != 0;
      // Listen before it goes, so a quick ack isn't missed
      final ack = wantsAck
          ? board.avatarAcks.firstWhere((a) => a.slot == slot && a.received >= sent).timeout(_ackTimeout)
          : null;
      if (!await board.sendFast(piece)) {
        ack?.ignore();
        return false;
      }
      if (ack != null) {
        try {
          final a = await ack;
          if (a.done) return a.ok;
        } on TimeoutException {
          return false;
        } on StateError {
          return false;
        }
      }
    }
    return false;
  }
}

/// A board's avatar heard over direct comms, [size] pixels square, RGB565
/// little endian, as a PNG to show.
Uint8List directAvatarPng((Uint8List, int) job) {
  final (rgb565, size) = job;
  final im = img.Image(width: size, height: size);
  for (var i = 0; i < size * size && 2 * i + 1 < rgb565.length; i++) {
    final v = rgb565[2 * i] | (rgb565[2 * i + 1] << 8);
    im.setPixelRgb(i % size, i ~/ size, ((v >> 11) & 31) * 255 ~/ 31, ((v >> 5) & 63) * 255 ~/ 63, (v & 31) * 255 ~/ 31);
  }
  return img.encodePng(im);
}
