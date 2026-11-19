import 'package:flutter/material.dart';

import '../comm/board_link.dart';
import '../comm/board_protocol.dart';
import '../comm/comm_controller.dart';
import '../comm/mumble_client.dart';
import 'firmware_ui.dart';
import 'groups_page.dart';
import 'people.dart';
import 'person_sheet.dart';
import 'setup_page.dart';
import 'status_strip.dart';
import 'theme.dart';
import 'widgets.dart';

/// HiveMind, built around talking: who's about, and the talk button where the
/// thumb is. What's set once is in [SetupPage], behind the gear.
class HiveMindPage extends StatelessWidget {
  final CommController comm;
  const HiveMindPage({super.key, required this.comm});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: comm,
      builder: (context, _) {
        final boardUp = comm.board.state == BoardState.connected && comm.board.status != null;
        final serverUp = comm.mumble?.state == MumbleState.connected;
        final direct = boardUp ? comm.boardSettings?.direct : null;
        final directOn = direct?.on ?? false;
        final sending = boardUp && (comm.board.status?.sending ?? false);
        final people = hivePeople(comm);
        return Scaffold(
          appBar: AppBar(
            title: Row(children: [
              const Icon(Icons.settings_input_antenna, color: Kc.green, size: 22),
              const SizedBox(width: 10),
              const Text('Voice'),
              const Spacer(),
              if (sending) Text('TX', style: Kc.term(16, color: Kc.pink, shadows: Kc.glow(Kc.pink))),
            ]),
            actions: [
              IconButton(
                tooltip: 'Setup',
                icon: const Icon(Icons.settings),
                onPressed: () =>
                    Navigator.of(context).push(MaterialPageRoute(builder: (_) => SetupPage(comm: comm))),
              ),
            ],
          ),
          body: Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                  children: [
                    if (!boardUp || (!serverUp && !directOn)) ...[
                      _Offline(comm: comm, boardUp: boardUp),
                      const SizedBox(height: 12),
                    ],
                    if (serverUp || directOn) ...[
                      _ChannelHeader(comm: comm, serverUp: serverUp, direct: direct),
                      if (comm.mumble?.denied case final why?)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(why, style: const TextStyle(color: Kc.softRed, fontSize: 13)),
                        ),
                      if (people.isEmpty)
                        const Panel(children: [PanelRow(title: 'Nobody else yet')])
                      else ...[
                        Panel(children: [for (final p in people) _PersonRow(comm: comm, person: p)]),
                        const Padding(
                          padding: EdgeInsets.only(top: 8),
                          child: Text('Tap someone for more', style: TextStyle(color: Kc.muted, fontSize: 13)),
                        ),
                      ],
                    ],
                  ],
                ),
              ),
              _Dock(comm: comm, boardUp: boardUp, serverUp: serverUp, direct: direct),
            ],
          ),
        );
      },
    );
  }
}

/// Why there's nobody to talk to, and what to do about it.
class _Offline extends StatelessWidget {
  final CommController comm;
  final bool boardUp;
  const _Offline({required this.comm, required this.boardUp});

  @override
  Widget build(BuildContext context) {
    final fresh = comm.lastBoardId == null || !comm.server.complete;
    final (title, text, button) = fresh
        ? ('Not linked yet', 'Pair the board and add the server to join the hive.', 'Set up')
        : !boardUp
            ? ('Board offline', '${boardStatusText(comm)}.', 'Links')
            : ('No link to the hive', 'Connect the server, or switch on Direct.', 'Links');
    return Panel(children: [
      Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('> ${title.toUpperCase()}', style: Kc.term(16, color: Kc.green)),
            const SizedBox(height: 8),
            Text(text),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () => fresh
                  ? Navigator.of(context).push(MaterialPageRoute(builder: (_) => SetupPage(comm: comm)))
                  : showLinks(context, comm),
              child: Text(button),
            ),
          ],
        ),
      ),
    ]);
  }
}

/// The channel talking goes to now, and a way to change it.
class _ChannelHeader extends StatelessWidget {
  final CommController comm;
  final bool serverUp;
  final DirectSettings? direct;
  const _ChannelHeader({required this.comm, required this.serverUp, required this.direct});

  @override
  Widget build(BuildContext context) {
    final m = comm.mumble;
    final d = direct;
    final onDirect = d != null && d.on && (!serverUp || comm.talkNow == CommController.talkDirect);
    final name = onDirect ? directChannelName(d) : m!.channelPath(m.myChannel);
    final canChange = onDirect || (m?.channels.length ?? 0) > 1;
    return SectionHeader(
      name.toLowerCase().contains('channel') ? name : 'Channel $name',
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        OtherFirmwareIcon(comm: comm),
        if (canChange)
          OutlinedButton(
            onPressed: () => onDirect
                ? Navigator.of(context).push(MaterialPageRoute(builder: (_) => GroupsPage(comm: comm)))
                : _pickChannel(context, m!),
            child: const Text('Change'),
          ),
      ]),
    );
  }

  Future<void> _pickChannel(BuildContext context, MumbleClient m) async {
    final ids = m.channels.keys.toList()..sort((a, b) => m.channelPath(a).compareTo(m.channelPath(b)));
    final counts = m.channelCounts;
    final picked = await showModalBottomSheet<int>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            const SectionHeader('Server channels'),
            const Text('Only those in the same channel hear each other',
                style: TextStyle(color: Kc.muted, fontSize: 13)),
            const SizedBox(height: 8),
            Panel(color: Kc.bg, children: [
              for (final id in ids)
                PanelRow(
                  leading: Icon(id == m.myChannel ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                      color: id == m.myChannel ? Kc.pink : Kc.muted),
                  title: m.channelPath(id),
                  trailing: [Text('${counts[id] ?? 0}', style: Kc.term(16, color: Kc.muted)), const SizedBox(width: 8)],
                  onTap: () => Navigator.pop(context, id),
                ),
            ]),
          ],
        ),
      ),
    );
    if (picked != null && picked != m.myChannel) await comm.joinChannel(picked);
  }
}

class _PersonRow extends StatelessWidget {
  final CommController comm;
  final Person person;
  const _PersonRow({required this.comm, required this.person});

  @override
  Widget build(BuildContext context) {
    final p = person;
    final talking = p.talking && !p.mutedByMe;
    final status = p.mutedByMe
        ? 'Muted by you'
        : talking
            ? 'TALKING'
            : p.user?.muted ?? false
                ? 'Muted'
                : p.onServer
                    ? 'Server'
                    : 'Direct';
    return Row(children: [
      Expanded(
        child: InkWell(
          onTap: () => showPerson(context, comm, p.key),
          child: Semantics(
            button: true,
            label: '${p.name}, $status. Tap for more',
            excludeSemantics: true,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
              child: Row(children: [
                DroneAvatar(picture: p.picture, talking: talking),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(p.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                      Text(status,
                          style: talking
                              ? Kc.term(14, color: Kc.green)
                              : const TextStyle(color: Kc.muted, fontSize: 13)),
                    ],
                  ),
                ),
                if (p.board != null) SignalBars(p.board!.rssi),
              ]),
            ),
          ),
        ),
      ),
      IconButton(
        tooltip: p.mutedByMe ? 'Hear ${p.name}' : 'Mute ${p.name}, here only',
        icon: Icon(p.mutedByMe ? Icons.volume_off : Icons.volume_up, color: p.mutedByMe ? Kc.softRed : Kc.muted),
        onPressed: () => comm.setMuted(p.name, !p.mutedByMe),
      ),
      const SizedBox(width: 4),
    ]);
  }
}

/// Where talking goes, and the talk button, at the foot of the screen.
class _Dock extends StatelessWidget {
  final CommController comm;
  final bool boardUp;
  final bool serverUp;
  final DirectSettings? direct;
  const _Dock({required this.comm, required this.boardUp, required this.serverUp, required this.direct});

  @override
  Widget build(BuildContext context) {
    final settings = comm.boardSettings;
    final d = direct;
    final ready = boardUp && (serverUp || (d?.on ?? false));
    String? note;
    if (ready && settings != null) {
      final now = comm.talkNow;
      final channel = comm.mumble?.channels[comm.mumble?.myChannel];
      final toServer = 'to the server${channel == null ? '' : ', in $channel'}';
      final toDirect = d == null ? 'to boards nearby' : 'to boards nearby, in ${directChannelName(d)}';
      note = now == settings.talkOn
          ? 'Talking ${now == CommController.talkDirect ? toDirect : toServer}'
          : now == CommController.talkDirect
              ? "Nobody's on the server, so talking $toDirect"
              : "Nobody's nearby, so talking $toServer";
    }
    final mode = comm.board.status?.mode;
    return Container(
      decoration: const BoxDecoration(color: Kc.dock, border: Border(top: BorderSide(color: Kc.line))),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (d != null && settings != null)
            Explained(
              help: "If nobody's on the one you pick, it talks on the other.",
              align: TextAlign.center,
              helpPadding: const EdgeInsets.only(top: 4),
              builder: (context, info) => Row(children: [
                Expanded(
                  child: SegmentedButton<int>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: CommController.talkServer, label: Text('SERVER')),
                      ButtonSegment(value: CommController.talkDirect, label: Text('DIRECT')),
                    ],
                    selected: {settings.talkOn},
                    onSelectionChanged: (sel) => comm.setTalkOn(sel.first),
                  ),
                ),
                info,
              ]),
            ),
          if (note != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(note,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: settings != null && comm.talkNow != settings.talkOn ? Kc.otherAir : Kc.muted,
                      fontSize: 13)),
            ),
          const SizedBox(height: 10),
          _TalkButton(comm: comm, enabled: boardUp),
          Explained(
            help: comm.headsetTalking
                ? "Talking from the headphones' button: press it again to stop."
                : "Or press the headphones' play/pause button to talk, and again to stop.",
            align: TextAlign.center,
            helpPadding: EdgeInsets.zero,
            builder: (context, info) => Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (mode != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(border: Border.all(color: Kc.darkGreen)),
                    child: Text(mode == BoardMode.voice ? '[ VOICE ]' : '[ PTT ]', style: Kc.term(14, color: Kc.green)),
                  ),
                info,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TalkButton extends StatefulWidget {
  final CommController comm;
  final bool enabled;
  const _TalkButton({required this.comm, required this.enabled});

  @override
  State<_TalkButton> createState() => _TalkButtonState();
}

class _TalkButtonState extends State<_TalkButton> {
  bool _held = false;

  void _set(bool held) {
    if (held == _held) return;
    setState(() => _held = held);
    widget.comm.holdToTalk(held);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled;
    final sending = enabled && (widget.comm.board.status?.sending ?? false);
    final fg = !enabled
        ? Kc.off
        : sending
            ? Kc.bg
            : Kc.pink;
    return Semantics(
      button: true,
      enabled: enabled,
      label: sending ? 'Talking' : 'Hold to talk',
      child: Listener(
        onPointerDown: enabled ? (_) => _set(true) : null,
        onPointerUp: (_) => _set(false),
        onPointerCancel: (_) => _set(false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          width: 128,
          height: 128,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: sending ? Kc.pink : Kc.panel,
            border: Border.all(color: enabled ? Kc.pink : Kc.line, width: 2),
            boxShadow: sending ? [BoxShadow(color: Kc.pink.withValues(alpha: 0.6), blurRadius: 42)] : null,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(sending ? Icons.mic : Icons.mic_none, size: 40, color: fg),
              const SizedBox(height: 4),
              Text(!enabled ? 'OFFLINE' : sending ? 'TALKING' : 'HOLD TO\nTALK',
                  textAlign: TextAlign.center, style: Kc.term(14, color: fg)),
            ],
          ),
        ),
      ),
    );
  }
}
