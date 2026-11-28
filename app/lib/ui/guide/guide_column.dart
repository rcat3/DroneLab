/// One panel column of the Guide page: a picker for the panel, its tabs,
/// and the tab's controls, scrolling on their own.
library;

import 'package:flutter/material.dart';

import '../../comm/guide_presets.dart';
import '../../comm/hivesight_guide.dart';
import '../theme.dart';
import 'guide_layout.dart';
import 'panels_picture.dart';
import 'panels_source.dart';
import 'panels_session.dart';
import 'panels_music.dart';
import 'panels_sound.dart';
import 'panels_toys.dart';
import 'panels_visuals.dart';
import 'words_panel.dart';

/// The settings a tab's reset button puts back to their defaults: none for
/// a tab with nothing of the sender's settings on it.
List<String> resetPaths(ColumnSpec spec, HiveSightGuide g) {
  List<String> under(String prefix, [Set<String> leave = const {}]) => [
    for (final p in g.paths)
      if (p.startsWith(prefix) && !leave.contains(p)) p,
  ];
  return switch ((spec.panel, spec.shownTab)) {
    (GuidePanel.session, 'calibrate') => under('view.'),
    (GuidePanel.picture, 'look') => PresetPanel.pictureLook.pathsIn(g),
    (GuidePanel.picture, 'screen') => ['fx.screen', 'fx.fade', 'fx.fade_s', 'fx.delay_ms', 'video.bitrate_kbps'],
    (GuidePanel.picture, 'source') => [
      'switch.effect',
      'switch.secs',
      'media.at_end',
      'media.av_offset_ms',
      'mix.media_vol',
    ],
    (GuidePanel.sound, 'music') => ['music.vol', 'music.xfade_s', 'music.at_end'],
    (GuidePanel.sound, 'mix') => under('mix.'),
    (GuidePanel.sound, 'beats') => under('beats.'),
    (GuidePanel.sound, 'voice') => under('voice.', {'voice.mute'}),
    (GuidePanel.visuals, 'light') => under('photic.'),
    (GuidePanel.visuals, _) => under('spiral.'),
    _ => const [],
  };
}

/// The controls of [spec]'s panel on its tab.
Widget guideTab(ColumnSpec spec, HiveSightGuide g) {
  final on = g.linked;
  return switch ((spec.panel, spec.shownTab)) {
    (GuidePanel.session, 'vessels') => VesselsTab(g),
    (GuidePanel.session, 'sender') => SenderTab(g),
    (GuidePanel.session, 'calibrate') => CalibrateTab(g, enabled: on),
    (GuidePanel.session, _) => SessionTab(g),
    (GuidePanel.picture, 'look') => LookTab(g, enabled: on),
    (GuidePanel.picture, 'screen') => ScreenTab(g, enabled: on),
    (GuidePanel.picture, _) => SourceTab(g, enabled: on),
    (GuidePanel.sound, 'mix') => MixTab(g, enabled: on),
    (GuidePanel.sound, 'beats') => BeatsTab(g, enabled: on),
    (GuidePanel.sound, 'music') => MusicTab(g, enabled: on),
    (GuidePanel.sound, _) => VoiceTab(g, enabled: on),
    (GuidePanel.visuals, 'light') => LightPulseTab(g, enabled: on),
    (GuidePanel.visuals, _) => SpiralTab(g, enabled: on),
    (GuidePanel.words, 'phrase') => WordsPhraseTab(g, enabled: on),
    (GuidePanel.words, _) => WordsCuesTab(g, enabled: on),
    (GuidePanel.toys, _) => ToysTab(g, enabled: on),
    (GuidePanel.scenes, _) => ScenesTab(g, enabled: on),
  };
}

class GuideColumn extends StatelessWidget {
  final HiveSightGuide g;
  final int index;

  /// Whether it scrolls on its own (in a narrow window the page does).
  final bool scrolls;
  const GuideColumn(this.g, this.index, {super.key, this.scrolls = true});

  @override
  Widget build(BuildContext context) {
    final ui = GuideUi.instance;
    return ListenableBuilder(
      listenable: ui,
      builder: (context, _) {
        final spec = ui.columns[index];
        final tabs = spec.panel.tabs;
        final header = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<GuidePanel>(
                      isExpanded: true,
                      value: spec.panel,
                      style: Kc.term(16, color: Kc.green),
                      iconEnabledColor: Kc.green,
                      items: [
                        for (final p in GuidePanel.values)
                          DropdownMenuItem(value: p, child: Text('> ${p.title.toUpperCase()}')),
                      ],
                      onChanged: (p) => p == null ? null : ui.setPanel(index, p),
                    ),
                  ),
                ),
                _ResetButton(g, spec),
              ],
            ),
            if (tabs.length > 1)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final (id, label) in tabs)
                      ChoiceChip(
                        showCheckmark: false,
                        visualDensity: VisualDensity.compact,
                        label: Text(label),
                        selected: spec.shownTab == id,
                        onSelected: (_) => ui.setTab(index, id),
                      ),
                  ],
                ),
              ),
          ],
        );
        final body = ListenableBuilder(listenable: g, builder: (context, _) => guideTab(spec, g));
        if (!scrolls) {
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [header, body]);
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header,
            Expanded(
              child: SingleChildScrollView(padding: const EdgeInsets.only(bottom: 24), child: body),
            ),
          ],
        );
      },
    );
  }
}

/// Puts every setting on the tab back to its default: in the same corner of
/// every column, grey when the tab has none to reset. One step to undo.
class _ResetButton extends StatelessWidget {
  final HiveSightGuide g;
  final ColumnSpec spec;
  const _ResetButton(this.g, this.spec);

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: g,
    builder: (context, _) {
      final values = <String, Object>{
        for (final p in resetPaths(spec, g))
          if (g.defaults[p] != null) p: g.defaults[p]!,
      };
      if (spec.panel == GuidePanel.sound && spec.shownTab == 'voice' && values.isNotEmpty) {
        values['voice.preset'] = g.defaults['voice.preset'] ?? 'clean';
      }
      return IconButton(
        tooltip: values.isEmpty ? 'Nothing here to reset' : 'Reset this tab to its defaults',
        visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.restart_alt),
        onPressed: g.linked && values.isNotEmpty ? () => g.setMany(values) : null,
      );
    },
  );
}
