import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../comm/board_link.dart';
import '../comm/board_protocol.dart';
import '../comm/comm_controller.dart';
import '../comm/conversations.dart';
import '../comm/rules.dart';
import 'theme.dart';
import 'utf8_limit.dart';
import 'widgets.dart';

/// The unit's own toys, for HiveMind Control (core/app/toys.h): which
/// channel, V1 to V6, each toy's outputs follow, so what others send on a
/// channel drives what you choose; and the controls the unit's screen
/// shows, each driving one or more channels together. Both are kept in the
/// app's rules (rules.dart), by toy, and go to the unit with the rest of
/// them; the toys themselves are the unit's, from its state (/api/state).
class ToysSetupPage extends StatefulWidget {
  final CommController comm;
  const ToysSetupPage({super.key, required this.comm});

  @override
  State<ToysSetupPage> createState() => _ToysSetupPageState();
}

/// As many controls as fit around the unit's screen (TOYS_SCREEN_CONTROLS),
/// and how long a label can be, in bytes (TOYS_LABEL_LEN, less its '\0').
const _controlsMax = 3;
const _labelMax = 11;

/// A toy, as the state has it.
class _Toy {
  final int slot;
  final String addr;          // its Bluetooth address, 12 hex digits
  final String name;
  final String model;
  final String state;
  final List<(String kind, int channel)> outputs;   // channel -1 for none
  _Toy(this.slot, this.addr, this.name, this.model, this.state, this.outputs);

  bool get connected => state == 'connected';
}

/// A screen control being laid out.
class _Control {
  final TextEditingController label;
  int channels;
  _Control(String label, this.channels) : label = TextEditingController(text: label);
}

class _ToysSetupPageState extends State<ToysSetupPage> {
  BoardLink get _board => widget.comm.board;

  StreamSubscription<String>? _statesSub;
  Timer? _poll;
  bool _asked = false;

  bool _known = false;         // the state's come, from firmware with channels
  bool _scanning = false;
  int _mapped = 0;
  List<_Toy> _toys = const [];

  List<_Control>? _editing;    // being laid out; null when not

  bool get _up => _board.state == BoardState.connected && _board.status != null;

  @override
  void initState() {
    super.initState();
    _statesSub = _board.states.listen(_onState);
    _board.addListener(_onBoard);
    widget.comm.permissions.addListener(_onRules);
    _onBoard();
    // Changes made on the display itself, or on the WiFi remote
    _poll = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_up) _board.request('GET', '/api/state').catchError((_) => RemoteAnswer(0, ''));
    });
  }

  @override
  void dispose() {
    _statesSub?.cancel();
    _board.removeListener(_onBoard);
    widget.comm.permissions.removeListener(_onRules);
    _poll?.cancel();
    for (final c in _editing ?? const <_Control>[]) {
      c.label.dispose();
    }
    super.dispose();
  }

  void _onBoard() {
    if (!_up) {
      _asked = false;
      if (mounted) setState(() {});
      return;
    }
    if (_asked) return;
    _asked = true;
    _board.request('GET', '/api/state').catchError((_) => RemoteAnswer(0, ''));
  }

  void _onRules() {
    if (mounted) setState(() {});
  }

  /// The controls as laid out in the rules: none for one per channel.
  List<(String, int)> get _controls => [for (final c in widget.comm.permissions.rules.controls ?? const <ScreenControl>[]) (c.label, c.channels)];

  void _onState(String json) {
    try {
      final j = jsonDecode(json) as Map<String, dynamic>;
      if (j['channels'] is! List) return;
      final toys = [
        for (final d in j['devices'] as List<dynamic>? ?? const [])
          if (d is Map<String, dynamic>)
            _Toy(
              (d['slot'] as num).toInt(),
              d['addr'] as String? ?? '',
              d['name'] as String? ?? '',
              (d['model'] as String?)?.isNotEmpty == true ? d['model'] as String : d['name'] as String? ?? 'Toy',
              d['state'] as String? ?? 'found',
              [
                for (final o in d['outputs'] as List<dynamic>? ?? const [])
                  ((o as Map<String, dynamic>)['kind'] as String? ?? 'Vibrate', (o['channel'] as num?)?.toInt() ?? -1),
              ],
            ),
      ];
      final notice = j['notice'] as String? ?? '';
      if (!mounted) return;
      setState(() {
        _known = true;
        _scanning = j['scan'] == 1;
        _mapped = (j['mapped'] as num?)?.toInt() ?? 0;
        _toys = toys;
      });
      if (notice.isNotEmpty) _toast(notice);
    } catch (_) {}
  }

  Future<void> _post(String what, [Map<String, Object> params = const {}]) async {
    final q = params.entries.map((e) => '${e.key}=${Uri.encodeQueryComponent('${e.value}')}').join('&');
    try {
      await _board.request('POST', '/api/$what${q.isEmpty ? '' : '?$q'}');
    } catch (_) {}
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  void _startEditing() {
    setState(() => _editing = [
          for (final (label, channels) in _controls) _Control(label, channels),
          if (_controls.isEmpty) _Control('V1', 0x01),
        ]);
  }

  void _stopEditing() {
    for (final c in _editing ?? const <_Control>[]) {
      c.label.dispose();
    }
    setState(() => _editing = null);
  }

  void _saveControls() {
    final e = [for (final c in _editing!) if (c.channels != 0) ScreenControl(c.label.text.trim(), c.channels)];
    widget.comm.permissions.setControls(e.isEmpty ? null : e);
    _stopEditing();
  }

  void _automatic() {
    widget.comm.permissions.setControls(null);
    _stopEditing();
  }

  /// An output's channel, in the rules: the toy's other outputs keep theirs.
  void _map(_Toy t, int output, int channel) {
    widget.comm.permissions.mapOutput(t.addr, [for (final o in t.outputs) o.$2], output, channel);
    setState(() {
      final outs = t.outputs;
      outs[output] = (outs[output].$1, channel);
    });
  }

  Widget _channelChips(int mask, ValueChanged<int> onChanged) => Wrap(spacing: 6, runSpacing: 6, children: [
        for (var c = 0; c < OthersCommand.vibeChannels; c++)
          FilterChip(
            label: Text('V${c + 1}'),
            labelStyle: Kc.term(15, color: mask & (1 << c) != 0 ? Kc.pink : Kc.text),
            showCheckmark: false,
            visualDensity: VisualDensity.compact,
            selected: mask & (1 << c) != 0,
            onSelected: (on) => onChanged(on ? mask | (1 << c) : mask & ~(1 << c)),
          ),
      ]);

  Widget _toyPanel(_Toy t) => Panel(children: [
        PanelRow(
          leading: Icon(Icons.vibration, color: t.connected ? Kc.pink : Kc.muted),
          title: t.model,
          subtitle: switch (t.state) {
            'connected' => t.name == t.model ? 'Connected' : '${t.name} · Connected',
            'connecting' => 'Connecting…',
            'lost' => 'Lost: reconnecting',
            'failed' => "Couldn't connect",
            _ => 'Found',
          },
          trailing: [
            TextButton(
              onPressed: _up ? () => _post('connect', {'d': t.slot}) : null,
              child: Text(t.connected || t.state == 'connecting' ? 'Disconnect' : 'Connect'),
            ),
          ],
        ),
        for (var o = 0; o < t.outputs.length; o++)
          PanelRow(
            title: t.outputs.length > 1 ? '${t.outputs[o].$1} (output ${o + 1})' : t.outputs[o].$1,
            trailing: [
              DropdownButton<int>(
                value: t.outputs[o].$2 >= 0 && t.outputs[o].$2 < OthersCommand.vibeChannels ? t.outputs[o].$2 : -1,
                underline: const SizedBox.shrink(),
                dropdownColor: Kc.raised,
                onChanged: t.addr.isEmpty ? null : (c) => _map(t, o, c ?? -1),
                items: [
                  const DropdownMenuItem(value: -1, child: Text('None')),
                  for (var c = 0; c < OthersCommand.vibeChannels; c++)
                    DropdownMenuItem(value: c, child: Text('V${c + 1}', style: Kc.term(16))),
                ],
              ),
            ],
          ),
      ]);

  List<Widget> _screenControls() {
    const small = TextStyle(color: Kc.muted, fontSize: 13);
    final e = _editing;
    if (e == null) {
      return [
        Panel(children: [
          if (_controls.isEmpty)
            const PanelRow(title: 'None yet', subtitle: 'One shows for each channel a connected toy follows'),
          for (final (label, channels) in _controls)
            PanelRow(
              leading: const Icon(Icons.radio_button_unchecked, color: Kc.muted),
              title: label.isEmpty ? channelNames(channels) : label,
              subtitle: 'Drives ${channelNames(channels)}',
            ),
          PanelRow(
            leading: const Icon(Icons.edit_outlined, color: Kc.muted),
            title: 'Lay them out',
            subtitle: 'Up to $_controlsMax, each driving one or more channels together',
            trailing: const [Icon(Icons.chevron_right, color: Kc.muted)],
            onTap: _startEditing,
          ),
        ]),
      ];
    }
    return [
      for (var i = 0; i < e.length; i++) ...[
        Panel(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: e[i].label,
                  inputFormatters: [Utf8LengthLimit(_labelMax)],
                  textCapitalization: TextCapitalization.characters,
                  style: Kc.term(16),
                  decoration: InputDecoration(labelText: 'Control ${i + 1}', hintText: 'LABEL', isDense: true),
                ),
              ),
              IconButton(
                tooltip: 'Remove',
                icon: const Icon(Icons.close),
                onPressed: () => setState(() => e.removeAt(i).label.dispose()),
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: _channelChips(e[i].channels, (m) => setState(() => e[i].channels = m)),
          ),
        ]),
        const SizedBox(height: 8),
      ],
      if (e.length < _controlsMax)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            icon: const Icon(Icons.add),
            label: const Text('Add a control'),
            onPressed: () => setState(() => e.add(_Control('', 0))),
          ),
        ),
      const Text('A control with no channel is left out.', style: small),
      const SizedBox(height: 8),
      Row(children: [
        TextButton(onPressed: _automatic, child: const Text('One per channel')),
        const Spacer(),
        TextButton(onPressed: _stopEditing, child: const Text('Cancel')),
        const SizedBox(width: 8),
        FilledButton(onPressed: _saveControls, child: const Text('Save')),
      ]),
    ];
  }

  @override
  Widget build(BuildContext context) {
    const small = TextStyle(color: Kc.muted, fontSize: 13);
    return ListenableBuilder(
      listenable: _board,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('Toys')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (!_up)
              const Text('Connect to your unit to set up its toys.', style: small)
            else if (!_known)
              const Text("Waiting for the unit… If nothing comes, update its firmware: this needs one with "
                  'toys by channel.', style: small)
            else ...[
              Explained(
                help: "Others control your toys by channel, V1 to V6. Choose which channel each of your toys' "
                    'outputs follows: what anyone sends on V1 drives every output on V1. None leaves an output '
                    'to your own controls. Your phone keeps it, by toy, and gives it to your unit.',
                builder: (context, info) => SectionHeader('Channels', trailing: info),
              ),
              if (_toys.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text('No toys found yet. Turn one on near the unit, then look for it.', style: small),
                ),
              for (final t in _toys) ...[_toyPanel(t), const SizedBox(height: 8)],
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  icon: _scanning
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.bluetooth_searching),
                  label: Text(_scanning ? 'Stop looking' : 'Look for toys'),
                  onPressed: () => _post('scan', {'on': _scanning ? 0 : 1}),
                ),
              ),
              Text(
                  _mapped == 0
                      ? "No connected toy follows a channel: others can't control your toys."
                      : 'Others can control ${channelNames(_mapped)}.',
                  style: small),
              Explained(
                help: "The controls around the unit's screen. Each drives one or more channels together, so a "
                    'single ring can run a vibrator and a rotator at once. Until you lay them out, there is one '
                    'for each channel a connected toy follows.',
                builder: (context, info) => SectionHeader('Screen controls', trailing: info),
              ),
              ..._screenControls(),
            ],
          ],
        ),
      ),
    );
  }
}
