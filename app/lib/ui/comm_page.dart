import 'package:flutter/material.dart';

import '../comm/board_link.dart';
import '../comm/board_protocol.dart';
import '../comm/comm_controller.dart';
import '../comm/mumble_client.dart';
import 'groups_page.dart';
import 'server_page.dart';
import 'settings_page.dart';

/// The comm channel at a glance: what's connected, talking, and who's about.
/// What's set once is in [CommSettingsPage], behind the gear.
class CommPage extends StatelessWidget {
  final CommController comm;
  const CommPage({super.key, required this.comm});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: comm,
      builder: (context, _) {
        final direct = comm.boardSettings?.direct;
        return Scaffold(
          appBar: AppBar(
            title: const Text('DroneLab Comm'),
            actions: [
              IconButton(
                tooltip: 'Settings',
                icon: const Icon(Icons.settings),
                onPressed: () => Navigator.of(context)
                    .push(MaterialPageRoute(builder: (_) => CommSettingsPage(comm: comm))),
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _LinksCard(comm: comm),
              const SizedBox(height: 16),
              if (direct != null && comm.board.state == BoardState.connected) ...[
                _TalkOn(comm: comm),
                const SizedBox(height: 12),
              ],
              _TalkButton(comm: comm),
              if (comm.board.state == BoardState.connected && comm.mumble?.state == MumbleState.connected)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                      comm.headsetTalking
                          ? "Talking from the headphones' button: press it again to stop"
                          : "Or press the headphones' play/pause button to talk, and again to stop",
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall),
                ),
              const SizedBox(height: 16),
              _PeopleCard(comm: comm),
              if (direct != null && comm.board.state == BoardState.connected) ...[
                const SizedBox(height: 12),
                _DirectCard(comm: comm),
              ],
              if (comm.texts.isNotEmpty) ...[
                const SizedBox(height: 12),
                _MessagesCard(comm: comm),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// The board, the server and direct comms, one line each, with what to do
/// next.
class _LinksCard extends StatelessWidget {
  final CommController comm;
  const _LinksCard({required this.comm});

  @override
  Widget build(BuildContext context) {
    final b = comm.board;
    final st = b.status;
    final connected = b.state == BoardState.connected;

    String boardStatus;
    switch (b.state) {
      case BoardState.off:
      case BoardState.scanning:
        boardStatus = b.error ?? "Not connected. Switch on the Phone App in the board's Settings";
      case BoardState.connecting:
        boardStatus = b.error == null ? 'Connecting...' : '${b.error}. Trying again...';
      case BoardState.connected:
        boardStatus = st == null
            ? 'Pairing: type in the code the board shows. A new phone can only pair while the board '
                'says so: in its Settings, Paired Phones, tap Pair a phone'
            : [
                st.sending ? 'Sending your voice' : st.mode == BoardMode.voice ? 'Voice mode' : 'Push to talk',
                if (st.buttonConnected) 'talk button connected',
              ].join(', ');
    }

    final m = comm.mumble;
    final s = comm.server;
    String serverStatus;
    if (!s.complete) {
      serverStatus = 'Not set up yet';
    } else if (m?.state == MumbleState.connected) {
      serverStatus = 'Connected as ${s.username}';
    } else if (comm.serverWanted) {
      serverStatus = comm.serverError == null ? 'Connecting...' : '${comm.serverError}. Trying again...';
    } else {
      serverStatus = comm.serverError ?? 'Not connected';
    }
    final certChanged = (comm.serverError ?? '').contains('certificate');

    return Card(
      child: Column(
        children: [
          ListTile(
            leading: Icon(connected ? Icons.bluetooth_connected : Icons.bluetooth),
            title: Text(b.name ?? 'Board'),
            subtitle: Text(boardStatus),
            trailing: b.state == BoardState.off || b.state == BoardState.scanning
                ? FilledButton(onPressed: () => _pickBoard(context), child: const Text('Find'))
                : TextButton(onPressed: comm.disconnectBoard, child: const Text('Disconnect')),
          ),
          const Divider(height: 1),
          ListTile(
            leading: Icon(m?.state == MumbleState.connected ? Icons.cloud_done : Icons.cloud_off),
            title: Text(s.host.isEmpty ? 'Server' : s.host),
            subtitle: Text(serverStatus),
            trailing: !s.complete
                ? FilledButton(
                    onPressed: () => Navigator.of(context)
                        .push(MaterialPageRoute(builder: (_) => ServerPage(comm: comm))),
                    child: const Text('Set up'))
                : comm.serverWanted
                    ? TextButton(onPressed: comm.disconnectServer, child: const Text('Disconnect'))
                    : FilledButton(onPressed: comm.connectServer, child: const Text('Connect')),
          ),
          if (certChanged)
            Padding(
              padding: const EdgeInsets.only(left: 72, bottom: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () async {
                    final ok = await _confirmNewCertificate(context);
                    if (ok == true) {
                      await comm.forgetCertificate();
                      await comm.connectServer();
                    }
                  },
                  child: const Text('Trust the new certificate'),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _pickBoard(BuildContext context) async {
    comm.board.scan();
    final picked = await showModalBottomSheet<FoundBoard>(
      context: context,
      builder: (context) => ListenableBuilder(
        listenable: comm.board,
        builder: (context, _) {
          final boards = comm.board.found.values.toList()..sort((a, b) => b.rssi.compareTo(a.rssi));
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const ListTile(title: Text('Boards with the Phone App on'), subtitle: Text('Looking...')),
                if (comm.board.error != null) ListTile(title: Text(comm.board.error!)),
                for (final f in boards)
                  ListTile(
                    leading: const Icon(Icons.bluetooth),
                    title: Text(f.name),
                    subtitle: Text(f.id == comm.lastBoardId ? 'Yours, last time' : 'Signal ${f.rssi} dBm'),
                    onTap: () => Navigator.pop(context, f),
                  ),
                const SizedBox(height: 16),
              ],
            ),
          );
        },
      ),
    );
    await comm.board.stopScan();
    if (picked != null) await comm.connectBoard(picked.id, picked.name);
  }

  Future<bool?> _confirmNewCertificate(BuildContext context) => showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('New certificate'),
          content: const Text("The server's certificate isn't the one it had before. That's expected if "
              'the server was set up again, but it could also be someone pretending to be the server. '
              'Trust it only if you know the server changed.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Trust it')),
          ],
        ),
      );
}

class _TalkButton extends StatefulWidget {
  final CommController comm;
  const _TalkButton({required this.comm});

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
    final enabled = widget.comm.board.state == BoardState.connected;
    final sending = widget.comm.board.status?.sending ?? false;
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Listener(
        onPointerDown: enabled ? (_) => _set(true) : null,
        onPointerUp: (_) => _set(false),
        onPointerCancel: (_) => _set(false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          width: 160,
          height: 160,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: !enabled
                ? scheme.surfaceContainerHighest
                : sending
                    ? scheme.primary
                    : scheme.primaryContainer,
            border: Border.all(color: sending ? scheme.onPrimary : Colors.transparent, width: 4),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(sending ? Icons.mic : Icons.mic_none,
                  size: 48, color: sending ? scheme.onPrimary : scheme.onPrimaryContainer),
              const SizedBox(height: 4),
              Text(sending ? 'Talking' : 'Hold to talk',
                  style: TextStyle(
                      fontWeight: FontWeight.bold, color: sending ? scheme.onPrimary : scheme.onPrimaryContainer)),
            ],
          ),
        ),
      ),
    );
  }
}

class _PeopleCard extends StatelessWidget {
  final CommController comm;
  const _PeopleCard({required this.comm});

  @override
  Widget build(BuildContext context) {
    final m = comm.mumble;
    if (m == null || m.state != MumbleState.connected) return const SizedBox.shrink();
    final users = m.channelUsers;
    final channel = m.channelPath(m.myChannel);
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            leading: const Icon(Icons.forum),
            title: Text(channel, style: Theme.of(context).textTheme.titleMedium),
            subtitle: m.denied != null ? Text(m.denied!) : null,
            trailing: m.channels.length > 1
                ? TextButton(onPressed: () => _pickChannel(context, m), child: const Text('Change'))
                : null,
          ),
          if (users.isEmpty) const ListTile(title: Text('Nobody else yet')),
          for (final u in users)
            ListTile(
              leading: Icon(comm.talking.contains(u.session)
                  ? Icons.record_voice_over
                  : u.muted
                      ? Icons.mic_off
                      : Icons.person),
              title: Text(u.name,
                  style: comm.talking.contains(u.session) ? const TextStyle(fontWeight: FontWeight.bold) : null),
              subtitle: comm.isMuted(u.name)
                  ? const Text('Muted by you')
                  : comm.talking.contains(u.session)
                      ? const Text('Talking')
                      : u.muted
                          ? const Text('Muted')
                          : null,
              trailing: IconButton(
                tooltip: comm.isMuted(u.name) ? 'Hear them' : 'Mute them, here only',
                icon: Icon(comm.isMuted(u.name) ? Icons.volume_off : Icons.volume_up),
                color: comm.isMuted(u.name) ? Theme.of(context).colorScheme.error : null,
                onPressed: () => comm.setMuted(u.name, !comm.isMuted(u.name)),
              ),
            ),
        ],
      ),
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
          children: [
            const ListTile(title: Text('Channels'), subtitle: Text('Only those in the same channel hear each other')),
            for (final id in ids)
              ListTile(
                leading: Icon(id == m.myChannel ? Icons.radio_button_checked : Icons.radio_button_unchecked),
                title: Text(m.channelPath(id)),
                trailing: Text('${counts[id] ?? 0}'),
                onTap: () => Navigator.pop(context, id),
              ),
          ],
        ),
      ),
    );
    if (picked != null && picked != m.myChannel) await comm.joinChannel(picked);
  }
}

/// Where talking goes: the server or direct comms, and when it's going the
/// other way, why.
class _TalkOn extends StatelessWidget {
  final CommController comm;
  const _TalkOn({required this.comm});

  @override
  Widget build(BuildContext context) {
    final chosen = comm.boardSettings!.talkOn;
    final now = comm.talkNow;
    final direct = comm.boardSettings!.direct!;
    final group = direct.keyed ? direct.group : 'the open group';
    final channel = comm.mumble?.channels[comm.mumble!.myChannel];
    String note;
    if (now == chosen) {
      note = now == CommController.talkDirect
          ? 'Talking to the boards nearby in $group'
          : 'Talking to the server${channel == null ? '' : ', in $channel'}';
    } else {
      note = now == CommController.talkDirect
          ? "Nobody's on the server, so talking to the boards nearby in $group"
          : "Nobody's nearby, so talking to the server${channel == null ? '' : ', in $channel'}";
    }
    return Column(
      children: [
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: CommController.talkServer, label: Text('Server'), icon: Icon(Icons.cloud)),
            ButtonSegment(
                value: CommController.talkDirect, label: Text('Direct'), icon: Icon(Icons.settings_input_antenna)),
          ],
          selected: {chosen},
          onSelectionChanged: (sel) => comm.setTalkOn(sel.first),
        ),
        const SizedBox(height: 6),
        Text(note,
            textAlign: TextAlign.center,
            style: now == chosen
                ? Theme.of(context).textTheme.bodySmall
                : Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.tertiary)),
      ],
    );
  }
}

/// Direct comms: on or off, the group, and the boards heard.
class _DirectCard extends StatelessWidget {
  final CommController comm;
  const _DirectCard({required this.comm});

  static IconData _signal(int rssi) => rssi > -60
      ? Icons.signal_cellular_4_bar
      : rssi > -75
          ? Icons.network_cell
          : Icons.signal_cellular_0_bar;

  @override
  Widget build(BuildContext context) {
    final direct = comm.boardSettings!.direct!;
    final boards = comm.nearby.values.toList()..sort((a, b) => b.rssi.compareTo(a.rssi));

    // The groups to pick from: the open group, those kept here, and those
    // heard nearby, each once
    final saved = comm.groups.toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final savedIds = {for (final g in saved) g.id};
    final heard = comm.heardGroups.values.where((h) => !savedIds.contains(h.id)).toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final current = !direct.keyed ? 'open' : 'group:${direct.id}';
    final known = current == 'open' || savedIds.contains(direct.id) || heard.any((h) => h.id == direct.id);
    Widget item(IconData icon, String text) => Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 18),
          const SizedBox(width: 8),
          Flexible(child: Text(text, overflow: TextOverflow.ellipsis)),
        ]);

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            secondary: const Icon(Icons.settings_input_antenna),
            title: Text('Direct', style: Theme.of(context).textTheme.titleMedium),
            subtitle: Text(!direct.on
                ? "Board to board, for where there's no signal"
                : boards.isEmpty
                    ? 'No boards heard yet'
                    : '${boards.length} ${boards.length == 1 ? 'board' : 'boards'} nearby'),
            value: direct.on,
            onChanged: comm.setDirect,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: DropdownButton<String>(
                    isExpanded: true,
                    value: current,
                    onChanged: (v) => _pick(context, v),
                    items: [
                      DropdownMenuItem(value: 'open', child: item(Icons.lock_open, 'Open group')),
                      for (final g in saved)
                        DropdownMenuItem(value: 'group:${g.id}', child: item(Icons.lock, g.name)),
                      for (final h in heard)
                        DropdownMenuItem(
                            value: 'group:${h.id}', child: item(Icons.lock_outline, '${h.name} (nearby, ${h.boards})')),
                      if (!known)
                        DropdownMenuItem(value: current, child: item(Icons.lock, direct.group)),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: () =>
                      Navigator.of(context).push(MaterialPageRoute(builder: (_) => GroupsPage(comm: comm))),
                  child: const Text('Manage'),
                ),
              ],
            ),
          ),
          if (direct.on)
            for (final b in boards)
              ListTile(
                leading: Icon(b.talking ? Icons.record_voice_over : _signal(b.rssi)),
                title: Text(b.name),
                subtitle: Text(comm.isMuted(b.name)
                    ? 'Muted by you'
                    : b.talking
                        ? 'Talking'
                        : '${b.rssi} dBm'),
                trailing: IconButton(
                  tooltip: comm.isMuted(b.name) ? 'Hear them' : 'Mute them, here only',
                  icon: Icon(comm.isMuted(b.name) ? Icons.volume_off : Icons.volume_up),
                  color: comm.isMuted(b.name) ? Theme.of(context).colorScheme.error : null,
                  onPressed: () => comm.setMuted(b.name, !comm.isMuted(b.name)),
                ),
              ),
        ],
      ),
    );
  }

  /// A group picked: the open group, one kept here, or one heard nearby,
  /// which needs its passphrase.
  Future<void> _pick(BuildContext context, String? value) async {
    if (value == null) return;
    if (value == 'open') {
      await comm.joinOpenGroup();
      return;
    }
    final id = value.substring('group:'.length);
    for (final g in comm.groups) {
      if (g.id == id) return joinSavedGroup(context, comm, g);
    }
    final h = comm.heardGroups[id];
    if (h != null) await joinHeardGroup(context, comm, h);
  }
}

class _MessagesCard extends StatelessWidget {
  final CommController comm;
  const _MessagesCard({required this.comm});

  static String _plain(String html) => html
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<[^>]*>'), '')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&amp;', '&')
      .trim();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(title: Text('Messages', style: Theme.of(context).textTheme.titleMedium)),
          for (final t in comm.texts.reversed.take(10))
            ListTile(title: Text(_plain(t.message)), subtitle: Text(t.from)),
        ],
      ),
    );
  }
}
