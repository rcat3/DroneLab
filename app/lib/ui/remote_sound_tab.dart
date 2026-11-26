import 'package:flutter/material.dart';

import '../comm/remote_model.dart';
import 'card_saving.dart';
import 'remote_widgets.dart';
import 'theme.dart';
import 'widgets.dart';

/// Remote → Sound: the voice effect, the visualizer and the voice ring, and
/// the sound player.
class RemoteSoundTab extends StatefulWidget {
  final RemoteModel model;
  const RemoteSoundTab({super.key, required this.model});

  @override
  State<RemoteSoundTab> createState() => _RemoteSoundTabState();
}

class _RemoteSoundTabState extends State<RemoteSoundTab> {
  int _part = 0;

  RemoteModel get m => widget.model;
  Map<String, dynamic> get s => m.state;

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
        child: SegmentedButton<int>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: 0, label: Text('Voice Effects')),
            ButtonSegment(value: 1, label: Text('Visualizer')),
            ButtonSegment(value: 2, label: Text('Playback')),
          ],
          selected: {_part},
          onSelectionChanged: (v) => setState(() => _part = v.first),
        ),
      ),
      Expanded(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          children: switch (_part) {
            0 => _voice(),
            1 => _visualizer(),
            _ => _playback(),
          },
        ),
      ),
    ]);
  }

  // ----- Voice Effects -----

  List<Widget> _voice() {
    final v = s['voice'] as Map<String, dynamic>?;
    // The low-profile model has no speaker: its effect is HiveMind's, set in Setup
    if (v == null || v['fitted'] == 0) {
      return const [
        RemoteEmpty('This unit has no speaker, so its voice effect is set for HiveMind in Setup.'),
      ];
    }
    final presets = [for (final p in (m.info['presets'] as List? ?? const [])) p as String];
    final loud = v['loud'] as int?;
    return [
      const SectionHeader('Voice effect'),
      Panel(children: [
        RemoteToggle(
          label: 'Play on speaker',
          on: v['speaker'] == 1,
          onTap: () => m.command('voice', {'speaker': v['speaker'] == 1 ? 0 : 1}),
        ),
        RemoteSlider(
          label: 'Effect volume',
          value: v['volume'] as int,
          max: 100,
          text: (x) => '$x%',
          steps: const [-5, -1, 1, 5],
          onChanged: (x) => m.queue('fx-vol', 'voice', {'v': x}),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: Text('If it feeds back, turn it down.', style: TextStyle(color: Kc.muted, fontSize: 13)),
        ),
        if (loud != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Loud room', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              RemoteChoices(
                labels: const ['Off', '1', '2', '3', 'Max'],
                selected: loud,
                onPick: (i) => m.command('voice', {'loud': i}),
              ),
              const SizedBox(height: 8),
              const Text(
                "Keeps a loud room's noise out between words. The stronger, the louder the room it keeps out, "
                'and the more of quiet speech it cuts, so only for loud places.',
                style: TextStyle(color: Kc.muted, fontSize: 13),
              ),
            ]),
          ),
      ]),
      const SectionHeader('Effect'),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: RemoteChoices(
          labels: presets,
          selected: v['preset'] as int,
          onPick: (i) => m.command('voice', {'p': i}),
        ),
      ),
    ];
  }

  // ----- Visualizer -----

  List<Widget> _visualizer() {
    final styles = [for (final p in (m.info['visualizers'] as List? ?? const [])) p as String];
    final ring = s['ring'] as Map<String, dynamic>?;
    final colors = (m.info['ring_colors'] as List? ?? const []);
    if (styles.isEmpty && ring == null) return const [RemoteEmpty('This unit has no microphone for a visualizer.')];
    return [
      if (styles.isNotEmpty) ...[
        const SectionHeader('Sound Visualizer'),
        RemoteChoices(
          labels: styles,
          selected: (s['vis'] as int?) ?? -1,
          // Pick a style, and bring it on the display
          onPick: (i) => m.command('vis', {'v': i, 'show': 1}),
        ),
      ],
      if (ring != null) ...[
        const SectionHeader('Voice ring'),
        Panel(children: [
          RemoteToggle(
            label: 'Show the voice ring',
            on: ring['on'] == 1,
            onTap: () => m.command('ring', {'on': ring['on'] == 1 ? 0 : 1}),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Wrap(spacing: 8, runSpacing: 8, children: [
              for (var c = 0; c < colors.length; c++)
                ChoiceChip(
                  avatar: CircleAvatar(backgroundColor: _hex(colors[c][1] as String)),
                  label: Text(colors[c][0] as String),
                  selected: ring['color'] == c,
                  showCheckmark: false,
                  onSelected: (_) => m.command('ring', {'c': c, 'on': 1}),
                ),
            ]),
          ),
        ]),
      ],
    ];
  }

  static Color _hex(String rgb) => Color(0xFF000000 | int.parse(rgb.substring(1), radix: 16));

  // ----- Playback -----

  List<Widget> _playback() {
    final p = s['sound'] as Map<String, dynamic>?;
    if (p == null) return const [RemoteEmpty('This unit has no speaker to play sounds.')];
    final tracks = m.tracks;
    final track = p['track'] as int;
    final playing = p['playing'] == 1;
    final length = p['length'] as int;
    final position = p['position'] as int;
    final speakerBusy = (s['voice'] as Map?)?['speaker'] == 1;
    return [
      const SectionHeader('Sound player'),
      Panel(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Column(children: [
            Text(
              track < tracks.length ? tracks[track] : (tracks.isEmpty ? 'No sound files on the SD card' : ''),
              textAlign: TextAlign.center,
              style: Kc.term(18, color: Kc.green),
            ),
            if (tracks.isNotEmpty)
              Text('${track + 1} / ${tracks.length}', style: const TextStyle(color: Kc.muted)),
          ]),
        ),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          IconButton(
            iconSize: 32,
            icon: const Icon(Icons.skip_previous),
            onPressed: () => m.command('sound', {'skip': -1}),
          ),
          IconButton.filled(
            iconSize: 40,
            icon: Icon(playing ? Icons.pause : Icons.play_arrow),
            onPressed: () => m.command('sound', {'play': playing ? 0 : 1}),
          ),
          IconButton(
            iconSize: 32,
            icon: const Icon(Icons.skip_next),
            onPressed: () => m.command('sound', {'skip': 1}),
          ),
        ]),
        RemoteSlider(
          label: '${_clock(position)}  /  ${_clock(length)}',
          value: length > 0 ? (1000 * position / length).round() : 0,
          max: 1000,
          text: (_) => '',
          enabled: length > 0,
          onChanged: (_) {},
          onEnd: (x) => m.command('sound', {'seek': (x * length / 1000).round()}),
        ),
        if (speakerBusy)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Text('The player waits while the voice effect is on the speaker.',
                style: TextStyle(color: Kc.muted, fontSize: 13)),
          ),
        RemoteSlider(
          label: 'Volume',
          value: p['volume'] as int,
          max: 100,
          text: (x) => '$x%',
          steps: const [-5, 5],
          onChanged: (x) => m.queue('snd-vol', 'sound', {'v': x}),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: RemoteChoices(
            labels: const ['Repeat all', 'Repeat one', 'Play once'],
            selected: p['repeat'] as int,
            onPick: (i) => m.command('sound', {'r': i}),
          ),
        ),
        RemoteToggle(
          label: 'Play at startup',
          on: p['autoplay'] == 1,
          onTap: () => m.command('sound', {'auto': p['autoplay'] == 1 ? 0 : 1}),
        ),
      ]),
      const SectionHeader('Tracks'),
      if (tracks.isEmpty)
        const Panel(children: [PanelRow(title: 'No tracks')])
      else
        Panel(children: [
          for (var t = 0; t < tracks.length; t++)
            PanelRow(
              title: tracks[t],
              leading: Icon(t == track ? Icons.volume_up : Icons.music_note, color: t == track ? Kc.green : Kc.dim),
              onTap: () => m.command('sound', {'t': t}),
              trailing: [
                if (cardSoundFor(m, t) case final file?)
                  IconButton(
                    tooltip: 'Delete',
                    icon: const Icon(Icons.delete_outline, color: Kc.softRed),
                    onPressed: () => deleteCardSound(context, m, file),
                  ),
              ],
            ),
        ]),
      ...cardSounds(context, m),
    ];
  }

  static String _clock(int ms) {
    final s = ms ~/ 1000;
    final mm = (s ~/ 60) % 60, ss = (s % 60).toString().padLeft(2, '0');
    return s >= 3600 ? '${s ~/ 3600}:${mm.toString().padLeft(2, '0')}:$ss' : '$mm:$ss';
  }
}
