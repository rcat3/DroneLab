import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../comm/board_link.dart';
import '../comm/board_protocol.dart';
import '../comm/calls.dart';
import '../comm/comm_controller.dart';
import '../comm/notifier.dart';
import 'about_page.dart';
import 'developer_page.dart';
import 'unit_sounds_page.dart';
import 'firmware_ui.dart';
import 'server_page.dart';
import 'status_strip.dart';
import 'theme.dart';
import 'widgets.dart';

/// What's set once and left: getting connected (the board, the server, your
/// avatar), how the board talks, and who's muted. Direct comms are on the
/// Text tab and the links' sheet.
class SetupPage extends StatelessWidget {
  final CommController comm;
  const SetupPage({super.key, required this.comm});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: comm,
      builder: (context, _) {
        final b = comm.board;
        final boardUp = b.state == BoardState.connected && b.status != null;
        final settings = boardUp ? comm.boardSettings : null;
        final paired = boardUp || comm.lastBoardId != null;
        const showWhile = [(0, 'NEVER'), (1, 'TALK'), (2, 'HEAR'), (3, 'BOTH')];
        return Scaffold(
          appBar: AppBar(
            title: const Text('Setup'),
            actions: [
              IconButton(tooltip: 'About', icon: const Icon(Icons.info_outline), onPressed: () => _about(context)),
            ],
          ),
          body: ListView(
            // Clear of the system's navigation bar, which can sit over the page
            padding: EdgeInsets.fromLTRB(16, 8, 16, 24 + MediaQuery.paddingOf(context).bottom),
            children: [
              const SectionHeader('Get connected'),
              Panel(children: [
                PanelRow(
                  leading: _Step(1, boardUp),
                  title: 'Pair the board',
                  subtitle: paired ? '${b.name ?? comm.lastBoardName ?? 'Board'} · ${boardStatusText(comm)}'
                      : "Switch on the board's Phone App first",
                  trailing: [
                    b.state == BoardState.off || b.state == BoardState.scanning
                        ? FilledButton(onPressed: () => pickBoard(context, comm), child: const Text('Find'))
                        : OutlinedButton(onPressed: comm.disconnectBoard, child: const Text('Disconnect')),
                  ],
                ),
                PanelRow(
                  leading: _Step(2, comm.server.complete),
                  title: 'Join the server',
                  subtitle: comm.server.complete
                      ? '${comm.server.host} · as ${comm.server.username}'
                      : 'A Mumble server: address, name, password',
                  trailing: [
                    comm.server.complete
                        ? OutlinedButton(onPressed: () => _server(context), child: const Text('Edit'))
                        : FilledButton(onPressed: () => _server(context), child: const Text('Set up')),
                  ],
                ),
                _AvatarRow(comm: comm),
              ]),
              const SectionHeader('Talking'),
              if (settings == null)
                const Panel(children: [PanelRow(title: 'Connect to the board to change these')])
              else
                Panel(children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      const Text('Talk with', style: TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 8),
                      SegmentedButton<BoardMode>(
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment(value: BoardMode.pushToTalk, label: Text('PUSH TO TALK')),
                          ButtonSegment(value: BoardMode.voice, label: Text('VOICE')),
                        ],
                        selected: {b.status?.mode ?? BoardMode.pushToTalk},
                        onSelectionChanged: (sel) => b.setMode(sel.first),
                      ),
                    ]),
                  ),
                  if (settings.voices.isNotEmpty)
                    Explained(
                      help: settings.hasSpeaker
                          ? 'The voice effect heard by the hive.'
                          : "The voice effect heard by the hive: the same as the unit's Voice Effect page, "
                              'as there is no speaker.',
                      builder: (context, info) => PanelRow(
                        title: 'HiveMind voice',
                        trailing: [
                          info,
                          DropdownButton<int>(
                            // Without a speaker it's the unit's one effect, never "the speaker's"
                            value: settings.hasSpeaker || settings.voice >= 0 ? settings.voice : 0,
                            underline: const SizedBox.shrink(),
                            dropdownColor: Kc.raised,
                            onChanged: (v) => comm.setBoardSettings(voice: v),
                            items: [
                              if (settings.hasSpeaker) const DropdownMenuItem(value: -1, child: Text('Same as speaker')),
                              for (var i = 0; i < settings.voices.length; i++)
                                DropdownMenuItem(value: i, child: Text(settings.voices[i])),
                            ],
                          ),
                        ],
                      ),
                    ),
                  // The low-profile housing has no speaker to mute
                  if (settings.hasSpeaker)
                    Explained(
                      help: 'Mute speaker when speaking to hive.',
                      builder: (context, info) => PanelRow(
                        title: 'Mute speaker on Tx',
                        trailing: [
                          info,
                          Switch(value: settings.muteSpeaker, onChanged: (on) => comm.setBoardSettings(muteSpeaker: on)),
                        ],
                      ),
                    ),
                  if (comm.boardTalksTo)
                    Explained(
                      help: 'Two short notes up in your headphones as push to talk starts, and down as it ends. '
                          'Not in voice mode. A low buzz when nobody would hear you sounds either way.',
                      builder: (context, info) => PanelRow(
                        title: 'Talk tones',
                        trailing: [info, Switch(value: comm.talkTones, onChanged: comm.setTalkTones)],
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      const Text('Show HiveMind on the board while', style: TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 8),
                      SegmentedButton<int>(
                        showSelectedIcon: false,
                        segments: [for (final (v, label) in showWhile) ButtonSegment(value: v, label: Text(label))],
                        selected: {settings.show},
                        onSelectionChanged: (sel) => comm.setBoardSettings(show: sel.first),
                      ),
                    ]),
                  ),
                ]),
              // Speaker units only: the low-profile one has none to play them on
              if (boardUp && (settings?.hasSpeaker ?? false)) ...[
                const SectionHeader('Unit'),
                Panel(children: [
                  PanelRow(
                    leading: const Icon(Icons.music_note_outlined, color: Kc.muted),
                    title: 'Unit sounds',
                    subtitle: 'Sounds the unit plays for calls, texts, commands and units nearby',
                    trailing: const [Icon(Icons.chevron_right, color: Kc.muted)],
                    onTap: () =>
                        Navigator.of(context).push(MaterialPageRoute(builder: (_) => UnitSoundsPage(comm: comm))),
                  ),
                ]),
              ],
              const SectionHeader('Headphones'),
              _CallsPanel(comm: comm),
              const SectionHeader('Your identity'),
              _IdentityPanel(comm: comm),
              const SectionHeader('Notifications'),
              _NotificationsPanel(comm: comm),
              if (boardUp) ...[
                const SectionHeader('Firmware'),
                FirmwarePanel(comm: comm),
              ],
              if (comm.muted.isNotEmpty) ...[
                const SectionHeader('Muted by you'),
                Panel(children: [
                  for (final p in comm.muted.toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase())))
                    PanelRow(
                      leading: const Icon(Icons.volume_off, color: Kc.softRed),
                      title: p.name,
                      subtitle: p.identified ? null : 'Known by name only',
                      trailing: [OutlinedButton(onPressed: () => comm.setMuted(p.id, false), child: const Text('Unmute'))],
                    ),
                ]),
              ],
              if (comm.developerOptions) ...[
                const SectionHeader('Developer'),
                Panel(children: [
                  PanelRow(
                    leading: const Icon(Icons.developer_mode, color: Kc.muted),
                    title: 'Developer options',
                    subtitle: 'Auto responders, for testing range and relays',
                    trailing: const [Icon(Icons.chevron_right, color: Kc.muted)],
                    onTap: () =>
                        Navigator.of(context).push(MaterialPageRoute(builder: (_) => DeveloperPage(comm: comm))),
                  ),
                ]),
              ],
              const SectionHeader('About'),
              Panel(children: [
                PanelRow(
                  leading: const Icon(Icons.info_outline, color: Kc.muted),
                  title: 'About DroneLab',
                  subtitle: 'Versions, the unit, its battery',
                  trailing: const [Icon(Icons.chevron_right, color: Kc.muted)],
                  onTap: () => _about(context),
                ),
              ]),
            ],
          ),
        );
      },
    );
  }

  void _about(BuildContext context) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => AboutPage(comm: comm)));

  void _server(BuildContext context) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => ServerPage(comm: comm)));
}

/// Who others know us as: the key the app made, which signs what we send.
/// Backing it up is its code; the same code on another phone, or after
/// reinstalling, makes that phone us.
class _IdentityPanel extends StatelessWidget {
  final CommController comm;
  const _IdentityPanel({required this.comm});

  @override
  Widget build(BuildContext context) {
    final me = comm.identity;
    return Panel(children: [
      PanelRow(
        leading: const Icon(Icons.fingerprint, color: Kc.muted),
        title: me == null ? 'None' : 'Identity ${me.id.substring(0, 8)}',
        subtitle: me == null
            ? "The phone's secure storage couldn't be used"
            : 'Others know you by this, not your name. Back it up to keep it.',
        trailing: [
          if (me != null)
            OutlinedButton(onPressed: () => _showCode(context, me.exportCode), child: const Text('Back up')),
        ],
      ),
      PanelRow(
        title: 'Restore an identity',
        subtitle: 'Become the identity in a backed-up code',
        trailing: [OutlinedButton(onPressed: () => _restore(context), child: const Text('Restore'))],
      ),
    ]);
  }

  void _showCode(BuildContext context, String code) => showDialog<void>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: const Text('Your identity code'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            SelectableText(code, style: Kc.term(16)),
            const SizedBox(height: 12),
            const Text('Anyone with this code can pass as you. Keep it somewhere safe, and nowhere else.',
                style: TextStyle(color: Kc.muted, fontSize: 13)),
          ]),
          actions: [
            TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: code));
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied')));
              },
              child: const Text('Copy'),
            ),
            TextButton(onPressed: () => Navigator.pop(dialog), child: const Text('Done')),
          ],
        ),
      );

  Future<void> _restore(BuildContext context) async {
    final field = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Restore an identity'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: field,
            autofocus: true,
            minLines: 2,
            maxLines: 3,
            decoration: const InputDecoration(hintText: 'XXXX-XXXX-...'),
          ),
          const SizedBox(height: 12),
          const Text("This phone's identity is replaced: back it up first if you'll want it again.",
              style: TextStyle(color: Kc.muted, fontSize: 13)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(dialog, field.text), child: const Text('Restore')),
        ],
      ),
    );
    if (code == null || code.trim().isEmpty) return;
    final error = await comm.importIdentity(code);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error ?? 'Identity restored')));
    }
  }
}

/// Which of DroneLab's notifications come, and a way into Android's own
/// settings for each: its sound, whether it pops up, the status bar.
class _NotificationsPanel extends StatefulWidget {
  final CommController comm;
  const _NotificationsPanel({required this.comm});

  @override
  State<_NotificationsPanel> createState() => _NotificationsPanelState();
}

class _NotificationsPanelState extends State<_NotificationsPanel> {
  @override
  Widget build(BuildContext context) {
    final n = widget.comm.notifier;
    Widget row(String title, String subtitle, String channel, bool on, Future<void> Function(bool) set) => PanelRow(
          title: title,
          subtitle: subtitle,
          trailing: [
            IconButton(
              tooltip: 'Sound, pop-up and more',
              icon: const Icon(Icons.tune, color: Kc.muted),
              onPressed: () => n.openChannelSettings(channel),
            ),
            Switch(
              value: on,
              onChanged: (v) async {
                if (v) await n.askPermission();
                await set(v);
                if (mounted) setState(() {});
              },
            ),
          ],
        );
    return Panel(children: [
      row('Text messages', 'Every text that comes in. Tap one to read it', Notifier.textsChannel, n.texts, n.setTexts),
      row('Calls', "Ring on the phone too, with its ringtone. Off, calls ring in the headphones only", Notifier.callsChannel, n.calls, n.setCalls),
      row('Missed calls', "Calls you didn't answer", Notifier.missedChannel, n.missed, n.setMissed),
      row('Unit battery low', 'At 15%, unless it\'s charging', Notifier.batteryChannel, n.battery, n.setBattery),
    ]);
  }
}

/// Sounds in the headphones: calls' ringing, on or off, and which tone (the
/// phone's own ring is the Calls notification's); and a tone for texts.
class _CallsPanel extends StatelessWidget {
  final CommController comm;
  const _CallsPanel({required this.comm});

  @override
  Widget build(BuildContext context) {
    return Panel(children: [
      Explained(
        help: 'Two quick high blips in your headphones as a text or photo comes in, unlike any other sound '
            "the app makes, so you know without looking. It's in the headphones only: the phone stays quiet "
            'unless the Text messages notification makes a sound.',
        builder: (context, info) => PanelRow(
          title: 'Text tone',
          trailing: [
            info,
            IconButton(
              tooltip: 'Play it',
              icon: const Icon(Icons.play_arrow, color: Kc.muted),
              onPressed: comm.previewTextTone,
            ),
            Switch(value: comm.textTone, onChanged: comm.setTextTone),
          ],
        ),
      ),
      Explained(
        help: "Someone calling rings in your headphones, so you hear it under the mask. To have the phone ring "
            "as well, switch on the Calls notification, under Notifications; its ringtone is set there.",
        builder: (context, info) => PanelRow(
          title: 'Ring in headphones',
          trailing: [info, Switch(value: comm.ringInHeadphones, onChanged: (on) => comm.setRing(headphones: on))],
        ),
      ),
      PanelRow(
        title: 'Headphone ring',
        trailing: [
          IconButton(
            tooltip: 'Play it',
            icon: const Icon(Icons.play_arrow, color: Kc.muted),
            onPressed: () => comm.previewRing(comm.ringTone),
          ),
          DropdownButton<String>(
            value: comm.ringTone,
            underline: const SizedBox.shrink(),
            dropdownColor: Kc.raised,
            onChanged: (t) {
              if (t == null) return;
              comm.setRing(tone: t);
              comm.previewRing(t);
            },
            items: [for (final e in ringTones.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
          ),
        ],
      ),
    ]);
  }
}

/// A step's number, or a tick once it's done.
class _Step extends StatelessWidget {
  final int n;
  final bool done;
  const _Step(this.n, this.done);

  @override
  Widget build(BuildContext context) => Container(
        width: 30,
        height: 30,
        alignment: Alignment.center,
        decoration: BoxDecoration(border: Border.all(color: done ? Kc.darkGreen : Kc.line)),
        child: done
            ? const Icon(Icons.check, size: 18, color: Kc.green, semanticLabel: 'Done')
            : Text('$n', style: Kc.term(16, color: Kc.muted)),
      );
}

/// Your avatar, for the server and direct comms alike.
class _AvatarRow extends StatefulWidget {
  final CommController comm;
  const _AvatarRow({required this.comm});

  @override
  State<_AvatarRow> createState() => _AvatarRowState();
}

class _AvatarRowState extends State<_AvatarRow> {
  bool _picking = false;

  Future<void> _pick() async {
    setState(() => _picking = true);
    try {
      final file = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (file == null) return;
      final ok = await widget.comm.setAvatar(await file.readAsBytes());
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("That doesn't look like a picture")));
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final avatar = widget.comm.avatar;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            _Step(3, avatar != null),
            const SizedBox(width: 12),
            const Text('Your avatar', style: TextStyle(fontWeight: FontWeight.w600)),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            DroneAvatar(picture: avatar, size: 96),
            const Spacer(),
            if (avatar != null)
              IconButton(
                tooltip: 'Remove your avatar',
                icon: const Icon(Icons.delete_outline, color: Kc.muted),
                onPressed: () => widget.comm.setAvatar(null),
              ),
            const SizedBox(width: 4),
            avatar == null
                ? FilledButton(onPressed: _picking ? null : _pick, child: const Text('Choose'))
                : OutlinedButton(onPressed: _picking ? null : _pick, child: const Text('Change')),
          ]),
        ],
      ),
    );
  }
}
