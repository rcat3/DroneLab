/// The Guide page's Picture panels: what the Vessels see (the camera or a
/// file, how it looks, and the screen and video settings).
library;

import 'dart:async';

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

/// The video switcher: what's on (the camera, or a file), what's picked to
/// go on next, how it changes over (a fade), then the controls for the file
/// and the files to pick from. Every control stays where it is whatever's on.
class SourceTab extends StatelessWidget {
  final HiveSightGuide g;
  final bool enabled;
  const SourceTab(this.g, {super.key, required this.enabled});

  @override
  Widget build(BuildContext context) {
    final busy = g.transitioning;
    final go = enabled && !busy;
    final cue = g.cue;
    return GCard(null, [
      Row(
        children: [
          Expanded(
            child: _SourceTile(
              icon: Icons.videocam_outlined,
              title: 'Camera',
              sub: g.options.camera.isEmpty
                  ? 'Test pattern'
                  : (g.cameras.where((c) => c.path == g.options.camera).firstOrNull?.name ?? g.options.camera),
              onAir: !g.liveIsFile,
              onTap: go && g.liveIsFile ? g.goCamera : null,
              hint: 'Fade back to the camera',
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _SourceTile(
              icon: Icons.movie_outlined,
              title: 'File',
              sub: cue ?? 'Pick one below',
              onAir: g.liveIsFile,
              cued: g.playTakesCue,
              onTap: null,
              hint: 'Pick a file below, then press Play',
            ),
          ),
        ],
      ),
      const SizedBox(height: 6),
      gRow(
        'Transition',
        Row(
          children: [
            DropdownButton<String>(
              value: 'fade',
              items: const [DropdownMenuItem(value: 'fade', child: Text('Fade'))],
              onChanged: enabled ? (_) {} : null,
            ),
            Expanded(
              child: GSlide(g, 'fx.fade_s', '', 0, 10, 0.1, unit: 's', enabled: enabled, labelWidth: 0),
            ),
          ],
        ),
      ),
      GSection('picture.camera', 'Camera setup', [CameraPicker(g, enabled: enabled)]),
      const Divider(height: 16),
      MediaControls(g, enabled: enabled),
      gGroup('Video files in ${g.mediaDir.isEmpty ? 'the media folder' : g.mediaDir}'),
      if (g.mediaFiles.isEmpty)
        const Text('None found. Set the folder under Session → Sender.', style: gSmall)
      else
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 260),
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final f in g.mediaFiles)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  selected: f == cue,
                  leading: f == g.liveFile
                      ? const Icon(Icons.sensors, size: 18, color: Kc.red)
                      : const Icon(Icons.movie_outlined, size: 18),
                  title: Text(f, overflow: TextOverflow.ellipsis),
                  onTap: () => g.cueFile(f),
                ),
            ],
          ),
        ),
      GSection('picture.playback', 'Playback options', [
        GChoice(g, 'media.at_end', 'At the end', const [
          ('loop', 'Loop'),
          ('camera', 'Camera'),
          ('hold', 'Hold'),
        ], enabled: enabled),
        GSlide(g, 'media.av_offset_ms', 'A/V offset', -500, 1000, 10, unit: 'ms', enabled: enabled),
        GSlide(g, 'mix.media_vol', 'Film sound', 0, 1.5, 0.01, enabled: enabled),
      ]),
    ]);
  }
}

/// A source on the switcher: what it is, and whether it's on air or picked
/// to go on next.
class _SourceTile extends StatelessWidget {
  final IconData icon;
  final String title, sub, hint;
  final bool onAir, cued;
  final VoidCallback? onTap;
  const _SourceTile({
    required this.icon,
    required this.title,
    required this.sub,
    required this.hint,
    required this.onAir,
    this.cued = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Tooltip(
    message: hint,
    child: Material(
      color: onAir ? Kc.raised : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: onAir ? Kc.red : Kc.line, width: onAir ? 2 : 1),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, size: 18, color: onAir ? Kc.text : Kc.muted),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
                  ),
                  // The same place whatever it says
                  Text(
                    onAir ? 'ON AIR' : (cued ? 'NEXT' : ''),
                    style: Kc.term(12, color: onAir ? Kc.softRed : Kc.warn),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(sub, style: gSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
      ),
    ),
  );
}

String _time(double s) {
  final m = s ~/ 60, r = (s % 60).floor();
  return '$m:${r.toString().padLeft(2, '0')}';
}

/// Skip back, Play or Pause, skip on, and the progress bar you can drag: in
/// the same place whatever's on. With the camera on they wait (disabled);
/// Play puts the picked file on.
class MediaControls extends StatefulWidget {
  final HiveSightGuide g;
  final bool enabled;
  const MediaControls(this.g, {super.key, required this.enabled});

  @override
  State<MediaControls> createState() => _MediaControlsState();
}

class _MediaControlsState extends State<MediaControls> {
  double? _drag; // where the slider is being dragged to
  Timer? _settle;

  @override
  void dispose() {
    _settle?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final g = widget.g;
    final go = widget.enabled && !g.transitioning;
    final file = g.liveIsFile && g.mediaDuration > 0;
    final playing = g.liveIsFile && !g.playTakesCue && !g.flag('media.paused');
    final pos = (_drag ?? g.mediaPosition).clamp(0.0, file ? g.mediaDuration : 1.0).toDouble();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              tooltip: 'Back 10 seconds',
              iconSize: 28,
              icon: const Icon(Icons.replay_10),
              onPressed: go && file ? () => g.skip(-10) : null,
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size(130, 44)),
              onPressed: go && g.cue != null ? g.playOrPause : null,
              icon: Icon(playing ? Icons.pause : Icons.play_arrow),
              label: Text(playing ? 'Pause' : 'Play'),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: 'On 10 seconds',
              iconSize: 28,
              icon: const Icon(Icons.forward_10),
              onPressed: go && file ? () => g.skip(10) : null,
            ),
          ],
        ),
        Row(
          children: [
            Expanded(
              child: Slider(
                value: pos,
                max: file ? g.mediaDuration : 1.0,
                onChanged: go && file ? (v) => setState(() => _drag = v) : null,
                onChangeEnd: go && file
                    ? (v) {
                        g.seek(v);
                        // Held where it was dropped until the sender's position catches up
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
                  file ? '${_time(pos)} / ${_time(g.mediaDuration)}' : '– / –',
                  style: Kc.term(13, color: file ? Kc.muted : Kc.dim),
                ),
              ),
            ),
          ],
        ),
        // A line kept for what Play will do, so nothing below moves
        SizedBox(
          height: 18,
          child: Text(
            g.playTakesCue ? 'Play puts "${g.cue}" on, with a fade.' : '',
            style: gSmall,
            overflow: TextOverflow.ellipsis,
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
