import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../comm/remote_model.dart';
import 'remote_widgets.dart';
import 'theme.dart';
import 'widgets.dart';

/// Remote → Terminal: type a message onto the unit's Terminal.
class RemoteTerminalTab extends StatefulWidget {
  final RemoteModel model;
  const RemoteTerminalTab({super.key, required this.model});

  @override
  State<RemoteTerminalTab> createState() => _RemoteTerminalTabState();
}

class _RemoteTerminalTabState extends State<RemoteTerminalTab> {
  final _text = TextEditingController();
  bool _append = false;
  bool _showIt = true;
  List<String> _history = [];

  RemoteModel get m => widget.model;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final p = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _append = p.getBool('remoteAppend') ?? false;
        _showIt = p.getBool('remoteShow') ?? true;
        _history = [for (final t in jsonDecode(p.getString('remoteHistory') ?? '[]') as List) t as String];
      });
    } catch (_) {}
  }

  Future<void> _save() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool('remoteAppend', _append);
      await p.setBool('remoteShow', _showIt);
      await p.setString('remoteHistory', jsonEncode(_history));
    } catch (_) {}
  }

  void _send(String text) {
    if (text.trim().isEmpty) return;
    m.command('message', {'append': _append ? 1 : 0, 'show': _showIt ? 1 : 0}, text);
    setState(() => _history = [text, ..._history.where((t) => t != text)].take(8).toList());
    _save();
  }

  @override
  Widget build(BuildContext context) {
    final s = m.state;
    final max = m.info['message_max'] as int? ?? 200;
    final size = s['term_size'] as int? ?? 0;
    final px = (s['term_scale'] as int? ?? 0) * 8;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        Container(
          constraints: const BoxConstraints(minHeight: 90),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.black,
            border: Border.all(color: Kc.darkGreen),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('ON THE DISPLAY${px > 0 ? ' · $px PX' : ''}', style: Kc.term(12, color: Kc.darkGreen)),
            const SizedBox(height: 6),
            Text('${s['message'] ?? ''}'.isEmpty ? '> ' : '${s['message']}', style: Kc.term(18, color: Kc.green)),
          ]),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _text,
          minLines: 2,
          maxLines: 5,
          maxLength: max,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(hintText: '> type a message', border: OutlineInputBorder()),
        ),
        Row(children: [
          TextButton(
            onPressed: () => m.command('clear'),
            child: const Text('CLEAR'),
          ),
          const Spacer(),
          FilledButton(
            onPressed: () {
              _send(_text.text);
              _text.clear();
            },
            child: const Text('SEND'),
          ),
        ]),
        Panel(children: [
          RemoteToggle(
            label: 'Add a line',
            on: _append,
            onTap: () {
              setState(() => _append = !_append);
              _save();
            },
          ),
          RemoteToggle(
            label: 'Switch to it',
            on: _showIt,
            onTap: () {
              setState(() => _showIt = !_showIt);
              _save();
            },
          ),
        ]),
        const SectionHeader('Letter size'),
        RemoteChoices(
          labels: const ['Auto', '8', '16', '24', '32', '40', '48'],
          selected: size,
          onPick: (i) => m.command('termsize', {'s': i}),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            size == 0
                ? 'Auto uses the biggest letters the whole message fits in, down to 16 px. Longer messages scroll.'
                : 'Messages too long for this size scroll, keeping the newest lines.',
            style: const TextStyle(color: Kc.muted, fontSize: 13),
          ),
        ),
        const SectionHeader('Sent'),
        if (_history.isEmpty)
          const Text('Nothing yet. Tap one to send it again.', style: TextStyle(color: Kc.muted))
        else
          Panel(children: [
            for (final t in _history)
              PanelRow(
                title: '> ${t.replaceAll('\n', ' ')}',
                onTap: () => _send(t),
              ),
          ]),
      ],
    );
  }
}
