import 'dart:async';

import 'package:flutter/material.dart';

import 'theme.dart';

/// A row of choices, the chosen one lit. [selected] is its index, or -1.
class RemoteChoices extends StatelessWidget {
  final List<String> labels;
  final int selected;
  final ValueChanged<int> onPick;
  final bool enabled;
  const RemoteChoices(
      {super.key, required this.labels, required this.selected, required this.onPick, this.enabled = true});

  @override
  Widget build(BuildContext context) {
    return Wrap(spacing: 8, runSpacing: 8, children: [
      for (var i = 0; i < labels.length; i++)
        ChoiceChip(
          label: Text(labels[i]),
          selected: i == selected,
          showCheckmark: false,
          onSelected: enabled ? (_) => onPick(i) : null,
        ),
    ]);
  }
}

/// An on/off choice, as a full-width button that shows which it is.
class RemoteToggle extends StatelessWidget {
  final String label;
  final bool on;
  final VoidCallback? onTap;
  const RemoteToggle({super.key, required this.label, required this.on, this.onTap});

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      title: Text(label),
      value: on,
      onChanged: onTap == null ? null : (_) => onTap!(),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
    );
  }
}

/// A slider that sends its value while it's held, with the board's value
/// shown when it isn't being touched. [steps] adds buttons that move it by
/// those amounts.
class RemoteSlider extends StatefulWidget {
  final String label;
  final int value;        // the board's
  final int max;
  final String Function(int) text;
  final ValueChanged<int> onChanged;     // as it moves
  final ValueChanged<int>? onEnd;        // on letting go
  final List<int> steps;
  final bool enabled;
  final Color? color;
  const RemoteSlider({
    super.key,
    required this.label,
    required this.value,
    required this.max,
    required this.onChanged,
    this.onEnd,
    this.text = _plain,
    this.steps = const [],
    this.enabled = true,
    this.color,
  });

  static String _plain(int v) => '$v';

  @override
  State<RemoteSlider> createState() => _RemoteSliderState();
}

class _RemoteSliderState extends State<RemoteSlider> {
  int? _held;
  Timer? _settle;

  @override
  void dispose() {
    _settle?.cancel();
    super.dispose();
  }

  void _set(int v) {
    v = v.clamp(0, widget.max);
    _settle?.cancel();
    setState(() => _held = v);
    widget.onChanged(v);
  }

  void _bump(int v, int by) {
    _set(v + by);
    _end();
  }

  void _end() {
    widget.onEnd?.call(_held ?? widget.value);
    // Keep showing it a moment, so it doesn't jump back before the board's
    // answer comes
    _settle?.cancel();
    _settle = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _held = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final v = _held ?? widget.value;
    final tint = widget.color ?? Kc.green;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text(widget.label, style: const TextStyle(fontWeight: FontWeight.w600))),
          Text(widget.text(v), style: Kc.term(16, color: tint)),
          const SizedBox(width: 8),
        ]),
        Row(children: [
          for (final s in widget.steps.where((s) => s < 0))
            _StepButton(s, widget.enabled ? () => _bump(v, s) : null),
          Expanded(
            child: Slider(
              value: v.clamp(0, widget.max).toDouble(),
              min: 0,
              max: widget.max.toDouble(),
              activeColor: tint,
              onChanged: widget.enabled ? (x) => _set(x.round()) : null,
              onChangeEnd: widget.enabled ? (_) => _end() : null,
            ),
          ),
          for (final s in widget.steps.where((s) => s > 0))
            _StepButton(s, widget.enabled ? () => _bump(v, s) : null),
        ]),
      ]),
    );
  }
}

class _StepButton extends StatelessWidget {
  final int step;
  final VoidCallback? onTap;
  const _StepButton(this.step, this.onTap);

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 40,
      child: TextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(36, 36)),
        child: Text(step > 0 ? '+$step' : '−${-step}'),
      ),
    );
  }
}

/// Said when there's nothing to show.
class RemoteEmpty extends StatelessWidget {
  final String text;
  const RemoteEmpty(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(24),
        child: Text(text, textAlign: TextAlign.center, style: const TextStyle(color: Kc.muted)),
      );
}
