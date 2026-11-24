import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../comm/board_link.dart';
import '../comm/board_protocol.dart';
import '../comm/capabilities.dart';
import '../comm/comm_controller.dart';
import '../comm/conversations.dart';
import 'capabilities_ui.dart';
import 'theme.dart';
import 'widgets.dart';

/// HiveMind Control's Toys, for everyone in a conversation, over the server
/// and direct comms (core/app/others.h): a tab for each class of toy, Vibe
/// for now (E-stim and Machines to come), and STOP, always in reach below
/// them. Each board only does them as its wearer allows, on its
/// Permissions.
///
/// Vibe toys are run by channel, V1 to V6: everyone maps their own toys'
/// outputs to channels (Setup → Toys), so what V1 drives is up to them. A
/// level for each channel, or one for several together (ganged, sent as
/// one command); patterns and their speed; and reactions; each on the
/// channels picked.
class ToysPage extends StatefulWidget {
  final CommController comm;
  final Conversation target;
  const ToysPage({super.key, required this.comm, required this.target});

  @override
  State<ToysPage> createState() => _ToysPageState();
}

/// The reactions, as reactive_mode_t: to the wearer's own voice or movement.
const _reactions = [(1, 'VOICE'), (2, 'MOVING'), (3, 'STILL'), (4, 'MOTION'), (5, 'TILT')];

/// The board's built-in patterns, for when it can't be asked.
const _builtInPatterns = ['Wave', 'Pulse', 'Heartbeat', 'Climb', 'Surge', 'Wander'];

/// How many channels show to start with: the usual most. The rest come
/// with More, or by themselves when someone's toys follow them.
const _usualChannels = 4;

/// How often a level's sent while its slider's dragged: about as fast as
/// direct comms sends them (each three times, 100 ms apart), and well within
/// what Mumble servers pass on by default.
const _dragEvery = Duration(milliseconds: 300);

/// The last command's sent again this long after, in case it was lost.
const _againAfter = Duration(milliseconds: 1500);

enum _ToyClass { vibe, estim, machine }

enum _Section { levels, patterns, react }

class _ToysPageState extends State<ToysPage> {
  CommController get comm => widget.comm;

  _Section _section = _Section.levels;
  final List<double> _levels = List.filled(OthersCommand.vibeChannels, 0);
  final Map<int, DateTime> _sentAt = {};  // by the channels sent to
  bool _more = false;
  bool _gang = false;
  int _gangMask = 0x03;                   // V1 and V2
  int? _onMask;                           // what patterns and reactions go on; null for all shown
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

  /// For one person who's said: the channels their toys follow; 0 if not
  /// known (a group, or they haven't said).
  int get _theirs => capabilitiesOfConversation(comm, widget.target)?.vibeChannels ?? 0;

  /// How many channels show.
  int get _shown => _more || _theirs >> _usualChannels != 0 ? OthersCommand.vibeChannels : _usualChannels;
  int get _shownMask => (1 << _shown) - 1;

  /// What patterns and reactions go on.
  int get _on => (_onMask ?? _shownMask) & _shownMask;

  void _send(OthersCommand what, {bool again = true}) {
    final cmd = comm.newCommand(what);
    final target = widget.target;
    comm.sendCommandTo(target, cmd);
    _again?.cancel();
    if (again) {
      _again = Timer(_againAfter, () => comm.sendCommandTo(target, cmd, log: false));
    }
  }

  void _stop() {
    setState(() {
      _levels.fillRange(0, _levels.length, 0);
      _playing = null;
      _reacting = 0;
      _stopped = true;
    });
    _send(OthersCommand.stopAll());
  }

  /// A level for [mask]'s channels, together.
  void _level(int mask, double v, {required bool done}) {
    if (mask == 0) return;
    setState(() {
      for (var c = 0; c < OthersCommand.vibeChannels; c++) {
        if (mask & (1 << c) != 0) _levels[c] = v;
      }
      _stopped = false;
    });
    final now = DateTime.now();
    final last = _sentAt[mask];
    if (!done && last != null && now.difference(last) < _dragEvery) return;
    _sentAt[mask] = now;
    _send(OthersCommand.setLevel(mask, v.round()), again: done);
  }

  void _play(String? name) {
    setState(() {
      _playing = name;
      _stopped = false;
    });
    _send(OthersCommand.play(_on, name));
  }

  void _react(int mode) {
    setState(() {
      _reacting = mode;
      _stopped = false;
    });
    _send(OthersCommand.setReact(_on, mode));
  }

  void _setSpeed(int percent) {
    setState(() => _speed = percent.clamp(25, 300));
    _send(OthersCommand.setSpeed(_speed));
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

  /// A chip for each channel shown, to pick some of them.
  Widget _channelPicker(int mask, ValueChanged<int> onChanged, {required bool enabled}) => Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (var c = 0; c < _shown; c++)
            FilterChip(
              label: Text('V${c + 1}'),
              labelStyle: Kc.term(15, color: mask & (1 << c) != 0 ? Kc.pink : _unmapped(c) ? Kc.dim : Kc.text),
              showCheckmark: false,
              visualDensity: VisualDensity.compact,
              selected: mask & (1 << c) != 0,
              onSelected: enabled ? (on) => onChanged(on ? mask | (1 << c) : mask & ~(1 << c)) : null,
            ),
        ],
      );

  /// Whether we know nothing of theirs follows channel [c].
  bool _unmapped(int c) => _theirs != 0 && _theirs & (1 << c) == 0;

  Widget _slider(String name, double value, int mask, {required bool canSend, bool dim = false}) {
    final row = Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Row(children: [
        SizedBox(width: 84, child: Text(name, style: Kc.term(16))),
        Expanded(
          child: Slider(
            value: value,
            max: OthersCommand.levelTop.toDouble(),
            divisions: OthersCommand.levelTop,
            label: '${value.round()}',
            semanticFormatterCallback: (v) => '$name ${v.round()}',
            onChanged: canSend ? (v) => _level(mask, v, done: false) : null,
            onChangeEnd: canSend ? (v) => _level(mask, v, done: true) : null,
          ),
        ),
        SizedBox(
          width: 32,
          child: Text('${value.round()}', textAlign: TextAlign.end, style: Kc.term(16, color: Kc.pink)),
        ),
      ]),
    );
    return dim ? Opacity(opacity: 0.5, child: row) : row;
  }

  Widget _moreButton() => Align(
        alignment: Alignment.centerLeft,
        child: _theirs >> _usualChannels != 0
            ? const SizedBox.shrink()
            : TextButton(
                onPressed: () => setState(() => _more = !_more),
                child: Text(_more ? 'Fewer channels' : 'More channels (V5, V6)'),
              ),
      );

  List<Widget> _vibe(bool canSend) {
    const small = TextStyle(color: Kc.muted, fontSize: 13);
    return switch (_section) {
      _Section.levels => [
          Panel(children: [
            Explained(
              help: 'Gang channels to move them together, with one slider: sent as one command, so they '
                  'change at the same moment.',
              builder: (context, info) => PanelRow(
                title: 'Gang channels',
                trailing: [info, Switch(value: _gang, onChanged: (on) => setState(() => _gang = on))],
              ),
            ),
            if (_gang) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: _channelPicker(_gangMask & _shownMask, (m) => setState(() => _gangMask = m), enabled: true),
              ),
              if (_gangMask & _shownMask != 0)
                _slider('GANG', _levels[_firstOf(_gangMask & _shownMask)], _gangMask & _shownMask, canSend: canSend),
            ],
          ]),
          const SizedBox(height: 12),
          Panel(children: [
            for (var c = 0; c < _shown; c++)
              if (!_gang || _gangMask & (1 << c) == 0)
                _slider('V${c + 1}', _levels[c], 1 << c, canSend: canSend, dim: _unmapped(c)),
            if (_gang && _gangMask & _shownMask == _shownMask)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('Every channel is ganged', style: small),
              ),
          ]),
          _moreButton(),
          Explained(
            help: "Each person chooses which of their toys' outputs follow which channel, so V1 may be a "
                "vibrator for one and a rotator for another. Levels are scaled to each output's own range, and "
                'also set how high Patterns and React go.',
            helpPadding: EdgeInsets.zero,
            builder: (context, info) => Row(children: [
              Expanded(
                child: Text(
                    _theirs != 0
                        ? 'Their toys follow ${channelNames(_theirs)}; greyed out: nothing on it'
                        : 'Each toy runs on the channels its owner chose',
                    style: small),
              ),
              info,
            ]),
          ),
        ],
      _Section.patterns => [
          _onPicker(canSend),
          const SizedBox(height: 12),
          _grid(2, [
            for (final p in _patterns)
              _chip(p.toUpperCase(), _playing == p, canSend && _on != 0 ? () => _play(_playing == p ? null : p) : null),
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
                SizedBox(width: 150, child: Text('SPEED $_speed%', textAlign: TextAlign.center, style: Kc.term(16))),
                IconButton(
                    tooltip: 'Faster',
                    color: Kc.pink,
                    onPressed: canSend && _speed < 300 ? () => _setSpeed(_speed + 25) : null,
                    icon: const Icon(Icons.add)),
              ],
            ),
          ]),
          const SizedBox(height: 8),
          const Text('Plays in step on the channels picked, if their board has it', style: small),
        ],
      _Section.react => [
          _onPicker(canSend),
          const SizedBox(height: 12),
          _grid(3, [
            for (final (mode, name) in _reactions)
              _chip(name, _reacting == mode,
                  canSend && _on != 0 ? () => _react(_reacting == mode ? 0 : mode) : null),
          ]),
          const SizedBox(height: 8),
          const Text('The channels picked follow their own voice or movement', style: small),
        ],
    };
  }

  /// Which channels patterns and reactions go on.
  Widget _onPicker(bool canSend) => Panel(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            Text('ON', style: Kc.term(16, color: Kc.muted)),
            const SizedBox(width: 12),
            Expanded(child: _channelPicker(_on, (m) => setState(() => _onMask = m), enabled: true)),
          ]),
        ),
        _moreButton(),
      ]);

  static int _firstOf(int mask) {
    for (var c = 0; c < OthersCommand.vibeChannels; c++) {
      if (mask & (1 << c) != 0) return c;
    }
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: comm,
      builder: (context, _) {
        final canSend = comm.isOnline(widget.target);
        final caps = capabilitiesOfConversation(comm, widget.target);
        const small = TextStyle(color: Kc.muted, fontSize: 13);
        return Scaffold(
          appBar: AppBar(title: const Text('Toys')),
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Explained(
                      help: "Their toys only do it if they allow you. If not, your first command asks them for permission.",
                      helpPadding: const EdgeInsets.only(bottom: 6),
                      builder: (context, info) => SectionHeader('To ${widget.target.audience}', trailing: info),
                    ),
                    if (!canSend)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 4),
                        child: Text("They can't be reached just now", style: small),
                      )
                    else if (!canControl(caps, Capabilities.vibe))
                      const Padding(
                        padding: EdgeInsets.only(bottom: 4),
                        child: Text("They don't let others control Vibe toys, or have none connected", style: small),
                      ),
                    const SizedBox(height: 6),
                    // The classes of toy: only Vibe so far
                    SegmentedButton<_ToyClass>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(value: _ToyClass.vibe, label: Text('VIBE')),
                        ButtonSegment(value: _ToyClass.estim, label: Text('E-STIM'), enabled: false),
                        ButtonSegment(value: _ToyClass.machine, label: Text('MACHINE'), enabled: false),
                      ],
                      selected: const {_ToyClass.vibe},
                      onSelectionChanged: (_) {},
                    ),
                  ],
                ),
              ),
              // STOP, for every toy, below the classes
              StopBar(onPressed: canSend ? _stop : null, label: _stopped ? 'STOPPED' : 'STOP'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
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
                child: SafeArea(
                  top: false,
                  child: ListView(padding: const EdgeInsets.all(16), children: _vibe(canSend)),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
