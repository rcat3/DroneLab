import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'theme.dart';

/// "> A HEADING", in the Terminal's letters, with anything after it on the
/// right.
class SectionHeader extends StatelessWidget {
  final String text;
  final Widget? trailing;
  const SectionHeader(this.text, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 32),
        child: Row(children: [
          Expanded(
            child: Semantics(
              header: true,
              child: Text('> ${text.toUpperCase()}', style: Kc.term(16, color: Kc.green)),
            ),
          ),
          ?trailing,
        ]),
      ),
    );
  }
}

/// A dark panel with a hairline border, its children divided by lines.
class Panel extends StatelessWidget {
  final List<Widget> children;
  final Color color;
  final Color border;
  const Panel({super.key, required this.children, this.color = Kc.panel, this.border = Kc.line});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
          color: color, border: Border.all(color: border), borderRadius: const BorderRadius.all(Radius.circular(12))),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const Divider(height: 1),
            children[i],
          ],
        ],
      ),
    );
  }
}

/// Something with a short explanation behind an (i), shown in green under it
/// while the (i) is on. [builder] is given the (i) button to place.
class Explained extends StatefulWidget {
  final String help;
  final Widget Function(BuildContext context, Widget info) builder;
  final EdgeInsets helpPadding;
  final TextAlign align;
  const Explained(
      {super.key,
      required this.help,
      required this.builder,
      this.helpPadding = const EdgeInsets.fromLTRB(16, 0, 16, 10),
      this.align = TextAlign.start});

  @override
  State<Explained> createState() => _ExplainedState();
}

class _ExplainedState extends State<Explained> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final info = IconButton(
      tooltip: _open ? 'Hide the explanation' : 'Explain',
      isSelected: _open,
      visualDensity: VisualDensity.compact,
      icon: const Icon(Icons.info_outline, size: 20, color: Kc.dim),
      selectedIcon: const Icon(Icons.info, size: 20, color: Kc.green),
      onPressed: () => setState(() => _open = !_open),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        widget.builder(context, info),
        if (_open)
          Padding(
            padding: widget.helpPadding,
            child: Text(widget.help,
                textAlign: widget.align, style: const TextStyle(color: Kc.green, fontSize: 13, height: 1.35)),
          ),
      ],
    );
  }
}

/// A row in a panel: a title, an optional line under it, and what's on the
/// right.
class PanelRow extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? leading;
  final List<Widget> trailing;
  final VoidCallback? onTap;
  const PanelRow({super.key, required this.title, this.subtitle, this.leading, this.trailing = const [], this.onTap});

  @override
  Widget build(BuildContext context) {
    final row = Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Row(children: [
          if (leading != null) ...[leading!, const SizedBox(width: 12)],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
                if (subtitle != null) Text(subtitle!, style: const TextStyle(color: Kc.muted, fontSize: 13)),
              ],
            ),
          ),
          ...trailing,
        ]),
      ),
    );
    return onTap == null ? row : InkWell(onTap: onTap, child: row);
  }
}

/// Someone's picture, or the board's head in a visor when they haven't one;
/// in a green glow while they talk.
class DroneAvatar extends StatelessWidget {
  final Uint8List? picture;
  final bool talking;
  final double size;
  const DroneAvatar({super.key, this.picture, this.talking = false, this.size = 40});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Kc.bg,
        border: Border.all(color: talking ? Kc.green : Kc.line),
        boxShadow: talking ? [BoxShadow(color: Kc.green.withValues(alpha: 0.45), blurRadius: 12)] : null,
      ),
      child: picture != null
          ? Image.memory(picture!, fit: BoxFit.cover, gaplessPlayback: true)
          : Padding(padding: EdgeInsets.all(size * 0.15), child: const CustomPaint(painter: _VisorPainter())),
    );
  }
}

class _VisorPainter extends CustomPainter {
  const _VisorPainter();

  // The default avatar, in a 16 px grid, as the board draws it
  static const _head = [
    (5, 1, 6, 1), (4, 2, 8, 1), (3, 3, 10, 7), (4, 10, 8, 1), (5, 11, 6, 1), (2, 13, 12, 2), //
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final px = size.shortestSide / 16;
    final head = Paint()..color = Kc.darkGreen;
    for (final (x, y, w, h) in _head) {
      canvas.drawRect(Rect.fromLTWH(x * px, y * px, w * px, h * px), head);
    }
    canvas.drawRect(Rect.fromLTWH(4 * px, 5 * px, 8 * px, 2 * px), Paint()..color = Kc.visor);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// How strong a board's heard over direct comms, in four bars.
class SignalBars extends StatelessWidget {
  final int rssi;
  const SignalBars(this.rssi, {super.key});

  static int bars(int rssi) => rssi > -60
      ? 4
      : rssi > -70
          ? 3
          : rssi > -80
              ? 2
              : 1;

  @override
  Widget build(BuildContext context) {
    final n = bars(rssi);
    return Semantics(
      label: 'Signal $n of 4, $rssi dBm',
      child: SizedBox(
        width: 22,
        height: 16,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            for (var i = 1; i <= 4; i++)
              Container(
                width: 4,
                height: 4.0 + (i - 1) * 3.3,
                decoration: BoxDecoration(
                    color: i <= n ? Kc.green : Kc.line, borderRadius: const BorderRadius.all(Radius.circular(1))),
              ),
          ],
        ),
      ),
    );
  }
}

/// A big STOP, kept at the foot of the screen.
class StopBar extends StatelessWidget {
  final VoidCallback? onPressed;
  final String label;
  const StopBar({super.key, required this.onPressed, this.label = 'STOP'});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      child: SizedBox(
        height: 64,
        child: FilledButton.icon(
          style: ButtonStyle(
            backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled) ? Kc.line : Kc.red),
            foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled) ? Kc.dim : Colors.white),
            shape: const WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(14)))),
            elevation: const WidgetStatePropertyAll(0),
            shadowColor: const WidgetStatePropertyAll(Colors.transparent),
          ),
          onPressed: onPressed,
          icon: const Icon(Icons.stop_rounded, size: 32),
          label: Text(label, style: Kc.term(32, color: onPressed == null ? Kc.dim : Colors.white)),
        ),
      ),
    );
  }
}
