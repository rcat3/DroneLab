/// The Guide page's Music tab: music files played to the Vessels beside the
/// voice and beats, with a queue, and a crossfade from one track into the next.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../comm/hivesight_guide.dart';
import '../theme.dart';
import 'guide_widgets.dart';

String _time(double s) {
  final m = s ~/ 60, r = (s % 60).floor();
  return '$m:${r.toString().padLeft(2, '0')}';
}

class MusicTab extends StatefulWidget {
  final HiveSightGuide g;
  final bool enabled;
  const MusicTab(this.g, {super.key, required this.enabled});

  @override
  State<MusicTab> createState() => _MusicTabState();
}

class _MusicTabState extends State<MusicTab> {
  final _search = TextEditingController();
  double? _drag;
  Timer? _settle;

  HiveSightGuide get g => widget.g;

  @override
  void dispose() {
    _search.dispose();
    _settle?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final en = widget.enabled;
    final now = g.musicNow;
    final paused = now?['paused'] == true;
    final dur = (now?['duration'] as num?)?.toDouble() ?? 0;
    final pos = (_drag ?? (now?['position'] as num?)?.toDouble() ?? 0).clamp(0.0, dur > 0 ? dur : 1.0).toDouble();
    final level = ((g.musicLevelDb + 60) / 60).clamp(0.0, 1.0);
    final q = _search.text.trim().toLowerCase();
    final files = q.isEmpty
        ? g.musicFiles
        : [
            for (final f in g.musicFiles)
              if (f.toLowerCase().contains(q)) f,
          ];
    return GCard(null, [
      Row(
        children: [
          Icon(Icons.music_note, size: 18, color: now == null ? Kc.dim : Kc.green),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              now == null ? 'Nothing playing' : '${now['name']}',
              style: const TextStyle(fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      const SizedBox(height: 6),
      Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size(110, 44)),
            onPressed: !en
                ? null
                : now == null
                ? (g.musicQueue.isEmpty ? null : g.musicNext)
                : () => g.musicPause(!paused),
            icon: Icon(now != null && !paused ? Icons.pause : Icons.play_arrow),
            label: Text(now != null && !paused ? 'Pause' : 'Play'),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: en && g.musicQueue.isNotEmpty ? g.musicNext : null,
            icon: const Icon(Icons.skip_next),
            label: const Text('Next'),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'Stop (it fades out)',
            onPressed: en && now != null ? g.musicStop : null,
            icon: const Icon(Icons.stop),
          ),
        ],
      ),
      Row(
        children: [
          Expanded(
            child: Slider(
              value: pos,
              max: dur > 0 ? dur : 1.0,
              onChanged: en && dur > 0 ? (v) => setState(() => _drag = v) : null,
              onChangeEnd: en && dur > 0
                  ? (v) {
                      g.musicSeek(v);
                      _settle?.cancel();
                      _settle = Timer(const Duration(milliseconds: 900), () {
                        if (mounted) setState(() => _drag = null);
                      });
                    }
                  : null,
            ),
          ),
          SizedBox(
            width: 104,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: Text(
                dur > 0 ? '${_time(pos)} / ${_time(dur)}' : '– / –',
                style: Kc.term(13, color: dur > 0 ? Kc.muted : Kc.dim),
              ),
            ),
          ),
        ],
      ),
      GSlide(g, 'music.vol', 'Volume', 0, 1.5, 0.01, enabled: en),
      GSlide(g, 'music.xfade_s', 'Crossfade', 0, 20, 0.5, unit: 's', enabled: en),
      GChoice(g, 'music.at_end', 'Queue empty', const [('stop', 'Stop'), ('loop', 'Repeat the track')], enabled: en),
      // The level going out to the Vessels, with their film's sound
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: level,
            minHeight: 6,
            backgroundColor: Kc.off,
            color: level > 0.9 ? Kc.softRed : Kc.green,
          ),
        ),
      ),
      Row(
        children: [
          Expanded(child: gGroup('Queue')),
          TextButton(onPressed: g.musicQueue.isEmpty ? null : g.musicClear, child: const Text('Clear')),
        ],
      ),
      if (g.musicQueue.isEmpty)
        const Text('Nothing queued. Add tracks below with +; the next one crossfades in as one ends.', style: gSmall)
      else
        for (var i = 0; i < g.musicQueue.length; i++)
          Row(
            children: [
              SizedBox(width: 22, child: Text('${i + 1}', style: gSmall)),
              Expanded(child: Text(g.musicQueue[i], overflow: TextOverflow.ellipsis)),
              IconButton(
                tooltip: 'Play now',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.play_arrow, size: 18),
                onPressed: en
                    ? () {
                        final f = g.musicQueue[i];
                        g.musicRemove(i);
                        g.musicPlay(f);
                      }
                    : null,
              ),
              IconButton(
                tooltip: 'Move up',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.arrow_upward, size: 18),
                onPressed: i == 0 ? null : () => g.musicMove(i, i - 1),
              ),
              IconButton(
                tooltip: 'Move down',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.arrow_downward, size: 18),
                onPressed: i == g.musicQueue.length - 1 ? null : () => g.musicMove(i, i + 1),
              ),
              IconButton(
                tooltip: 'Remove',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close, size: 18),
                onPressed: () => g.musicRemove(i),
              ),
            ],
          ),
      gGroup('Music in ${g.musicDir.isEmpty ? 'the music folder' : g.musicDir}'),
      TextField(
        controller: _search,
        onChanged: (_) => setState(() {}),
        decoration: const InputDecoration(
          hintText: 'Find a track',
          isDense: true,
          prefixIcon: Icon(Icons.search, size: 18),
        ),
      ),
      if (g.musicFiles.isEmpty)
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text('None found. Set the folder under Session → Sender.', style: gSmall),
        )
      else
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 260),
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: files.length,
            itemBuilder: (context, i) {
              final f = files[i];
              return ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                selected: now?['name'] == f,
                title: Text(f, overflow: TextOverflow.ellipsis),
                onTap: en ? () => g.musicPlay(f) : null,
                trailing: IconButton(
                  tooltip: 'Add to the queue',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.playlist_add, size: 20),
                  onPressed: en ? () => g.musicAdd(f) : null,
                ),
              );
            },
          ),
        ),
      const Text('Tap a track to play it now (the one playing crossfades out).', style: gSmall),
    ]);
  }
}
