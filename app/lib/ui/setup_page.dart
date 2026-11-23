import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../comm/board_link.dart';
import '../comm/board_protocol.dart';
import '../comm/calls.dart';
import '../comm/comm_controller.dart';
import '../comm/notifier.dart';
import '../comm/virtual_unit.dart';
import 'about_page.dart';
import 'developer_page.dart';
import 'display_unit_page.dart';
import 'identity_page.dart';
import 'permissions_page.dart';
import 'phone_mic_ui.dart';
import 'unit_sounds_page.dart';
import 'firmware_ui.dart';
import 'server_page.dart';
import 'status_strip.dart';
import 'theme.dart';
import 'widgets.dart';

/// What's set once and left: getting connected (the board, the server, who
/// you are), how the board talks, and who's muted. Direct comms are on the
/// Text tab and the links' sheet.
Widget _talkTones(CommController comm) => Explained(
      help: 'Two short notes up in your headphones as push to talk starts, and down as it ends. '
          'Not in voice mode. A low buzz when nobody would hear you sounds either way.',
      builder: (context, info) => PanelRow(
        title: 'Talk tones',
        trailing: [info, Switch(value: comm.talkTones, onChanged: comm.setTalkTones)],
      ),
    );

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
                  // Optional: without a unit, the phone's mic talks
                  subtitle: paired ? '${b.name ?? comm.lastBoardName ?? 'Board'} · ${boardStatusText(comm)}'
                      : VirtualUnits.available
                          ? "If you have one: switch on its Phone App first. Or start a virtual unit, "
                              "or talk from the computer's microphone"
                          : "If you have one: switch on its Phone App first. Without one, you talk from "
                              "the phone's microphone",
                  trailing: [
                    b.state == BoardState.off || b.state == BoardState.scanning
                        ? FilledButton(onPressed: () => pickBoard(context, comm), child: const Text('Find'))
                        : OutlinedButton(onPressed: comm.disconnectBoard, child: const Text('Disconnect')),
                  ],
                ),
                PanelRow(
                  leading: _Step(2, comm.server.complete),
                  title: 'Join the server',
                  subtitle: comm.refusedName != null
                      ? '${comm.serverError}: change it under Identity'
                      : comm.server.complete
                      ? '${comm.server.host} · as ${comm.server.username}'
                      : comm.server.host.isNotEmpty
                          ? 'Set your name under Identity to join'
                          : 'A Mumble server: address and password',
                  trailing: [
                    comm.server.complete
                        ? OutlinedButton(onPressed: () => _server(context), child: const Text('Edit'))
                        : FilledButton(onPressed: () => _server(context), child: const Text('Set up')),
                  ],
                ),
                _IdentityRow(comm: comm),
              ]),
              const SectionHeader('Permissions'),
              Panel(children: [PermissionsRow(comm: comm)]),
              const SectionHeader('Talking'),
              // One order, whichever mic talks, rows coming and going in
              // place: how you talk, then your voice, then the board's
              // screen. The unit's rows show while it's connected, as its
              // own talk button and voice mode talk through it whichever
              // mic's picked.
              Panel(children: [
                if (MicSourceRow.shown(boardUp)) MicSourceRow(comm: comm, unitUp: boardUp),
                if (comm.phoneMicTalks) PhoneMicRow(comm: comm),
                // Voice mode's only for the unit's mic: with the phone's, the
                // unit's in push to talk (CommController._checkUnitMode)
                if (settings != null && !comm.phoneMicTalks)
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
                if (comm.phoneMicTalks || comm.boardTalksTo) _talkTones(comm),
                if (settings == null && !comm.phoneMicTalks)
                  const PanelRow(title: 'Connect to the board to change these'),
              ]),
              if (settings != null || comm.phoneMicTalks) ...[
                const SizedBox(height: 12),
                Panel(children: [
                  if (settings != null && settings.voices.isNotEmpty)
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
                  if (settings != null && settings.hasSpeaker)
                    Explained(
                      help: settings.muteForced
                          ? 'Mute speaker when speaking to hive. Always on while the HiveMind voice differs from '
                              "the speaker's: the unit runs one voice effect at a time, so the speaker goes quiet "
                              'while you talk to the hive, and comes back when you stop. Set HiveMind voice to '
                              'Same as speaker to choose.'
                          : 'Mute speaker when speaking to hive.',
                      builder: (context, info) => PanelRow(
                        title: 'Mute speaker on Tx',
                        trailing: [
                          info,
                          // On and greyed out while it's forced; the choice is kept for after
                          Switch(
                              value: settings.muteSpeaker || settings.muteForced,
                              onChanged: settings.muteForced
                                  ? null
                                  : (on) => comm.setBoardSettings(muteSpeaker: on)),
                        ],
                      ),
                    ),
                  if (comm.phoneMicTalks) ...[
                    MicBoostRow(comm: comm),
                    MicMeter(comm: comm),
                  ],
                ]),
              ],
              if (settings != null) ...[
                const SizedBox(height: 12),
                Panel(children: [
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
              ],
              if (boardUp) ...[
                const SectionHeader('Unit'),
                Panel(children: [
                  PanelRow(
                    leading: const Icon(Icons.brightness_6_outlined, color: Kc.muted),
                    title: 'Display unit',
                    subtitle: 'Brightness, rotation, what it shows at startup, the WiFi remote',
                    trailing: const [Icon(Icons.chevron_right, color: Kc.muted)],
                    onTap: () =>
                        Navigator.of(context).push(MaterialPageRoute(builder: (_) => DisplayUnitPage(comm: comm))),
                  ),
                  // Speaker units only: the low-profile one has none to play them on
                  if (settings?.hasSpeaker ?? false)
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
            // Android's own settings for the channel; none elsewhere
            if (defaultTargetPlatform == TargetPlatform.android)
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
      row('Permission requests', 'Someone asks to control something of yours. Tap one to see to it',
          Notifier.permissionsChannel, n.permissionRequests, n.setPermissionRequests),
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
        help: 'Notes up and down in your headphones when something needs you: for now, someone asking to '
            'control something of yours.',
        builder: (context, info) => PanelRow(
          title: 'Attention tone',
          trailing: [
            info,
            IconButton(
              tooltip: 'Play it',
              icon: const Icon(Icons.play_arrow, color: Kc.muted),
              onPressed: comm.previewAttentionTone,
            ),
            Switch(value: comm.attentionTone, onChanged: comm.setAttentionTone),
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

/// Who you are, at a glance: your avatar, name and identity, and the way
/// into the Identity page to change them or back the key up.
class _IdentityRow extends StatelessWidget {
  final CommController comm;
  const _IdentityRow({required this.comm});

  @override
  Widget build(BuildContext context) {
    final name = comm.server.username;
    final me = comm.identity;
    return InkWell(
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => IdentityPage(comm: comm))),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              _Step(3, name.isNotEmpty),
              const SizedBox(width: 12),
              const Expanded(child: Text('Identity', style: TextStyle(fontWeight: FontWeight.w600))),
              const Icon(Icons.chevron_right, color: Kc.muted),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              DroneAvatar(picture: comm.avatar, size: 72),
              const SizedBox(width: 16),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(name.isEmpty ? 'No name yet' : name,
                      style: TextStyle(fontSize: 18, color: name.isEmpty ? Kc.muted : null),
                      overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 4),
                  Text(me == null ? 'No identity key' : 'Identity ${me.id.substring(0, 8)}',
                      style: const TextStyle(color: Kc.muted, fontSize: 13)),
                ]),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}
