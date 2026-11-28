/// The Guide page's Picture panels: what the Vessels see (the camera or a
/// file, how it looks, and the screen and video settings).
library;

import 'package:flutter/material.dart';

import '../../comm/guide_presets.dart';
import '../../comm/hivesight_guide.dart';
import '../theme.dart';
import 'guide_widgets.dart';

/// Which camera, in which mode, as stereo or mono: changed at once, and
/// what the Vessels see from then on (a file playing stops).
class CameraPicker extends StatelessWidget {
  final HiveSightGuide g;
  final bool enabled;
  const CameraPicker(this.g, {super.key, required this.enabled});

  /// The mode to start a camera in: the biggest picture that still runs
  /// smoothly (24 fps or more), MJPEG before YUYV, or failing that the
  /// smoothest. Big YUYV modes often run at 2–5 fps.
  static ({String format, int width, int height, List<int> fps}) _best(
    List<({String format, int width, int height, List<int> fps})> modes,
  ) {
    int score(({String format, int width, int height, List<int> fps}) m) {
      final fps = _top(m.fps) ?? 0;
      return (fps >= 24 ? 1 << 40 : fps << 32) + (m.format == 'mjpeg' ? 1 << 31 : 0) + m.width * m.height;
    }

    return ([...modes]..sort((a, b) => score(b).compareTo(score(a)))).first;
  }

  static int? _top(List<int> fps) => fps.isEmpty ? null : fps.reduce((a, b) => a > b ? a : b);

  /// What the sender starts with, and the test pattern always uses.
  static const _pattern = SenderOptions();

  void _use(SenderOptions o) => g.setOptions(o, useCamera: true);

  @override
  Widget build(BuildContext context) {
    final o = g.options;
    final cam = g.cameras.where((c) => c.path == o.camera).firstOrNull;
    // Biggest first, MJPEG before YUYV
    final modes = [...?cam?.modes]
      ..sort((a, b) {
        final f = (a.format == 'mjpeg' ? 0 : 1).compareTo(b.format == 'mjpeg' ? 0 : 1);
        return f != 0 ? f : (b.width * b.height).compareTo(a.width * a.height);
      });
    final mode = modes.where((m) => m.format == o.format && m.width == o.width && m.height == o.height).firstOrNull;
    Widget row(String label, Widget child) => gRow(label, child, labelWidth: 80);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        row(
          'Camera',
          Row(
            children: [
              Expanded(
                child: DropdownButton<String>(
                  isExpanded: true,
                  value: o.camera.isEmpty || cam != null ? o.camera : null,
                  hint: Text(o.camera, overflow: TextOverflow.ellipsis),
                  items: [
                    const DropdownMenuItem(value: '', child: Text('Test pattern')),
                    for (final c in g.cameras)
                      DropdownMenuItem(
                        value: c.path,
                        child: Text(c.name, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: enabled
                      ? (p) {
                          final c = g.cameras.where((x) => x.path == p).firstOrNull;
                          final m = c == null || c.modes.isEmpty ? null : _best(c.modes);
                          _use(
                            m == null
                                ? o.copyWith(
                                    camera: p ?? '',
                                    format: _pattern.format,
                                    width: _pattern.width,
                                    height: _pattern.height,
                                    fps: _pattern.fps,
                                    layout: 'sbs',
                                  )
                                : o.copyWith(
                                    camera: p,
                                    format: m.format,
                                    width: m.width,
                                    height: m.height,
                                    fps: _top(m.fps),
                                  ),
                          );
                        }
                      : null,
                ),
              ),
              IconButton(
                tooltip: 'Look for cameras and microphones again',
                icon: const Icon(Icons.refresh, size: 20),
                onPressed: g.listDevices,
              ),
            ],
          ),
        ),
        if (cam != null)
          row(
            'Mode',
            DropdownButton<int>(
              isExpanded: true,
              value: mode == null ? null : modes.indexOf(mode),
              items: [
                for (var i = 0; i < modes.length; i++)
                  DropdownMenuItem(
                    value: i,
                    child: Text(
                      '${modes[i].width}×${modes[i].height} ${modes[i].format.toUpperCase()}'
                      '${_top(modes[i].fps) == null ? '' : ', ${_top(modes[i].fps)} fps'}',
                      style: TextStyle(color: (_top(modes[i].fps) ?? 30) < 24 ? Kc.muted : null),
                    ),
                  ),
              ],
              onChanged: enabled
                  ? (i) {
                      final m = modes[i!];
                      _use(o.copyWith(format: m.format, width: m.width, height: m.height, fps: _top(m.fps)));
                    }
                  : null,
            ),
          ),
        row(
          'Picture',
          Wrap(
            spacing: 6,
            children: [
              for (final (v, l) in const [('sbs', 'Stereo side by side'), ('mono', 'Mono')])
                ChoiceChip(
                  showCheckmark: false,
                  label: Text(l),
                  selected: o.layout == v,
                  onSelected: enabled && o.camera.isNotEmpty ? (_) => _use(o.copyWith(layout: v)) : null,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// How the picture looks: a preset, the main colour controls, the rest folded.
class LookTab extends StatelessWidget {
  final HiveSightGuide g;
  final bool enabled;
  const LookTab(this.g, {super.key, required this.enabled});

  @override
  Widget build(BuildContext context) => GCard(null, [
    PresetBar(g, g.presetStore, PresetPanel.pictureLook, enabled: enabled),
    GSlide(g, 'fx.brightness', 'Picture lift', -0.5, 0.5, 0.01, enabled: enabled),
    GSlide(g, 'fx.contrast', 'Contrast', 0, 2, 0.01, enabled: enabled),
    GSlide(g, 'fx.saturation', 'Saturation', 0, 2, 0.01, enabled: enabled),
    GSlide(g, 'fx.vignette', 'Vignette', 0, 1, 0.01, enabled: enabled),
    GSection('picture.tint', 'Tint', [
      GSlide(g, 'fx.tint_r', 'Tint red', 0, 1.5, 0.01, enabled: enabled),
      GSlide(g, 'fx.tint_g', 'Tint green', 0, 1.5, 0.01, enabled: enabled),
      GSlide(g, 'fx.tint_b', 'Tint blue', 0, 1.5, 0.01, enabled: enabled),
      GToggle(g, 'fx.invert', 'Invert', enabled: enabled),
    ]),
    GSection('picture.flip', 'Eyes and orientation', [
      GToggle(g, 'fx.swap', 'Swap eyes', enabled: enabled),
      GToggle(g, 'fx.mirror', 'Mirror', enabled: enabled),
      GToggle(g, 'fx.rotate180', 'Rotate 180°', enabled: enabled),
      GToggle(g, 'fx.mono', 'Left eye only', enabled: enabled),
    ]),
  ]);
}

/// The phone's screen, the fade, the delay, and what's sent.
class ScreenTab extends StatelessWidget {
  final HiveSightGuide g;
  final bool enabled;
  const ScreenTab(this.g, {super.key, required this.enabled});

  @override
  Widget build(BuildContext context) => GCard(null, [
    GSlide(g, 'fx.screen', 'Screen brightness', 0, 1, 0.01, enabled: enabled),
    const Text("0 leaves the phone's own level, held as it was when the Vessel joined.", style: gSmall),
    gGroup('Fade and time'),
    GSlide(g, 'fx.fade', 'Fade', 0, 1, 0.01, enabled: enabled),
    GSlide(g, 'fx.fade_s', 'Fade time', 0, 10, 0.1, unit: 's', enabled: enabled),
    GSlide(g, 'fx.delay_ms', 'Video delay', 0, 5000, 10, unit: 'ms', enabled: enabled),
    GSection('picture.video', 'Video', [
      GSlide(g, 'video.bitrate_kbps', 'Bitrate', 1000, 30000, 500, unit: 'kb/s', enabled: enabled),
      GChoice(g, 'stream.layout', 'Layout', const [
        ('mono', 'Mono'),
        ('sbs', 'Side by side'),
        ('hsbs', 'Half SBS'),
        ('tb', 'Top/bottom'),
        ('htb', 'Half T/B'),
      ], enabled: enabled),
    ]),
  ]);
}
