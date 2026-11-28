/// One panel column of the Guide page: a picker for the panel, its tabs,
/// and the tab's controls, scrolling on their own.
library;

import 'package:flutter/material.dart';

import '../../comm/hivesight_guide.dart';
import '../theme.dart';
import 'guide_layout.dart';
import 'panels_picture.dart';
import 'panels_session.dart';
import 'panels_sound.dart';
import 'panels_toys.dart';
import 'panels_visuals.dart';
import 'words_panel.dart';

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
