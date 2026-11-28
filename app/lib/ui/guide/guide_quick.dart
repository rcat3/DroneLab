/// The Guide page's fixed left side: the preview and the quick controls,
/// always in view while the panel columns scroll beside them.
library;

import 'package:flutter/material.dart';

import '../../comm/hivesight_guide.dart';
import '../../comm/hivesight_words.dart';
import '../theme.dart';
import 'guide_widgets.dart';
import 'panels_session.dart';

/// What the first Vessel sees (without the lens correction), kept in view:
/// [maxHeight] at most, with its switch and frame rate on one line.
class GuidePreview extends StatelessWidget {
  final HiveSightGuide g;
  final bool enabled;
  final double maxHeight;
  const GuidePreview(this.g, {super.key, required this.enabled, required this.maxHeight});

  @override
  Widget build(BuildContext context) {
    final img = g.preview;
    final on = g.flag('preview.video');
    final fps = g.number('preview.fps', 5).toDouble().clamp(1.0, 20.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight.clamp(120.0, 600.0)),
          child: AspectRatio(
            aspectRatio: 2,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Container(
                color: Colors.black,
                alignment: Alignment.center,
                child: on && img != null
                    ? Image.memory(img, gaplessPlayback: true, fit: BoxFit.contain)
                    : Text(on ? 'Waiting for a Vessel…' : 'Preview off', style: gSmall),
              ),
            ),
          ),
        ),
        Row(
          children: [
            const Text('Preview', style: TextStyle(fontSize: 14)),
            Switch(value: on, onChanged: enabled ? (v) => g.set('preview.video', v) : null),
            Expanded(
              child: Slider(
                value: fps,
                min: 1,
                max: 20,
                divisions: 19,
                onChanged: enabled && on ? (v) => g.set('preview.fps', v.round()) : null,
              ),
            ),
            Text('${fps.round()} fps', style: Kc.term(13, color: Kc.muted)),
          ],
        ),
      ],
    );
  }
}

/// Fade, Master, the scenes, the words' cues, a line per Vessel and the
/// session's buttons.
class GuideQuick extends StatelessWidget {
  final HiveSightGuide g;
  final bool enabled;
  const GuideQuick(this.g, {super.key, required this.enabled});

  @override
  Widget build(BuildContext context) {
    final w = g.words;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GCard(null, [
          GSlide(g, 'fx.fade', 'Fade', 0, 1, 0.01, enabled: enabled),
          GSlide(g, 'mix.master', 'Master', 0, 1, 0.01, enabled: enabled),
          const SizedBox(height: 4),
          if (g.scenes.isEmpty)
            const Text('No scenes yet: keep one under Scenes.', style: gSmall)
          else
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final s in g.scenes)
                  ActionChip(
                    avatar: const Icon(Icons.movie_filter_outlined, size: 16),
                    label: Text(s),
                    onPressed: enabled ? () => g.loadScene(s) : null,
                  ),
              ],
            ),
        ]),
        const SizedBox(height: 10),
        ListenableBuilder(
          listenable: w,
          builder: (context, _) {
            final phrases = w.list?.phrases ?? const <WordsPhrase>[];
            final now = w.current >= 0 && w.current < phrases.length ? phrases[w.current].text : '';
            final can = enabled && phrases.isNotEmpty;
            return GCard(null, [
              Row(
                children: [
                  IconButton.outlined(
                    tooltip: 'Previous phrase',
                    icon: const Icon(Icons.skip_previous),
                    onPressed: can ? w.previous : null,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      now.isEmpty ? (phrases.isEmpty ? 'No phrases in this list' : 'Words: nothing cued') : now,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: now.isEmpty ? Kc.muted : Kc.text),
                    ),
                  ),
                  const SizedBox(width: 10),
                  IconButton.filled(
                    tooltip: w.current < 0 ? 'Start the phrases' : 'Next phrase',
                    icon: const Icon(Icons.skip_next),
                    onPressed: can ? w.next : null,
                  ),
                  IconButton.outlined(
                    tooltip: 'Clear the words',
                    icon: const Icon(Icons.clear_all),
                    onPressed: enabled ? w.clear : null,
                  ),
                ],
              ),
            ]);
          },
        ),
        const SizedBox(height: 10),
        GCard(null, [
          if (g.vessels.isEmpty)
            Text(g.session == null ? 'No session' : 'Nobody has joined yet', style: gSmall)
          else
            for (final v in g.vessels)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Icon(
                      v.verified ? Icons.verified_user_outlined : Icons.help_outline,
                      color: v.verified ? Kc.green : Kc.warn,
                      size: 16,
                    ),
                    const SizedBox(width: 8),
                    Text(g.nameOf(v), style: const TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        [
                          if (v.stats['fps'] != null) '${v.stats['fps']} fps',
                          if (v.stats['loss'] != null) 'loss ${v.stats['loss']}',
                          if (v.stats['battery'] != null) '${v.stats['battery']}%',
                          if (!v.lightPulse) 'no light pulse',
                        ].join(' · '),
                        style: gSmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
          const SizedBox(height: 8),
          SessionControls(g, compact: true),
        ]),
      ],
    );
  }
}
