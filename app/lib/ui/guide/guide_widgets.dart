/// The controls the Guide's panels are made of: a card, a slider that's
/// sent while it's held, a switch, a choice, a folded section that
/// remembers whether it's open, and the preset bar.
library;

import 'package:flutter/material.dart';

import '../../comm/guide_presets.dart';
import '../../comm/guide_settings.dart';
import '../theme.dart';
import '../widgets.dart';
import 'guide_layout.dart';

const gSmall = TextStyle(color: Kc.muted, fontSize: 13);

/// A panel's card: its title and its controls.
class GCard extends StatelessWidget {
  final String? title;
  final List<Widget> children;
  const GCard(this.title, this.children, {super.key});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (title != null) SectionHeader(title!),
      Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        decoration: BoxDecoration(
          color: Kc.panel,
          border: Border.all(color: Kc.line),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
      ),
    ],
  );
}

Widget gGroup(String text) => Padding(
  padding: const EdgeInsets.only(top: 10, bottom: 2),
  child: Text(text.toUpperCase(), style: Kc.term(13, color: Kc.muted)),
);

/// A setting's slider: its name, value and unit; sent while it's held.
class GSlide extends StatelessWidget {
  final GuideSettings g;
  final String path, label, unit;
  final double min, max, step;
  final bool enabled;
  const GSlide(
    this.g,
    this.path,
    this.label,
    this.min,
    this.max,
    this.step, {
    super.key,
    this.unit = '',
    required this.enabled,
  });

  @override
  Widget build(BuildContext context) {
    final v = g.number(path, min).toDouble().clamp(min, max);
    final whole = step >= 1;
    final digits = whole
        ? 0
        : step >= 0.1
        ? 1
        : step >= 0.01
        ? 2
        : 3;
    return Row(
      children: [
        SizedBox(
          width: 100,
          child: Text(label, style: TextStyle(color: enabled ? Kc.text : Kc.dim, fontSize: 14)),
        ),
        Expanded(
          child: Slider(
            value: v,
            min: min,
            max: max,
            divisions: ((max - min) / step).round().clamp(1, 2000),
            onChanged: enabled ? (x) => g.set(path, whole ? x.round() : x) : null,
          ),
        ),
        SizedBox(
          width: 86,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerRight,
            child: Text(
              '${v.toStringAsFixed(digits)}${unit.isEmpty ? '' : ' $unit'}',
              textAlign: TextAlign.right,
              style: Kc.term(14, color: enabled ? Kc.text : Kc.dim),
            ),
          ),
        ),
      ],
    );
  }
}

class GToggle extends StatelessWidget {
  final GuideSettings g;
  final String path, label;
  final bool enabled;
  const GToggle(this.g, this.path, this.label, {super.key, required this.enabled});

  @override
  Widget build(BuildContext context) => SwitchListTile(
    contentPadding: EdgeInsets.zero,
    dense: true,
    title: Text(label, style: const TextStyle(fontSize: 14)),
    value: g.flag(path),
    onChanged: enabled ? (on) => g.set(path, on) : null,
  );
}

/// One of a few: chips, wrapping as they need.
class GChoice extends StatelessWidget {
  final GuideSettings g;
  final String path, label;
  final List<(String, String)> options; // value, label
  final bool enabled;
  const GChoice(this.g, this.path, this.label, this.options, {super.key, required this.enabled});

  @override
  Widget build(BuildContext context) => gChips(label, options, g.text(path), (v) => g.set(path, v), enabled: enabled);
}

/// A row of chips under a label, one picked.
Widget gChips(
  String label,
  List<(String, String)> options,
  String value,
  void Function(String) pick, {
  bool enabled = true,
}) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 4),
  child: Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(
        width: 100,
        child: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(label, style: TextStyle(color: enabled ? Kc.text : Kc.dim, fontSize: 14)),
        ),
      ),
      Expanded(
        child: Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final (v, l) in options)
              ChoiceChip(
                showCheckmark: false,
                label: Text(l),
                selected: value == v,
                onSelected: enabled ? (_) => pick(v) : null,
              ),
          ],
        ),
      ),
    ],
  ),
);

/// A labelled row for a dropdown or a field.
Widget gRow(String label, Widget child, {double labelWidth = 100}) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 2),
  child: Row(
    children: [
      SizedBox(
        width: labelWidth,
        child: Text(label, style: const TextStyle(fontSize: 14)),
      ),
      Expanded(child: child),
    ],
  ),
);

/// The rest of a panel's controls, folded under "▸ title": open or shut as
/// the Guide left it last time ([id] names it).
class GSection extends StatelessWidget {
  final String id, title;
  final List<Widget> children;
  final bool open; // when the Guide hasn't touched it
  const GSection(this.id, this.title, this.children, {super.key, this.open = false});

  @override
  Widget build(BuildContext context) {
    final ui = GuideUi.instance;
    return ListenableBuilder(
      listenable: ui,
      builder: (context, _) {
        final on = ui.isOpen(id, open: open);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () => ui.setOpen(id, !on),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    Icon(on ? Icons.arrow_drop_down : Icons.arrow_right, size: 22, color: Kc.muted),
                    Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ),
            if (on) ...children,
          ],
        );
      },
    );
  }
}

/// A panel's presets: the one picked, kept on this computer or built in,
/// "Changed from …" when what's set has moved off it, with Revert and
/// Save as preset…; the Guide's own can be deleted.
class PresetBar extends StatelessWidget {
  final GuideSettings g;
  final GuidePresets store;
  final PresetPanel panel;
  final bool enabled;

  /// Built-in presets' names, if the panel has any (Voice).
  final List<String> builtIn;
  const PresetBar(this.g, this.store, this.panel, {super.key, required this.enabled, this.builtIn = const []});

  bool get _voice => panel == PresetPanel.voice;

  String? get _picked => _voice ? g.text('voice.preset') : store.selected[panel.key];

  void _use(String name) {
    final v = store.valuesOf(panel, name);
    if (v == null) {
      if (_voice) g.set('voice.preset', name);
      return;
    }
    if (_voice && store.isBuiltIn(panel, name)) {
      g.set('voice.preset', name); // the sender knows it, and leaves the mic's settings
      return;
    }
    store.select(panel, name);
    g.setMany({...v, if (_voice) 'voice.preset': name});
  }

  Future<void> _save(BuildContext context) async {
    final mine = store.mine(panel);
    final c = TextEditingController(text: mine.contains(_picked) ? _picked : '');
    final name = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Save as preset'),
        content: SizedBox(
          width: 320,
          child: TextField(
            controller: c,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'Name'),
            onSubmitted: (v) => Navigator.pop(d, v),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(d, c.text), child: const Text('Save')),
        ],
      ),
    );
    if (name == null || !context.mounted) return;
    final values = <String, Object>{
      for (final p in panel.pathsIn(g))
        if (g.value(p) != null) p: g.value(p)!,
    };
    final why = store.save(panel, name, values);
    if (why != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(why)));
    } else if (_voice) {
      g.set('voice.preset', name.trim());
    }
  }

  Future<void> _delete(BuildContext context, String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('Delete the preset $name?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true) store.delete(panel, name);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([g, store]),
    builder: (context, _) {
      final mine = store.mine(panel);
      final picked = _picked;
      final known = picked != null && (builtIn.contains(picked) || mine.contains(picked));
      final off = picked != null && known ? store.differences(panel, g, picked) : const <String>[];
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const SizedBox(width: 100, child: Text('Preset', style: TextStyle(fontSize: 14))),
              Expanded(
                child: DropdownButton<String>(
                  isExpanded: true,
                  value: known ? picked : null,
                  hint: Text(
                    mine.isEmpty && builtIn.isEmpty ? 'None saved yet' : 'Pick one',
                    style: const TextStyle(color: Kc.muted),
                  ),
                  items: [
                    for (final n in builtIn)
                      DropdownMenuItem(
                        value: n,
                        child: Text(n, overflow: TextOverflow.ellipsis),
                      ),
                    for (final n in mine)
                      DropdownMenuItem(
                        value: n,
                        child: Row(
                          children: [
                            Expanded(child: Text(n, overflow: TextOverflow.ellipsis)),
                            const Icon(Icons.person_outline, size: 14, color: Kc.muted),
                          ],
                        ),
                      ),
                  ],
                  onChanged: enabled ? (n) => n == null ? null : _use(n) : null,
                ),
              ),
              if (picked != null && mine.contains(picked))
                IconButton(
                  tooltip: 'Delete this preset',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.delete_outline, size: 20),
                  onPressed: () => _delete(context, picked),
                ),
              IconButton(
                tooltip: 'Save as preset…',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.save_outlined, size: 20),
                onPressed: () => _save(context),
              ),
            ],
          ),
          if (off.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text('Changed from $picked', style: const TextStyle(color: Kc.warn, fontSize: 13)),
                  TextButton(
                    style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                    onPressed: enabled ? () => _use(picked!) : null,
                    child: const Text('Revert'),
                  ),
                  TextButton(
                    style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                    onPressed: () => _save(context),
                    child: const Text('Save as preset…'),
                  ),
                ],
              ),
            ),
        ],
      );
    },
  );
}
