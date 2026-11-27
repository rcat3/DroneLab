import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../comm/comm_controller.dart';
import '../comm/conversations.dart';
import '../comm/hivesight_guide.dart';
import '../comm/hivesight_invite.dart';
import '../comm/hivesight_words.dart';
import 'theme.dart';
import 'widgets.dart';

/// HiveSight's Guide page, on a computer: the sender, the session and its
/// invitations, the Vessels in it, and everything they see and hear, in
/// panels side by side as the window allows. BLACKOUT, mic mute and
/// push-to-talk stay at the top. Experimental: developer options only.
class HiveSightGuidePage extends StatefulWidget {
  final CommController comm;
  const HiveSightGuidePage({super.key, required this.comm});

  @override
  State<HiveSightGuidePage> createState() => _HiveSightGuidePageState();
}

class _HiveSightGuidePageState extends State<HiveSightGuidePage> {
  late final HiveSightGuide g = HiveSightGuide.of(widget.comm);
  StreamSubscription<String>? _notices;
  final _focus = FocusNode();
  bool _ptt = false; // push-to-talk mode: the mic's live only while held

  @override
  void initState() {
    super.initState();
    _notices = g.notices.stream.listen((t) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));
    });
    g.words.load();
    if (g.cameras.isEmpty) g.listDevices();
    if (g.state == SenderState.stopped) g.start();
  }

  @override
  void dispose() {
    _notices?.cancel();
    _focus.dispose();
    super.dispose();
  }

  void _talk(bool on) {
    if (_ptt) g.set('voice.mute', !on);
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e.logicalKey == LogicalKeyboardKey.space && _ptt) {
      if (e is KeyDownEvent) _talk(true);
      if (e is KeyUpEvent) _talk(false);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _invite() async {
    final convs = widget.comm.conversations.all.values.toList()
      ..sort((a, b) => (b.last ?? DateTime(0)).compareTo(a.last ?? DateTime(0)));
    final c = await showDialog<Conversation>(
      context: context,
      builder: (d) => SimpleDialog(
        title: const Text('Invite to your HiveSight session'),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(
              'They get a text with a Join button. Everyone in a channel can join with it.',
              style: TextStyle(color: Kc.muted, fontSize: 13),
            ),
          ),
          if (convs.isEmpty)
            const Padding(padding: EdgeInsets.all(24), child: Text('No conversations yet'))
          else
            for (final c in convs)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(d, c),
                child: Row(
                  children: [
                    Icon(
                      c.kind == ConversationKind.person ? Icons.person_outline : Icons.groups_outlined,
                      color: Kc.muted,
                      size: 20,
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: Text(c.title)),
                  ],
                ),
              ),
        ],
      ),
    );
    if (c == null || !mounted) return;
    final ok = await g.invite(c);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok ? 'Invitation sent to ${c.audience}' : "Couldn't send it: ${c.title} can't be reached just now",
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: g,
    builder: (context, _) => Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('HiveSight Guide'),
          bottom: PreferredSize(preferredSize: const Size.fromHeight(64), child: _topBar()),
        ),
        // The preview stays put, beside the panels in a wide window and
        // above them in a narrow one, so whatever's changed can be seen
        body: LayoutBuilder(
          builder: (context, box) {
            final live = g.linked;
            final wide = box.maxWidth >= 900;
            final side = wide ? (box.maxWidth * 0.38).clamp(360.0, 640.0) : 0.0;
            final rest = box.maxWidth - side;
            final cols = ((rest - 32) / 360).floor().clamp(1, 4);
            final w = (rest - 32 - 12 * (cols - 1)) / cols;
            final panels = <Widget>[
              if (!wide) ...[_SessionPanel(g, onInvite: _invite), _VesselsPanel(g)],
              _SourcePanel(g, enabled: live),
              _VoicePanel(g, enabled: live),
              _MixPanel(g, enabled: live),
              _BeatsPanel(g, enabled: live),
              _VisionPanel(g, enabled: live),
              _SpiralPanel(g, enabled: live),
              _WordsPanel(g, enabled: live),
              _LightPulsePanel(g, enabled: live),
              _ScenesPanel(g, enabled: live),
              _CalibratePanel(g, enabled: live),
              _SenderPanel(g),
            ];
            final scroll = SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              child: Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [for (final p in panels) SizedBox(width: w, child: p)],
              ),
            );
            if (!wide) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                    decoration: const BoxDecoration(
                      border: Border(bottom: BorderSide(color: Kc.line)),
                    ),
                    child: _PreviewPanel(g, enabled: live, maxHeight: box.maxHeight * 0.3),
                  ),
                  Expanded(child: scroll),
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: side,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 0, 0),
                        child: _PreviewPanel(g, enabled: live, maxHeight: box.maxHeight * 0.45),
                      ),
                      Expanded(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(16, 12, 0, 24),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _SessionPanel(g, onInvite: _invite),
                              const SizedBox(height: 12),
                              _VesselsPanel(g),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(child: scroll),
              ],
            );
          },
        ),
      ),
    ),
  );

  Widget _topBar() {
    final live = g.linked;
    final muted = g.flag('voice.mute');
    // In a narrow window, the buttons' words go: their icons stay, with tooltips
    final compact = MediaQuery.sizeOf(context).width < 820;
    const pad = EdgeInsets.symmetric(horizontal: 12);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: Row(
        children: [
          _status(compact),
          const Spacer(),
          Tooltip(
            message: 'BLACKOUT: fade to black and stop the light pulse',
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: g.blackedOut ? Kc.red : Kc.raised,
                foregroundColor: Kc.text,
                minimumSize: Size(compact ? 0 : 150, 48),
                padding: pad,
              ),
              onPressed: live ? g.blackout : null,
              icon: Icon(g.blackedOut ? Icons.visibility_off : Icons.visibility),
              label: Text(g.blackedOut && !compact ? 'BLACKED OUT' : 'BLACKOUT'),
            ),
          ),
          const SizedBox(width: 8),
          Tooltip(
            message: muted ? 'Mic muted' : 'Mic live',
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                minimumSize: Size(compact ? 48 : 130, 48),
                padding: pad,
                foregroundColor: muted ? Kc.softRed : Kc.green,
              ),
              onPressed: live && !_ptt ? () => g.set('voice.mute', !muted) : null,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(muted ? Icons.mic_off : Icons.mic, size: 20),
                  if (!compact) ...[const SizedBox(width: 8), Text(muted ? 'MIC MUTED' : 'MIC LIVE')],
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          _MicMeter(g, width: compact ? 40 : 80),
          const SizedBox(width: 8),
          // Push-to-talk: switched on, the mic's muted but while the button or
          // Space is held
          GestureDetector(
            onTapDown: live && _ptt ? (_) => _talk(true) : null,
            onTapUp: live && _ptt ? (_) => _talk(false) : null,
            onTapCancel: live && _ptt ? () => _talk(false) : null,
            child: Tooltip(
              message: 'Push-to-talk: hold this or Space',
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(minimumSize: Size(compact ? 48 : 130, 48), padding: pad),
                onPressed: live && _ptt ? () {} : null,
                child: compact
                    ? const Icon(Icons.record_voice_over_outlined, size: 20)
                    : Text(_ptt ? 'HOLD TO TALK' : 'PUSH-TO-TALK OFF'),
              ),
            ),
          ),
          Switch(
            value: _ptt,
            onChanged: live
                ? (on) {
                    setState(() => _ptt = on);
                    g.set('voice.mute', on);
                    _focus.requestFocus();
                  }
                : null,
          ),
        ],
      ),
    );
  }

  Widget _status(bool compact) {
    final (icon, color, text) = switch (g.state) {
      SenderState.running when g.linked => (Icons.check_circle_outline, Kc.green, 'Sender running'),
      SenderState.running || SenderState.starting => (Icons.sync, Kc.muted, 'Starting the sender…'),
      SenderState.failed => (Icons.error_outline, Kc.softRed, 'Sender stopped'),
      SenderState.stopped => (Icons.stop_circle_outlined, Kc.muted, 'Sender off'),
    };
    return Tooltip(
      message: text,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 18),
          if (!compact) ...[const SizedBox(width: 6), Text(text, style: TextStyle(color: color))],
        ],
      ),
    );
  }
}

// ----- Panels -----

class _Card extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _Card(this.title, this.children);

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SectionHeader(title),
      Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        decoration: BoxDecoration(
          color: Kc.panel,
          border: Border.all(color: Kc.line),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
      ),
    ],
  );
}

const _small = TextStyle(color: Kc.muted, fontSize: 13);

Widget _group(String text) => Padding(
  padding: const EdgeInsets.only(top: 10, bottom: 2),
  child: Text(text.toUpperCase(), style: Kc.term(13, color: Kc.muted)),
);

/// A setting's slider: its name, value and unit; sent while it's held.
class _Slide extends StatelessWidget {
  final HiveSightGuide g;
  final String path, label, unit;
  final double min, max, step;
  final bool enabled;
  const _Slide(this.g, this.path, this.label, this.min, this.max, this.step, {this.unit = '', required this.enabled});

  @override
  Widget build(BuildContext context) {
    final v = g.number(path, min).toDouble().clamp(min, max);
    final whole = step >= 1;
    final digits = whole
        ? 0
        : step >= 0.1
        ? 1
        : step >= 0.01
        ? 2
        : 3;
    return Row(
      children: [
        SizedBox(
          width: 112,
          child: Text(label, style: TextStyle(color: enabled ? Kc.text : Kc.dim, fontSize: 14)),
        ),
        Expanded(
          child: Slider(
            value: v,
            min: min,
            max: max,
            divisions: ((max - min) / step).round().clamp(1, 2000),
            onChanged: enabled ? (x) => g.set(path, whole ? x.round() : x) : null,
          ),
        ),
        SizedBox(
          width: 78,
          child: Text(
            '${v.toStringAsFixed(digits)}${unit.isEmpty ? '' : ' $unit'}',
            textAlign: TextAlign.right,
            style: Kc.term(14, color: enabled ? Kc.text : Kc.dim),
          ),
        ),
      ],
    );
  }
}

class _Toggle extends StatelessWidget {
  final HiveSightGuide g;
  final String path, label;
  final bool enabled;
  const _Toggle(this.g, this.path, this.label, {required this.enabled});

  @override
  Widget build(BuildContext context) => SwitchListTile(
    contentPadding: EdgeInsets.zero,
    dense: true,
    title: Text(label, style: const TextStyle(fontSize: 14)),
    value: g.flag(path),
    onChanged: enabled ? (on) => g.set(path, on) : null,
  );
}

/// One of a few: chips, wrapping as they need.
class _Choice extends StatelessWidget {
  final HiveSightGuide g;
  final String path, label;
  final List<(String, String)> options; // value, label
  final bool enabled;
  const _Choice(this.g, this.path, this.label, this.options, {required this.enabled});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 112,
          child: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(label, style: TextStyle(color: enabled ? Kc.text : Kc.dim, fontSize: 14)),
          ),
        ),
        Expanded(
          child: Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final (v, l) in options)
                ChoiceChip(
                  showCheckmark: false,
                  label: Text(l),
                  selected: g.text(path) == v,
                  onSelected: enabled ? (_) => g.set(path, v) : null,
                ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _SessionPanel extends StatelessWidget {
  final HiveSightGuide g;
  final VoidCallback onInvite;
  const _SessionPanel(this.g, {required this.onInvite});

  @override
  Widget build(BuildContext context) {
    final s = g.session;
    final running = g.state == SenderState.running && g.linked;
    return _Card('Session', [
      if (s == null) ...[
        const Text(
          'No session. Start one, then invite your Vessels from here or from a conversation in Text. '
          'Your camera and mic stay off until then.',
          style: _small,
        ),
        const SizedBox(height: 10),
        FilledButton.icon(
          onPressed: running ? g.startSession : null,
          icon: const Icon(Icons.play_arrow),
          label: const Text('Start a session'),
        ),
      ] else ...[
        Text('Open until ${HiveSightInvite.clock(s.expires)}', style: const TextStyle(fontWeight: FontWeight.w600)),
        Text(
          g.addrs.isEmpty
              ? "This computer has no network address for Vessels to reach"
              : 'Vessels reach you at ${g.addrs.join(', ')}, port ${HiveSightGuide.vesselPort}, over TLS',
          style: _small,
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: g.canInvite ? onInvite : null,
                icon: const Icon(Icons.send),
                label: const Text('Invite…'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () async {
                  final yes = await showDialog<bool>(
                    context: context,
                    builder: (d) => AlertDialog(
                      title: const Text('End the session?'),
                      content: const Text(
                        'Every Vessel is disconnected, the invitations stop working, and your camera and mic '
                        'are let go.',
                      ),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
                        FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('End it')),
                      ],
                    ),
                  );
                  if (yes == true) g.endSession();
                },
                icon: const Icon(Icons.stop),
                label: const Text('End'),
              ),
            ),
          ],
        ),
      ],
    ]);
  }
}

class _VesselsPanel extends StatelessWidget {
  final HiveSightGuide g;
  const _VesselsPanel(this.g);

  @override
  Widget build(BuildContext context) => _Card('Vessels', [
    if (g.vessels.isEmpty)
      Text(g.session == null ? 'Nobody: no session' : 'Nobody has joined yet', style: _small)
    else
      for (final v in g.vessels)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Icon(
                v.verified ? Icons.verified_user_outlined : Icons.help_outline,
                color: v.verified ? Kc.green : Kc.warn,
                size: 20,
                semanticLabel: v.verified ? 'Identity checked' : 'Identity not checked',
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(g.nameOf(v), style: const TextStyle(fontWeight: FontWeight.w600)),
                    Text(
                      [
                        if (!v.verified) 'not signed',
                        v.lightPulse ? 'light pulse allowed' : 'no light pulse',
                        if (v.stats['fps'] != null) '${v.stats['fps']} fps',
                        if (v.stats['kbps'] != null) '${v.stats['kbps']} kb/s',
                        if (v.stats['loss'] != null) 'loss ${v.stats['loss']}',
                        if (v.stats['rtt_ms'] != null) 'rtt ${v.stats['rtt_ms']} ms',
                        if (v.stats['battery'] != null) 'battery ${v.stats['battery']}%',
                      ].join(' · '),
                      style: _small,
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Remove from the session',
                icon: const Icon(Icons.person_remove_outlined, color: Kc.muted),
                onPressed: () async {
                  final name = g.nameOf(v);
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (d) => AlertDialog(
                      title: Text('Remove $name?'),
                      content: const Text('They leave the session and can only come back with a new invitation.'),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
                        FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Remove')),
                      ],
                    ),
                  );
                  if (ok == true) g.remove(v);
                },
              ),
            ],
          ),
        ),
  ]);
}

/// What the first Vessel sees (without the lens correction), kept in view:
/// [maxHeight] at most, with its switch and frame rate on one line.
class _PreviewPanel extends StatelessWidget {
  final HiveSightGuide g;
  final bool enabled;
  final double maxHeight;
  const _PreviewPanel(this.g, {required this.enabled, required this.maxHeight});

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
                    : Text(on ? 'Waiting for a Vessel…' : 'Preview off', style: _small),
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

/// Which camera, in which mode, as stereo or mono: changed at once, and
/// what the Vessels see from then on (a file playing stops).
class _CameraPicker extends StatelessWidget {
  final HiveSightGuide g;
  final bool enabled;
  const _CameraPicker(this.g, {required this.enabled});

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
    Widget row(String label, Widget child) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(width: 80, child: Text(label, style: const TextStyle(fontSize: 14))),
          Expanded(child: child),
        ],
      ),
    );
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

class _SourcePanel extends StatelessWidget {
  final HiveSightGuide g;
  final bool enabled;
  const _SourcePanel(this.g, {required this.enabled});

  static String _time(double s) {
    final m = s ~/ 60, r = (s % 60).floor();
    return '$m:${r.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final file = g.text('media.source') == 'file';
    final paused = g.flag('media.paused');
    return _Card('Source', [
      Row(
        children: [
          Expanded(
            child: Text(
              file ? g.text('media.file') : 'Camera: ${g.text('stream.source')}',
              style: const TextStyle(fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (file) ...[
            IconButton(
              tooltip: paused ? 'Play' : 'Pause',
              icon: Icon(paused ? Icons.play_arrow : Icons.pause),
              onPressed: enabled ? () => g.set('media.paused', !paused) : null,
            ),
            OutlinedButton(onPressed: enabled ? g.useCamera : null, child: const Text('Use camera')),
          ],
        ],
      ),
      _CameraPicker(g, enabled: enabled),
      if (file && g.mediaDuration > 0)
        Row(
          children: [
            Expanded(
              child: Slider(
                value: g.mediaPosition.clamp(0, g.mediaDuration),
                max: g.mediaDuration,
                onChanged: enabled ? (_) {} : null,
                onChangeEnd: enabled ? g.seek : null,
              ),
            ),
            Text('${_time(g.mediaPosition)} / ${_time(g.mediaDuration)}', style: Kc.term(13, color: Kc.muted)),
          ],
        ),
      _group('Video files in ${g.mediaDir.isEmpty ? 'the media folder' : g.mediaDir}'),
      if (g.mediaFiles.isEmpty)
        const Text('None found. Set the folder under Sender.', style: _small)
      else
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 180),
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final f in g.mediaFiles)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  selected: file && g.text('media.file') == f,
                  leading: const Icon(Icons.movie_outlined, size: 18),
                  title: Text(f, overflow: TextOverflow.ellipsis),
                  onTap: enabled ? () => g.playFile(f) : null,
                ),
            ],
          ),
        ),
      _group('Playback'),
      _Choice(g, 'media.at_end', 'At the end', const [
        ('loop', 'Loop'),
        ('camera', 'Camera'),
        ('hold', 'Hold'),
      ], enabled: enabled),
      _Slide(g, 'media.av_offset_ms', 'A/V offset', -500, 1000, 10, unit: 'ms', enabled: enabled),
      _Slide(g, 'mix.media_vol', 'Film sound', 0, 1.5, 0.01, enabled: enabled),
      _group('Stereo layout'),
      _Choice(g, 'stream.layout', 'Layout', const [
        ('mono', 'Mono'),
        ('sbs', 'Side by side'),
        ('hsbs', 'Half SBS'),
        ('tb', 'Top/bottom'),
        ('htb', 'Half T/B'),
      ], enabled: enabled),
    ]);
  }
}

class _VoicePanel extends StatelessWidget {
  final HiveSightGuide g;
  final bool enabled;
  const _VoicePanel(this.g, {required this.enabled});

  @override
  Widget build(BuildContext context) {
    final mode = g.text('voice.fx_mode');
    return _Card('Voice', [
      Row(
        children: [
          const SizedBox(width: 112, child: Text('Preset', style: TextStyle(fontSize: 14))),
          Expanded(
            child: DropdownButton<String>(
              isExpanded: true,
              value: g.presets.contains(g.text('voice.preset')) ? g.text('voice.preset') : null,
              items: [for (final p in g.presets) DropdownMenuItem(value: p, child: Text(p))],
              onChanged: enabled ? (p) => p == null ? null : g.set('voice.preset', p) : null,
            ),
          ),
        ],
      ),
      _Slide(g, 'voice.gain_db', 'Gain', -12, 36, 0.5, unit: 'dB', enabled: enabled),
      _Slide(g, 'voice.gate_db', 'Gate', -90, -20, 1, unit: 'dB', enabled: enabled),
      _Slide(g, 'voice.comp_ratio', 'Compression', 1, 10, 0.1, unit: ':1', enabled: enabled),
      _Toggle(g, 'voice.denoise', 'Noise suppression', enabled: enabled),
      _group('Effect'),
      _Choice(g, 'voice.fx_mode', 'Mode', const [
        ('off', 'Off'),
        ('shift', 'Shift'),
        ('robot', 'Robot'),
      ], enabled: enabled),
      if (mode == 'shift') ...[
        _Slide(g, 'voice.shift_pitch', 'Pitch', 0.5, 2.5, 0.01, unit: '×', enabled: enabled),
        _Slide(g, 'voice.shift_formant', 'Formant', 0.7, 1.5, 0.01, unit: '×', enabled: enabled),
      ],
      if (mode == 'robot') ...[
        _Slide(g, 'voice.robot_hz', 'Robot pitch', 60, 400, 1, unit: 'Hz', enabled: enabled),
        _Slide(g, 'voice.robot_noise', 'Breath', 0, 0.5, 0.01, enabled: enabled),
      ],
      _group('Tone and space'),
      _Slide(g, 'voice.pitch', 'Simple pitch', 0.5, 2, 0.01, unit: '×', enabled: enabled),
      _Slide(g, 'voice.highpass_hz', 'High-pass', 20, 1500, 5, unit: 'Hz', enabled: enabled),
      _Slide(g, 'voice.lowpass_hz', 'Low-pass', 500, 20000, 50, unit: 'Hz', enabled: enabled),
      _Slide(g, 'voice.echo_ms', 'Echo time', 1, 1500, 1, unit: 'ms', enabled: enabled),
      _Slide(g, 'voice.echo_feedback', 'Echo feedback', 0, 0.95, 0.01, enabled: enabled),
      _Slide(g, 'voice.echo_mix', 'Echo mix', 0, 1, 0.01, enabled: enabled),
      _Slide(g, 'voice.reverb_room', 'Reverb room', 0, 1, 0.01, enabled: enabled),
      _Slide(g, 'voice.reverb_damp', 'Reverb damping', 0, 1, 0.01, enabled: enabled),
      _Slide(g, 'voice.reverb_mix', 'Reverb mix', 0, 1, 0.01, enabled: enabled),
    ]);
  }
}

class _MixPanel extends StatelessWidget {
  final HiveSightGuide g;
  final bool enabled;
  const _MixPanel(this.g, {required this.enabled});

  @override
  Widget build(BuildContext context) => _Card('Mix', [
    _Slide(g, 'mix.master', 'Master', 0, 1, 0.01, enabled: enabled),
    _Slide(g, 'mix.voice_vol', 'Voice', 0, 1.5, 0.01, enabled: enabled),
    _Slide(g, 'mix.voice_pan', 'Voice pan', -1, 1, 0.01, enabled: enabled),
    _Slide(g, 'mix.autopan_hz', 'Auto-pan', 0, 2, 0.01, unit: 'Hz', enabled: enabled),
    _Slide(g, 'mix.beats_vol', 'Beats', 0, 1, 0.01, enabled: enabled),
    _Slide(g, 'mix.noise_vol', 'Pink noise', 0, 1, 0.01, enabled: enabled),
    _Slide(g, 'mix.media_vol', 'Film sound', 0, 1.5, 0.01, enabled: enabled),
    _Slide(g, 'mix.jitter_ms', 'Voice buffer', 10, 200, 5, unit: 'ms', enabled: enabled),
  ]);
}

class _BeatsPanel extends StatelessWidget {
  final HiveSightGuide g;
  final bool enabled;
  const _BeatsPanel(this.g, {required this.enabled});

  @override
  Widget build(BuildContext context) => _Card('Beats', [
    _Toggle(g, 'beats.on', 'Binaural beats', enabled: enabled),
    _Slide(g, 'beats.carrier_hz', 'Carrier', 60, 600, 1, unit: 'Hz', enabled: enabled),
    _Slide(g, 'beats.beat_hz', 'Beat', 0.5, 40, 0.1, unit: 'Hz', enabled: enabled),
    _Slide(g, 'beats.glide_s', 'Glide', 0, 30, 0.5, unit: 's', enabled: enabled),
  ]);
}

class _VisionPanel extends StatelessWidget {
  final HiveSightGuide g;
  final bool enabled;
  const _VisionPanel(this.g, {required this.enabled});

  @override
  Widget build(BuildContext context) => _Card('Vision', [
    _group('Screen'),
    _Slide(g, 'fx.screen', 'Screen brightness', 0, 1, 0.01, enabled: enabled),
    const Text('0 leaves the phone\'s own level, held as it was when the Vessel joined.', style: _small),
    _group('Fade and time'),
    _Slide(g, 'fx.fade', 'Fade', 0, 1, 0.01, enabled: enabled),
    _Slide(g, 'fx.fade_s', 'Fade time', 0, 10, 0.1, unit: 's', enabled: enabled),
    _Slide(g, 'fx.delay_ms', 'Video delay', 0, 5000, 10, unit: 'ms', enabled: enabled),
    _group('Colour'),
    _Slide(g, 'fx.brightness', 'Picture lift', -0.5, 0.5, 0.01, enabled: enabled),
    _Slide(g, 'fx.contrast', 'Contrast', 0, 2, 0.01, enabled: enabled),
    _Slide(g, 'fx.saturation', 'Saturation', 0, 2, 0.01, enabled: enabled),
    _Slide(g, 'fx.tint_r', 'Tint red', 0, 1.5, 0.01, enabled: enabled),
    _Slide(g, 'fx.tint_g', 'Tint green', 0, 1.5, 0.01, enabled: enabled),
    _Slide(g, 'fx.tint_b', 'Tint blue', 0, 1.5, 0.01, enabled: enabled),
    _Slide(g, 'fx.vignette', 'Vignette', 0, 1, 0.01, enabled: enabled),
    _Toggle(g, 'fx.invert', 'Invert', enabled: enabled),
    _group('Picture'),
    _Toggle(g, 'fx.swap', 'Swap eyes', enabled: enabled),
    _Toggle(g, 'fx.mirror', 'Mirror', enabled: enabled),
    _Toggle(g, 'fx.rotate180', 'Rotate 180°', enabled: enabled),
    _Toggle(g, 'fx.mono', 'Left eye only', enabled: enabled),
    _group('Video'),
    _Slide(g, 'video.bitrate_kbps', 'Bitrate', 1000, 30000, 500, unit: 'kb/s', enabled: enabled),
  ]);
}

class _SpiralPanel extends StatelessWidget {
  final HiveSightGuide g;
  final bool enabled;
  const _SpiralPanel(this.g, {required this.enabled});

  @override
  Widget build(BuildContext context) => _Card('Spiral', [
    _Slide(g, 'spiral.amount', 'Amount', 0, 1, 0.01, enabled: enabled),
    _Slide(g, 'spiral.speed', 'Spin', -2, 2, 0.01, unit: 'rev/s', enabled: enabled),
    _Slide(g, 'spiral.zoom_hz', 'Zoom flow', -2, 2, 0.01, unit: 'Hz', enabled: enabled),
    _Slide(g, 'spiral.arms', 'Arms', 1, 12, 1, enabled: enabled),
    _Slide(g, 'spiral.twist', 'Twist', -20, 20, 0.1, enabled: enabled),
    _Slide(g, 'spiral.sharp', 'Sharpness', 0, 1, 0.01, enabled: enabled),
    _Slide(g, 'spiral.hue', 'Hue', 0, 1, 0.01, enabled: enabled),
    _Slide(g, 'spiral.sat', 'Colour', 0, 1, 0.01, enabled: enabled),
  ]);
}

class _LightPulsePanel extends StatelessWidget {
  final HiveSightGuide g;
  final bool enabled;
  const _LightPulsePanel(this.g, {required this.enabled});

  @override
  Widget build(BuildContext context) {
    final allowing = g.vessels.where((v) => v.lightPulse).length;
    return _Card('Light pulse', [
      Text(
        'Flashing light, at up to 30 Hz, ramped in over 3 s. Only Vessels who allow you the light pulse see it'
        '${g.vessels.isEmpty ? '' : ' ($allowing of ${g.vessels.length} now)'}. BLACKOUT stops it.',
        style: _small,
      ),
      _Toggle(g, 'photic.on', 'Light pulse on', enabled: enabled),
      _Toggle(g, 'photic.sync', 'Follow the beat', enabled: enabled),
      _Toggle(g, 'photic.alternate', 'Alternate left and right', enabled: enabled),
      _Slide(g, 'photic.hz', 'Rate', 0.5, 30, 0.1, unit: 'Hz', enabled: enabled && !g.flag('photic.sync')),
      _Slide(g, 'photic.depth', 'Depth', 0, 1, 0.01, enabled: enabled),
      _Slide(g, 'photic.amount', 'Colour field', 0, 1, 0.01, enabled: enabled),
      _Slide(g, 'photic.hue', 'Hue', 0, 1, 0.01, enabled: enabled),
      _Slide(g, 'photic.sat', 'Saturation', 0, 1, 0.01, enabled: enabled),
      _Slide(g, 'photic.hue_cycle_s', 'Hue cycle', 0, 120, 1, unit: 's', enabled: enabled),
    ]);
  }
}

class _ScenesPanel extends StatefulWidget {
  final HiveSightGuide g;
  final bool enabled;
  const _ScenesPanel(this.g, {required this.enabled});

  @override
  State<_ScenesPanel> createState() => _ScenesPanelState();
}

class _ScenesPanelState extends State<_ScenesPanel> {
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final g = widget.g, enabled = widget.enabled;
    return _Card('Scenes', [
      const Text('Voice, mix, beats, vision, spiral and light pulse together, kept on this computer.', style: _small),
      if (g.scenes.isNotEmpty) ...[
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final s in g.scenes)
              InputChip(
                label: Text(s),
                onPressed: enabled ? () => g.loadScene(s) : null,
                onDeleted: enabled ? () => g.deleteScene(s) : null,
                deleteButtonTooltipMessage: 'Delete',
              ),
          ],
        ),
      ],
      const SizedBox(height: 6),
      Row(
        children: [
          Expanded(
            child: TextField(
              controller: _name,
              enabled: enabled,
              decoration: const InputDecoration(hintText: 'Name for this scene', isDense: true),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: enabled
                ? () {
                    final n = _name.text.trim();
                    if (n.isEmpty) return;
                    g.saveScene(n);
                    _name.clear();
                  }
                : null,
            child: const Text('Save'),
          ),
        ],
      ),
    ]);
  }
}

class _CalibratePanel extends StatelessWidget {
  final HiveSightGuide g;
  final bool enabled;
  const _CalibratePanel(this.g, {required this.enabled});

  @override
  Widget build(BuildContext context) => _Card('Calibrate', [
    const Text(
      "The headset's lenses, saved on the Vessel's phone. With several Vessels, every phone takes these.",
      style: _small,
    ),
    _Slide(g, 'view.lens_sep_mm', 'Lens spacing', 50, 75, 0.5, unit: 'mm', enabled: enabled),
    _Slide(g, 'view.lens_y_mm', 'Lens height', -20, 20, 0.5, unit: 'mm', enabled: enabled),
    _Slide(g, 'view.k1', 'Distortion k1', -0.3, 1.5, 0.01, enabled: enabled),
    _Slide(g, 'view.k2', 'Distortion k2', -0.3, 1.5, 0.01, enabled: enabled),
    _Slide(g, 'view.zoom', 'Zoom', 0.4, 2.5, 0.01, unit: '×', enabled: enabled),
    _Slide(g, 'view.convergence', 'Convergence', -0.15, 0.15, 0.002, enabled: enabled),
    _Slide(g, 'view.vertical', 'Vertical', -0.1, 0.1, 0.001, enabled: enabled),
    _Toggle(g, 'view.grid', 'Grid', enabled: enabled),
    _Toggle(g, 'view.stats', 'Stats on the Vessel', enabled: enabled),
  ]);
}

/// The sender's camera, microphone and media folder; changing them
/// restarts it, and the session carries on.
class _SenderPanel extends StatefulWidget {
  final HiveSightGuide g;
  const _SenderPanel(this.g);

  @override
  State<_SenderPanel> createState() => _SenderPanelState();
}

class _SenderPanelState extends State<_SenderPanel> {
  // The voice and media folder, as being changed (the camera's in Source)
  late bool _audio = widget.g.options.audio;
  late String _mic = widget.g.options.mic;
  late final _media = TextEditingController(text: widget.g.options.mediaDir);

  @override
  void dispose() {
    _media.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final g = widget.g;
    final o = g.options;
    final changed = _audio != o.audio || _mic != o.mic || _media.text.trim() != o.mediaDir;
    Widget row(String label, Widget child) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(width: 112, child: Text(label, style: const TextStyle(fontSize: 14))),
          Expanded(child: child),
        ],
      ),
    );
    return _Card('Sender', [
      if (g.state == SenderState.failed && g.problem != null) ...[
        Text(g.problem!, style: const TextStyle(color: Kc.softRed)),
        if (g.missing.isNotEmpty) ...[
          const SizedBox(height: 4),
          const Text('Install them, then start it again:', style: _small),
          SelectableText('sudo apt install ${g.missing.join(' ')}', style: Kc.term(13)),
        ],
        const SizedBox(height: 8),
      ],
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        title: const Text('Send my voice', style: TextStyle(fontSize: 14)),
        value: _audio,
        onChanged: (on) => setState(() => _audio = on),
      ),
      if (_audio)
        row(
          'Microphone',
          DropdownButton<String>(
            isExpanded: true,
            value: _mic.isEmpty || g.mics.any((m) => m.name == _mic) ? _mic : null,
            items: [
              const DropdownMenuItem(value: '', child: Text('Default')),
              for (final m in g.mics)
                DropdownMenuItem(
                  value: m.name,
                  child: Text(m.label, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (m) => setState(() => _mic = m ?? ''),
          ),
        ),
      row(
        'Media folder',
        TextField(
          controller: _media,
          decoration: const InputDecoration(hintText: '~/Videos', isDense: true),
          onChanged: (_) => setState(() {}),
        ),
      ),
      const SizedBox(height: 10),
      Row(
        children: [
          Expanded(
            child: FilledButton(
              onPressed: changed
                  ? () => g.setOptions(o.copyWith(audio: _audio, mic: _mic, mediaDir: _media.text.trim()))
                  : null,
              child: const Text('Apply'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: g.state == SenderState.running || g.state == SenderState.starting
                ? OutlinedButton(onPressed: g.stop, child: const Text('Stop sender'))
                : OutlinedButton(onPressed: g.start, child: const Text('Start sender')),
          ),
        ],
      ),
      const SizedBox(height: 4),
      const Text(
        'The camera is chosen under Source. A new microphone or folder applies at once; turning your voice on or '
        'off restarts the sender, and a session carries on.',
        style: _small,
      ),
      if (g.output.isNotEmpty)
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text("The sender's output", style: TextStyle(fontSize: 14)),
          children: [
            Container(
              height: 180,
              color: Kc.bg,
              padding: const EdgeInsets.all(6),
              child: SingleChildScrollView(
                reverse: true,
                child: SelectableText(g.output.join('\n'), style: Kc.term(12, color: Kc.muted)),
              ),
            ),
          ],
        ),
    ]);
  }
}

/// The Guide's mic level, after the voice chain, and the gate's light.
class _MicMeter extends StatelessWidget {
  final HiveSightGuide g;
  final double width;
  const _MicMeter(this.g, {this.width = 80});

  @override
  Widget build(BuildContext context) {
    final level = ((g.outDb + 60) / 60).clamp(0.0, 1.0);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.circle,
          size: 10,
          color: g.gateOpen ? Kc.green : Kc.off,
          semanticLabel: g.gateOpen ? 'Gate open' : 'Gate closed',
        ),
        const SizedBox(width: 6),
        SizedBox(
          width: width,
          height: 10,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(5),
            child: LinearProgressIndicator(
              value: level,
              backgroundColor: Kc.off,
              color: level > 0.9 ? Kc.softRed : Kc.green,
            ),
          ),
        ),
      ],
    );
  }
}

// ----- Words -----

/// A colour, picked by its hue, saturation and brightness, a hex code, or
/// its red, green and blue values. Returns RGB, or null if cancelled.
Future<int?> _pickColor(BuildContext context, int rgb) => showDialog<int>(
  context: context,
  builder: (d) {
    var hsv = HSVColor.fromColor(Color(0xFF000000 | rgb));
    final hex = TextEditingController();
    final r = TextEditingController(), g = TextEditingController(), b = TextEditingController();
    void fill() {
      final c = hsv.toColor();
      final v = c.toARGB32() & 0xFFFFFF;
      hex.text = v.toRadixString(16).padLeft(6, '0').toUpperCase();
      r.text = '${(v >> 16) & 255}';
      g.text = '${(v >> 8) & 255}';
      b.text = '${v & 255}';
    }

    fill();
    return StatefulBuilder(
      builder: (d, setState) {
        void setRgb(int v) => setState(() {
          hsv = HSVColor.fromColor(Color(0xFF000000 | (v & 0xFFFFFF)));
          fill();
        });
        int channel(TextEditingController c) => (int.tryParse(c.text) ?? 0).clamp(0, 255);
        Widget num3(String label, TextEditingController c) => Expanded(
          child: Padding(
            padding: const EdgeInsets.only(right: 6),
            child: TextField(
              controller: c,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: label, isDense: true),
              onChanged: (_) => setRgb((channel(r) << 16) | (channel(g) << 8) | channel(b)),
            ),
          ),
        );
        return AlertDialog(
          title: const Text('Colour'),
          content: SizedBox(
            width: 340,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  height: 36,
                  decoration: BoxDecoration(
                    color: hsv.toColor(),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Kc.line),
                  ),
                ),
                for (final (label, value, max, set) in <(String, double, double, void Function(double))>[
                  ('Hue', hsv.hue, 360, (v) => hsv = hsv.withHue(v)),
                  ('Saturation', hsv.saturation, 1, (v) => hsv = hsv.withSaturation(v)),
                  ('Brightness', hsv.value, 1, (v) => hsv = hsv.withValue(v)),
                ])
                  Row(
                    children: [
                      SizedBox(width: 84, child: Text(label)),
                      Expanded(
                        child: Slider(
                          value: value.clamp(0, max),
                          max: max,
                          onChanged: (v) => setState(() {
                            set(v);
                            fill();
                          }),
                        ),
                      ),
                    ],
                  ),
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: TextField(
                          controller: hex,
                          decoration: const InputDecoration(labelText: 'Hex', prefixText: '#', isDense: true),
                          onChanged: (t) {
                            final v = int.tryParse(t.replaceAll('#', '').trim(), radix: 16);
                            if (v != null && t.replaceAll('#', '').trim().length == 6) {
                              hsv = HSVColor.fromColor(Color(0xFF000000 | v));
                              r.text = '${(v >> 16) & 255}';
                              g.text = '${(v >> 8) & 255}';
                              b.text = '${v & 255}';
                              setState(() {});
                            }
                          },
                        ),
                      ),
                    ),
                    num3('R', r),
                    num3('G', g),
                    num3('B', b),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
            FilledButton(
              onPressed: () => Navigator.pop(d, hsv.toColor().toARGB32() & 0xFFFFFF),
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
  },
);

class _WordsPanel extends StatefulWidget {
  final HiveSightGuide g;
  final bool enabled;
  const _WordsPanel(this.g, {required this.enabled});

  @override
  State<_WordsPanel> createState() => _WordsPanelState();
}

class _WordsPanelState extends State<_WordsPanel> {
  final _text = TextEditingController();
  WordsPhrase? _shownIn; // whose text the field holds

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<String?> _ask(String title, String initial) => showDialog<String>(
    context: context,
    builder: (d) {
      final c = TextEditingController(text: initial);
      return AlertDialog(
        title: Text(title),
        content: TextField(controller: c, autofocus: true, onSubmitted: (v) => Navigator.pop(d, v)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(d, c.text), child: const Text('OK')),
        ],
      );
    },
  );

  /// A slider on the edited phrase's own value.
  Widget _num(
    GuideWords w,
    String label,
    double min,
    double max,
    double step,
    double Function(WordsLook) get,
    void Function(WordsLook, double) set, {
    String unit = '',
    bool enabled = true,
  }) {
    final l = w.edited.look;
    final v = get(l).clamp(min, max);
    final digits = step >= 1
        ? 0
        : step >= 0.1
        ? 1
        : 2;
    return Row(
      children: [
        SizedBox(width: 112, child: Text(label, style: const TextStyle(fontSize: 14))),
        Expanded(
          child: Slider(
            value: v,
            min: min,
            max: max,
            divisions: ((max - min) / step).round().clamp(1, 2000),
            onChanged: enabled
                ? (x) {
                    set(l, x);
                    w.editedChanged();
                  }
                : null,
          ),
        ),
        SizedBox(
          width: 78,
          child: Text(
            '${v.toStringAsFixed(digits)}${unit.isEmpty ? '' : ' $unit'}',
            textAlign: TextAlign.right,
            style: Kc.term(14),
          ),
        ),
      ],
    );
  }

  Widget _chips(String label, List<(String, String)> options, String value, void Function(String) pick) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 112,
          child: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(label, style: const TextStyle(fontSize: 14)),
          ),
        ),
        Expanded(
          child: Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final (v, l) in options)
                ChoiceChip(showCheckmark: false, label: Text(l), selected: value == v, onSelected: (_) => pick(v)),
            ],
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final g = widget.g, enabled = widget.enabled;
    final w = g.words;
    return ListenableBuilder(
      listenable: w,
      builder: (context, _) {
        final l = w.list;
        final phrases = l?.phrases ?? const <WordsPhrase>[];
        final p = w.edited;
        final look = p.look;
        // The field follows whichever phrase is being edited
        if (!identical(_shownIn, p)) {
          _shownIn = p;
          _text.text = p.text;
        }
        void changed(void Function() f) {
          f();
          w.editedChanged();
        }

        return _Card('Words', [
          const Text(
            'Phrases shown in the Vessel\'s view, each with its own look and timing. BLACKOUT hides them too. '
            'Lists are kept on this computer.',
            style: _small,
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: DropdownButton<int>(
                  isExpanded: true,
                  value: w.listIndex.clamp(0, w.lists.isEmpty ? 0 : w.lists.length - 1),
                  items: [
                    for (var i = 0; i < w.lists.length; i++) DropdownMenuItem(value: i, child: Text(w.lists[i].name)),
                  ],
                  onChanged: (i) => i == null ? null : w.selectList(i),
                ),
              ),
              IconButton(
                tooltip: 'New list',
                icon: const Icon(Icons.add),
                onPressed: () async {
                  final n = await _ask('New list', '');
                  if (n != null) w.addList(n);
                },
              ),
              IconButton(
                tooltip: 'Rename list',
                icon: const Icon(Icons.edit_outlined),
                onPressed: () async {
                  final n = await _ask('Rename list', l?.name ?? '');
                  if (n != null) w.renameList(n);
                },
              ),
              IconButton(
                tooltip: 'Delete list',
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (d) => AlertDialog(
                      title: Text('Delete ${l?.name}?'),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
                        FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Delete')),
                      ],
                    ),
                  );
                  if (ok == true) w.deleteList();
                },
              ),
            ],
          ),
          for (var i = 0; i < phrases.length; i++)
            Container(
              decoration: BoxDecoration(
                color: i == w.selected ? Kc.raised : null,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: i == w.selected ? Kc.darkGreen : Colors.transparent),
              ),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Show it',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(w.onScreen(phrases[i]) ? Icons.visibility : Icons.play_arrow, size: 20),
                    color: w.onScreen(phrases[i]) ? Kc.green : null,
                    onPressed: enabled ? () => w.cue(i) : null,
                  ),
                  Container(
                    width: 10,
                    height: 10,
                    margin: const EdgeInsets.only(right: 8),
                    decoration: BoxDecoration(color: Color(0xFF000000 | phrases[i].look.color), shape: BoxShape.circle),
                  ),
                  Expanded(
                    child: InkWell(
                      onTap: () => w.select(i),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Text(phrases[i].text, maxLines: 2, overflow: TextOverflow.ellipsis),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Move up',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.arrow_upward, size: 18),
                    onPressed: i == 0 ? null : () => w.movePhrase(i, -1),
                  ),
                  IconButton(
                    tooltip: 'Move down',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.arrow_downward, size: 18),
                    onPressed: i == phrases.length - 1 ? null : () => w.movePhrase(i, 1),
                  ),
                  IconButton(
                    tooltip: 'Remove',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => w.removePhrase(i),
                  ),
                ],
              ),
            ),
          InkWell(
            onTap: () => w.select(-1),
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: w.selected < 0 ? Kc.darkGreen : Kc.line),
              ),
              child: Row(
                children: [
                  const Icon(Icons.add, size: 18, color: Kc.muted),
                  const SizedBox(width: 8),
                  Text(w.selected < 0 ? 'A new phrase, below' : 'A new phrase', style: _small),
                ],
              ),
            ),
          ),
          _group(w.selected < 0 ? 'New phrase' : 'This phrase'),
          TextField(
            controller: _text,
            minLines: 2,
            maxLines: 5,
            maxLength: wordsMaxLength,
            onChanged: (t) => changed(() => p.text = t),
            decoration: const InputDecoration(hintText: 'What to show', isDense: true, counterText: ''),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              FilledButton.icon(
                icon: const Icon(Icons.visibility_outlined),
                label: const Text('Show now'),
                onPressed: enabled ? () => w.play(p, index: w.selected >= 0 ? w.selected : null) : null,
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.terminal),
                label: const Text('As terminal'),
                onPressed: enabled
                    ? () {
                        look.terminal();
                        w.editedChanged();
                        w.play(p, index: w.selected >= 0 ? w.selected : null);
                      }
                    : null,
              ),
              if (w.selected < 0)
                OutlinedButton.icon(
                  icon: const Icon(Icons.playlist_add),
                  label: const Text('Add to list'),
                  onPressed: p.text.trim().isEmpty ? null : () => w.addDraft(),
                ),
            ],
          ),
          _group('Cues'),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.skip_previous),
                label: const Text('Previous'),
                onPressed: enabled && phrases.isNotEmpty ? w.previous : null,
              ),
              FilledButton.icon(
                icon: const Icon(Icons.skip_next),
                label: Text(w.current < 0 ? 'Start' : 'Next'),
                onPressed: enabled && phrases.isNotEmpty ? w.next : null,
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.clear_all),
                label: const Text('Clear all'),
                onPressed: enabled ? w.clear : null,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text('On screen, unless a phrase says otherwise: ${wordsHoldLabel(w.holdSeconds)}'),
          Slider(
            value: w.hold.toDouble(),
            max: (wordsHolds.length - 1).toDouble(),
            divisions: wordsHolds.length - 1,
            label: wordsHoldLabel(w.holdSeconds),
            onChanged: (v) => w.setHold(v.round()),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Go on to the next phrase by itself', style: TextStyle(fontSize: 14)),
            subtitle: w.holdSeconds == 0 ? const Text('Needs a time above', style: _small) : null,
            value: w.auto,
            onChanged: w.setAuto,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Start again after the last', style: TextStyle(fontSize: 14)),
            value: w.loop,
            onChanged: w.setLoop,
          ),
          _group('Look'),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final (label, f) in <(String, void Function(WordsLook))>[
                ('Plain', (x) => x.plain()),
                ('Terminal', (x) => x.terminal()),
                ('Whisper', (x) => x.whisper()),
                ('Shout', (x) => x.shout()),
              ])
                ActionChip(label: Text(label), onPressed: () => changed(() => f(look))),
            ],
          ),
          _chips('Font', wordsFonts, look.font, (v) => changed(() => look.font = v)),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              FilterChip(
                label: const Text('Bold', style: TextStyle(fontWeight: FontWeight.bold)),
                selected: look.bold,
                onSelected: (v) => changed(() => look.bold = v),
              ),
              FilterChip(
                label: const Text('Italic', style: TextStyle(fontStyle: FontStyle.italic)),
                selected: look.italic,
                onSelected: (v) => changed(() => look.italic = v),
              ),
              FilterChip(
                label: const Text('Underline', style: TextStyle(decoration: TextDecoration.underline)),
                selected: look.underline,
                onSelected: (v) => changed(() => look.underline = v),
              ),
              FilterChip(
                label: const Text('Outline'),
                selected: look.outline,
                onSelected: (v) => changed(() => look.outline = v),
              ),
              FilterChip(
                label: const Text('Terminal glow'),
                selected: look.crt,
                onSelected: (v) => changed(() => look.crt = v),
              ),
              FilterChip(
                label: const Text('Blinking cursor'),
                selected: look.cursor,
                onSelected: (v) => changed(() => look.cursor = v),
              ),
              FilterChip(
                label: const Text('Type it out'),
                selected: look.typing,
                onSelected: (v) => changed(() => look.typing = v),
              ),
            ],
          ),
          if (look.typing)
            _num(w, 'Typing speed', 2, 120, 1, (l) => l.typeSpeed, (l, v) => l.typeSpeed = v, unit: 'letters/s'),
          const SizedBox(height: 4),
          Row(
            children: [
              const SizedBox(width: 112, child: Text('Colour', style: TextStyle(fontSize: 14))),
              OutlinedButton.icon(
                icon: Container(
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    color: Color(0xFF000000 | look.color),
                    shape: BoxShape.circle,
                    border: Border.all(color: Kc.muted),
                  ),
                ),
                label: Text('#${look.hex.toUpperCase()}'),
                onPressed: () async {
                  final c = await _pickColor(context, look.color);
                  if (c != null) changed(() => look.color = c);
                },
              ),
            ],
          ),
          _num(w, 'Size', 0.02, 0.4, 0.005, (l) => l.size, (l, v) => l.size = v),
          _num(w, 'Opacity', 0, 1, 0.01, (l) => l.opacity, (l, v) => l.opacity = v),
          _num(w, 'Fade', 0, 10, 0.1, (l) => l.fade, (l, v) => l.fade = v, unit: 's'),
          _group('Where and for how long'),
          Row(
            children: [
              const SizedBox(width: 112, child: Text('Layer', style: TextStyle(fontSize: 14))),
              Expanded(
                child: DropdownButton<int>(
                  isExpanded: true,
                  value: p.layer,
                  items: [
                    const DropdownMenuItem(value: WordsPhrase.replaceAll, child: Text('Replace everything')),
                    const DropdownMenuItem(value: WordsPhrase.addLayer, child: Text('Add to what\'s showing')),
                    for (var n = 0; n < wordsLayers; n++) DropdownMenuItem(value: n, child: Text('Layer ${n + 1}')),
                  ],
                  onChanged: (v) => v == null ? null : changed(() => p.layer = v),
                ),
              ),
            ],
          ),
          Row(
            children: [
              const SizedBox(width: 112, child: Text('On screen', style: TextStyle(fontSize: 14))),
              Expanded(
                child: DropdownButton<int>(
                  isExpanded: true,
                  value: p.hold,
                  items: [
                    const DropdownMenuItem(value: -1, child: Text('The list\'s time')),
                    for (var n = 0; n < wordsHolds.length; n++)
                      DropdownMenuItem(value: n, child: Text(wordsHoldLabel(wordsHolds[n]))),
                  ],
                  onChanged: (v) => v == null ? null : changed(() => p.hold = v),
                ),
              ),
            ],
          ),
          _group('Motion'),
          _chips('Motion', wordsModes, look.mode, (v) => changed(() => look.mode = v)),
          _num(w, 'Motion speed', 0, 4, 0.05, (l) => l.speed, (l, v) => l.speed = v),
          _num(w, 'Left / right', -1, 1, 0.01, (l) => l.x, (l, v) => l.x = v),
          _num(w, 'Down / up', -1, 1, 0.01, (l) => l.y, (l, v) => l.y = v),
          _num(w, 'Depth', 0, 1, 0.01, (l) => l.depth, (l, v) => l.depth = v),
          _num(w, 'Turn', -180, 180, 1, (l) => l.yaw, (l, v) => l.yaw = v, unit: '°'),
          _num(w, 'Tilt', -180, 180, 1, (l) => l.pitch, (l, v) => l.pitch = v, unit: '°'),
          _num(w, 'Roll', -180, 180, 1, (l) => l.roll, (l, v) => l.roll = v, unit: '°'),
          _group('Distortion'),
          _chips('Effect', wordsDistortions, look.distort, (v) => changed(() => look.setDistortion(v))),
          _num(
            w,
            'Amount',
            0,
            1,
            0.01,
            (l) => l.distAmount,
            (l, v) => l.distAmount = v,
            enabled: look.distort != 'none',
          ),
          _num(
            w,
            'Size of effect',
            0,
            1,
            0.01,
            (l) => l.distFreq,
            (l, v) => l.distFreq = v,
            enabled: look.distort != 'none',
          ),
          _num(
            w,
            'Effect speed',
            0,
            4,
            0.05,
            (l) => l.distSpeed,
            (l, v) => l.distSpeed = v,
            enabled: look.distort != 'none',
          ),
          const Text(
            'Depth: 0 is as far as the lenses go, 1 is nearest. Pulse with the beat only brightens with the light pulse allowed. '
            'Changes show at once on a phrase that\'s on screen.',
            style: _small,
          ),
        ]);
      },
    );
  }
}
