import 'package:flutter/material.dart';

import '../comm/comm_controller.dart';
import '../comm/remote_model.dart';
import 'remote_widgets.dart';
import 'theme.dart';
import 'toys_setup_page.dart';
import 'widgets.dart';

/// Remote → Toys: the toys' levels, patterns, reactions and connections, and
/// a Stop that's always at the bottom.
class RemoteToysTab extends StatefulWidget {
  final RemoteModel model;
  final CommController comm;
  const RemoteToysTab({super.key, required this.model, required this.comm});

  @override
  State<RemoteToysTab> createState() => _RemoteToysTabState();
}

class _RemoteToysTabState extends State<RemoteToysTab> {
  int _target = -1;   // where patterns play: every channel, or one control's

  RemoteModel get m => widget.model;
  Map<String, dynamic> get s => m.state;

  List<Map<String, dynamic>> get _devices => [for (final d in (s['devices'] as List? ?? const [])) d as Map<String, dynamic>];
  List<Map<String, dynamic>> get _controls {
    final connected = _devices.any((d) => d['state'] == 'connected');
    return connected ? [for (final c in (s['controls'] as List? ?? const [])) c as Map<String, dynamic>] : const [];
  }

  static const _bits = [0, 1, 2, 3, 4, 5];
  static String _names(int c) => _bits.where((i) => c & (1 << i) != 0).map((i) => 'V${i + 1}').join('+');
  List<Map<String, dynamic>> get _channels => [for (final c in (s['channels'] as List? ?? const [])) c as Map<String, dynamic>];
  int _first(int c) => _bits.firstWhere((i) => c & (1 << i) != 0, orElse: () => 0);
  bool _driven(int c) => _bits.any((i) => c & (1 << i) != 0 && _channels[i]['driven'] == 1);

  int get _targetChannels {
    final list = _controls;
    return _target >= 0 && _target < list.length ? list[_target]['channels'] as int : 63;
  }

  bool _playing(int slot) {
    var c = _targetChannels;
    if (_target < 0) c &= (s['mapped'] as int? ?? 63);
    final on = _bits.where((i) => c & (1 << i) != 0).toList();
    return on.isNotEmpty && on.every((i) => _channels[i]['pattern'] == slot);
  }

  @override
  Widget build(BuildContext context) {
    final controls = _controls;
    if (_target >= controls.length) _target = -1;
    final patterns = (m.info['patterns'] as List? ?? const []);
    final modes = (m.info['modes'] as List? ?? const []);
    final react = s['react'] as int? ?? 0;
    final devices = _devices;
    return Column(children: [
      Expanded(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          children: [
            const SectionHeader('Channels'),
            if (controls.isEmpty)
              const Panel(children: [PanelRow(title: 'Nothing connected yet', subtitle: 'Search for toys below')])
            else
              Panel(children: [
                for (final c in controls) _control(c),
              ]),
            const SectionHeader('Patterns'),
            if (controls.length > 1)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: RemoteChoices(
                  labels: ['Every channel', for (final c in controls) c['label'] as String],
                  selected: _target + 1,
                  onPick: (i) => setState(() => _target = i - 1),
                ),
              ),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final p in patterns)
                ChoiceChip(
                  label: Text(p[1] as String),
                  selected: _playing(p[0] as int),
                  showCheckmark: false,
                  onSelected: (_) =>
                      m.command('play', {'c': _targetChannels, 'p': _playing(p[0] as int) ? -1 : p[0] as int}),
                ),
            ]),
            Panel(children: [
              RemoteSlider(
                label: 'Speed',
                value: (s['speed'] as int? ?? 100),
                max: 300,
                text: (x) => '$x%',
                steps: const [-25, 25],
                onChanged: (x) => m.queue('speed', 'speed', {'v': x < 25 ? 25 : x}),
              ),
            ]),
            if (modes.isNotEmpty) ...[
              const SectionHeader('React to'),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final mode in modes)
                  ChoiceChip(
                    label: Text(mode[1] as String),
                    selected: react == mode[0],
                    showCheckmark: false,
                    onSelected: (_) => m.command('react', {'m': react == mode[0] ? 0 : mode[0] as int}),
                  ),
              ]),
              if (react != 0 && '${s['status'] ?? ''}'.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text('${s['status']}', style: const TextStyle(color: Kc.muted)),
                ),
            ],
            SectionHeader('Toys',
                trailing: TextButton(
                  onPressed: () => Navigator.of(context)
                      .push(MaterialPageRoute(builder: (_) => ToysSetupPage(comm: widget.comm))),
                  child: const Text('Channels in Setup'),
                )),
            Panel(children: [
              if (devices.isEmpty)
                PanelRow(title: s['scan'] == 1 ? 'Searching…' : 'No toys found yet')
              else
                for (final d in devices) _device(d),
            ]),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => m.command('scan', {'on': s['scan'] == 1 ? 0 : 1}),
              icon: Icon(s['scan'] == 1 ? Icons.stop : Icons.search),
              label: Text(s['scan'] == 1 ? 'Searching… tap to stop' : 'Search'),
            ),
          ],
        ),
      ),
      // Docked, so it's always there, and reacts the moment it's touched
      SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: SizedBox(
            width: double.infinity,
            height: 56,
            child: Listener(
              onPointerDown: (_) => m.stop(),
              child: Container(
                alignment: Alignment.center,
                decoration: BoxDecoration(color: Kc.red, borderRadius: BorderRadius.circular(28)),
                child: const Text('STOP',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Colors.white)),
              ),
            ),
          ),
        ),
      ),
    ]);
  }

  Widget _control(Map<String, dynamic> c) {
    final channels = c['channels'] as int;
    final ch = _channels[_first(channels)];
    final label = c['label'] as String;
    final driven = _driven(channels);
    return RemoteSlider(
      label: label == _names(channels) ? label : '$label  (${_names(channels)})',
      value: ch['level'] as int,
      max: 20,
      text: (x) => driven ? 'up to $x' : '$x',
      onChanged: (x) => m.queue('c$channels', 'level', {'c': channels, 'v': x}),
      onEnd: (x) => m.queue('c$channels', 'level', {'c': channels, 'v': x, 'release': 1}),
    );
  }

  Widget _device(Map<String, dynamic> d) {
    final state = d['state'] as String;
    final connected = state == 'connected';
    final battery = d['battery'] as int? ?? -1;
    final right = switch (state) {
      'connecting' => '…',
      'failed' => 'failed',
      'lost' => 'lost',
      'found' => 'connect',
      'connected' => '${battery >= 0 ? '$battery%  ' : ''}✓',
      _ => '',
    };
    return PanelRow(
      title: connected ? '${d['model']}' : '${d['name']}',
      leading: Icon(Icons.bluetooth, color: connected ? Kc.green : Kc.dim),
      trailing: [Padding(padding: const EdgeInsets.only(right: 8), child: Text(right, style: const TextStyle(color: Kc.muted)))],
      onTap: () => m.command('connect', {'d': d['slot'] as int}),
    );
  }
}
