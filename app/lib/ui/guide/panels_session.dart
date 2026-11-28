/// The Guide page's session panels: the session and its invitations, the
/// Vessels in it, the sender, and the headset's calibration.
library;

import 'package:flutter/material.dart';

import '../../comm/conversations.dart';
import '../../comm/hivesight_guide.dart';
import '../../comm/hivesight_invite.dart';
import '../../comm/guide_settings.dart';
import '../hivesight_code.dart';
import '../theme.dart';
import 'guide_widgets.dart';

/// Invite a conversation to the session, as a text with a Join button.
Future<void> inviteToSession(BuildContext context, HiveSightGuide g) async {
  final convs = g.comm.conversations.all.values.toList()
    ..sort((a, b) => (b.last ?? DateTime(0)).compareTo(a.last ?? DateTime(0)));
  final messenger = ScaffoldMessenger.of(context);
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
  if (c == null) return;
  final ok = await g.invite(c);
  messenger.showSnackBar(
    SnackBar(
      content: Text(ok ? 'Invitation sent to ${c.audience}' : "Couldn't send it: ${c.title} can't be reached just now"),
    ),
  );
}

/// Start a session, or when one's on: when it ends, and Invite, Show code
/// and End, with the same dialogs wherever it's shown.
class SessionControls extends StatelessWidget {
  final HiveSightGuide g;

  /// Short: no explanation, for the quick controls.
  final bool compact;
  const SessionControls(this.g, {super.key, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final s = g.session;
    final running = g.state == SenderState.running && g.linked;
    if (s == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!compact) ...[
            const Text(
              'No session. Start one, then invite your Vessels from here or from a conversation in Text. '
              'Your camera and mic stay off until then. During a session, HiveMind voice is held: nothing plays '
              "or goes out (texts still arrive).",
              style: gSmall,
            ),
            const SizedBox(height: 10),
          ],
          FilledButton.icon(
            onPressed: running ? g.startSession : null,
            icon: const Icon(Icons.play_arrow),
            label: const Text('Start a session'),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!compact) ...[
          Text('Open until ${HiveSightInvite.clock(s.expires)}', style: const TextStyle(fontWeight: FontWeight.w600)),
          Text(
            g.addrs.isEmpty
                ? "This computer has no network address for Vessels to reach"
                : 'Vessels reach you at ${g.addrs.join(', ')}, port ${HiveSightGuide.vesselPort}, over TLS',
            style: gSmall,
          ),
          const SizedBox(height: 10),
        ],
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: g.canInvite ? () => inviteToSession(context, g) : null,
              icon: const Icon(Icons.send),
              label: const Text('Invite…'),
            ),
            OutlinedButton.icon(
              onPressed: g.canInvite
                  ? () async {
                      final messenger = ScaffoldMessenger.of(context);
                      final why = await showHiveSightCode(context, g);
                      if (why != null) messenger.showSnackBar(SnackBar(content: Text(why)));
                    }
                  : null,
              icon: const Icon(Icons.qr_code_2),
              label: const Text('Show code'),
            ),
            OutlinedButton.icon(
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
          ],
        ),
      ],
    );
  }
}

class SessionTab extends StatelessWidget {
  final HiveSightGuide g;
  const SessionTab(this.g, {super.key});

  @override
  Widget build(BuildContext context) => GCard(null, [SessionControls(g)]);
}

/// One line about a Vessel: what's known of how they're doing.
String vesselDetail(GuideVessel v) => [
  if (!v.verified) 'not signed',
  v.lightPulse ? 'light pulse allowed' : 'no light pulse',
  if (v.stats['fps'] != null) '${v.stats['fps']} fps',
  if (v.stats['kbps'] != null) '${v.stats['kbps']} kb/s',
  if (v.stats['loss'] != null) 'loss ${v.stats['loss']}',
  if (v.stats['rtt_ms'] != null) 'rtt ${v.stats['rtt_ms']} ms',
  if (v.stats['battery'] != null) 'battery ${v.stats['battery']}%',
].join(' · ');

class VesselsTab extends StatelessWidget {
  final HiveSightGuide g;
  const VesselsTab(this.g, {super.key});

  @override
  Widget build(BuildContext context) => GCard(null, [
    if (g.vessels.isEmpty)
      Text(g.session == null ? 'Nobody: no session' : 'Nobody has joined yet', style: gSmall)
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
                    Text(vesselDetail(v), style: gSmall),
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

class CalibrateTab extends StatelessWidget {
  final GuideSettings g;
  final bool enabled;
  const CalibrateTab(this.g, {super.key, required this.enabled});

  @override
  Widget build(BuildContext context) => GCard(null, [
    const Text(
      "The headset's lenses, saved on the Vessel's phone. With several Vessels, every phone takes these.",
      style: gSmall,
    ),
    GSlide(g, 'view.lens_sep_mm', 'Lens spacing', 50, 75, 0.5, unit: 'mm', enabled: enabled),
    GSlide(g, 'view.lens_y_mm', 'Lens height', -20, 20, 0.5, unit: 'mm', enabled: enabled),
    GSlide(g, 'view.k1', 'Distortion k1', -0.3, 1.5, 0.01, enabled: enabled),
    GSlide(g, 'view.k2', 'Distortion k2', -0.3, 1.5, 0.01, enabled: enabled),
    GSlide(g, 'view.zoom', 'Zoom', 0.4, 2.5, 0.01, unit: '×', enabled: enabled),
    GSlide(g, 'view.convergence', 'Convergence', -0.15, 0.15, 0.002, enabled: enabled),
    GSlide(g, 'view.vertical', 'Vertical', -0.1, 0.1, 0.001, enabled: enabled),
    GToggle(g, 'view.grid', 'Grid', enabled: enabled),
    GToggle(g, 'view.stats', 'Stats on the Vessel', enabled: enabled),
  ]);
}

/// The sender's camera, microphone and media folder; changing them
/// restarts it, and the session carries on.
class SenderTab extends StatefulWidget {
  final HiveSightGuide g;
  const SenderTab(this.g, {super.key});

  @override
  State<SenderTab> createState() => _SenderTabState();
}

class _SenderTabState extends State<SenderTab> {
  // The voice and media folder, as being changed (the camera's in Source)
  late bool _audio = widget.g.options.audio;
  late String _mic = widget.g.options.mic;
  late final _media = TextEditingController(text: widget.g.options.mediaDir);
  late final _music = TextEditingController(text: widget.g.options.musicDir);

  @override
  void dispose() {
    _media.dispose();
    _music.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final g = widget.g;
    final o = g.options;
    final changed =
        _audio != o.audio || _mic != o.mic || _media.text.trim() != o.mediaDir || _music.text.trim() != o.musicDir;
    final row = gRow;
    return GCard(null, [
      if (g.state == SenderState.failed && g.problem != null) ...[
        Text(g.problem!, style: const TextStyle(color: Kc.softRed)),
        if (g.missing.isNotEmpty) ...[
          const SizedBox(height: 4),
          const Text('Install them, then start it again:', style: gSmall),
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
            value: _mic.isEmpty || _mic == HiveSightGuide.unitSource || g.mics.any((m) => m.name == _mic) ? _mic : null,
            items: [
              const DropdownMenuItem(value: '', child: Text('Default')),
              const DropdownMenuItem(value: HiveSightGuide.unitSource, child: Text("Display unit's microphone")),
              for (final m in g.mics)
                DropdownMenuItem(
                  value: m.name,
                  child: Text(m.label, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (m) => setState(() => _mic = m ?? ''),
          ),
        ),
      if (_audio && _mic == HiveSightGuide.unitSource)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            g.usesUnit && g.unitProblem != null
                ? g.unitProblem!
                : g.usesUnit && g.unitReceiving
                ? 'Your voice is coming from the display unit, dry: the effects here make it.'
                : "The display unit's microphone, dry: the effects here make the voice. It's used while a session "
                      'is on.',
            style: TextStyle(fontSize: 13, color: g.usesUnit && g.unitProblem != null ? Kc.softRed : Kc.muted),
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
      row(
        'Music folder',
        TextField(
          controller: _music,
          decoration: const InputDecoration(hintText: '~/Music', isDense: true),
          onChanged: (_) => setState(() {}),
        ),
      ),
      const SizedBox(height: 10),
      Row(
        children: [
          Expanded(
            child: FilledButton(
              onPressed: changed
                  ? () => g.setOptions(
                      o.copyWith(audio: _audio, mic: _mic, mediaDir: _media.text.trim(), musicDir: _music.text.trim()),
                    )
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
        'The camera is chosen under Picture → Source. A new microphone or folder applies at once; turning your voice on or '
        'off restarts the sender, and a session carries on.',
        style: gSmall,
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
