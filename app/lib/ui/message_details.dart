import 'package:flutter/material.dart';

import '../comm/board_protocol.dart';
import '../comm/comm_controller.dart';
import '../comm/conversations.dart';
import '../comm/message_details.dart';
import 'channel_details.dart';
import 'theme.dart';
import 'widgets.dart';

void showMessageDetails(BuildContext context, CommController comm, Conversation c, ConversationEntry e) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => MessageDetailsPage(comm: comm, conversation: c, entry: e)));

/// A text's details: who sent it, when, how big, and each way it came or
/// went: over the server, or direct, with each packet on the air and every
/// copy of it heard, for testing direct comms' range and relaying. Copies
/// that come while it's on screen are added as they come.
class MessageDetailsPage extends StatelessWidget {
  final CommController comm;
  final Conversation conversation;
  final ConversationEntry entry;
  const MessageDetailsPage({super.key, required this.comm, required this.conversation, required this.entry});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: comm.conversations,
      builder: (context, _) {
        final e = entry;
        final d = e.details;
        final routes = d?.routes ?? const <MessageRoute>[];
        final firstMs = routes.isEmpty ? null : routes.map((r) => r.atMs).reduce((a, b) => a < b ? a : b);
        return Scaffold(
          appBar: AppBar(title: const Text('Message details')),
          body: ListView(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 24 + MediaQuery.paddingOf(context).bottom),
            children: [
              const SectionHeader('Message'),
              Panel(children: [
                Fact('From', e.mine ? 'You' : comm.fromLabel(e)),
                Fact('To', _to(d)),
                Fact(e.mine ? 'Sent' : 'Received', _when(e.time)),
                Fact('Kind', switch (e.kind) {
                  ConversationEntry.text => 'Text',
                  ConversationEntry.photo => 'Photo',
                  ConversationEntry.display => 'Display command',
                  ConversationEntry.sound => 'Sound command',
                  _ => 'Toy command',
                }),
                if (e.kind == ConversationEntry.text)
                  Fact('Size', '${_bytes(e.body)} bytes, ${e.body.runes.length} characters'),
                if (routes.isNotEmpty)
                  Fact(e.mine ? 'Went by' : 'Came by',
                      routes.map((r) => r.via == MessageRoute.server ? 'Server' : 'Direct').join(e.mine ? ' and ' : ', then ')),
              ]),
              if (d == null) ...[
                const SizedBox(height: 12),
                Text(
                    e.kind == ConversationEntry.text || e.kind == ConversationEntry.photo
                        ? 'No delivery details: it came before the app kept them.'
                        : 'Commands keep no delivery details.',
                    style: const TextStyle(color: Kc.muted)),
              ],
              for (final (i, r) in routes.indexed) ...[
                SectionHeader(
                  r.via == MessageRoute.server ? 'Server' : 'Direct',
                  trailing: e.mine || routes.length < 2
                      ? null
                      : Text(i == 0 && r.atMs == firstMs ? 'FIRST' : '+${_secs(r.atMs - firstMs!)} LATER',
                          style: Kc.term(14, color: Kc.muted)),
                ),
                if (r.via == MessageRoute.server) _server(r) else ..._direct(context, r, e.mine),
              ],
            ],
          ),
        );
      },
    );
  }

  String _to(MessageDetails? d) {
    final c = conversation;
    if (d == null) return c.audience;
    return switch (d.scope) {
      OthersCommand.scopeOne => entry.mine ? c.title : 'You alone',
      OthersCommand.scopeChannel => 'Everyone in ${c.title}',
      _ => 'Everyone who can hear ${entry.mine ? 'you' : 'them'}',
    };
  }

  Widget _server(MessageRoute r) => Panel(children: [
        if (r.host != null) Fact('Server', r.host!),
        Fact('Channel', r.channel.isEmpty ? 'Private, to one person' : r.channel),
        Fact(entry.mine ? 'Sent' : 'Came', _clock(DateTime.fromMillisecondsSinceEpoch(r.atMs))),
        Fact('Packets', '1 Mumble text message, TCP, encrypted'),
        if (r.bytes > 0) Fact('Its size', '${r.bytes} bytes, with its markup'),
      ]);

  List<Widget> _direct(BuildContext context, MessageRoute r, bool mine) {
    final info = r.radio;
    final copies = [for (final p in r.packets) ...p.copies];
    final relayed = copies.where((c) => c.hops > 0).length;
    final sends = r.packets.length * r.sends;
    final heard = r.packets.fold(0, (n, p) => n + p.sendsHeard);
    final airBytes = r.packets.fold(0, (n, p) => n + p.bytes);
    final first = r.firstCopyMs, last = r.lastCopyMs;
    final rssis = [for (final c in copies) c.rssi];
    final noCopies = !mine && copies.isEmpty && r.packets.any((p) => p.counter != null);
    return [
      Panel(children: [
        Fact('Channel', r.channel.isEmpty ? 'Not known' : r.channel,
            trailing: info == null
                ? null
                : IconButton(
                    tooltip: 'Its radio',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.info_outline, size: 20, color: Kc.muted),
                    onPressed: () => _radioInfo(context, info),
                  )),
        Fact(mine ? 'Sent' : 'Came', _clock(DateTime.fromMillisecondsSinceEpoch(r.atMs))),
        if (r.bytes > 0) Fact('Text', '${r.bytes} bytes'),
        Fact('Packets', r.packets.length == 1 ? '1 on the air' : '${r.packets.length} on the air: the text in parts'),
        if (airBytes > 0) Fact('On the air', '$airBytes bytes a send${r.packets.length > 1 ? ', all the packets' : ''}'),
        if (r.sends > 0) Fact('Each sent', '${r.sends} times, as nothing says it came'),
        if (mine) const Fact('Heard', 'Units don\'t say which copies came'),
        if (!mine && !noCopies) ...[
          Fact('Sends heard', '$heard of $sends',
              color: heard == sends ? Kc.green : heard * 2 >= sends ? Kc.warn : Kc.softRed),
          Fact('Copies heard', '${copies.length}${relayed > 0 ? ', $relayed relayed' : ', none relayed'}'),
          if (rssis.isNotEmpty)
            Fact('Signal', rssis.length == 1
                ? '${rssis.first} dBm'
                : '${rssis.reduce((a, b) => a > b ? a : b)} to ${rssis.reduce((a, b) => a < b ? a : b)} dBm'),
          if (first != null && last != null && last > first) Fact('Copies spread over', '${last - first} ms'),
        ],
        if (r.packets.any((p) => p.counter == null))
          Fact('Missing', '${r.packets.where((p) => p.counter == null).length} part(s) never came', color: Kc.softRed),
      ]),
      if (noCopies) ...[
        const SizedBox(height: 8),
        const Text("No copies reported: the unit's firmware is older than this, or the unit wasn't linked.",
            style: TextStyle(color: Kc.muted)),
      ],
      if (r.packets.length > 1 || copies.isNotEmpty) ...[
        const SizedBox(height: 12),
        Panel(children: [
          for (final p in r.packets) _packet(p, r.packets.length, r.sends, first, mine),
        ]),
      ],
    ];
  }

  Widget _packet(RadioPacket p, int count, int sends, int? firstMs, bool mine) {
    final title = 'Packet ${p.part + 1} of $count${p.bytes > 0 ? ' · ${p.bytes} bytes' : ''}';
    if (p.counter == null) return PanelRow(title: title, subtitle: 'Never came');
    if (mine) return PanelRow(title: title, subtitle: 'Sent $sends times');
    if (p.copies.isEmpty) return PanelRow(title: title, subtitle: 'No copies reported');
    // Each send heard, numbered as they came, and a relayed copy of one under it
    final order = <int>[];
    for (final c in p.copies) {
      if (!order.contains(c.broadcast)) order.add(c.broadcast);
    }
    final lines = [
      for (final c in p.copies)
        'Send ${order.indexOf(c.broadcast) + 1}: ${c.rssi} dBm, '
            '${c.hops == 0 ? 'direct' : 'relayed${c.hops > 1 ? ' ${c.hops} hops' : ''}'}'
            '${firstMs == null ? '' : ', +${c.atMs - firstMs} ms'}'
    ];
    final best = p.copies.map((c) => c.rssi).reduce((a, b) => a > b ? a : b);
    return PanelRow(
      title: '$title · ${p.sendsHeard} of $sends heard',
      subtitle: lines.join('\n'),
      trailing: [SignalBars(best), const SizedBox(width: 8)],
    );
  }

  void _radioInfo(BuildContext context, DirectChannelInfo info) => showDialog<void>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(info.name),
          contentPadding: const EdgeInsets.fromLTRB(8, 16, 8, 0),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Fact('Frequency', '${info.frequency}'),
            Fact('Long Range', info.longRange ? 'On' : 'Off'),
            Fact('Access', info.keyed ? 'Passphrase: encrypted' : 'Open: anyone nearby can hear it'),
            if (info.keyed) Fact('Channel id', info.id),
            if (info.boardName.isNotEmpty) Fact('Your unit', info.boardName),
          ]),
          actions: [TextButton(onPressed: () => Navigator.pop(dialog), child: const Text('OK'))],
        ),
      );

  static int _bytes(String s) => s.runes.fold(0, (n, r) => n + (r < 0x80 ? 1 : r < 0x800 ? 2 : r < 0x10000 ? 3 : 4));

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _clock(DateTime t) =>
      '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}.${t.millisecond.toString().padLeft(3, '0')}';

  static String _when(DateTime t) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${t.day} ${months[t.month - 1]}, ${_clock(t)}';
  }

  static String _secs(int ms) => '${(ms / 1000).toStringAsFixed(ms < 10000 ? 2 : 1)} s';
}
