import 'package:flutter/material.dart';

import '../comm/board_link.dart';
import '../comm/comm_controller.dart';
import '../comm/mumble_client.dart';
import 'server_page.dart';
import 'setup_page.dart';
import 'theme.dart';
import 'widgets.dart';

/// The links at a glance, on every tab: the board, the server and direct
/// comms, what's going out and coming in, and the board's battery. Tapping it
/// opens [showLinks].
class StatusStrip extends StatelessWidget {
  final CommController comm;
  const StatusStrip({super.key, required this.comm});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: comm,
      builder: (context, _) {
        final l = Links.of(comm);
        final st = comm.board.status;
        Widget item(bool ok, String text) => Row(mainAxisSize: MainAxisSize.min, children: [
              _Dot(ok),
              const SizedBox(width: 6),
              Text(text, style: Kc.term(14, color: ok ? Kc.text : Kc.dim)),
            ]);
        return Semantics(
          button: true,
          label: 'Links: ${l.summary}. Tap to connect or disconnect',
          excludeSemantics: true,
          child: Material(
            color: Kc.dock,
            child: InkWell(
              onTap: () => showLinks(context, comm),
              child: Container(
                height: 34,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Kc.line))),
                child: Row(children: [
                  item(l.board, 'BOARD'),
                  const SizedBox(width: 12),
                  item(l.server, 'SERVER'),
                  const SizedBox(width: 12),
                  item(l.direct, l.direct && l.nearby > 0 ? 'DIRECT ${l.nearby}' : 'DIRECT'),
                  const Spacer(),
                  _Arrow(up: true, color: l.sending ? Kc.pink : Kc.off),
                  _Arrow(up: false, color: l.hearing ? Kc.green : l.otherVoice ? Kc.otherAir : Kc.off),
                  if (l.board && st?.battery != null) ...[
                    const SizedBox(width: 12),
                    _Battery(st!.battery!, st.charging),
                  ],
                ]),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// How the links stand, for the strip and the sheet.
class Links {
  final bool board, server, direct, sending, hearing, otherVoice;
  final int nearby;
  const Links(this.board, this.server, this.direct, this.nearby, this.sending, this.hearing, this.otherVoice);

  static Links of(CommController comm) {
    final board = comm.board.state == BoardState.connected && comm.board.status != null;
    final server = comm.mumble?.state == MumbleState.connected;
    final direct = board && (comm.boardSettings?.direct?.on ?? false);
    final st = comm.board.status;
    final hearing = comm.talking.isNotEmpty || (direct && comm.nearby.values.any((b) => b.talking));
    return Links(board, server, direct, direct ? comm.nearby.length : 0, board && (st?.sending ?? false), hearing,
        direct && (st?.otherVoice ?? false));
  }

  String get summary => [
        'board ${board ? 'connected' : 'not connected'}',
        'server ${server ? 'connected' : 'not connected'}',
        'direct ${direct ? 'on' : 'off'}',
        if (sending) 'sending',
        if (hearing) 'hearing voice',
        if (!hearing && otherVoice) 'voice on another channel nearby',
      ].join(', ');
}

class _Dot extends StatelessWidget {
  final bool on;
  const _Dot(this.on);

  @override
  Widget build(BuildContext context) => Container(
        width: 9,
        height: 9,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: on ? Kc.green : Kc.off,
          boxShadow: on ? [BoxShadow(color: Kc.green.withValues(alpha: 0.8), blurRadius: 8)] : null,
        ),
      );
}

class _Arrow extends StatelessWidget {
  final bool up;
  final Color color;
  const _Arrow({required this.up, required this.color});

  @override
  Widget build(BuildContext context) => SizedBox(
      width: 13, height: 14, child: CustomPaint(painter: _ArrowPainter(up, color)));
}

class _ArrowPainter extends CustomPainter {
  final bool up;
  final Color color;
  _ArrowPainter(this.up, this.color);

  @override
  void paint(Canvas canvas, Size s) {
    final p = Path();
    if (up) {
      p
        ..moveTo(s.width / 2, 2)
        ..lineTo(s.width - 1, s.height - 3)
        ..lineTo(1, s.height - 3);
    } else {
      p
        ..moveTo(s.width / 2, s.height - 2)
        ..lineTo(1, 3)
        ..lineTo(s.width - 1, 3);
    }
    canvas.drawPath(p..close(), Paint()..color = color);
  }

  @override
  bool shouldRepaint(_ArrowPainter old) => old.color != color || old.up != up;
}

class _Battery extends StatelessWidget {
  final int percent;
  final bool charging;
  const _Battery(this.percent, this.charging);

  @override
  Widget build(BuildContext context) {
    final color = percent <= 15 ? Kc.softRed : Kc.green;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: 22,
        height: 12,
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
            border: Border.all(color: color, width: 1.5), borderRadius: const BorderRadius.all(Radius.circular(2))),
        alignment: Alignment.centerLeft,
        child: FractionallySizedBox(widthFactor: percent.clamp(0, 100) / 100, child: Container(color: color)),
      ),
      Container(width: 2, height: 5, color: color),
      if (charging) const Icon(Icons.bolt, size: 14, color: Kc.green),
      const SizedBox(width: 4),
      Text('$percent%', style: Kc.term(14, color: color)),
    ]);
  }
}

/// The links, to connect and disconnect: the board, the server, direct comms;
/// and what the traffic arrows mean.
Future<void> showLinks(BuildContext context, CommController comm) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheet) => ListenableBuilder(
        listenable: comm,
        builder: (sheet, _) {
          final b = comm.board;
          final l = Links.of(comm);
          final s = comm.server;
          final direct = comm.boardSettings?.direct;
          final certChanged = (comm.serverError ?? '').contains('certificate');
          Widget arrowRow(bool up, Color c, String text) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(children: [
                  _Arrow(up: up, color: c),
                  const SizedBox(width: 10),
                  Text(text, style: const TextStyle(color: Kc.muted, fontSize: 13)),
                ]),
              );
          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SectionHeader('Links'),
                  Panel(color: Kc.bg, children: [
                    PanelRow(
                      leading: _Dot(l.board),
                      title: b.name ?? 'Board',
                      subtitle: boardStatusText(comm),
                      trailing: [
                        b.state == BoardState.off || b.state == BoardState.scanning
                            ? FilledButton(onPressed: () => pickBoard(context, comm), child: const Text('Find'))
                            : OutlinedButton(onPressed: comm.disconnectBoard, child: const Text('Disconnect')),
                      ],
                    ),
                    PanelRow(
                      leading: _Dot(l.server),
                      title: s.host.isEmpty ? 'Server' : s.host,
                      subtitle: serverStatusText(comm),
                      trailing: [
                        !s.complete
                            ? FilledButton(
                                onPressed: () => Navigator.of(context)
                                    .push(MaterialPageRoute(builder: (_) => ServerPage(comm: comm))),
                                child: const Text('Set up'))
                            : comm.serverWanted
                                ? OutlinedButton(onPressed: comm.disconnectServer, child: const Text('Disconnect'))
                                : FilledButton(onPressed: comm.connectServer, child: const Text('Connect')),
                      ],
                    ),
                    if (certChanged)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton(
                            onPressed: () => trustNewCertificate(context, comm),
                            child: const Text('Trust the new certificate'),
                          ),
                        ),
                      ),
                    PanelRow(
                      leading: _Dot(l.direct),
                      title: 'Direct',
                      subtitle: direct == null
                          ? 'Needs the board'
                          : !direct.on
                              ? 'Off'
                              : '${directChannelName(direct)} · ${l.nearby} nearby',
                      trailing: [
                        Switch(value: direct?.on ?? false, onChanged: direct == null ? null : comm.setDirect),
                      ],
                    ),
                  ]),
                  const SectionHeader('Traffic'),
                  Panel(color: Kc.bg, children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Column(children: [
                        arrowRow(true, Kc.pink, 'Sending your voice'),
                        arrowRow(false, Kc.green, 'Voice on your channel, heard'),
                        arrowRow(false, Kc.otherAir, 'Voice on another channel nearby, not heard'),
                      ]),
                    ),
                  ]),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: () {
                      Navigator.pop(sheet);
                      Navigator.of(context).push(MaterialPageRoute(builder: (_) => SetupPage(comm: comm)));
                    },
                    child: const Text('Open Setup'),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );

/// A direct comms channel's name, as shown.
String directChannelName(DirectSettings d) => d.keyed ? d.group : 'Open channel';

String boardStatusText(CommController comm) {
  final b = comm.board;
  final st = b.status;
  switch (b.state) {
    case BoardState.off:
    case BoardState.scanning:
      return b.error ?? "Not connected. Switch on the Phone App in the board's Settings";
    case BoardState.connecting:
      return b.error == null ? 'Connecting...' : '${b.error}. Trying again...';
    case BoardState.connected:
      return st == null
          ? 'Pairing: type in the code the board shows (Settings, Paired Phones, Pair a phone)'
          : [
              'Connected',
              if (st.buttonConnected) 'talk button linked',
            ].join(' · ');
  }
}

String serverStatusText(CommController comm) {
  final s = comm.server;
  if (!s.complete) return 'Not set up';
  if (comm.mumble?.state == MumbleState.connected) return 'Connected as ${s.username}';
  if (comm.serverWanted) return comm.serverError == null ? 'Connecting...' : '${comm.serverError}. Trying again...';
  return comm.serverError ?? 'Not connected';
}

/// Look for boards with the Phone App on, and connect to the one picked.
Future<void> pickBoard(BuildContext context, CommController comm) async {
  comm.board.scan();
  final picked = await showModalBottomSheet<FoundBoard>(
    context: context,
    builder: (context) => ListenableBuilder(
      listenable: comm.board,
      builder: (context, _) {
        final boards = comm.board.found.values.toList()..sort((a, b) => b.rssi.compareTo(a.rssi));
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SectionHeader('Boards nearby'),
                const Text('Those with the Phone App on. Looking...', style: TextStyle(color: Kc.muted, fontSize: 13)),
                if (comm.board.error != null) Text(comm.board.error!, style: const TextStyle(color: Kc.softRed)),
                const SizedBox(height: 8),
                if (boards.isNotEmpty)
                  Panel(color: Kc.bg, children: [
                    for (final f in boards)
                      PanelRow(
                        leading: const Icon(Icons.bluetooth, color: Kc.muted),
                        title: f.name,
                        subtitle: f.id == comm.lastBoardId ? 'Yours, last time' : 'Signal ${f.rssi} dBm',
                        onTap: () => Navigator.pop(context, f),
                      ),
                  ]),
              ],
            ),
          ),
        );
      },
    ),
  );
  await comm.board.stopScan();
  if (picked != null) await comm.connectBoard(picked.id, picked.name);
}

/// The server's certificate changed: ask before trusting the new one.
Future<void> trustNewCertificate(BuildContext context, CommController comm) async {
  final ok = await showDialog<bool>(
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
  if (ok == true) {
    await comm.forgetCertificate();
    await comm.connectServer();
  }
}
