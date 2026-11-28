/// The Guide page's Sound panels: the voice and its effects, the mix, and
/// the binaural beats.
library;

import 'package:flutter/material.dart';

import '../../comm/guide_presets.dart';
import '../../comm/hivesight_guide.dart';
import '../theme.dart';
import 'guide_widgets.dart';

/// The voice: a preset, the mic's basics, and every effect folded under Adjust.
class VoiceTab extends StatelessWidget {
  final HiveSightGuide g;
  final bool enabled;
  const VoiceTab(this.g, {super.key, required this.enabled});

  @override
  Widget build(BuildContext context) {
    final mode = g.text('voice.fx_mode');
    return GCard(null, [
      if (g.voiceProblem.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text('No voice: ${g.voiceProblem}', style: const TextStyle(fontSize: 13, color: Kc.softRed)),
        ),
      PresetBar(g, g.presetStore, PresetPanel.voice, enabled: enabled, builtIn: g.presets),
      GSlide(g, 'voice.gain_db', 'Gain', -12, 36, 0.5, unit: 'dB', enabled: enabled),
      GSlide(g, 'voice.gate_db', 'Gate', -90, -20, 1, unit: 'dB', enabled: enabled),
      GSlide(g, 'voice.comp_ratio', 'Compression', 1, 10, 0.1, unit: ':1', enabled: enabled),
      GToggle(g, 'voice.denoise', 'Noise suppression', enabled: enabled),
      GSection('sound.adjust', 'Adjust', [
        gGroup('Effect'),
        GChoice(g, 'voice.fx_mode', 'Mode', const [
          ('off', 'Off'),
          ('shift', 'Shift'),
          ('robot', 'Robot'),
        ], enabled: enabled),
        if (mode == 'shift') ...[
          GSlide(g, 'voice.shift_pitch', 'Pitch', 0.5, 2.5, 0.01, unit: '×', enabled: enabled),
          GSlide(g, 'voice.shift_formant', 'Formant', 0.7, 1.5, 0.01, unit: '×', enabled: enabled),
        ],
        if (mode == 'robot') ...[
          GSlide(g, 'voice.robot_hz', 'Robot pitch', 60, 400, 1, unit: 'Hz', enabled: enabled),
          GSlide(g, 'voice.robot_noise', 'Breath', 0, 0.5, 0.01, enabled: enabled),
        ],
        gGroup('Tone and space'),
        GSlide(g, 'voice.pitch', 'Simple pitch', 0.5, 2, 0.01, unit: '×', enabled: enabled),
        GSlide(g, 'voice.highpass_hz', 'High-pass', 20, 1500, 5, unit: 'Hz', enabled: enabled),
        GSlide(g, 'voice.lowpass_hz', 'Low-pass', 500, 20000, 50, unit: 'Hz', enabled: enabled),
        GSlide(g, 'voice.echo_ms', 'Echo time', 1, 1500, 1, unit: 'ms', enabled: enabled),
        GSlide(g, 'voice.echo_feedback', 'Echo feedback', 0, 0.95, 0.01, enabled: enabled),
        GSlide(g, 'voice.echo_mix', 'Echo mix', 0, 1, 0.01, enabled: enabled),
        GSlide(g, 'voice.reverb_room', 'Reverb room', 0, 1, 0.01, enabled: enabled),
        GSlide(g, 'voice.reverb_damp', 'Reverb damping', 0, 1, 0.01, enabled: enabled),
        GSlide(g, 'voice.reverb_mix', 'Reverb mix', 0, 1, 0.01, enabled: enabled),
        // The display unit's simpler effects, for its presets ("… (unit)"): 0 leaves each out
        gGroup('Character'),
        GToggle(g, 'voice.crowd', 'Crowd (three voices)', enabled: enabled),
        GSlide(g, 'voice.drive_db', 'Drive', 0, 36, 0.5, unit: 'dB', enabled: enabled),
        GSlide(g, 'voice.ring_hz', 'Ring rate', 1, 1000, 1, unit: 'Hz', enabled: enabled),
        GSlide(g, 'voice.ring_mix', 'Ring mix', 0, 1, 0.01, enabled: enabled),
        GSlide(g, 'voice.crush_bits', 'Bit crush', 0, 16, 1, unit: 'bits', enabled: enabled),
        GSlide(g, 'voice.chorus_rate', 'Chorus rate', 0.05, 5, 0.05, unit: 'Hz', enabled: enabled),
        GSlide(g, 'voice.chorus_depth_ms', 'Chorus depth', 0, 10, 0.1, unit: 'ms', enabled: enabled),
        GSlide(g, 'voice.chorus_mix', 'Chorus mix', 0, 1, 0.01, enabled: enabled),
        GSlide(g, 'voice.out_gain_db', 'Output gain', -12, 12, 0.5, unit: 'dB', enabled: enabled),
      ]),
    ]);
  }
}

class MixTab extends StatelessWidget {
  final HiveSightGuide g;
  final bool enabled;
  const MixTab(this.g, {super.key, required this.enabled});

  @override
  Widget build(BuildContext context) => GCard(null, [
    GSlide(g, 'mix.master', 'Master', 0, 1, 0.01, enabled: enabled),
    GSlide(g, 'mix.voice_vol', 'Voice', 0, 1.5, 0.01, enabled: enabled),
    GSlide(g, 'mix.beats_vol', 'Beats', 0, 1, 0.01, enabled: enabled),
    GSlide(g, 'mix.noise_vol', 'Pink noise', 0, 1, 0.01, enabled: enabled),
    GSlide(g, 'mix.media_vol', 'Film sound', 0, 1.5, 0.01, enabled: enabled),
    GSlide(g, 'mix.type_vol', 'Typing sound', 0, 1, 0.01, enabled: enabled),
    GSection('sound.mix_more', 'Placement and buffer', [
      GSlide(g, 'mix.voice_pan', 'Voice pan', -1, 1, 0.01, enabled: enabled),
      GSlide(g, 'mix.autopan_hz', 'Auto-pan', 0, 2, 0.01, unit: 'Hz', enabled: enabled),
      GSlide(g, 'mix.jitter_ms', 'Voice buffer', 10, 200, 5, unit: 'ms', enabled: enabled),
    ]),
  ]);
}

class BeatsTab extends StatelessWidget {
  final HiveSightGuide g;
  final bool enabled;
  const BeatsTab(this.g, {super.key, required this.enabled});

  @override
  Widget build(BuildContext context) => GCard(null, [
    PresetBar(g, g.presetStore, PresetPanel.beats, enabled: enabled),
    GToggle(g, 'beats.on', 'Binaural beats', enabled: enabled),
    GChoice(g, 'beats.source', 'Made of', const [
      ('tone', 'Tones'),
      ('pink', 'Pink noise'),
      ('white', 'White noise'),
    ], enabled: enabled),
    GSlide(
      g,
      'beats.noise_bw',
      'Noise width',
      100,
      6000,
      50,
      unit: 'Hz',
      enabled: enabled && g.text('beats.source') != 'tone',
    ),
    if (g.text('beats.source') != 'tone')
      const Text(
        'The same beat, on noise around the carrier: softer than two plain tones. Narrower sounds more like a tone.',
        style: gSmall,
      ),
    GSlide(g, 'beats.carrier_hz', 'Carrier', 60, 600, 1, unit: 'Hz', enabled: enabled),
    GSlide(g, 'beats.beat_hz', 'Beat', 0.5, 40, 0.1, unit: 'Hz', enabled: enabled),
    GSlide(g, 'beats.glide_s', 'Glide', 0, 30, 0.5, unit: 's', enabled: enabled),
  ]);
}
