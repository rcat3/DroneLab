import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../comm/avatars.dart';
import '../comm/photos.dart';
import 'theme.dart';

/// The size an avatar's kept at (avatarForMumble): a picture square and no
/// bigger needs no cropping.
const _avatarSize = 256;

/// [picture] as an avatar: if it's bigger than one, or not square, you pick
/// the square of it to keep. Null if it's cancelled; a FormatException if
/// it isn't a picture.
Future<Uint8List?> cropAvatar(BuildContext context, Uint8List picture) async {
  final pic = await compute(avatarToCrop, picture);
  if (pic == null) throw const FormatException('Not a picture');
  if (pic.width == pic.height && pic.width <= _avatarSize) return picture;
  final shown = await _toUiImage(pic.rgba, pic.width, pic.height);
  if (!context.mounted) {
    shown.dispose();
    return null;
  }
  final Rect? square;
  try {
    square = await Navigator.of(context).push<Rect>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _CropPage(
          image: shown,
          title: 'Crop your avatar',
          hint: 'Drag the square to move it. Pinch, or drag a corner, to resize it.',
        ),
      ),
    );
  } finally {
    shown.dispose();
  }
  if (square == null) return null;
  final x = square.left.round().clamp(0, pic.width - 1);
  final y = square.top.round().clamp(0, pic.height - 1);
  final int side = square.width.round().clamp(1, math.min(pic.width - x, pic.height - y));
  return compute(avatarCut, (
    width: pic.width,
    height: pic.height,
    rgba: pic.rgba,
    x: x,
    y: y,
    side: side,
    size: _avatarSize * 2,
  ));
}

/// What [cropForDisplay] gives: the cut, for the display, and where it was
/// cut from, to start from next time.
typedef DisplayCrop = ({Uint8List picture, Rect area});

/// The part of [picture] to fill someone's display with: you pick it in a
/// circle, the round screen's shape, made smaller to zoom in. Starts at
/// [area] if given (a [DisplayCrop]'s). Null if it's cancelled, or if Fit
/// whole is chosen instead, when [onFit] is called. A FormatException if it
/// isn't a picture.
Future<DisplayCrop?> cropForDisplay(BuildContext context, Uint8List picture, {Rect? area, VoidCallback? onFit}) async {
  final pic = await compute(avatarToCrop, picture);
  if (pic == null) throw const FormatException('Not a picture');
  final shown = await _toUiImage(pic.rgba, pic.width, pic.height);
  if (!context.mounted) {
    shown.dispose();
    return null;
  }
  final Object? picked;
  try {
    picked = await Navigator.of(context).push<Object>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _CropPage(
          image: shown,
          title: 'Crop for their display',
          hint: "What's in the circle fills their display. Drag it to move it. Pinch, or drag a corner, "
              'to resize it: smaller zooms in.',
          round: true,
          start: area,
          fit: onFit != null,
        ),
      ),
    );
  } finally {
    shown.dispose();
  }
  if (picked == _fitWhole) onFit?.call();
  if (picked is! Rect) return null;
  final x = picked.left.round().clamp(0, pic.width - 1);
  final y = picked.top.round().clamp(0, pic.height - 1);
  final int side = picked.width.round().clamp(1, math.min(pic.width - x, pic.height - y));
  final cut = await compute(displayCut, (width: pic.width, height: pic.height, rgba: pic.rgba, x: x, y: y, side: side));
  return (picture: cut, area: picked);
}

/// What the crop page gives back for Fit whole.
const _fitWhole = #fitWhole;

Future<ui.Image> _toUiImage(Uint8List rgba, int width, int height) {
  final done = Completer<ui.Image>();
  ui.decodeImageFromPixels(rgba, width, height, ui.PixelFormat.rgba8888, done.complete);
  return done.future;
}

/// Picking a square of [image], shown as a circle if it's for a [round]
/// screen. Gives back the square (a Rect, in the picture's pixels), or
/// [_fitWhole] if [fit] offers that and it's chosen.
class _CropPage extends StatefulWidget {
  final ui.Image image;
  final String title;
  final String hint;
  final bool round;
  final Rect? start;
  final bool fit;
  const _CropPage(
      {required this.image, required this.title, required this.hint, this.round = false, this.start, this.fit = false});

  @override
  State<_CropPage> createState() => _CropPageState();
}

enum _Drag { move, corner }

class _CropPageState extends State<_CropPage> {
  /// The square kept, in the picture's pixels.
  late Rect _sel;

  // Where the picture's drawn: its scale and top left on the screen
  double _scale = 1;
  Offset _origin = Offset.zero;

  _Drag _drag = _Drag.move;
  Offset _anchor = Offset.zero;   // the corner that stays put, dragging one
  Offset _away = Offset.zero;     // which way from it the dragged corner is
  int _pointers = 0;
  double _lastScale = 1;          // the pinch so far, as last seen

  static const _handleReach = 28.0;   // how near a corner a touch takes it

  double get _w => widget.image.width.toDouble();
  double get _h => widget.image.height.toDouble();
  double get _maxSide => math.min(_w, _h);
  double get _minSide => math.min(_maxSide, math.max(32, _maxSide / 20));

  @override
  void initState() {
    super.initState();
    final side = _maxSide;
    final start = widget.start;
    _sel = start != null ? _fit(start.center, start.width) : Rect.fromLTWH((_w - side) / 2, (_h - side) / 2, side, side);
  }

  /// A square [side] about [center], kept inside the picture.
  Rect _fit(Offset center, double side) {
    side = side.clamp(_minSide, _maxSide);
    final left = (center.dx - side / 2).clamp(0.0, _w - side);
    final top = (center.dy - side / 2).clamp(0.0, _h - side);
    return Rect.fromLTWH(left, top, side, side);
  }

  Offset _toImage(Offset screen) => (screen - _origin) / _scale;

  void _start(ScaleStartDetails d) {
    _pointers = d.pointerCount;
    _lastScale = 1;
    _drag = _Drag.move;
    if (d.pointerCount != 1) return;
    final at = d.localFocalPoint;
    final corners = [_sel.topLeft, _sel.topRight, _sel.bottomLeft, _sel.bottomRight];
    for (var i = 0; i < 4; i++) {
      if ((_origin + corners[i] * _scale - at).distance <= _handleReach) {
        _drag = _Drag.corner;
        _anchor = corners[3 - i];
        _away = Offset(i.isOdd ? 1 : -1, i >= 2 ? 1 : -1);
        return;
      }
    }
  }

  void _update(ScaleUpdateDetails d) {
    // A finger more or less starts the pinch afresh
    if (d.pointerCount != _pointers) {
      _pointers = d.pointerCount;
      _lastScale = d.scale;
      if (_pointers > 1) _drag = _Drag.move;
    }
    final grow = d.scale / _lastScale;
    _lastScale = d.scale;
    setState(() {
      if (_drag == _Drag.corner) {
        final p = _toImage(d.localFocalPoint) - _anchor;
        // As big as the finger's furthest from the corner kept, but no
        // bigger than the room on that side of it
        final room = math.min(_away.dx > 0 ? _w - _anchor.dx : _anchor.dx, _away.dy > 0 ? _h - _anchor.dy : _anchor.dy);
        final side = math.max(p.dx * _away.dx, p.dy * _away.dy).clamp(_minSide, math.max(_minSide, room)).toDouble();
        _sel = Rect.fromPoints(_anchor, _anchor + _away * side);
      } else {
        _sel = _fit(_sel.center + d.focalPointDelta / _scale, _sel.width * grow);
      }
    });
  }

  void _wheel(PointerSignalEvent e) {
    if (e is PointerScrollEvent) {
      setState(() => _sel = _fit(_sel.center, _sel.width * math.exp(e.scrollDelta.dy * 0.002)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Kc.bg,
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          if (widget.fit)
            TextButton(onPressed: () => Navigator.of(context).pop(_fitWhole), child: const Text('Fit whole')),
          TextButton(onPressed: () => Navigator.of(context).pop(_sel), child: const Text('Use')),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: LayoutBuilder(builder: (context, box) {
                  _scale = math.min(box.maxWidth / _w, box.maxHeight / _h);
                  _origin = Offset((box.maxWidth - _w * _scale) / 2, (box.maxHeight - _h * _scale) / 2);
                  return Listener(
                    onPointerSignal: _wheel,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onScaleStart: _start,
                      onScaleUpdate: _update,
                      child: CustomPaint(
                        size: Size(box.maxWidth, box.maxHeight),
                        painter: _CropPainter(widget.image, _sel, _scale, _origin, widget.round),
                      ),
                    ),
                  );
                }),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Text(
                widget.hint,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Kc.muted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CropPainter extends CustomPainter {
  final ui.Image image;
  final Rect sel;
  final double scale;
  final Offset origin;
  final bool round;
  _CropPainter(this.image, this.sel, this.scale, this.origin, this.round);

  @override
  void paint(Canvas canvas, Size size) {
    final whole = Rect.fromLTWH(origin.dx, origin.dy, image.width * scale, image.height * scale);
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      whole,
      Paint()..filterQuality = FilterQuality.medium,
    );
    final kept = Rect.fromLTWH(origin.dx + sel.left * scale, origin.dy + sel.top * scale, sel.width * scale, sel.height * scale);
    canvas.drawPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(whole)
        ..addRect(kept),
      Paint()..color = Colors.black.withValues(alpha: 0.6),
    );
    if (round) {
      // The screen's round: outside the circle isn't seen
      canvas.drawPath(
        Path()
          ..fillType = PathFillType.evenOdd
          ..addRect(kept)
          ..addOval(kept),
        Paint()..color = Colors.black.withValues(alpha: 0.85),
      );
    }
    final thirds = Paint()
      ..color = Colors.white.withValues(alpha: 0.25)
      ..strokeWidth = 1;
    for (var i = 1; i < 3; i++) {
      final x = kept.left + kept.width * i / 3, y = kept.top + kept.height * i / 3;
      canvas.drawLine(Offset(x, kept.top), Offset(x, kept.bottom), thirds);
      canvas.drawLine(Offset(kept.left, y), Offset(kept.right, y), thirds);
    }
    final edge = Paint()
      ..color = Kc.pink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    if (round) {
      canvas.drawOval(kept, edge);
      edge
        ..color = Kc.pink.withValues(alpha: 0.5)
        ..strokeWidth = 1;
    }
    canvas.drawRect(kept, edge);
    final handle = Paint()..color = Kc.pink;
    for (final c in [kept.topLeft, kept.topRight, kept.bottomLeft, kept.bottomRight]) {
      canvas.drawRect(Rect.fromCenter(center: c, width: 12, height: 12), handle);
    }
  }

  @override
  bool shouldRepaint(_CropPainter old) => old.sel != sel || old.scale != scale || old.origin != origin || old.image != image || old.round != round;
}
