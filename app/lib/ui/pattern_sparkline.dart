import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../comm/patterns.dart';
import 'theme.dart';

/// A pattern's shape, small: its rows over one repeat, the first brightest.
class PatternSparkline extends StatelessWidget {
  final VibePattern? pattern;
  final String? builtIn;
  final double width, height;
  final Color color;
  const PatternSparkline({super.key, this.pattern, this.builtIn, this.width = 72, this.height = 28, this.color = Kc.pink});

  @override
  Widget build(BuildContext context) => SizedBox(
        width: width,
        height: height,
        child: CustomPaint(painter: _SparkPainter(pattern, builtIn, color)),
      );
}

class _SparkPainter extends CustomPainter {
  final VibePattern? pattern;
  final String? builtIn;
  final Color color;
  _SparkPainter(this.pattern, this.builtIn, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final p = pattern;
    final rows = p == null ? (builtIn == 'Heartbeat' || builtIn == 'Climb' ? 1 : 2) : math.min(3, p.rowCount);
    final length = p == null ? builtInLengthMs(builtIn ?? '') : math.max(1, p.lengthMs);
    final points = math.max(2, size.width.round());
    for (var r = rows - 1; r >= 0; r--) {
      final path = Path();
      for (var i = 0; i < points; i++) {
        final ms = length * i ~/ (points - 1);
        final v = p == null ? builtInLevel(builtIn ?? '', r, ms / 1000) : p.level(r, math.min(ms, length - 1)) ?? 0;
        final x = size.width * i / (points - 1);
        final y = size.height - 1 - (size.height - 2) * v.clamp(0, 1);
        i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
      }
      canvas.drawPath(
          path,
          Paint()
            ..color = color.withValues(alpha: r == 0 ? 1 : 0.45)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5);
    }
  }

  @override
  bool shouldRepaint(_SparkPainter old) => old.pattern != pattern || old.builtIn != builtIn || old.color != color;
}
