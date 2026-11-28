/// The colour dialog every colour in the Guide uses: a palette of presets to
/// pick from, a spectrum to click or drag on, hue, saturation and brightness
/// sliders, a hex code, and red, green and blue.
library;

import 'package:flutter/material.dart';

import '../theme.dart';

/// Colours to pick from at once: greys, then the colours of the wheel, light to dark.
const colorPalette = <int>[
  0x000000,
  0x202020,
  0x404040,
  0x808080,
  0xC0C0C0,
  0xF0F0F0,
  0xFFFFFF,
  0xF5DEB3,
  0x8B0000,
  0xD7263D,
  0xFF0000,
  0xFF6B7D,
  0xFF40C0,
  0xFF1493,
  0xDDA0DD,
  0xEE82EE,
  0xFF7F00,
  0xFFA500,
  0xFFC940,
  0xFFFF00,
  0x808000,
  0x7FFFD4,
  0xCCFF66,
  0xFFE4B5,
  0x004D1A,
  0x1E9C45,
  0x33FF33,
  0x00FF00,
  0x00FF99,
  0x008080,
  0x00FFFF,
  0x66FFFF,
  0x000080,
  0x0000FF,
  0x4169E1,
  0x00BFFF,
  0x87CEEB,
  0x4B0082,
  0x8000FF,
  0x9932CC,
];

/// A colour, picked from the palette, on the spectrum, by its hue, saturation
/// and brightness, a hex code, or its red, green and blue values. Returns
/// RGB, or null if cancelled.
Future<int?> pickColor(BuildContext context, int rgb) => showDialog<int>(
  context: context,
  builder: (d) {
    var hsv = HSVColor.fromColor(Color(0xFF000000 | rgb));
    final hex = TextEditingController();
    final r = TextEditingController(), g = TextEditingController(), b = TextEditingController();
    void fill() {
      final v = hsv.toColor().toARGB32() & 0xFFFFFF;
      hex.text = v.toRadixString(16).padLeft(6, '0').toUpperCase();
      r.text = '${(v >> 16) & 255}';
      g.text = '${(v >> 8) & 255}';
      b.text = '${v & 255}';
    }

    fill();
    return StatefulBuilder(
      builder: (d, setState) {
        void setRgb(int v) => setState(() {
          hsv = HSVColor.fromColor(Color(0xFF000000 | (v & 0xFFFFFF)));
          fill();
        });
        int channel(TextEditingController c) => (int.tryParse(c.text) ?? 0).clamp(0, 255);
        Widget num3(String label, TextEditingController c) => Expanded(
          child: Padding(
            padding: const EdgeInsets.only(right: 6),
            child: TextField(
              controller: c,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: label, isDense: true),
              onChanged: (_) => setRgb((channel(r) << 16) | (channel(g) << 8) | channel(b)),
            ),
          ),
        );
        final now = hsv.toColor().toARGB32() & 0xFFFFFF;
        return AlertDialog(
          title: const Text('Colour'),
          content: SizedBox(
            width: 360,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(
                    spacing: 5,
                    runSpacing: 5,
                    children: [
                      for (final c in colorPalette)
                        Tooltip(
                          message: '#${c.toRadixString(16).padLeft(6, '0').toUpperCase()}',
                          child: InkWell(
                            onTap: () => setRgb(c),
                            child: Container(
                              width: 34,
                              height: 26,
                              decoration: BoxDecoration(
                                color: Color(0xFF000000 | c),
                                borderRadius: BorderRadius.circular(5),
                                border: Border.all(color: c == now ? Kc.green : Kc.line, width: c == now ? 2 : 1),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 130,
                    child: _Spectrum(
                      hsv: hsv,
                      onPick: (h) => setState(() {
                        hsv = h;
                        fill();
                      }),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    height: 30,
                    decoration: BoxDecoration(
                      color: hsv.toColor(),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Kc.line),
                    ),
                  ),
                  for (final (label, value, max, set) in <(String, double, double, void Function(double))>[
                    ('Hue', hsv.hue, 360, (v) => hsv = hsv.withHue(v)),
                    ('Saturation', hsv.saturation, 1, (v) => hsv = hsv.withSaturation(v)),
                    ('Brightness', hsv.value, 1, (v) => hsv = hsv.withValue(v)),
                  ])
                    Row(
                      children: [
                        SizedBox(width: 84, child: Text(label)),
                        Expanded(
                          child: Slider(
                            value: value.clamp(0, max),
                            max: max,
                            onChanged: (v) => setState(() {
                              set(v);
                              fill();
                            }),
                          ),
                        ),
                      ],
                    ),
                  Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: TextField(
                            controller: hex,
                            decoration: const InputDecoration(labelText: 'Hex', prefixText: '#', isDense: true),
                            onChanged: (t) {
                              final v = int.tryParse(t.replaceAll('#', '').trim(), radix: 16);
                              if (v != null && t.replaceAll('#', '').trim().length == 6) {
                                hsv = HSVColor.fromColor(Color(0xFF000000 | v));
                                r.text = '${(v >> 16) & 255}';
                                g.text = '${(v >> 8) & 255}';
                                b.text = '${v & 255}';
                                setState(() {});
                              }
                            },
                          ),
                        ),
                      ),
                      num3('R', r),
                      num3('G', g),
                      num3('B', b),
                    ],
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(d, now), child: const Text('OK')),
          ],
        );
      },
    );
  },
);

/// Hue across, and down: white at the top, the colour in the middle, black at the bottom.
class _Spectrum extends StatelessWidget {
  final HSVColor hsv;
  final void Function(HSVColor) onPick;
  const _Spectrum({required this.hsv, required this.onPick});

  void _at(Offset p, Size size) {
    final x = (p.dx / size.width).clamp(0.0, 1.0), y = (p.dy / size.height).clamp(0.0, 1.0);
    final h = x >= 0.9999 ? 359.99 : x * 360;
    onPick(HSVColor.fromAHSV(1, h, y <= 0.5 ? y * 2 : 1, y <= 0.5 ? 1 : (1 - y) * 2));
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final size = Size(box.maxWidth, box.maxHeight);
      final px = hsv.hue / 360 * size.width;
      final py = (hsv.value >= 0.999 ? 0.5 * (1 - hsv.saturation) : 0.5 + 0.5 * (1 - hsv.value)) * size.height;
      return GestureDetector(
        onPanDown: (e) => _at(e.localPosition, size),
        onPanUpdate: (e) => _at(e.localPosition, size),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Stack(
            children: [
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [for (var h = 0; h <= 360; h += 60) HSVColor.fromAHSV(1, h.toDouble(), 1, 1).toColor()],
                    ),
                  ),
                ),
              ),
              const Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.white, Color(0x00FFFFFF), Color(0x00000000), Colors.black],
                      stops: [0, 0.45, 0.55, 1],
                    ),
                  ),
                ),
              ),
              Positioned(
                left: px - 8,
                top: py - 8,
                child: Container(
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                    boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 2)],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
