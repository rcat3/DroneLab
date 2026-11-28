/// The Guide page's Visuals panels: the spiral and the light pulse.
library;

import 'package:flutter/material.dart';

import '../../comm/guide_presets.dart';
import '../../comm/hivesight_guide.dart';
import 'guide_widgets.dart';

class SpiralTab extends StatelessWidget {
  final HiveSightGuide g;
  final bool enabled;
  const SpiralTab(this.g, {super.key, required this.enabled});

  @override
  Widget build(BuildContext context) => GCard(null, [
    PresetBar(g, g.presetStore, PresetPanel.spiral, enabled: enabled),
    GSlide(g, 'spiral.amount', 'Amount', 0, 1, 0.01, enabled: enabled),
    GSlide(g, 'spiral.speed', 'Spin', -2, 2, 0.01, unit: 'rev/s', enabled: enabled),
    GSlide(g, 'spiral.zoom_hz', 'Zoom flow', -2, 2, 0.01, unit: 'Hz', enabled: enabled),
    GSection('visuals.shape', 'Shape', [
      GSlide(g, 'spiral.arms', 'Arms', 1, 12, 1, enabled: enabled),
      GSlide(g, 'spiral.twist', 'Twist', -20, 20, 0.1, enabled: enabled),
      GSlide(g, 'spiral.sharp', 'Sharpness', 0, 1, 0.01, enabled: enabled),
    ]),
    GSection('visuals.colour', 'Colour', [
      GSlide(g, 'spiral.hue', 'Hue', 0, 1, 0.01, enabled: enabled),
      GSlide(g, 'spiral.sat', 'Colour', 0, 1, 0.01, enabled: enabled),
    ]),
  ]);
}

class LightPulseTab extends StatelessWidget {
  final HiveSightGuide g;
  final bool enabled;
  const LightPulseTab(this.g, {super.key, required this.enabled});

  @override
  Widget build(BuildContext context) {
    final allowing = g.vessels.where((v) => v.lightPulse).length;
    return GCard(null, [
      Text(
        'Flashing light, at up to 30 Hz, ramped in over 3 s. Only Vessels who allow you the light pulse see it'
        '${g.vessels.isEmpty ? '' : ' ($allowing of ${g.vessels.length} now)'}. BLACKOUT stops it.',
        style: gSmall,
      ),
      PresetBar(g, g.presetStore, PresetPanel.lightPulse, enabled: enabled),
      GToggle(g, 'photic.on', 'Light pulse on', enabled: enabled),
      GToggle(g, 'photic.sync', 'Follow the beat', enabled: enabled),
      GSlide(g, 'photic.hz', 'Rate', 0.5, 30, 0.1, unit: 'Hz', enabled: enabled && !g.flag('photic.sync')),
      GSlide(g, 'photic.depth', 'Depth', 0, 1, 0.01, enabled: enabled),
      GSection('visuals.pulse_more', 'Colour and alternation', [
        GToggle(g, 'photic.alternate', 'Alternate left and right', enabled: enabled),
        GSlide(g, 'photic.amount', 'Colour field', 0, 1, 0.01, enabled: enabled),
        GSlide(g, 'photic.hue', 'Hue', 0, 1, 0.01, enabled: enabled),
        GSlide(g, 'photic.sat', 'Saturation', 0, 1, 0.01, enabled: enabled),
        GSlide(g, 'photic.hue_cycle_s', 'Hue cycle', 0, 120, 1, unit: 's', enabled: enabled),
      ]),
    ]);
  }
}
