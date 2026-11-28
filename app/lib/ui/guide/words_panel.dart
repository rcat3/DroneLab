/// The Guide page's Words panel: the phrase lists and their cues, and the
/// editor for one phrase's text and look. They use the Guide's own words
/// object (hivesight_words.dart), not the settings.
library;

import 'package:flutter/material.dart';

import '../../comm/hivesight_guide.dart';
import '../../comm/hivesight_words.dart';
import '../theme.dart';
import 'guide_widgets.dart';

/// A colour, picked by its hue, saturation and brightness, a hex code, or
/// its red, green and blue values. Returns RGB, or null if cancelled.
Future<int?> pickColor(BuildContext context, int rgb) => showDialog<int>(
  context: context,
  builder: (d) {
    var hsv = HSVColor.fromColor(Color(0xFF000000 | rgb));
    final hex = TextEditingController();
    final r = TextEditingController(), g = TextEditingController(), b = TextEditingController();
    void fill() {
      final c = hsv.toColor();
      final v = c.toARGB32() & 0xFFFFFF;
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
        return AlertDialog(
          title: const Text('Colour'),
          content: SizedBox(
            width: 340,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  height: 36,
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
          actions: [
            TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
            FilledButton(
              onPressed: () => Navigator.pop(d, hsv.toColor().toARGB32() & 0xFFFFFF),
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
  },
);

Future<String?> _ask(BuildContext context, String title, String initial) => showDialog<String>(
  context: context,
  builder: (d) {
    final c = TextEditingController(text: initial);
    return AlertDialog(
      title: Text(title),
      content: TextField(controller: c, autofocus: true, onSubmitted: (v) => Navigator.pop(d, v)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(d, c.text), child: const Text('OK')),
      ],
    );
  },
);

/// A slider on the edited phrase's own value.
Widget _num(
  GuideWords w,
  String label,
  double min,
  double max,
  double step,
  double Function(WordsLook) get,
  void Function(WordsLook, double) set, {
  String unit = '',
  bool enabled = true,
}) {
  final l = w.edited.look;
  final v = get(l).clamp(min, max);
  final digits = step >= 1
      ? 0
      : step >= 0.1
      ? 1
      : 2;
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
          onChanged: enabled
              ? (x) {
                  set(l, x);
                  w.editedChanged();
                }
              : null,
        ),
      ),
      SizedBox(
        width: 86,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerRight,
          child: Text(
            '${v.toStringAsFixed(digits)}${unit.isEmpty ? '' : ' $unit'}',
            style: Kc.term(14, color: enabled ? Kc.text : Kc.dim),
          ),
        ),
      ),
    ],
  );
}

/// The phrase lists, the phrases in the one chosen, and the cues: Previous,
/// Next, Clear, and how long a phrase stays.
class WordsCuesTab extends StatelessWidget {
  final HiveSightGuide g;
  final bool enabled;
  const WordsCuesTab(this.g, {super.key, required this.enabled});

  @override
  Widget build(BuildContext context) {
    final w = g.words;
    return ListenableBuilder(
      listenable: w,
      builder: (context, _) {
        final l = w.list;
        final phrases = l?.phrases ?? const <WordsPhrase>[];
        return GCard(null, [
          const Text(
            "Phrases shown in the Vessel's view, each with its own look and timing. BLACKOUT hides them too. "
            'Lists are kept on this computer. Pick a phrase to edit it under Phrase.',
            style: gSmall,
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: DropdownButton<int>(
                  isExpanded: true,
                  value: w.listIndex.clamp(0, w.lists.isEmpty ? 0 : w.lists.length - 1),
                  items: [
                    for (var i = 0; i < w.lists.length; i++) DropdownMenuItem(value: i, child: Text(w.lists[i].name)),
                  ],
                  onChanged: (i) => i == null ? null : w.selectList(i),
                ),
              ),
              IconButton(
                tooltip: 'New list',
                icon: const Icon(Icons.add),
                onPressed: () async {
                  final n = await _ask(context, 'New list', '');
                  if (n != null) w.addList(n);
                },
              ),
              IconButton(
                tooltip: 'Rename list',
                icon: const Icon(Icons.edit_outlined),
                onPressed: () async {
                  final n = await _ask(context, 'Rename list', l?.name ?? '');
                  if (n != null) w.renameList(n);
                },
              ),
              IconButton(
                tooltip: 'Delete list',
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (d) => AlertDialog(
                      title: Text('Delete ${l?.name}?'),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
                        FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Delete')),
                      ],
                    ),
                  );
                  if (ok == true) w.deleteList();
                },
              ),
            ],
          ),
          for (var i = 0; i < phrases.length; i++)
            Container(
              decoration: BoxDecoration(
                color: i == w.selected ? Kc.raised : null,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: i == w.selected ? Kc.darkGreen : Colors.transparent),
              ),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Show it',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(w.onScreen(phrases[i]) ? Icons.visibility : Icons.play_arrow, size: 20),
                    color: w.onScreen(phrases[i]) ? Kc.green : null,
                    onPressed: enabled ? () => w.cue(i) : null,
                  ),
                  Container(
                    width: 10,
                    height: 10,
                    margin: const EdgeInsets.only(right: 8),
                    decoration: BoxDecoration(color: Color(0xFF000000 | phrases[i].look.color), shape: BoxShape.circle),
                  ),
                  Expanded(
                    child: InkWell(
                      onTap: () => w.select(i),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Text(phrases[i].text, maxLines: 2, overflow: TextOverflow.ellipsis),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Move up',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.arrow_upward, size: 18),
                    onPressed: i == 0 ? null : () => w.movePhrase(i, -1),
                  ),
                  IconButton(
                    tooltip: 'Move down',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.arrow_downward, size: 18),
                    onPressed: i == phrases.length - 1 ? null : () => w.movePhrase(i, 1),
                  ),
                  IconButton(
                    tooltip: 'Remove',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => w.removePhrase(i),
                  ),
                ],
              ),
            ),
          InkWell(
            onTap: () => w.select(-1),
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: w.selected < 0 ? Kc.darkGreen : Kc.line),
              ),
              child: Row(
                children: [
                  const Icon(Icons.add, size: 18, color: Kc.muted),
                  const SizedBox(width: 8),
                  Text(w.selected < 0 ? 'A new phrase, below' : 'A new phrase', style: gSmall),
                ],
              ),
            ),
          ),
          gGroup('Cues'),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.skip_previous),
                label: const Text('Previous'),
                onPressed: enabled && phrases.isNotEmpty ? w.previous : null,
              ),
              FilledButton.icon(
                icon: const Icon(Icons.skip_next),
                label: Text(w.current < 0 ? 'Start' : 'Next'),
                onPressed: enabled && phrases.isNotEmpty ? w.next : null,
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.clear_all),
                label: const Text('Clear all'),
                onPressed: enabled ? w.clear : null,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text('On screen, unless a phrase says otherwise: ${wordsHoldLabel(w.holdSeconds)}'),
          Slider(
            value: w.hold.toDouble(),
            max: (wordsHolds.length - 1).toDouble(),
            divisions: wordsHolds.length - 1,
            label: wordsHoldLabel(w.holdSeconds),
            onChanged: (v) => w.setHold(v.round()),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Go on to the next phrase by itself', style: TextStyle(fontSize: 14)),
            subtitle: w.holdSeconds == 0 ? const Text('Needs a time above', style: gSmall) : null,
            value: w.auto,
            onChanged: w.setAuto,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Start again after the last', style: TextStyle(fontSize: 14)),
            value: w.loop,
            onChanged: w.setLoop,
          ),
        ]);
      },
    );
  }
}

/// One phrase: its text, how it looks, where it goes and for how long.
class WordsPhraseTab extends StatefulWidget {
  final HiveSightGuide g;
  final bool enabled;
  const WordsPhraseTab(this.g, {super.key, required this.enabled});

  @override
  State<WordsPhraseTab> createState() => _WordsPhraseTabState();
}

class _WordsPhraseTabState extends State<WordsPhraseTab> {
  final _text = TextEditingController();
  WordsPhrase? _shownIn; // whose text the field holds

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final g = widget.g, enabled = widget.enabled;
    final w = g.words;
    return ListenableBuilder(
      listenable: w,
      builder: (context, _) {
        final p = w.edited;
        final look = p.look;
        // The field follows whichever phrase is being edited
        if (!identical(_shownIn, p)) {
          _shownIn = p;
          _text.text = p.text;
        }
        void changed(void Function() f) {
          f();
          w.editedChanged();
        }

        return GCard(null, [
          gGroup(w.selected < 0 ? 'New phrase' : 'This phrase'),
          if (w.selected >= 0)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => w.select(-1),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('A new phrase instead'),
              ),
            ),
          TextField(
            controller: _text,
            minLines: 2,
            maxLines: 5,
            maxLength: wordsMaxLength,
            onChanged: (t) => changed(() => p.text = t),
            decoration: const InputDecoration(hintText: 'What to show', isDense: true, counterText: ''),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              FilledButton.icon(
                icon: const Icon(Icons.visibility_outlined),
                label: const Text('Show now'),
                onPressed: enabled ? () => w.play(p, index: w.selected >= 0 ? w.selected : null) : null,
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.terminal),
                label: const Text('As terminal'),
                onPressed: enabled
                    ? () {
                        look.terminal();
                        w.editedChanged();
                        w.play(p, index: w.selected >= 0 ? w.selected : null);
                      }
                    : null,
              ),
              if (w.selected < 0)
                OutlinedButton.icon(
                  icon: const Icon(Icons.playlist_add),
                  label: const Text('Add to list'),
                  onPressed: p.text.trim().isEmpty ? null : () => w.addDraft(),
                ),
            ],
          ),
          gGroup('Look'),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final (label, f) in <(String, void Function(WordsLook))>[
                ('Plain', (x) => x.plain()),
                ('Terminal', (x) => x.terminal()),
                ('Whisper', (x) => x.whisper()),
                ('Shout', (x) => x.shout()),
              ])
                ActionChip(label: Text(label), onPressed: () => changed(() => f(look))),
            ],
          ),
          gChips('Font', wordsFonts, look.font, (v) => changed(() => look.font = v)),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              FilterChip(
                label: const Text('Bold', style: TextStyle(fontWeight: FontWeight.bold)),
                selected: look.bold,
                onSelected: (v) => changed(() => look.bold = v),
              ),
              FilterChip(
                label: const Text('Italic', style: TextStyle(fontStyle: FontStyle.italic)),
                selected: look.italic,
                onSelected: (v) => changed(() => look.italic = v),
              ),
              FilterChip(
                label: const Text('Underline', style: TextStyle(decoration: TextDecoration.underline)),
                selected: look.underline,
                onSelected: (v) => changed(() => look.underline = v),
              ),
              FilterChip(
                label: const Text('Outline'),
                selected: look.outline,
                onSelected: (v) => changed(() => look.outline = v),
              ),
              FilterChip(
                label: const Text('Terminal glow'),
                selected: look.crt,
                onSelected: (v) => changed(() => look.crt = v),
              ),
              FilterChip(
                label: const Text('Blinking cursor'),
                selected: look.cursor,
                onSelected: (v) => changed(() => look.cursor = v),
              ),
              FilterChip(
                label: const Text('Type it out'),
                selected: look.typing,
                onSelected: (v) => changed(() => look.typing = v),
              ),
            ],
          ),
          if (look.typing)
            _num(w, 'Typing speed', 2, 120, 1, (l) => l.typeSpeed, (l, v) => l.typeSpeed = v, unit: 'letters/s'),
          const SizedBox(height: 4),
          Row(
            children: [
              const SizedBox(width: 112, child: Text('Colour', style: TextStyle(fontSize: 14))),
              OutlinedButton.icon(
                icon: Container(
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    color: Color(0xFF000000 | look.color),
                    shape: BoxShape.circle,
                    border: Border.all(color: Kc.muted),
                  ),
                ),
                label: Text('#${look.hex.toUpperCase()}'),
                onPressed: () async {
                  final c = await pickColor(context, look.color);
                  if (c != null) changed(() => look.color = c);
                },
              ),
            ],
          ),
          _num(w, 'Size', 0.02, 0.4, 0.005, (l) => l.size, (l, v) => l.size = v),
          _num(w, 'Opacity', 0, 1, 0.01, (l) => l.opacity, (l, v) => l.opacity = v),
          _num(w, 'Fade', 0, 10, 0.1, (l) => l.fade, (l, v) => l.fade = v, unit: 's'),
          GSection('words.where', 'Where and for how long', [
            Row(
              children: [
                const SizedBox(width: 112, child: Text('Layer', style: TextStyle(fontSize: 14))),
                Expanded(
                  child: DropdownButton<int>(
                    isExpanded: true,
                    value: p.layer,
                    items: [
                      const DropdownMenuItem(value: WordsPhrase.replaceAll, child: Text('Replace everything')),
                      const DropdownMenuItem(value: WordsPhrase.addLayer, child: Text('Add to what\'s showing')),
                      for (var n = 0; n < wordsLayers; n++) DropdownMenuItem(value: n, child: Text('Layer ${n + 1}')),
                    ],
                    onChanged: (v) => v == null ? null : changed(() => p.layer = v),
                  ),
                ),
              ],
            ),
            Row(
              children: [
                const SizedBox(width: 112, child: Text('On screen', style: TextStyle(fontSize: 14))),
                Expanded(
                  child: DropdownButton<int>(
                    isExpanded: true,
                    value: p.hold,
                    items: [
                      const DropdownMenuItem(value: -1, child: Text('The list\'s time')),
                      for (var n = 0; n < wordsHolds.length; n++)
                        DropdownMenuItem(value: n, child: Text(wordsHoldLabel(wordsHolds[n]))),
                    ],
                    onChanged: (v) => v == null ? null : changed(() => p.hold = v),
                  ),
                ),
              ],
            ),
          ]),
          GSection('words.motion', 'Motion', [
            gChips('Motion', wordsModes, look.mode, (v) => changed(() => look.mode = v)),
            _num(w, 'Motion speed', 0, 4, 0.05, (l) => l.speed, (l, v) => l.speed = v),
            _num(w, 'Left / right', -1, 1, 0.01, (l) => l.x, (l, v) => l.x = v),
            _num(w, 'Down / up', -1, 1, 0.01, (l) => l.y, (l, v) => l.y = v),
            _num(w, 'Depth', 0, 1, 0.01, (l) => l.depth, (l, v) => l.depth = v),
            _num(w, 'Turn', -180, 180, 1, (l) => l.yaw, (l, v) => l.yaw = v, unit: '°'),
            _num(w, 'Tilt', -180, 180, 1, (l) => l.pitch, (l, v) => l.pitch = v, unit: '°'),
            _num(w, 'Roll', -180, 180, 1, (l) => l.roll, (l, v) => l.roll = v, unit: '°'),
          ]),
          GSection('words.distortion', 'Distortion', [
            gChips('Effect', wordsDistortions, look.distort, (v) => changed(() => look.setDistortion(v))),
            _num(
              w,
              'Amount',
              0,
              1,
              0.01,
              (l) => l.distAmount,
              (l, v) => l.distAmount = v,
              enabled: look.distort != 'none',
            ),
            _num(
              w,
              'Size of effect',
              0,
              1,
              0.01,
              (l) => l.distFreq,
              (l, v) => l.distFreq = v,
              enabled: look.distort != 'none',
            ),
            _num(
              w,
              'Effect speed',
              0,
              4,
              0.05,
              (l) => l.distSpeed,
              (l, v) => l.distSpeed = v,
              enabled: look.distort != 'none',
            ),
          ]),
          const SizedBox(height: 4),
          const Text(
            'Depth: 0 is as far as the lenses go, 1 is nearest. Pulse with the beat only brightens with the light pulse allowed. '
            "Changes show at once on a phrase that's on screen.",
            style: gSmall,
          ),
        ]);
      },
    );
  }
}
