import 'dart:async';

import 'package:flutter/material.dart';

import '../comm/board_protocol.dart';
import '../comm/capabilities.dart';
import '../comm/comm_controller.dart';
import '../comm/conversations.dart';
import '../comm/patterns.dart';
import 'capabilities_ui.dart';
import 'patterns_page.dart';
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
/// channels picked. The channels can be split into two groups, each with a
/// pattern, speed and reaction of its own.
class ToysPage extends StatefulWidget {
  final CommController comm;
  final Conversation target;
  const ToysPage({super.key, required this.comm, required this.target});

  @override
  State<ToysPage> createState() => _ToysPageState();
}

/// The reactions, as reactive_mode_t: to the wearer's own voice or movement.
const _reactions = [(1, 'VOICE'), (2, 'MOVING'), (3, 'STILL'), (4, 'MOTION'), (5, 'TILT')];

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

/// A pattern playing: a built-in one, by its name, or a custom one.
class _Playing {
  final String? builtIn;
  final VibePattern? custom;
  _Playing.builtIn(String this.builtIn) : custom = null;
  _Playing.custom(VibePattern this.custom) : builtIn = null;

  late final String? _hash = custom?.hashHex;
  String get name => builtIn ?? custom!.name;

  bool same(_Playing? other) => other != null && other.builtIn == builtIn && other._hash == _hash;
}

/// Channels that play a pattern and follow a reaction together.
class _Group {
  int? mask;              // null for every channel shown (the first group, unsplit)
  _Playing? playing;
  int reacting = 0;
  int speed = 100;
  _Group([this.mask]);
}

class _ToysPageState extends State<ToysPage> {
  CommController get comm => widget.comm;

  _Section _section = _Section.levels;
  final List<double> _levels = List.filled(OthersCommand.vibeChannels, 0);
  final Map<int, DateTime> _sentAt = {};  // by the channels sent to
  bool _more = false;
  bool _gang = false;
  int _gangMask = 0x03;                   // V1 and V2
  final List<_Group> _groups = [_Group(), _Group(0)];
  bool _split = false;                    // two groups
  int _group = 0;                         // the group shown
  bool _stopped = false;
  final Map<int, Timer> _again = {};      // by group
  final Map<int, Timer> _dragLater = {};  // a level held back while dragged, by the channels

  @override
  void dispose() {
    for (final t in [..._again.values, ..._dragLater.values]) {
      t.cancel();
    }
    super.dispose();
  }

  /// For one person who's said: the channels their toys follow; 0 if not
  /// known (a group, or they haven't said).
  int get _theirs => capabilitiesOfConversation(comm, widget.target)?.vibeChannels ?? 0;

  /// How many channels show.
  int get _shown => _more || _theirs >> _usualChannels != 0 ? OthersCommand.vibeChannels : _usualChannels;
  int get _shownMask => (1 << _shown) - 1;

  _Group get _g => _groups[_split ? _group : 0];

  /// What the group shown's patterns and reactions go on.
  int get _on => _maskOf(_g);

  int _maskOf(_Group g) => (g.mask ?? _shownMask) & _shownMask;

  void _send(OthersCommand what) => comm.sendCommandTo(widget.target, comm.newCommand(what));

  /// A group's channels, as a whole: each one's level, its pattern (a
  /// custom one's definition first, with [parts]), speed and reaction. Sent
  /// again a little later, in case it was lost, unless [again] is false
  /// (while a slider's dragged).
  void _sendGroup(int i, {bool again = true, bool parts = false}) {
    final g = _groups[i];
    final mask = _maskOf(g);
    if (mask == 0) return;
    final target = widget.target;
    final custom = g.playing?.custom;
    if (custom != null && parts) comm.sendPattern(target, custom);
    final cmd = comm.newCommand(OthersCommand.setVibe(mask, [for (final l in _levels) l.round()],
        speed: g.speed, react: g.reacting, builtIn: g.playing?.builtIn, hash: custom?.hash));
    comm.sendCommandTo(target, cmd);
    _again.remove(i)?.cancel();
    if (again) _again[i] = Timer(_againAfter, () => comm.sendCommandTo(target, cmd, log: false));
    _playingChanged();
  }

  /// The groups that [mask]'s channels are in.
  Iterable<int> _groupsOf(int mask) sync* {
    for (var i = 0; i < (_split ? 2 : 1); i++) {
      if (_maskOf(_groups[i]) & mask != 0) yield i;
    }
  }

  /// The custom patterns playing, for the app to send again now and then.
  void _playingChanged() => comm.setPlayingPatterns(widget.target, [
        for (var i = 0; i < (_split ? 2 : 1); i++)
          if (_groups[i].playing?.custom != null && _maskOf(_groups[i]) != 0) _groups[i].playing!.custom!,
      ]);

  /// Channels starting a pattern or a reaction while off go three quarters of
  /// the way up, for it to drive up to.
  void _startDriving(_Group g) {
    if (g.playing != null || g.reacting != 0) return;
    final mask = _maskOf(g);
    for (var c = 0; c < OthersCommand.vibeChannels; c++) {
      if (mask & (1 << c) != 0 && _levels[c] == 0) _levels[c] = (OthersCommand.levelTop * 3 / 4).roundToDouble();
    }
  }

  void _stop() {
    setState(() {
      _levels.fillRange(0, _levels.length, 0);
      for (final g in _groups) {
        g
          ..playing = null
          ..reacting = 0;
      }
      _stopped = true;
    });
    for (final t in _again.values) {
      t.cancel();
    }
    _again.clear();
    _send(OthersCommand.stopAll());
    comm.setPlayingPatterns(widget.target, const []);
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
    // While it's dragged, no more often than [_dragEvery], but whatever
    // it's at when that's up goes then, held still or not
    final now = DateTime.now();
    final last = _sentAt[mask];
    final wait = last == null ? Duration.zero : _dragEvery - now.difference(last);
    _dragLater.remove(mask)?.cancel();
    if (!done && wait > Duration.zero) {
      _dragLater[mask] = Timer(wait, () {
        _dragLater.remove(mask);
        if (mounted) _sendLevels(mask, again: true);
      });
      return;
    }
    _sendLevels(mask, again: done);
  }

  void _sendLevels(int mask, {required bool again}) {
    _sentAt[mask] = DateTime.now();
    for (final i in _groupsOf(mask).toList()) {
      _sendGroup(i, again: again);
    }
  }

  int get _gi => _split ? _group : 0;

  void _play(_Playing? p) {
    setState(() {
      if (p != null) _startDriving(_g);
      _g.playing = p;
      _stopped = false;
      if (p == null && _g.reacting == 0) _zero(_on);
    });
    _sendGroup(_gi, parts: true);
  }

  void _react(int mode) {
    setState(() {
      if (mode != 0) _startDriving(_g);
      _g.reacting = mode;
      _stopped = false;
      if (mode == 0 && _g.playing == null) _zero(_on);
    });
    _sendGroup(_gi);
  }

  /// Channels with neither a pattern nor a reaction left go off, as the
  /// board has them.
  void _zero(int mask) {
    for (var c = 0; c < OthersCommand.vibeChannels; c++) {
      if (mask & (1 << c) != 0) _levels[c] = 0;
    }
  }

  /// The channels [mask] move to group [to], from the other: they take on
  /// its pattern and reaction, so each group's channels do what it shows.
  void _moveTo(int to, int mask) {
    final g = _groups[to], from = _groups[1 - to];
    final fromMask = _maskOf(from);
    final moved = mask & fromMask;
    if (moved != 0) from.mask = fromMask & ~moved;
    if (moved == 0) return;
    if (g.playing == null && g.reacting == 0 && (from.playing != null || from.reacting != 0)) _zero(moved);
    // The channels moved take on the group's state, with the rest of it
    final newPattern = g.playing != null && !g.playing!.same(from.playing);
    g.mask = (g.mask ?? 0) | moved;
    _sendGroup(to, parts: newPattern);
  }

  void _setOn(int mask) => setState(() {
        if (_split) _moveTo(_group, mask & ~_on);
        _g.mask = mask;
      });

  void _setSplit(bool on) => setState(() {
        if (on) {
          _groups[0].mask = _maskOf(_groups[0]);
          _groups[1]
            ..mask = 0
            ..playing = null
            ..reacting = 0
            ..speed = _groups[0].speed;
          _group = 0;
        } else {
          _moveTo(0, _maskOf(_groups[1]));
          _groups[0].mask = null;
        }
        _split = on;
      });

  void _setSpeed(int percent) {
    setState(() => _g.speed = percent.clamp(25, 300));
    _sendGroup(_gi);
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
    // Nothing of theirs follows it: shown, but not to be moved
    if (dim) canSend = false;
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
                        ? "Their toys follow ${channelNames(_theirs)}; greyed out: nothing on it, so it can't be moved"
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
            for (final name in builtInPatterns) _patternChip(_Playing.builtIn(name), canSend),
          ]),
          if (_yours.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text('YOURS', style: Kc.term(14, color: Kc.muted)),
            const SizedBox(height: 6),
            _grid(2, [for (final e in _yours) _patternChip(_Playing.custom(e.pattern), canSend)]),
          ],
          const SizedBox(height: 12),
          Panel(children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                    tooltip: 'Slower',
                    color: Kc.pink,
                    onPressed: canSend && _g.speed > 25 ? () => _setSpeed(_g.speed - 25) : null,
                    icon: const Icon(Icons.remove)),
                SizedBox(width: 150, child: Text('SPEED ${_g.speed}%', textAlign: TextAlign.center, style: Kc.term(16))),
                IconButton(
                    tooltip: 'Faster',
                    color: Kc.pink,
                    onPressed: canSend && _g.speed < 300 ? () => _setSpeed(_g.speed + 25) : null,
                    icon: const Icon(Icons.add)),
              ],
            ),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            const Expanded(child: Text('Plays in step on the channels picked. Yours are sent along with it', style: small)),
            TextButton.icon(
              onPressed: () =>
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => PatternsPage(comm: comm))),
              icon: const Icon(Icons.edit_outlined, size: 18),
              label: const Text('Patterns'),
            ),
          ]),
        ],
      _Section.react => [
          _onPicker(canSend),
          const SizedBox(height: 12),
          _grid(3, [
            for (final (mode, name) in _reactions)
              _chip(name, _g.reacting == mode,
                  canSend && _on != 0 ? () => _react(_g.reacting == mode ? 0 : mode) : null),
          ]),
          const SizedBox(height: 8),
          const Text('The channels picked follow their own voice or movement', style: small),
        ],
    };
  }

  /// Which channels patterns and reactions go on: one group, or two, each
  /// with its own.
  Widget _onPicker(bool canSend) => Panel(children: [
        Explained(
          help: 'Split the channels into two groups, each with its own pattern, speed and reaction: pick a group, '
              'then its channels. A channel is in one group at a time.',
          builder: (context, info) => PanelRow(
            title: 'Two groups',
            trailing: [info, Switch(value: _split, onChanged: _setSplit)],
          ),
        ),
        if (_split)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: SegmentedButton<int>(
              showSelectedIcon: false,
              segments: [
                for (final (i, name) in const [(0, 'A'), (1, 'B')])
                  ButtonSegment(value: i, label: Text('GROUP $name${_summary(_groups[i])}')),
              ],
              selected: {_group},
              onSelectionChanged: (sel) => setState(() => _group = sel.first),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            Text('ON', style: Kc.term(16, color: Kc.muted)),
            const SizedBox(width: 12),
            Expanded(child: _channelPicker(_on, _setOn, enabled: true)),
          ]),
        ),
        _moreButton(),
      ]);

  /// Our own patterns, and the favourites of those sent us.
  List<PatternEntry> get _yours => [
        ...comm.patterns.mine,
        ...comm.patterns.received.where((e) => e.favourite),
      ];

  Widget _patternChip(_Playing p, bool canSend) {
    final on = p.same(_g.playing);
    return _chip(p.name.toUpperCase(), on, canSend && _on != 0 ? () => _play(on ? null : p) : null);
  }

  /// A dot on a group's tab while it plays or reacts.
  String _summary(_Group g) => g.playing != null || g.reacting != 0 ? ' ●' : '';

  static int _firstOf(int mask) {
    for (var c = 0; c < OthersCommand.vibeChannels; c++) {
      if (mask & (1 << c) != 0) return c;
    }
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([comm, comm.patterns]),
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
