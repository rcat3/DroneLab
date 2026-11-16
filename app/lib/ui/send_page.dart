import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../comm/board_link.dart';
import '../comm/board_protocol.dart';
import '../comm/comm_controller.dart';
import '../comm/mumble_client.dart';

/// Commands for others' boards, over the server and direct comms
/// (core/app/others.h): who to send them to, a message for their Terminal,
/// and their Lovense toys: Stop, a level for each kind of motor, patterns,
/// their speed, and reactions. Each board only does them if its wearer has
/// allowed us, on that feature's Others page.
class SendPage extends StatefulWidget {
  final CommController comm;
  const SendPage({super.key, required this.comm});

  @override
  State<SendPage> createState() => _SendPageState();
}

/// The motors, as OthersCommand's kinds.
const _kinds = [
  (OthersCommand.vibrate, 'Vibrate', Icons.vibration),
  (OthersCommand.rotate, 'Rotate', Icons.rotate_right),
  (OthersCommand.air, 'Pump', Icons.air),
  (OthersCommand.oscillate, 'Thrust', Icons.swap_vert),
];

/// The reactions, as reactive_mode_t: to the wearer's own voice or movement.
const _reactions = [(1, 'Voice'), (2, 'Moving'), (3, 'Still'), (4, 'Motion'), (5, 'Tilt')];

/// The board's built-in patterns, for when it can't be asked.
const _builtInPatterns = ['Wave', 'Pulse', 'Heartbeat', 'Climb', 'Surge', 'Wander'];

/// How often a level's sent while its slider's dragged: about as fast as
/// direct comms sends them (each three times, 100 ms apart), and well within
/// what Mumble servers pass on by default.
const _dragEvery = Duration(milliseconds: 300);

/// The last command's sent again this long after, in case it was lost.
const _againAfter = Duration(milliseconds: 1500);

class _SendPageState extends State<SendPage> {
  CommController get comm => widget.comm;

  bool _everyone = true;
  final Set<int> _server = {};   // sessions
  final Set<int> _direct = {};   // boards' ids

  final _message = TextEditingController();
  bool _named = true;
  final Map<int, double> _levels = {for (final k in _kinds) k.$1: 0};
  final Map<int, DateTime> _sentAt = {};
  int _speed = 100;
  String? _playing;
  int _reacting = 0;
  List<String> _patterns = _builtInPatterns;
  bool _askedPatterns = false;
  Timer? _again;

  @override
  void initState() {
    super.initState();
    comm.addListener(_onComm);
    _onComm();
  }

  @override
  void dispose() {
    comm.removeListener(_onComm);
    _again?.cancel();
    _message.dispose();
    super.dispose();
  }

  /// Ask the board for its patterns once it's connected: its own names,
  /// those on its card too.
  void _onComm() {
    final connected = comm.board.state == BoardState.connected && comm.board.status != null;
    if (connected && !_askedPatterns) {
      _askedPatterns = true;
      comm.board.request('GET', '/api/info').then((a) {
        if (a.status != 200 || !mounted) return;
        final names = (jsonDecode(a.body) as Map<String, dynamic>)['patterns'] as List<dynamic>?;
        if (names != null && names.isNotEmpty) setState(() => _patterns = [for (final n in names) n as String]);
      }).catchError((_) {});
    } else if (!connected) {
      _askedPatterns = false;
    }
  }

  void _send(OthersCommand Function(int source, int seq) make, {bool again = true}) {
    final cmd = comm.newCommand(make);
    final everyone = _everyone, server = _server.toList(), direct = _direct.toList();
    comm.sendCommand(cmd, everyone: everyone, server: server, direct: direct);
    _again?.cancel();
    if (again) {
      _again = Timer(_againAfter, () => comm.sendCommand(cmd, everyone: everyone, server: server, direct: direct));
    }
  }

  void _sendMessage() {
    final text = _message.text.trim();
    if (text.isEmpty) return;
    final named = _named;
    _send((source, seq) => OthersCommand.sendMessage(source, seq, text, named: named));
    _message.clear();
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Sent'), duration: Duration(seconds: 1)));
  }

  void _stop() {
    setState(() {
      for (final k in _levels.keys) {
        _levels[k] = 0;
      }
      _playing = null;
      _reacting = 0;
    });
    _send(OthersCommand.stopAll);
  }

  void _level(int kind, double v, {required bool done}) {
    setState(() => _levels[kind] = v);
    final now = DateTime.now();
    final last = _sentAt[kind];
    if (!done && last != null && now.difference(last) < _dragEvery) return;
    _sentAt[kind] = now;
    _send((source, seq) => OthersCommand.setLevel(source, seq, kind, v.round()), again: done);
  }

  void _play(String? name) {
    setState(() => _playing = name);
    _send((source, seq) => OthersCommand.play(source, seq, name));
  }

  void _react(int mode) {
    setState(() => _reacting = mode);
    _send((source, seq) => OthersCommand.setReact(source, seq, mode));
  }

  void _setSpeed(int percent) {
    setState(() => _speed = percent.clamp(25, 300));
    _send((source, seq) => OthersCommand.setSpeed(source, seq, _speed));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: comm,
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;
        final small = Theme.of(context).textTheme.bodySmall;
        final m = comm.mumble;
        final serverPeople = m != null && m.state == MumbleState.connected ? m.channelUsers : const <MumbleUser>[];
        final directOn = comm.boardTakesCommands && (comm.boardSettings?.direct?.on ?? false);
        final directPeople =
            directOn ? (comm.nearby.values.toList()..sort((a, b) => a.name.compareTo(b.name))) : <NearbyBoard>[];
        // Forget those who've gone
        _server.retainWhere((s) => serverPeople.any((u) => u.session == s));
        _direct.retainWhere((id) => directPeople.any((b) => b.id == id));
        if (_server.isEmpty && _direct.isEmpty) _everyone = true;
        final canSend = comm.canSendCommands;
        final title = Theme.of(context).textTheme.titleSmall?.copyWith(color: scheme.primary);
        final line = Padding(
          padding: const EdgeInsets.only(top: 20),
          child: Divider(height: 1, color: scheme.outlineVariant),
        );
        Widget header(IconData icon, String text) => Padding(
              padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
              child: Row(children: [
                Icon(icon, size: 18, color: scheme.primary),
                const SizedBox(width: 8),
                Text(text, style: title),
              ]),
            );

        return Scaffold(
          appBar: AppBar(title: const Text('Send to Others')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (!canSend)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.info_outline),
                    title: const Text('Connect to the server, or turn on direct comms, to send to others'),
                    subtitle: comm.board.state == BoardState.connected && !comm.boardTakesCommands
                        ? const Text('Direct comms needs newer firmware on the board for this')
                        : null,
                  ),
                ),
              header(Icons.group, 'Send to'),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilterChip(
                    label: const Text('Everyone'),
                    selected: _everyone,
                    onSelected: (on) => setState(() {
                      _everyone = on;
                      if (on) {
                        _server.clear();
                        _direct.clear();
                      }
                    }),
                  ),
                  for (final u in serverPeople)
                    FilterChip(
                      avatar: const Icon(Icons.cloud, size: 18),
                      label: Text(u.name),
                      selected: _server.contains(u.session),
                      onSelected: (on) => setState(() {
                        on ? _server.add(u.session) : _server.remove(u.session);
                        _everyone = _server.isEmpty && _direct.isEmpty;
                      }),
                    ),
                  for (final b in directPeople)
                    FilterChip(
                      avatar: const Icon(Icons.settings_input_antenna, size: 18),
                      label: Text(b.name),
                      selected: _direct.contains(b.id),
                      onSelected: (on) => setState(() {
                        on ? _direct.add(b.id) : _direct.remove(b.id);
                        _everyone = _server.isEmpty && _direct.isEmpty;
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                  _everyone
                      ? "Everyone in your server channel and your direct comms group. Only those who've allowed you "
                          'on their board get them'
                      : "Only those who've allowed you on their board get them",
                  style: small),
              line,
              header(Icons.terminal, 'Message'),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _message,
                      enabled: canSend,
                      maxLength: OthersCommand.messageMax,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _sendMessage(),
                      decoration: const InputDecoration(hintText: 'For their Terminal', counterText: ''),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                      onPressed: canSend ? _sendMessage : null, tooltip: 'Send', icon: const Icon(Icons.send)),
                ],
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('Show my name'),
                subtitle: Text(_named
                    ? "Shown on their display's Terminal, after your name"
                    : "Shown on their display's Terminal without your name, unless they've chosen not to show "
                        "unnamed ones. It still only goes to those who've allowed you"),
                value: _named,
                onChanged: (on) => setState(() => _named = on),
              ),
              line,
              header(Icons.vibration, 'Toys'),
              SizedBox(
                height: 64,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: scheme.error, foregroundColor: scheme.onError),
                  onPressed: canSend ? _stop : null,
                  icon: const Icon(Icons.stop_circle, size: 32),
                  label: const Text('STOP', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                ),
              ),
              const SizedBox(height: 12),
              for (final (kind, name, icon) in _kinds)
                Row(
                  children: [
                    Icon(icon, size: 20),
                    const SizedBox(width: 8),
                    SizedBox(width: 64, child: Text(name)),
                    Expanded(
                      child: Slider(
                        value: _levels[kind]!,
                        max: OthersCommand.levelTop.toDouble(),
                        divisions: OthersCommand.levelTop,
                        label: '${_levels[kind]!.round()}',
                        onChanged: canSend ? (v) => _level(kind, v, done: false) : null,
                        onChangeEnd: canSend ? (v) => _level(kind, v, done: true) : null,
                      ),
                    ),
                    SizedBox(width: 28, child: Text('${_levels[kind]!.round()}', textAlign: TextAlign.end)),
                  ],
                ),
              Text('Each toy runs the motors it has, scaled to its own range', style: small),
              header(Icons.waves, 'Patterns'),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final p in _patterns)
                    ChoiceChip(
                      label: Text(p),
                      selected: _playing == p,
                      onSelected: canSend ? (on) => _play(on ? p : null) : null,
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton.outlined(
                      onPressed: canSend && _speed > 25 ? () => _setSpeed(_speed - 25) : null,
                      icon: const Icon(Icons.remove)),
                  SizedBox(width: 120, child: Text('Speed $_speed%', textAlign: TextAlign.center)),
                  IconButton.outlined(
                      onPressed: canSend && _speed < 300 ? () => _setSpeed(_speed + 25) : null,
                      icon: const Icon(Icons.add)),
                ],
              ),
              Text('Played on all their toys, if their board has a pattern by that name', style: small),
              header(Icons.sensors, 'React to'),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final (mode, name) in _reactions)
                    ChoiceChip(
                      label: Text(name),
                      selected: _reacting == mode,
                      onSelected: canSend ? (on) => _react(on ? mode : 0) : null,
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text("Their toys follow their own voice or movement, if their board can sense it. "
                  'The levels above set how high it goes', style: small),
              const SizedBox(height: 24),
            ],
          ),
        );
      },
    );
  }
}
