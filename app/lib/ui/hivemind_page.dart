import 'package:flutter/material.dart';

import '../comm/board_link.dart';
import '../comm/board_protocol.dart';
import '../comm/comm_controller.dart';
import '../comm/mumble_client.dart';
import 'firmware_ui.dart';
import 'channel_lists.dart';
import 'people.dart';
import 'person_sheet.dart';
import 'setup_page.dart';
import 'status_strip.dart';
import 'theme.dart';
import 'widgets.dart';

/// HiveMind, built around talking: the channels we're on and the people
/// about, as on the Text tab, each once. Tap one to talk to it: a channel by
/// its own way (the server's, or direct), one person by whichever reaches
/// them. The talk button's where the thumb is. What's set once is in
/// [SetupPage], behind the gear.
class HiveMindPage extends StatelessWidget {
  final CommController comm;
  const HiveMindPage({super.key, required this.comm});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: comm,
      builder: (context, _) {
        final boardUp = comm.board.state == BoardState.connected && comm.board.status != null;
        final m = comm.mumble;
        final serverUp = m?.state == MumbleState.connected;
        final direct = boardUp ? comm.boardSettings?.direct : null;
        final directOn = direct?.on ?? false;
        final sending = boardUp && (comm.board.status?.sending ?? false);
        final to = comm.talkTo;
        final people = peopleOnce(comm)
          ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        // The one talked to stays in the list while they're out of reach
        final away = to.kind == TalkTo.person && !people.any((p) => p.id == to.personId)
            ? comm.people[to.personId!]
            : null;
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
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  children: [
                    if (!boardUp || (!serverUp && !directOn)) ...[
                      const SizedBox(height: 4),
                      _Offline(comm: comm, boardUp: boardUp),
                      const SizedBox(height: 4),
                    ],
                    if (serverUp || directOn) ...[
                      SectionHeader('Channels', trailing: OtherFirmwareIcon(comm: comm)),
                      ChannelLists(
                        comm: comm,
                        serverCurrent:
                            serverUp ? _ServerChannelRow(comm: comm, m: m!, selected: to.kind == TalkTo.server) : null,
                        directCurrent:
                            directOn ? _DirectChannelRow(comm: comm, d: direct!, selected: to.kind == TalkTo.direct) : null,
                      ),
                      if (m?.denied case final why?)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(why, style: const TextStyle(color: Kc.softRed, fontSize: 13)),
                        ),
                      const SectionHeader('People'),
                      if (people.isEmpty && away == null)
                        const Panel(children: [PanelRow(title: 'Nobody else yet')])
                      else
                        Panel(children: [
                          for (final p in people)
                            _PersonRow(comm: comm, person: p, selected: to.kind == TalkTo.person && to.personId == p.id),
                          if (away != null) _AwayRow(comm: comm, id: away.id, name: away.name),
                        ]),
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                            comm.boardTalksTo
                                ? 'Tap a channel or someone to talk to them; their picture for more'
                                : "Tap someone for more. To talk to one person alone, update the unit's firmware",
                            style: const TextStyle(color: Kc.muted, fontSize: 13)),
                      ),
                    ],
                  ],
                ),
              ),
              _Dock(comm: comm, boardUp: boardUp),
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

/// A row to talk to: pink, with a mic, while it's the one talked to.
class _TalkRow extends StatelessWidget {
  final Widget leading;
  final String title;
  final Widget? titleExtra;
  final String subtitle;
  final bool subtitleLit;
  final bool selected;
  final bool enabled;
  final String semantics;
  final VoidCallback? onTap;
  final List<Widget> trailing;
  const _TalkRow(
      {required this.leading,
      required this.title,
      this.titleExtra,
      required this.subtitle,
      this.subtitleLit = false,
      required this.selected,
      this.enabled = true,
      required this.semantics,
      this.onTap,
      this.trailing = const []});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: selected ? Kc.pink : Colors.transparent, width: 3)),
        color: selected ? Kc.pink.withValues(alpha: 0.08) : null,
      ),
      child: Row(children: [
        Expanded(
          child: InkWell(
            onTap: onTap,
            child: Semantics(
              button: onTap != null,
              selected: selected,
              label: semantics,
              excludeSemantics: true,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(13, 8, 8, 8),
                child: Row(children: [
                  leading,
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Flexible(
                            child: Text(title,
                                style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    color: selected ? Kc.pink : enabled ? null : Kc.muted)),
                          ),
                          ?titleExtra,
                        ]),
                        Text(subtitle,
                            style: subtitleLit
                                ? Kc.term(14, color: Kc.green)
                                : const TextStyle(color: Kc.muted, fontSize: 13)),
                      ],
                    ),
                  ),
                  if (selected) const Icon(Icons.mic, color: Kc.pink, size: 20, semanticLabel: 'Talking to'),
                ]),
              ),
            ),
          ),
        ),
        ...trailing,
      ]),
    );
  }
}

/// Who's talking among these, for a channel's row: not those talking to
/// us alone, who aren't talking on it.
String? _talkersIn(CommController comm, Iterable<int> sessions) {
  final names = [
    for (final s in sessions)
      if (comm.talking.contains(s) && !comm.talkingToUs.contains(s)) comm.talkerName(s)
  ];
  return names.isEmpty ? null : '${names.join(', ')} TALKING';
}

/// Our channel on the server: tap to talk to it.
class _ServerChannelRow extends StatelessWidget {
  final CommController comm;
  final MumbleClient m;
  final bool selected;
  const _ServerChannelRow({required this.comm, required this.m, required this.selected});

  @override
  Widget build(BuildContext context) {
    final name = m.channelPath(m.myChannel);
    final n = m.channelUsers.length;
    final talking = _talkersIn(comm, [for (final u in m.channelUsers) u.session]);
    final status = talking ?? (n == 0 ? 'Server · nobody else here' : 'Server · $n here');
    return _TalkRow(
      leading: const Icon(Icons.cloud_outlined, color: Kc.green),
      title: name,
      subtitle: status,
      subtitleLit: talking != null,
      selected: selected,
      semantics: '$name, on the server, $status${selected ? ', talking to it' : ''}',
      onTap: () => comm.setTalkTo(const TalkTarget.server()),
    );
  }
}

/// Our direct channel: tap to talk to it.
class _DirectChannelRow extends StatelessWidget {
  final CommController comm;
  final DirectSettings d;
  final bool selected;
  const _DirectChannelRow({required this.comm, required this.d, required this.selected});

  @override
  Widget build(BuildContext context) {
    final name = directChannelName(d);
    final n = comm.nearby.length;
    final talking = _talkersIn(comm, [for (final b in comm.nearby.values) CommController.directSession(b.id)]);
    final status = talking ?? (n == 0 ? 'Direct · nobody nearby' : 'Direct · $n nearby');
    return _TalkRow(
      leading: const Icon(Icons.settings_input_antenna, color: Kc.green),
      title: name,
      subtitle: status,
      subtitleLit: talking != null,
      selected: selected,
      semantics: '$name, direct, $status${selected ? ', talking to it' : ''}',
      onTap: () => comm.setTalkTo(const TalkTarget.direct()),
    );
  }
}

class _PersonRow extends StatelessWidget {
  final CommController comm;
  final Person person;
  final bool selected;
  const _PersonRow({required this.comm, required this.person, required this.selected});

  @override
  Widget build(BuildContext context) {
    final p = person;
    final talking = p.talking && !p.mutedByMe;
    final sessions = [?p.user?.session, if (p.board != null) CommController.directSession(p.board!.id)];
    final toUs = talking && sessions.any(comm.talkingToUs.contains);
    final ways = [if (p.onServer) 'Server', if (p.board != null) 'Direct'].join(' · ');
    final status = p.mutedByMe
        ? 'Muted by you'
        : toUs
            ? 'TALKING TO YOU'
            : talking
                ? 'TALKING'
                : p.user?.muted ?? false
                    ? 'Muted · $ways'
                    : ways;
    final canTalkTo = comm.boardTalksTo;
    return _TalkRow(
      leading: GestureDetector(
        onTap: () => showPerson(context, comm, id: p.id),
        child: DroneAvatar(picture: p.picture, talking: talking),
      ),
      title: p.name,
      titleExtra: comm.nameClash(p.who) == null
          ? null
          : const Padding(
              padding: EdgeInsets.only(left: 6),
              child: Icon(Icons.warning_amber, size: 16, color: Kc.softRed, semanticLabel: 'Not the one known by that name'),
            ),
      subtitle: status,
      subtitleLit: talking,
      selected: selected,
      semantics: '${p.name}, $status${selected ? ', talking to them' : ''}',
      onTap: canTalkTo ? () => comm.setTalkTo(TalkTarget.person(p.id)) : () => showPerson(context, comm, id: p.id),
      trailing: [
        if (p.board != null) SignalBars(p.board!.rssi),
        IconButton(
          tooltip: p.mutedByMe ? 'Hear ${p.name}' : 'Mute ${p.name}, here only',
          icon: Icon(p.mutedByMe ? Icons.volume_off : Icons.volume_up, color: p.mutedByMe ? Kc.softRed : Kc.muted),
          onPressed: () => comm.setMuted(p.id, !p.mutedByMe),
        ),
        const SizedBox(width: 4),
      ],
    );
  }
}

/// The one talked to, while they're out of reach: still picked, so talking
/// goes to them again once they're back, and to nobody else meanwhile.
class _AwayRow extends StatelessWidget {
  final CommController comm;
  final String id;
  final String name;
  const _AwayRow({required this.comm, required this.id, required this.name});

  @override
  Widget build(BuildContext context) {
    return _TalkRow(
      leading: GestureDetector(
        onTap: () => showPerson(context, comm, id: id),
        child: const DroneAvatar(picture: null),
      ),
      title: name,
      subtitle: 'Out of reach',
      selected: true,
      enabled: false,
      semantics: '$name, out of reach, talking to them',
    );
  }
}

/// Who talking goes to, and the talk button, at the foot of the screen.
class _Dock extends StatelessWidget {
  final CommController comm;
  final bool boardUp;
  const _Dock({required this.comm, required this.boardUp});

  @override
  Widget build(BuildContext context) {
    final route = comm.talkRoute;
    final to = comm.talkTo;
    final name = comm.talkToName;
    final person = to.kind == TalkTo.person && comm.boardTalksTo;
    final String note;
    if (!boardUp) {
      note = 'Connect the unit to talk';
    } else if (route == null) {
      note = person ? "$name can't hear you just now" : 'Nobody to hear you on $name just now';
    } else {
      final how = route == TalkRoute.direct ? 'direct' : 'over the server';
      note = person ? 'Talking to $name alone, $how' : 'Talking to $name';
    }
    final mode = comm.board.status?.mode;
    return Container(
      decoration: const BoxDecoration(color: Kc.dock, border: Border(top: BorderSide(color: Kc.line))),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(note,
              textAlign: TextAlign.center,
              style: TextStyle(color: boardUp && route == null ? Kc.softRed : Kc.muted, fontSize: 13)),
          const SizedBox(height: 10),
          // Grey while nobody would hear; it still talks, for the board to
          // say no, and the tone with it
          _TalkButton(comm: comm, enabled: boardUp, heard: route != null),
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
  final bool enabled;     // a board to talk through
  final bool heard;       // and someone who'd hear
  const _TalkButton({required this.comm, required this.enabled, required this.heard});

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
    final lit = enabled && widget.heard;
    final sending = enabled && (widget.comm.board.status?.sending ?? false);
    final fg = !lit
        ? Kc.off
        : sending
            ? Kc.bg
            : Kc.pink;
    return Semantics(
      button: true,
      enabled: enabled,
      label: sending
          ? 'Talking'
          : lit
              ? 'Hold to talk'
              : 'Hold to talk. Nobody would hear you just now',
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
            border: Border.all(color: lit ? Kc.pink : Kc.line, width: 2),
            boxShadow: sending ? [BoxShadow(color: Kc.pink.withValues(alpha: 0.6), blurRadius: 42)] : null,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(sending ? Icons.mic : lit ? Icons.mic_none : Icons.mic_off, size: 40, color: fg),
              const SizedBox(height: 4),
              Text(
                  !enabled
                      ? 'OFFLINE'
                      : sending
                          ? 'TALKING'
                          : lit
                              ? 'HOLD TO\nTALK'
                              : 'NOBODY\nTO HEAR',
                  textAlign: TextAlign.center,
                  style: Kc.term(14, color: fg)),
            ],
          ),
        ),
      ),
    );
  }
}
