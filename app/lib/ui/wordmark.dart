import 'package:flutter/material.dart';

import 'theme.dart';

/// DroneLab's name as the logo has it: glowing green Terminal letters in
/// brackets, wired in at each side, with scanlines. Drawn, not a picture,
/// so it's sharp however wide it's shown: it fills the width it's given.
class DroneLabWordmark extends StatelessWidget {
  const DroneLabWordmark({super.key});

  static const _green = Color(0xFF4DFF6A);

  @override
  Widget build(BuildContext context) {
    final letters = Kc.term(40, color: _green, shadows: [
      Shadow(color: _green.withValues(alpha: 0.9), blurRadius: 6),
      Shadow(color: _green.withValues(alpha: 0.6), blurRadius: 18),
    ]);
    final ghost = Kc.term(40, color: const Color(0xFFD8FFE0).withValues(alpha: 0.35));
    return Semantics(
      label: 'DroneLab',
      excludeSemantics: true,
      child: FittedBox(
        fit: BoxFit.contain,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const _Wire(left: true),
          const _Bracket(left: true),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Stack(children: [
              Text('DRONELAB', style: letters),
              // A brighter copy a little off, as a screen's ghost
              Transform.translate(offset: const Offset(2, -1), child: Text('DRONELAB', style: ghost)),
              Positioned.fill(child: CustomPaint(painter: _Scanlines())),
            ]),
          ),
          const _Bracket(left: false),
          const _Wire(left: false),
        ]),
      ),
    );
  }
}

class _Bracket extends StatelessWidget {
  final bool left;
  const _Bracket({required this.left});

  @override
  Widget build(BuildContext context) =>
      SizedBox(width: 12, height: 62, child: CustomPaint(painter: _BracketPainter(left)));
}

class _BracketPainter extends CustomPainter {
  final bool left;
  _BracketPainter(this.left);

  @override
  void paint(Canvas canvas, Size s) {
    final x = left ? 1.5 : s.width - 1.5, end = left ? s.width : 0.0;
    final path = Path()
      ..moveTo(end, 1.5)
      ..lineTo(x, 1.5)
      ..lineTo(x, s.height - 1.5)
      ..lineTo(end, s.height - 1.5);
    final glow = Paint()
      ..color = DroneLabWordmark._green.withValues(alpha: 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
    final line = Paint()
      ..color = DroneLabWordmark._green
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    canvas
      ..drawPath(path, glow)
      ..drawPath(path, line);
  }

  @override
  bool shouldRepaint(_BracketPainter old) => old.left != left;
}

/// A wire from the bracket out to a node, stepping down, as the logo's.
class _Wire extends StatelessWidget {
  final bool left;
  const _Wire({required this.left});

  @override
  Widget build(BuildContext context) => SizedBox(width: 30, height: 62, child: CustomPaint(painter: _WirePainter(left)));
}

class _WirePainter extends CustomPainter {
  final bool left;
  _WirePainter(this.left);

  @override
  void paint(Canvas canvas, Size s) {
    double x(double f) => left ? s.width * f : s.width * (1 - f);
    final y = s.height / 2;
    final path = Path()
      ..moveTo(x(0.12), y + 4)
      ..lineTo(x(0.45), y + 4)
      ..lineTo(x(0.65), y)
      ..lineTo(x(1), y);
    final p = Paint()
      ..color = DroneLabWordmark._green
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawPath(path, p);
    canvas.drawCircle(Offset(x(0.1), y + 4), 3,
        Paint()..color = DroneLabWordmark._green..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5));
  }

  @override
  bool shouldRepaint(_WirePainter old) => old.left != left;
}

/// Dark lines across the letters, every few pixels, as a screen's.
class _Scanlines extends CustomPainter {
  @override
  void paint(Canvas canvas, Size s) {
    final p = Paint()..color = Kc.bg.withValues(alpha: 0.35);
    for (var y = 1.0; y < s.height; y += 3) {
      canvas.drawRect(Rect.fromLTWH(0, y, s.width, 1), p);
    }
  }

  @override
  bool shouldRepaint(_Scanlines old) => false;
}
