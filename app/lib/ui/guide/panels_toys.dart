/// The Guide page's Toys and Scenes panels.
library;

import 'package:flutter/material.dart';

import '../../comm/board_protocol.dart' show OthersCommand;
import '../../comm/hivesight_guide.dart';
import '../../comm/hivesight_toys.dart';
import '../../comm/patterns.dart' show builtInPatterns;
import '../patterns_page.dart';
import '../theme.dart';
import 'guide_widgets.dart';

/// One Vessel's toys, by channel, as HiveMind Control does them: levels,
/// patterns (built in, ours and our favourites) and their speed, and STOP.
/// What the Vessel's phone says decides what shows: no unit, or not allowed.
class ToysTab extends StatefulWidget {
  final HiveSightGuide g;
  final bool enabled;
  const ToysTab(this.g, {super.key, required this.enabled});

  @override
  State<ToysTab> createState() => _ToysTabState();
}

class _ToysTabState extends State<ToysTab> {
  HiveSightGuide get g => widget.g;
  GuideToys get t => g.toys;

  void _do(VoidCallback f) => setState(f);

  @override
  void initState() {
    super.initState();
    g.comm.patterns.addListener(_changed);
  }

  @override
  void dispose() {
    g.comm.patterns.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final vessels = g.vessels;
    // One Vessel's the one driven: the only one there is, or the one picked
    if (t.vessel == null) t.target = vessels.length == 1 ? vessels.first.id : null;
    final v = t.vessel;
    final info = v?.toys;
    final playable = widget.enabled && t.ready;
    final yours = [...g.comm.patterns.mine, ...g.comm.patterns.received.where((e) => e.favourite)];
    return GCard(null, [
      const Text(
        "One Vessel's toys at a time, by channel. They only do what that Vessel has allowed you on Vibe, and "
        'stop when you press STOP, when they leave, when you remove them, or when the session ends or the link drops.',
        style: gSmall,
      ),
      if (vessels.isEmpty)
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text('No Vessel in the session yet.', style: gSmall),
        )
      else ...[
        gGroup('Vessel'),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final x in vessels)
              ChoiceChip(
                showCheckmark: false,
                label: Text(g.nameOf(x)),
                selected: t.target == x.id,
                onSelected: widget.enabled ? (_) => _do(() => t.pick(x.id)) : null,
              ),
          ],
        ),
        if (v == null)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('Pick a Vessel.', style: gSmall),
          )
        else if (info == null)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text("Waiting for their phone to say…", style: gSmall),
          )
        else if (!info.unit)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('${g.nameOf(v)} has no display unit connected, so no toys.', style: gSmall),
          )
        else if (!info.allowed)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(switch (info.why) {
              'ignored' => '${g.nameOf(v)} is ignoring toys in sessions.',
              'off' => "${g.nameOf(v)} isn't letting anyone use their toys.",
              _ => "${g.nameOf(v)} hasn't allowed you to use their toys (Permissions → Vibe).",
            }, style: gSmall),
          )
        else if (info.mapped == 0)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text("${g.nameOf(v)}'s unit has no toys connected.", style: gSmall),
          ),
        if (playable) ...[
          gGroup('Levels'),
          for (var c = 0; c < OthersCommand.vibeChannels; c++)
            if (info!.mapped & (1 << c) != 0)
              Row(
                children: [
                  SizedBox(width: 112, child: Text('V${c + 1}', style: const TextStyle(fontSize: 14))),
                  Expanded(
                    child: Slider(
                      value: t.levels[c].toDouble(),
                      min: 0,
                      max: OthersCommand.levelTop.toDouble(),
                      divisions: OthersCommand.levelTop,
                      onChanged: (x) => _do(() => t.setLevel(c, x.round())),
                    ),
                  ),
                  SizedBox(
                    width: 78,
                    child: Text('${t.levels[c]}', textAlign: TextAlign.right, style: Kc.term(14)),
                  ),
                ],
              ),
          gGroup('Pattern'),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              ChoiceChip(
                showCheckmark: false,
                label: const Text('NONE'),
                selected: t.playing == null,
                onSelected: (_) => _do(() => t.play(null)),
              ),
              for (final name in builtInPatterns) _patternChip(ToyPattern.builtIn(name)),
              for (final e in yours) _patternChip(ToyPattern.custom(e.pattern)),
            ],
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () =>
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => PatternsPage(comm: g.comm))),
              icon: const Icon(Icons.edit, size: 16),
              label: Text(yours.isEmpty ? 'Make or import patterns…' : 'Edit patterns…'),
            ),
          ),
          if (t.playing != null) ...[
            gGroup('Plays on'),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (var c = 0; c < OthersCommand.vibeChannels; c++)
                  if (info!.mapped & (1 << c) != 0)
                    FilterChip(
                      showCheckmark: false,
                      label: Text('V${c + 1}'),
                      selected: t.active & (1 << c) != 0,
                      onSelected: (_) => _do(() => t.toggleActive(c)),
                    ),
              ],
            ),
            Row(
              children: [
                const SizedBox(width: 112, child: Text('Speed', style: TextStyle(fontSize: 14))),
                Expanded(
                  child: Slider(
                    value: t.speed.toDouble().clamp(25, 300),
                    min: 25,
                    max: 300,
                    divisions: 55,
                    onChanged: (x) => _do(() => t.setSpeed((x / 5).round() * 5)),
                  ),
                ),
                SizedBox(
                  width: 78,
                  child: Text('${t.speed}%', textAlign: TextAlign.right, style: Kc.term(14)),
                ),
              ],
            ),
          ],
        ],
        const SizedBox(height: 10),
        // STOP's always there, whatever else isn't
        FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
          onPressed: widget.enabled && v != null ? () => _do(t.stop) : null,
          icon: const Icon(Icons.stop),
          label: const Text('STOP'),
        ),
      ],
    ]);
  }

  Widget _patternChip(ToyPattern p) {
    final on = p.same(t.playing);
    return ChoiceChip(
      showCheckmark: false,
      label: Text(p.name.toUpperCase()),
      selected: on,
      onSelected: (_) => _do(() => t.play(on ? null : p)),
    );
  }
}

class ScenesTab extends StatefulWidget {
  final HiveSightGuide g;
  final bool enabled;
  const ScenesTab(this.g, {super.key, required this.enabled});

  @override
  State<ScenesTab> createState() => _ScenesTabState();
}

class _ScenesTabState extends State<ScenesTab> {
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final g = widget.g, enabled = widget.enabled;
    return GCard(null, [
      const Text('Voice, mix, beats, vision, spiral and light pulse together, kept on this computer.', style: gSmall),
      if (g.scenes.isNotEmpty) ...[
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final s in g.scenes)
              InputChip(
                label: Text(s),
                onPressed: enabled ? () => g.loadScene(s) : null,
                onDeleted: enabled ? () => g.deleteScene(s) : null,
                deleteButtonTooltipMessage: 'Delete',
              ),
          ],
        ),
      ],
      const SizedBox(height: 6),
      Row(
        children: [
          Expanded(
            child: TextField(
              controller: _name,
              enabled: enabled,
              decoration: const InputDecoration(hintText: 'Name for this scene', isDense: true),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: enabled
                ? () {
                    final n = _name.text.trim();
                    if (n.isEmpty) return;
                    g.saveScene(n);
                    _name.clear();
                  }
                : null,
            child: const Text('Save'),
          ),
        ],
      ),
    ]);
  }
}
