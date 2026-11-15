import 'package:flutter/material.dart';

import '../comm/board_link.dart';
import '../comm/board_protocol.dart';
import '../comm/comm_controller.dart';
import '../comm/mumble_client.dart';
import 'server_page.dart';

class CommPage extends StatelessWidget {
  final CommController comm;
  const CommPage({super.key, required this.comm});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: comm,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: const Text('DroneLab Comm'),
          actions: [
            IconButton(
              tooltip: 'Server',
              icon: const Icon(Icons.settings),
              onPressed: () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => ServerPage(comm: comm))),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _ServerCard(comm: comm),
            const SizedBox(height: 12),
            _BoardCard(comm: comm),
            const SizedBox(height: 12),
            _TalkButton(comm: comm),
            const SizedBox(height: 12),
            _PeopleCard(comm: comm),
            if (comm.texts.isNotEmpty) ...[
              const SizedBox(height: 12),
              _MessagesCard(comm: comm),
            ],
          ],
        ),
      ),
    );
  }
}

class _ServerCard extends StatelessWidget {
  final CommController comm;
  const _ServerCard({required this.comm});

  @override
  Widget build(BuildContext context) {
    final m = comm.mumble;
    final s = comm.server;
    String status;
    IconData icon;
    if (!s.complete) {
      status = 'Set up the server first';
      icon = Icons.cloud_off;
    } else if (m?.state == MumbleState.connected) {
      final n = m!.channelUsers.length;
      status = 'Connected as ${s.username}, ${n == 0 ? 'nobody else here' : n == 1 ? '1 other here' : '$n others here'}.\n'
          '${m.udpActive ? 'Voice over UDP' : 'Voice over TCP (UDP isn\'t getting through)'}';
      icon = Icons.cloud_done;
    } else if (comm.serverWanted) {
      status = comm.serverError == null ? 'Connecting...' : '${comm.serverError}. Trying again...';
      icon = Icons.cloud_sync;
    } else {
      status = comm.serverError ?? 'Not connected';
      icon = Icons.cloud_off;
    }
    final certChanged = (comm.serverError ?? '').contains('certificate');

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(icon),
              const SizedBox(width: 12),
              Expanded(
                child: Text(s.host.isEmpty ? 'Server' : '${s.host}:${s.port}',
                    style: Theme.of(context).textTheme.titleMedium),
              ),
            ]),
            const SizedBox(height: 8),
            Text(status),
            const SizedBox(height: 12),
            Wrap(spacing: 8, children: [
              if (!s.complete)
                FilledButton(
                  onPressed: () => Navigator.of(context)
                      .push(MaterialPageRoute(builder: (_) => ServerPage(comm: comm))),
                  child: const Text('Set up'),
                )
              else if (comm.serverWanted)
                OutlinedButton(onPressed: comm.disconnectServer, child: const Text('Disconnect'))
              else
                FilledButton(onPressed: comm.connectServer, child: const Text('Connect')),
              if (certChanged)
                TextButton(
                  onPressed: () async {
                    final ok = await _confirmNewCertificate(context);
                    if (ok == true) {
                      await comm.forgetCertificate();
                      await comm.connectServer();
                    }
                  },
                  child: const Text('Trust the new certificate'),
                ),
            ]),
          ],
        ),
      ),
    );
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

class _BoardCard extends StatelessWidget {
  final CommController comm;
  const _BoardCard({required this.comm});

  @override
  Widget build(BuildContext context) {
    final b = comm.board;
    final st = b.status;
    String status;
    switch (b.state) {
      case BoardState.off:
      case BoardState.scanning:
        status = b.error ?? 'Not connected. Switch Comm on in the board\'s Settings.';
      case BoardState.connecting:
        status = b.error == null ? 'Connecting...' : '${b.error}. Trying again...';
      case BoardState.connected:
        status = st == null
            ? 'Pairing: type in the code the board shows'
            : st.sending
                ? 'Sending your voice${comm.sendingToServer ? ' to the server' : ''}'
                : st.mode == BoardMode.voice
                    ? (st.hearsVoice ? 'Hears you' : 'Listening for your voice')
                    : 'Ready';
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(b.state == BoardState.connected ? Icons.bluetooth_connected : Icons.bluetooth),
              const SizedBox(width: 12),
              Expanded(
                child: Text(b.name ?? 'Board', style: Theme.of(context).textTheme.titleMedium),
              ),
            ]),
            const SizedBox(height: 8),
            Text(status),
            if (b.firmware != null) ...[
              const SizedBox(height: 4),
              Text('Firmware ${b.firmware}, app ${b.appVersion}',
                  style: Theme.of(context).textTheme.bodySmall),
            ],
            if (st != null && st.buttonConnected) ...[
              const SizedBox(height: 4),
              const Row(children: [
                Icon(Icons.radio_button_checked, size: 16),
                SizedBox(width: 6),
                Text('Talk button connected'),
              ]),
            ],
            if (b.state == BoardState.connected) ...[
              const SizedBox(height: 12),
              SegmentedButton<BoardMode>(
                segments: const [
                  ButtonSegment(value: BoardMode.pushToTalk, label: Text('Push to talk'), icon: Icon(Icons.touch_app)),
                  ButtonSegment(value: BoardMode.voice, label: Text('Voice'), icon: Icon(Icons.graphic_eq)),
                ],
                selected: {st?.mode ?? BoardMode.pushToTalk},
                onSelectionChanged: (sel) => b.setMode(sel.first),
              ),
            ],
            const SizedBox(height: 12),
            Wrap(spacing: 8, children: [
              if (b.state == BoardState.off || b.state == BoardState.scanning)
                FilledButton(
                  onPressed: () => _pickBoard(context),
                  child: const Text('Find the board'),
                )
              else
                OutlinedButton(onPressed: comm.disconnectBoard, child: const Text('Disconnect')),
            ]),
          ],
        ),
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
                const ListTile(title: Text('Boards with Comm on'), subtitle: Text('Looking...')),
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
    widget.comm.board.setTalk(held);
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
    final channel = m.channels[m.myChannel] ?? 'Channel';
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(title: Text(channel, style: Theme.of(context).textTheme.titleMedium)),
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
              subtitle: comm.talking.contains(u.session)
                  ? const Text('Talking')
                  : u.muted
                      ? const Text('Muted')
                      : null,
            ),
        ],
      ),
    );
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
