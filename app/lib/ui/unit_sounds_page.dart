import 'dart:async';

import 'package:flutter/material.dart';

import '../comm/board_link.dart';
import '../comm/comm_controller.dart';
import '../comm/unit_sounds.dart';
import 'theme.dart';
import 'widgets.dart';

/// Which of the unit's sound files it plays for what happens: one for each
/// event, or none, each with a play button to hear it on the unit.
class UnitSoundsPage extends StatefulWidget {
  final CommController comm;
  const UnitSoundsPage({super.key, required this.comm});

  @override
  State<UnitSoundsPage> createState() => _UnitSoundsPageState();
}

class _UnitSoundsPageState extends State<UnitSoundsPage> {
  CommController get comm => widget.comm;
  List<String>? _tracks;

  /// The one being played on the unit, to hear it, till it ends or is stopped.
  UnitSoundEvent? _playing;
  Timer? _watch;

  Future<void> _play(UnitSoundEvent e, String track) async {
    await comm.chimeOnUnit(track);
    if (!mounted) return;
    setState(() => _playing = e);
    // Watch for its end: the unit says whether it's still playing
    _watch?.cancel();
    _watch = Timer.periodic(const Duration(milliseconds: 800), (_) async {
      if (!await comm.unitChiming() && mounted) _stopped();
    });
  }

  Future<void> _stop() async {
    await comm.stopChimeOnUnit();
    _stopped();
  }

  void _stopped() {
    _watch?.cancel();
    _watch = null;
    if (mounted) setState(() => _playing = null);
  }

  @override
  void dispose() {
    _watch?.cancel();
    if (_playing != null) comm.stopChimeOnUnit();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final t = await comm.unitTracks(fresh: true);
    if (mounted) setState(() => _tracks = t);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: comm,
      builder: (context, _) {
        final up = comm.board.state == BoardState.connected && comm.board.status != null;
        final tracks = _tracks;
        return Scaffold(
          appBar: AppBar(title: const Text('Unit Sounds')),
          body: ListView(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 24 + MediaQuery.paddingOf(context).bottom),
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 8, bottom: 4),
                child: Text(
                    'The unit plays the sound file picked for each, from the sounds folder on its SD card, '
                    'over whatever its sound player is doing, which carries on after. Short files work best.',
                    style: TextStyle(color: Kc.muted, fontSize: 13)),
              ),
              if (!up)
                const Panel(children: [PanelRow(title: 'Connect to the unit to pick its sounds')])
              else if (!comm.unitCanPlay)
                const Panel(children: [
                  PanelRow(title: 'This unit has no speaker', subtitle: 'The low-profile housing has none to play them on'),
                ])
              else if (tracks == null)
                const Panel(children: [PanelRow(title: 'Asking the unit for its sound files...')])
              else if (tracks.isEmpty)
                const Panel(children: [
                  PanelRow(
                      title: 'No sound files on the SD card',
                      subtitle: 'Put WAV, MP3 or FLAC files in its sounds folder, then come back here'),
                ])
              else ...[
                const SectionHeader('When'),
                Panel(children: [
                  for (final e in UnitSoundEvent.values)
                    _EventRow(
                      comm: comm,
                      event: e,
                      tracks: tracks,
                      playing: _playing == e,
                      onPlay: (t) => _play(e, t),
                      onStop: _stop,
                    ),
                ]),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _EventRow extends StatelessWidget {
  final CommController comm;
  final UnitSoundEvent event;
  final List<String> tracks;
  final bool playing;
  final void Function(String track) onPlay;
  final VoidCallback onStop;
  const _EventRow(
      {required this.comm,
      required this.event,
      required this.tracks,
      required this.playing,
      required this.onPlay,
      required this.onStop});

  @override
  Widget build(BuildContext context) {
    final picked = comm.unitSounds[event];
    // One picked before that's not on the card now still shows, marked
    final missing = picked != null && !tracks.contains(picked);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(event.title, style: const TextStyle(fontWeight: FontWeight.w600)),
        Text(event.help, style: const TextStyle(color: Kc.muted, fontSize: 13)),
        const SizedBox(height: 4),
        Row(children: [
          Expanded(
            child: DropdownButton<String?>(
              isExpanded: true,
              value: picked,
              dropdownColor: Kc.raised,
              underline: const SizedBox.shrink(),
              onChanged: (t) {
                comm.setUnitSound(event, t);
                if (t != null) onPlay(t);
              },
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('None', style: TextStyle(color: Kc.muted))),
                if (missing)
                  DropdownMenuItem<String?>(
                      value: picked, child: Text('$picked (not on the card)', style: const TextStyle(color: Kc.softRed))),
                for (final t in tracks) DropdownMenuItem<String?>(value: t, child: Text(t, overflow: TextOverflow.ellipsis)),
              ],
            ),
          ),
          // Play it on the unit, and stop it part way
          playing
              ? IconButton(
                  tooltip: 'Stop it',
                  icon: const Icon(Icons.stop, color: Kc.pink),
                  onPressed: onStop,
                )
              : IconButton(
                  tooltip: 'Play it on the unit',
                  icon: const Icon(Icons.play_arrow, color: Kc.muted),
                  onPressed: picked == null || missing ? null : () => onPlay(picked),
                ),
        ]),
      ]),
    );
  }
}
