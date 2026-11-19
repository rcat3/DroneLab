import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../comm/board_link.dart';
import '../comm/board_protocol.dart';
import '../comm/comm_controller.dart';
import '../comm/notifier.dart';
import 'firmware_ui.dart';
import 'groups_page.dart';
import 'server_page.dart';
import 'status_strip.dart';
import 'theme.dart';
import 'widgets.dart';

/// What's set once and left: getting connected (the board, the server, your
/// avatar), how the board talks, direct comms, and who's muted.
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
        final direct = settings?.direct;
        final paired = boardUp || comm.lastBoardId != null;
        const showWhile = [(0, 'NEVER'), (1, 'TALK'), (2, 'HEAR'), (3, 'BOTH')];
        return Scaffold(
          appBar: AppBar(title: const Text('Setup')),
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
                      help: 'The voice effect heard by the hive.',
                      builder: (context, info) => PanelRow(
                        title: 'HiveMind voice',
                        trailing: [
                          info,
                          DropdownButton<int>(
                            value: settings.voice,
                            underline: const SizedBox.shrink(),
                            dropdownColor: Kc.raised,
                            onChanged: (v) => comm.setBoardSettings(voice: v),
                            items: [
                              const DropdownMenuItem(value: -1, child: Text('Same as speaker')),
                              for (var i = 0; i < settings.voices.length; i++)
                                DropdownMenuItem(value: i, child: Text(settings.voices[i])),
                            ],
                          ),
                        ],
                      ),
                    ),
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
              if (direct != null) ...[
                const SectionHeader('Direct'),
                Panel(children: [
                  Explained(
                    help: 'Local comms without Internet.',
                    builder: (context, info) => PanelRow(
                      title: 'Direct, board to board',
                      trailing: [info, Switch(value: direct.on, onChanged: comm.setDirect)],
                    ),
                  ),
                  PanelRow(
                    leading: Icon(direct.keyed ? Icons.lock : Icons.lock_open, color: Kc.muted),
                    title: 'Channel: ${directChannelName(direct)}',
                    subtitle: 'F${radioText(direct.channel, direct.longRange).substring(1)} · others see you as ${direct.name}',
                    trailing: const [Icon(Icons.chevron_right, color: Kc.muted)],
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => GroupsPage(comm: comm))),
                  ),
                ]),
              ],
              const SectionHeader('Notifications'),
              _NotificationsPanel(comm: comm),
              if (boardUp) ...[
                const SectionHeader('Firmware'),
                FirmwarePanel(comm: comm),
              ],
              if (comm.muted.isNotEmpty) ...[
                const SectionHeader('Muted by you'),
                Panel(children: [
                  for (final name in comm.muted.toList()..sort())
                    PanelRow(
                      leading: const Icon(Icons.volume_off, color: Kc.softRed),
                      title: name,
                      trailing: [OutlinedButton(onPressed: () => comm.setMuted(name, false), child: const Text('Unmute'))],
                    ),
                ]),
              ],
            ],
          ),
        );
      },
    );
  }

  void _server(BuildContext context) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => ServerPage(comm: comm)));
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
      row('Unit battery low', 'At 15%, unless it\'s charging', Notifier.batteryChannel, n.battery, n.setBattery),
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
