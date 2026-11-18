import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../comm/board_link.dart';
import '../comm/board_protocol.dart';
import '../comm/comm_controller.dart';
import 'people.dart';
import 'theme.dart';
import 'widgets.dart';

/// Others' Lovense toys, over the server and direct comms
/// (core/app/others.h): who to send to, a level for each kind of motor,
/// patterns and their speed, and reactions; and STOP, always in reach. Each
/// board only does them if its wearer has allowed us, on that feature's
/// Others page.
class ControlPage extends StatefulWidget {
  final CommController comm;
  const ControlPage({super.key, required this.comm});

  @override
  State<ControlPage> createState() => _ControlPageState();
}

/// The motors, as OthersCommand's kinds.
const _kinds = [
  (OthersCommand.vibrate, 'VIBRATE'),
  (OthersCommand.rotate, 'ROTATE'),
  (OthersCommand.air, 'PUMP'),
  (OthersCommand.oscillate, 'THRUST'),
];

/// The reactions, as reactive_mode_t: to the wearer's own voice or movement.
const _reactions = [(1, 'VOICE'), (2, 'MOVING'), (3, 'STILL'), (4, 'MOTION'), (5, 'TILT')];

/// The board's built-in patterns, for when it can't be asked.
const _builtInPatterns = ['Wave', 'Pulse', 'Heartbeat', 'Climb', 'Surge', 'Wander'];

/// How often a level's sent while its slider's dragged: about as fast as
/// direct comms sends them (each three times, 100 ms apart), and well within
/// what Mumble servers pass on by default.
const _dragEvery = Duration(milliseconds: 300);

/// The last command's sent again this long after, in case it was lost.
const _againAfter = Duration(milliseconds: 1500);

enum _Section { levels, patterns, react }

class _ControlPageState extends State<ControlPage> {
  CommController get comm => widget.comm;

  _Section _section = _Section.levels;
  final Map<int, double> _levels = {for (final k in _kinds) k.$1: 0};
  final Map<int, DateTime> _sentAt = {};
  int _speed = 100;
  String? _playing;
  int _reacting = 0;
  bool _stopped = false;
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
    final everyone = recipients.everyone, server = recipients.serverSessions, direct = recipients.directIds;
    comm.sendCommand(cmd, everyone: everyone, server: server, direct: direct);
    _again?.cancel();
    if (again) {
      _again = Timer(_againAfter, () => comm.sendCommand(cmd, everyone: everyone, server: server, direct: direct));
    }
  }

  void _stop() {
    setState(() {
      for (final k in _levels.keys) {
        _levels[k] = 0;
      }
      _playing = null;
      _reacting = 0;
      _stopped = true;
    });
    _send(OthersCommand.stopAll);
  }

  void _level(int kind, double v, {required bool done}) {
    setState(() {
      _levels[kind] = v;
      _stopped = false;
    });
    final now = DateTime.now();
    final last = _sentAt[kind];
    if (!done && last != null && now.difference(last) < _dragEvery) return;
    _sentAt[kind] = now;
    _send((source, seq) => OthersCommand.setLevel(source, seq, kind, v.round()), again: done);
  }

  void _play(String? name) {
    setState(() {
      _playing = name;
      _stopped = false;
    });
    _send((source, seq) => OthersCommand.play(source, seq, name));
  }

  void _react(int mode) {
    setState(() {
      _reacting = mode;
      _stopped = false;
    });
    _send((source, seq) => OthersCommand.setReact(source, seq, mode));
  }

  void _setSpeed(int percent) {
    setState(() => _speed = percent.clamp(25, 300));
    _send((source, seq) => OthersCommand.setSpeed(source, seq, _speed));
  }

  Widget _chip(String label, bool selected, VoidCallback? onTap) => ChoiceChip(
        label: SizedBox(width: double.infinity, child: Text(label, textAlign: TextAlign.center)),
        labelStyle: Kc.term(16, color: selected ? Kc.pink : Kc.text),
        selected: selected,
        onSelected: onTap == null ? null : (_) => onTap(),
      );

  Widget _grid(int columns, List<Widget> children) => LayoutBuilder(
        builder: (context, box) {
          final w = (box.maxWidth - 8 * (columns - 1)) / columns;
          return Wrap(spacing: 8, runSpacing: 8, children: [for (final c in children) SizedBox(width: w, child: c)]);
        },
      );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: comm,
      builder: (context, _) {
        final canSend = comm.canSendCommands;
        const small = TextStyle(color: Kc.muted, fontSize: 13);
        return Scaffold(
          appBar: AppBar(title: const Text('Control')),
          body: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (!canSend)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(
                            comm.board.state == BoardState.connected && !comm.boardTakesCommands
                                ? 'Direct needs newer firmware on the board for this. Or connect to the server'
                                : 'Connect to the server, or switch on Direct, to control others',
                            style: small),
                      ),
                    Explained(
                      help: 'Recipient must permit for command to process.',
                      helpPadding: const EdgeInsets.only(bottom: 6),
                      builder: (context, info) => SectionHeader('Send to', trailing: info),
                    ),
                    RecipientChips(comm: comm),
                    const SizedBox(height: 10),
                    SegmentedButton<_Section>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(value: _Section.levels, label: Text('LEVELS')),
                        ButtonSegment(value: _Section.patterns, label: Text('PATTERNS')),
                        ButtonSegment(value: _Section.react, label: Text('REACT')),
                      ],
                      selected: {_section},
                      onSelectionChanged: (sel) => setState(() => _section = sel.first),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: switch (_section) {
                    _Section.levels => [
                        Panel(children: [
                          for (final (kind, name) in _kinds)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                              child: Row(children: [
                                SizedBox(width: 84, child: Text(name, style: Kc.term(16))),
                                Expanded(
                                  child: Slider(
                                    value: _levels[kind]!,
                                    max: OthersCommand.levelTop.toDouble(),
                                    divisions: OthersCommand.levelTop,
                                    label: '${_levels[kind]!.round()}',
                                    semanticFormatterCallback: (v) => '$name ${v.round()}',
                                    onChanged: canSend ? (v) => _level(kind, v, done: false) : null,
                                    onChangeEnd: canSend ? (v) => _level(kind, v, done: true) : null,
                                  ),
                                ),
                                SizedBox(
                                  width: 32,
                                  child: Text('${_levels[kind]!.round()}',
                                      textAlign: TextAlign.end, style: Kc.term(16, color: Kc.pink)),
                                ),
                              ]),
                            ),
                        ]),
                        Explained(
                          help: "Scaled to each toy's own range. The levels also set how high Patterns and React go.",
                          helpPadding: EdgeInsets.zero,
                          builder: (context, info) => Row(children: [
                            const Expanded(child: Text('Each toy runs the motors it has', style: small)),
                            info,
                          ]),
                        ),
                      ],
                    _Section.patterns => [
                        _grid(2, [
                          for (final p in _patterns)
                            _chip(p.toUpperCase(), _playing == p, canSend ? () => _play(_playing == p ? null : p) : null),
                        ]),
                        const SizedBox(height: 12),
                        Panel(children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              IconButton(
                                  tooltip: 'Slower',
                                  color: Kc.pink,
                                  onPressed: canSend && _speed > 25 ? () => _setSpeed(_speed - 25) : null,
                                  icon: const Icon(Icons.remove)),
                              SizedBox(
                                  width: 150,
                                  child: Text('SPEED $_speed%', textAlign: TextAlign.center, style: Kc.term(16))),
                              IconButton(
                                  tooltip: 'Faster',
                                  color: Kc.pink,
                                  onPressed: canSend && _speed < 300 ? () => _setSpeed(_speed + 25) : null,
                                  icon: const Icon(Icons.add)),
                            ],
                          ),
                        ]),
                        const SizedBox(height: 8),
                        const Text('Plays on their toys, if their board has it', style: small),
                      ],
                    _Section.react => [
                        _grid(3, [
                          for (final (mode, name) in _reactions)
                            _chip(name, _reacting == mode, canSend ? () => _react(_reacting == mode ? 0 : mode) : null),
                        ]),
                        const SizedBox(height: 8),
                        const Text('Their toys follow their own voice or movement', style: small),
                      ],
                  },
                ),
              ),
              StopBar(onPressed: canSend ? _stop : null, label: _stopped ? 'STOPPED' : 'STOP'),
            ],
          ),
        );
      },
    );
  }
}
