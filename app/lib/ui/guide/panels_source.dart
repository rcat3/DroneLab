/// The Guide page's Source tab: a video switcher. What's on air, what's
/// picked to go on next (with a look at it), and how it changes over (a
/// fade out to black and in, a dissolve, or a cut); the controls for the
/// film that's on; then, for the kind of source being looked at, its own
/// settings and what to pick from; and the queue. Every control stays where
/// it is whatever's on.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../comm/hivesight_guide.dart';
import '../theme.dart';
import 'color_picker.dart';
import 'guide_widgets.dart';
import 'panels_picture.dart' show CameraPicker;

String _hex(int rgb) => '#${(rgb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

String specLabel(Map<String, dynamic>? s) => switch (s?['kind']) {
  'camera' => 'Camera',
  'color' => 'Colour ${_hex((s!['rgb'] as num?)?.toInt() ?? 0)}',
  'image' => 'Image ${s!['file']}',
  'file' => '${s!['file']}',
  _ => '',
};

IconData _kindIcon(String? kind) => switch (kind) {
  'camera' => Icons.videocam_outlined,
  'color' => Icons.palette_outlined,
  'image' => Icons.image_outlined,
  _ => Icons.movie_outlined,
};

class SourceTab extends StatefulWidget {
  final HiveSightGuide g;
  final bool enabled;
  const SourceTab(this.g, {super.key, required this.enabled});

  @override
  State<SourceTab> createState() => _SourceTabState();
}

class _SourceTabState extends State<SourceTab> {
  String _browse = ''; // the kind of source being looked at; the one on air until picked
  String? _lastFile, _lastImage;

  HiveSightGuide get g => widget.g;

  int get _rgb => g.number('color.rgb', 0x202020).toInt();

  /// Look at a kind of source: and, if there's one to pick, pick it to go on next.
  void _tile(String kind) {
    setState(() => _browse = kind);
    final spec = switch (kind) {
      'camera' => HiveSightGuide.cameraSpec,
      'color' => HiveSightGuide.colorSpec(_rgb),
      'image' => _lastImage == null ? null : HiveSightGuide.imageSpec(_lastImage!),
      _ => _lastFile == null ? null : HiveSightGuide.fileSpec(_lastFile!),
    };
    if (spec != null && !(g.liveKind == kind && kind == 'camera')) g.cue(spec);
  }

  @override
  Widget build(BuildContext context) {
    final en = widget.enabled;
    final go = en && !g.transitioning;
    final browse = _browse.isEmpty ? g.liveKind : _browse;
    final cue = g.cueSpec;
    final next = cue ?? (g.queue.isEmpty ? null : g.queue.first);
    return GCard(null, [
      // What's cued, looked at
      Row(
        children: [
          Text('NEXT', style: Kc.term(13, color: Kc.warn)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              next == null ? 'Nothing cued' : '${specLabel(next)}${cue == null ? '  (first in the queue)' : ''}',
              style: gSmall,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      const SizedBox(height: 4),
      NextPreview(g),
      const SizedBox(height: 8),
      // The sources
      Row(
        children: [
          for (final (kind, label) in const [
            ('camera', 'Camera'),
            ('color', 'Colour'),
            ('image', 'Image'),
            ('file', 'File'),
          ]) ...[
            Expanded(
              child: _SourceTile(
                icon: _kindIcon(kind),
                title: label,
                onAir: g.liveKind == kind,
                next: cue?['kind'] == kind,
                looking: browse == kind,
                onTap: () => _tile(kind),
              ),
            ),
            if (kind != 'file') const SizedBox(width: 6),
          ],
        ],
      ),
      const SizedBox(height: 4),
      // How it changes over, and the buttons that do it
      gRow(
        'Transition',
        Row(
          children: [
            DropdownButton<String>(
              value: const ['fade', 'dissolve', 'cut'].contains(g.text('switch.effect'))
                  ? g.text('switch.effect')
                  : 'fade',
              items: const [
                DropdownMenuItem(value: 'fade', child: Text('Fade')),
                DropdownMenuItem(value: 'dissolve', child: Text('Dissolve')),
                DropdownMenuItem(value: 'cut', child: Text('Cut')),
              ],
              onChanged: en ? (v) => v == null ? null : g.set('switch.effect', v) : null,
            ),
            Expanded(
              child: GSlide(
                g,
                'switch.secs',
                '',
                0,
                10,
                0.1,
                unit: 's',
                enabled: en && g.text('switch.effect') != 'cut',
                labelWidth: 0,
              ),
            ),
          ],
        ),
      ),
      Wrap(
        spacing: 8,
        runSpacing: 6,
        children: [
          FilledButton.icon(
            onPressed: go && cue != null ? g.takeCue : null,
            icon: const Icon(Icons.swap_horiz),
            label: const Text('Take'),
          ),
          OutlinedButton(onPressed: go && cue != null ? () => g.takeCue(cut: true) : null, child: const Text('Cut')),
          OutlinedButton.icon(
            onPressed: go && g.queue.isNotEmpty ? g.nextQueued : null,
            icon: const Icon(Icons.skip_next),
            label: Text(g.queue.isEmpty ? 'Next' : 'Next (${g.queue.length})'),
          ),
          if (g.transitioning)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(g.transitionPhase == 'waiting' ? 'Getting ready…' : 'Changing over…', style: gSmall),
            ),
        ],
      ),
      const Divider(height: 18),
      MediaControls(g, enabled: en),
      const Divider(height: 18),
      // The kind of source being looked at
      if (browse == 'camera') _camera(),
      if (browse == 'color') _color(en),
      if (browse == 'image') _image(en),
      if (browse == 'file') _files(),
      const Divider(height: 18),
      _queue(),
      GSection('picture.playback', 'Playback options', [
        GChoice(g, 'media.at_end', 'At the end', const [
          ('loop', 'Loop'),
          ('camera', 'Camera'),
          ('hold', 'Hold'),
          ('next', 'Next'),
        ], enabled: en),
        GSlide(g, 'media.av_offset_ms', 'A/V offset', -500, 1000, 10, unit: 'ms', enabled: en),
        GSlide(g, 'mix.media_vol', 'Film sound', 0, 1.5, 0.01, enabled: en),
      ]),
    ]);
  }

  Widget _camera() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        g.options.camera.isEmpty
            ? 'The test pattern: two balls, one for each eye.'
            : 'The camera: ${g.cameras.where((c) => c.path == g.options.camera).firstOrNull?.name ?? g.options.camera}',
        style: gSmall,
      ),
      GSection('picture.camera', 'Camera setup', [CameraPicker(g, enabled: widget.enabled)]),
    ],
  );

  Widget _color(bool en) {
    final c = _rgb;
    void use(int rgb) {
      g.set('color.rgb', rgb);
      g.cue(HiveSightGuide.colorSpec(rgb));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        gRow(
          'Colour',
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              icon: Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  color: Color(0xFF000000 | c),
                  shape: BoxShape.circle,
                  border: Border.all(color: Kc.muted),
                ),
              ),
              label: Text(_hex(c)),
              onPressed: () async {
                final p = await pickColor(context, c);
                if (p != null) use(p);
              },
            ),
          ),
        ),
        Wrap(
          spacing: 5,
          runSpacing: 5,
          children: [
            for (final p in colorPalette.take(16))
              InkWell(
                onTap: () => use(p),
                child: Container(
                  width: 30,
                  height: 22,
                  decoration: BoxDecoration(
                    color: Color(0xFF000000 | p),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: p == c ? Kc.green : Kc.line, width: p == c ? 2 : 1),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        const Text('On air, the colour follows as you pick. Take it to change over to it.', style: gSmall),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => g.queueAdd(HiveSightGuide.colorSpec(c)),
            icon: const Icon(Icons.playlist_add, size: 18),
            label: const Text('Add this colour to the queue'),
          ),
        ),
      ],
    );
  }

  Widget _image(bool en) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      GSlide(g, 'image.zoom', 'Zoom', 0.2, 8, 0.01, unit: '×', enabled: en),
      GSlide(g, 'image.x', 'Left / right', -1, 1, 0.01, enabled: en),
      GSlide(g, 'image.y', 'Up / down', -1, 1, 0.01, enabled: en),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: en ? () => g.setMany({'image.zoom': 1.0, 'image.x': 0.0, 'image.y': 0.0}) : null,
          icon: const Icon(Icons.center_focus_strong, size: 18),
          label: const Text('Fit the whole picture'),
        ),
      ),
      gGroup('Images in ${g.mediaDir.isEmpty ? 'the media folder' : g.mediaDir}'),
      if (g.mediaImages.isEmpty)
        const Text('None found. Set the folder under Session → Sender.', style: gSmall)
      else
        _list(g.mediaImages, 'image', (f) {
          _lastImage = f;
          g.cue(HiveSightGuide.imageSpec(f));
        }),
    ],
  );

  Widget _files() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      gGroup('Video files in ${g.mediaDir.isEmpty ? 'the media folder' : g.mediaDir}'),
      if (g.mediaFiles.isEmpty)
        const Text('None found. Set the folder under Session → Sender.', style: gSmall)
      else
        _list(g.mediaFiles, 'file', (f) {
          _lastFile = f;
          g.cue(HiveSightGuide.fileSpec(f));
        }),
    ],
  );

  /// Files to pick from: one cues it, + adds it to the queue.
  Widget _list(List<String> files, String kind, void Function(String) pick) => ConstrainedBox(
    constraints: const BoxConstraints(maxHeight: 240),
    child: ListView.builder(
      shrinkWrap: true,
      itemCount: files.length,
      itemBuilder: (context, i) {
        final f = files[i];
        final spec = {'kind': kind, 'file': f};
        return ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          selected: HiveSightGuide.sameSpec(g.cueSpec, spec),
          leading: g.liveKind == kind && g.liveFile == f
              ? const Icon(Icons.sensors, size: 18, color: Kc.red)
              : Icon(_kindIcon(kind), size: 18),
          title: Text(f, overflow: TextOverflow.ellipsis),
          trailing: IconButton(
            tooltip: 'Add to the queue',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.playlist_add, size: 20),
            onPressed: () => g.queueAdd(spec),
          ),
          onTap: () => pick(f),
        );
      },
    ),
  );

  Widget _queue() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Expanded(child: gGroup('Queue')),
          TextButton(onPressed: g.queue.isEmpty ? null : g.queueClear, child: const Text('Clear')),
        ],
      ),
      if (g.queue.isEmpty)
        const Text('Nothing queued. Add files, images or colours with +; Next puts the first one on.', style: gSmall)
      else
        for (var i = 0; i < g.queue.length; i++)
          Row(
            children: [
              Icon(_kindIcon(g.queue[i]['kind'] as String?), size: 18, color: Kc.muted),
              const SizedBox(width: 8),
              Expanded(child: Text(specLabel(g.queue[i]), overflow: TextOverflow.ellipsis)),
              IconButton(
                tooltip: 'Move up',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.arrow_upward, size: 18),
                onPressed: i == 0 ? null : () => g.queueMove(i, i - 1),
              ),
              IconButton(
                tooltip: 'Move down',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.arrow_downward, size: 18),
                onPressed: i == g.queue.length - 1 ? null : () => g.queueMove(i, i + 1),
              ),
              IconButton(
                tooltip: 'Remove',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close, size: 18),
                onPressed: () => g.queueRemove(i),
              ),
            ],
          ),
    ],
  );
}

/// A kind of source on the switcher: on air, picked to go on next, or being looked at.
class _SourceTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final bool onAir, next, looking;
  final VoidCallback onTap;
  const _SourceTile({
    required this.icon,
    required this.title,
    required this.onAir,
    required this.next,
    required this.looking,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Material(
    color: looking ? Kc.raised : Colors.transparent,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
      side: BorderSide(color: onAir ? Kc.red : (next ? Kc.warn : Kc.line), width: onAir || next ? 2 : 1),
    ),
    child: InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Column(
          children: [
            Icon(icon, size: 20, color: looking || onAir ? Kc.text : Kc.muted),
            const SizedBox(height: 2),
            Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            // The same place whatever it says
            SizedBox(
              height: 14,
              child: Text(
                onAir ? 'ON AIR' : (next ? 'NEXT' : ''),
                style: Kc.term(10, color: onAir ? Kc.softRed : Kc.warn),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// What's cued, as the sender sees it, small.
class NextPreview extends StatelessWidget {
  final HiveSightGuide g;
  const NextPreview(this.g, {super.key});

  @override
  Widget build(BuildContext context) {
    final img = g.nextPreview;
    return AspectRatio(
      aspectRatio: 2560 / 720,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Container(
          color: Colors.black,
          alignment: Alignment.center,
          child: img != null
              ? Image.memory(img, gaplessPlayback: true, fit: BoxFit.contain)
              : Text(
                  g.cueSpec?['kind'] == 'camera' && g.liveKind == 'camera'
                      ? 'The camera is on air'
                      : 'Nothing to look at',
                  style: gSmall,
                ),
        ),
      ),
    );
  }
}

String _time(double s) {
  final m = s ~/ 60, r = (s % 60).floor();
  return '$m:${r.toString().padLeft(2, '0')}';
}

/// Skip back, Play or Pause, skip on, and the progress bar you can drag: in
/// the same place whatever's on. With nothing playing they wait (disabled);
/// Play puts the picked film on.
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
              onPressed: go && g.canPlay ? g.playOrPause : null,
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
            g.playTakesCue ? 'Play puts "${g.cueSpec!['file']}" on, by the transition set.' : '',
            style: gSmall,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
