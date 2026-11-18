import 'package:flutter/material.dart';

import '../comm/board_link.dart';
import '../comm/board_protocol.dart';
import '../comm/comm_controller.dart';
import 'people.dart';
import 'theme.dart';
import 'widgets.dart';

/// Messages: those that come in, from others' apps and the server, and ours,
/// with a box to write more. A message goes to the others' displays too, or
/// only to their apps.
class TerminalPage extends StatefulWidget {
  final CommController comm;
  const TerminalPage({super.key, required this.comm});

  @override
  State<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends State<TerminalPage> {
  CommController get comm => widget.comm;
  final _text = TextEditingController();
  final _scroll = ScrollController();
  bool _named = true;
  bool _onDisplay = true;
  int _shown = 0;

  @override
  void dispose() {
    _text.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _send() {
    final text = _text.text.trim();
    if (text.isEmpty || !comm.canSendCommands) return;
    final named = _named, appOnly = !_onDisplay;
    final cmd = comm.newCommand((source, seq) => OthersCommand.sendMessage(source, seq, text, named: named, appOnly: appOnly));
    final to = recipients.describe(hivePeople(comm));
    comm.sendCommand(cmd,
        everyone: recipients.everyone, server: recipients.serverSessions, direct: recipients.directIds);
    comm.logSent(text, to, onDisplay: _onDisplay, named: _named);
    _text.clear();
  }

  static String _time(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([comm, appTab]),
      builder: (context, _) {
        final log = comm.terminal;
        // Seen while it's showing; and keep to the newest
        if (appTab.value == tabTerminal && comm.unread > 0) {
          WidgetsBinding.instance.addPostFrameCallback((_) => comm.markTerminalRead());
        }
        if (log.length != _shown) {
          _shown = log.length;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
          });
        }
        final canSend = comm.canSendCommands;
        final tooOld = comm.board.state == BoardState.connected &&
            (comm.board.status?.version ?? 0) < commVersionMessages;
        return Scaffold(
          appBar: AppBar(title: const Text('Terminal')),
          body: Column(
            children: [
              Expanded(
                child: log.isEmpty
                    ? Center(child: Text('NO MESSAGES YET', style: Kc.term(16, color: Kc.dim)))
                    : ListView.separated(
                        controller: _scroll,
                        padding: const EdgeInsets.all(16),
                        itemCount: log.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 12),
                        itemBuilder: (context, i) => _Entry(log[i], _time(log[i].time)),
                      ),
              ),
              Container(
                decoration: const BoxDecoration(color: Kc.dock, border: Border(top: BorderSide(color: Kc.line))),
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (!canSend)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 8),
                        child: Text('Connect to the server, or switch on Direct, to send messages',
                            style: TextStyle(color: Kc.muted, fontSize: 13)),
                      ),
                    if (tooOld)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 8),
                        child: Text("The board's firmware is too old to pass messages to this Terminal",
                            style: TextStyle(color: Kc.otherAir, fontSize: 13)),
                      ),
                    RecipientChips(comm: comm),
                    const SizedBox(height: 8),
                    Row(children: [
                      Expanded(
                        child: TextField(
                          controller: _text,
                          enabled: canSend,
                          maxLength: OthersCommand.messageMax,
                          textCapitalization: TextCapitalization.characters,
                          textInputAction: TextInputAction.send,
                          onSubmitted: (_) => _send(),
                          style: Kc.term(16, color: Kc.green),
                          decoration: const InputDecoration(
                            hintText: 'TYPE A MESSAGE',
                            counterText: '',
                            isDense: true,
                            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filled(
                        tooltip: 'Send',
                        onPressed: canSend ? _send : null,
                        icon: const Icon(Icons.send),
                        style: IconButton.styleFrom(
                            backgroundColor: Kc.pink, foregroundColor: Kc.bg, minimumSize: const Size(48, 48)),
                      ),
                    ]),
                    Explained(
                      help: "On: shown on their board's display and in their app. Off: only in their app's Terminal.",
                      helpPadding: const EdgeInsets.only(bottom: 4),
                      builder: (context, info) => Row(children: [
                        Expanded(
                          child: CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            controlAffinity: ListTileControlAffinity.leading,
                            title: const Text('Show on their display', style: TextStyle(fontSize: 14)),
                            value: _onDisplay,
                            onChanged: (v) => setState(() => _onDisplay = v ?? true),
                          ),
                        ),
                        info,
                      ]),
                    ),
                    Explained(
                      help: 'Off: message displays without your name. May be blocked by permissions.',
                      helpPadding: const EdgeInsets.only(bottom: 4),
                      builder: (context, info) => Row(children: [
                        const Expanded(child: Text('Show my name', style: TextStyle(fontSize: 14))),
                        info,
                        Switch(value: _named, onChanged: (on) => setState(() => _named = on)),
                      ]),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Entry extends StatelessWidget {
  final TerminalEntry e;
  final String time;
  const _Entry(this.e, this.time);

  @override
  Widget build(BuildContext context) {
    final who = e.mine
        ? 'YOU${e.named ? '' : ' (UNNAMED)'} → ${e.to}'
        : e.from.isEmpty
            ? 'UNNAMED'
            : e.from.toUpperCase();
    final color = e.mine ? Kc.pink : Kc.green;
    return Semantics(
      label: '$who at $time${e.onDisplay ? ', on display' : ', app only'}: ${e.text}',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Flexible(
              child: Text('$who · $time',
                  overflow: TextOverflow.ellipsis, style: const TextStyle(color: Kc.dim, fontSize: 12)),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(border: Border.all(color: e.onDisplay ? Kc.darkGreen : Kc.line)),
              child: Text(e.onDisplay ? 'ON DISPLAY' : 'APP ONLY',
                  style: Kc.term(10, color: e.onDisplay ? Kc.green : Kc.muted)),
            ),
          ]),
          const SizedBox(height: 4),
          Text(e.text, style: Kc.term(16, color: color, shadows: Kc.glow(color))),
        ],
      ),
    );
  }
}
