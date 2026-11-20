import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../comm/board_protocol.dart';
import '../comm/comm_controller.dart';
import '../comm/conversations.dart';
import 'control_page.dart';
import 'channel_lists.dart';
import 'people.dart';
import 'person_sheet.dart';
import 'remote_page.dart';
import 'setup_page.dart';
import 'theme.dart';
import 'widgets.dart';

/// HiveMind by text: a conversation for everyone who can hear us, for each
/// channel, and for each person, picked from a list as in a chat app. Each
/// has its own texts, and its own way to put words on their displays and to
/// control their toys.
class TextPage extends StatelessWidget {
  final CommController comm;
  const TextPage({super.key, required this.comm});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([comm, comm.conversations]),
      builder: (context, _) {
        final convs = comm.conversations;
        // The channels we're on, as conversations (made as they're needed)
        final channels = <Conversation>[
          if (comm.isOnline(comm.everyoneConversation)) comm.everyoneConversation,
          ?comm.serverConversation,
          ?comm.directConversation,
        ];
        // Everyone about, and anyone we've a conversation with who's reachable
        // by who they are
        final people = <String, Person?>{};
        for (final p in hivePeople(comm)) {
          people.putIfAbsent(p.id, () => p);
        }
        for (final c in convs.all.values) {
          if (c.kind == ConversationKind.person && comm.isOnline(c)) {
            people.putIfAbsent(CommController.personOf(c), () => null);
          }
        }
        final online = {for (final c in channels) c.key, for (final id in people.keys) Conversation.personKey(id)};
        final offline = [
          for (final c in convs.all.values)
            if (!online.contains(c.key) && c.entries.isNotEmpty) c
        ]..sort((a, b) => (b.last ?? DateTime(0)).compareTo(a.last ?? DateTime(0)));
        String nameOf(String id) => (people[id]?.name ?? comm.people[id]?.name ?? '').toLowerCase();
        final ids = people.keys.toList()..sort((a, b) => nameOf(a).compareTo(nameOf(b)));
        return Scaffold(
          appBar: AppBar(
            title: const Text('Text'),
            actions: [
              IconButton(
                tooltip: 'Setup',
                icon: const Icon(Icons.settings),
                onPressed: () =>
                    Navigator.of(context).push(MaterialPageRoute(builder: (_) => SetupPage(comm: comm))),
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              const SectionHeader('Channels'),
              if (channels.isEmpty)
                const Panel(children: [
                  PanelRow(title: 'Not linked to the hive', subtitle: 'Connect to the server, or switch on Direct'),
                ])
              else ...[
                // Everyone who can hear us, by any means
                if (comm.isOnline(comm.everyoneConversation))
                  Panel(children: [_Row(comm: comm, c: comm.everyoneConversation)]),
                ChannelLists(
                  comm: comm,
                  serverCurrent: comm.serverConversation == null ? null : _Row(comm: comm, c: comm.serverConversation!),
                  directCurrent: comm.directConversation == null ? null : _Row(comm: comm, c: comm.directConversation!),
                ),
              ],
              const SectionHeader('People'),
              if (ids.isEmpty)
                const Panel(children: [PanelRow(title: 'Nobody about')])
              else
                Panel(children: [
                  for (final id in ids)
                    _Row(comm: comm, c: comm.personConversation(id), picture: people[id]?.picture, person: true),
                ]),
              if (offline.isNotEmpty) ...[
                const SectionHeader('Offline'),
                Panel(children: [
                  for (final c in offline) _Row(comm: comm, c: c, person: c.kind == ConversationKind.person),
                ]),
              ],
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('Hold a conversation to delete it', style: TextStyle(color: Kc.muted, fontSize: 13)),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Row extends StatelessWidget {
  final CommController comm;
  final Conversation c;
  final Uint8List? picture;
  final bool person;
  const _Row({required this.comm, required this.c, this.picture, this.person = false});

  @override
  Widget build(BuildContext context) {
    final last = c.entries.isEmpty ? null : c.entries.last;
    final preview = last == null
        ? null
        : last.kind == ConversationEntry.text
            ? '${last.mine ? 'You: ' : c.kind == ConversationKind.person ? '' : '${comm.fromLabel(last)}: '}${last.body}'
            : '${last.mine ? 'You' : comm.fromLabel(last)} ${last.body}';
    return InkWell(
      onTap: () => openConversation(context, comm, c),
      onLongPress: () => deleteConversation(context, comm, c),
      child: PanelRow(
        leading: person
            // Their avatar: who they are, as on the Voice tab
            ? GestureDetector(
                onTap: () => showPerson(context, comm, id: CommController.personOf(c)),
                child: DroneAvatar(picture: picture, size: 36),
              )
            : Icon(
                switch (c.kind) {
                  ConversationKind.everyone => Icons.campaign_outlined,
                  ConversationKind.server => Icons.cloud_outlined,
                  ConversationKind.direct => Icons.settings_input_antenna,
                  ConversationKind.person => Icons.person_outline,
                },
                color: Kc.green),
        title: c.title,
        subtitle: preview,
        trailing: [
          if (c.unread > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: const BoxDecoration(color: Kc.pink, borderRadius: BorderRadius.all(Radius.circular(10))),
              child: Text('${c.unread}', style: const TextStyle(color: Kc.bg, fontWeight: FontWeight.w600)),
            ),
        ],
      ),
    );
  }
}

void openConversation(BuildContext context, CommController comm, Conversation c) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => ConversationPage(comm: comm, conversationKey: c.key)));

Future<void> deleteConversation(BuildContext context, CommController comm, Conversation c, {bool leave = false}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Delete ${c.title}?'),
      content: const Text('Its messages are deleted from this phone. It starts afresh if they text again.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
      ],
    ),
  );
  if (ok != true) return;
  comm.conversations.delete(c);
  if (leave && context.mounted) Navigator.of(context).pop();
}

/// One conversation: its texts and commands, a box to text, and buttons to
/// put words on their displays or control their toys.
class ConversationPage extends StatefulWidget {
  final CommController comm;
  final String conversationKey;
  const ConversationPage({super.key, required this.comm, required this.conversationKey});

  @override
  State<ConversationPage> createState() => _ConversationPageState();
}

class _ConversationPageState extends State<ConversationPage> {
  CommController get comm => widget.comm;
  final _text = TextEditingController();
  final _scroll = ScrollController();
  int _shown = -1;

  @override
  void initState() {
    super.initState();
    comm.conversations.open = widget.conversationKey;
  }

  @override
  void dispose() {
    if (comm.conversations.open == widget.conversationKey) comm.conversations.open = null;
    _text.dispose();
    _scroll.dispose();
    super.dispose();
  }

  static String _time(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([comm, comm.conversations]),
      builder: (context, _) {
        final c = comm.conversations.all[widget.conversationKey];
        if (c == null) return const Scaffold(body: Center(child: Text('Deleted')));
        if (c.unread > 0) WidgetsBinding.instance.addPostFrameCallback((_) => comm.conversations.markRead(c));
        if (c.entries.length != _shown) {
          _shown = c.entries.length;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
          });
        }
        final online = comm.isOnline(c);
        final group = c.kind != ConversationKind.person;
        return Scaffold(
          appBar: AppBar(
            // Smaller to fit beside the buttons, as a long name needs
            title: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(c.title, style: Theme.of(context).appBarTheme.titleTextStyle?.copyWith(fontSize: 20)),
            ),
            titleSpacing: 0,
            actions: [
              IconButton(
                tooltip: 'Put words on their display',
                icon: const Icon(Icons.terminal),
                onPressed: online ? () => showTerminalSheet(context, comm, c) : null,
              ),
              IconButton(
                tooltip: 'Control their toys',
                icon: const Icon(Icons.tune),
                onPressed: online
                    ? () => Navigator.of(context)
                        .push(MaterialPageRoute(builder: (_) => ControlPage(comm: comm, target: c)))
                    : null,
              ),
              PopupMenuButton<String>(
                onSelected: (v) => v == 'details'
                    ? showPerson(context, comm, id: CommController.personOf(c), inConversation: true)
                    : deleteConversation(context, comm, c, leave: true),
                itemBuilder: (_) => [
                  if (c.kind == ConversationKind.person) const PopupMenuItem(value: 'details', child: Text('Details')),
                  const PopupMenuItem(value: 'delete', child: Text('Delete conversation')),
                ],
              ),
            ],
          ),
          body: Column(children: [
            Expanded(
              child: c.entries.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                            'Texts here go to ${c.audience}.',
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Kc.muted)),
                      ),
                    )
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                      itemCount: c.entries.length,
                      itemBuilder: (context, i) => _Entry(c.entries[i], _time(c.entries[i].time),
                          from: comm.fromLabel(c.entries[i]), named: group),
                    ),
            ),
            Container(
              decoration: const BoxDecoration(color: Kc.dock, border: Border(top: BorderSide(color: Kc.line))),
              padding: EdgeInsets.fromLTRB(12, 8, 8, 8 + MediaQuery.paddingOf(context).bottom),
              child: online
                  ? Row(children: [
                      Expanded(
                        child: TextField(
                          controller: _text,
                          minLines: 1,
                          maxLines: 4,
                          textCapitalization: TextCapitalization.sentences,
                          maxLength: c.kind == ConversationKind.server ? null : OthersCommand.longTextMax,
                          decoration: InputDecoration(
                              hintText: 'Text ${c.kind == ConversationKind.everyone ? 'everyone' : c.title}',
                              counterText: '',
                              isDense: true),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filled(
                        tooltip: 'Send',
                        icon: const Icon(Icons.send),
                        style: IconButton.styleFrom(backgroundColor: Kc.pink, foregroundColor: Kc.bg),
                        onPressed: () {
                          if (comm.sendText(c, _text.text)) _text.clear();
                        },
                      ),
                    ])
                  : Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Text(
                          group ? 'Not on this channel just now' : "${c.title} can't be reached just now",
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Kc.muted)),
                    ),
            ),
          ]),
        );
      },
    );
  }
}

class _Entry extends StatelessWidget {
  final ConversationEntry e;
  final String time;
  final String from;    // who it's from, as shown: with a warning for someone using another's name
  final bool named;     // show who it's from: in a channel, not with one person
  const _Entry(this.e, this.time, {required this.from, required this.named});

  @override
  Widget build(BuildContext context) {
    if (e.kind != ConversationEntry.text) {
      // A command: what it did, in the middle
      final what = '${e.mine ? 'You' : from} ${e.body}';
      final blocked = !e.mine && !e.done;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(e.kind == ConversationEntry.terminal ? Icons.terminal : Icons.tune, size: 14, color: Kc.muted),
          const SizedBox(width: 6),
          Flexible(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(
                blocked ? '$what (not done)' : what,
                textAlign: TextAlign.center,
                style: TextStyle(color: blocked ? Kc.softRed : Kc.muted, fontSize: 13, fontStyle: FontStyle.italic),
              ),
              // Not taken: to where it's said who may, on the Remote tab
              if (blocked)
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => showRemotePermissions(context, e.kind == ConversationEntry.terminal ? 1 : 0),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Text(
                      'Not taken by your ${e.kind == ConversationEntry.terminal ? 'Hive Messages' : 'Hive Commands'} '
                      'settings: change them ›',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: Kc.pink, fontSize: 13, decoration: TextDecoration.underline, decorationColor: Kc.pink),
                    ),
                  ),
                ),
            ]),
          ),
          const SizedBox(width: 6),
          Text(time, style: const TextStyle(color: Kc.dim, fontSize: 11)),
        ]),
      );
    }
    final color = e.mine ? Kc.pink : Kc.green;
    return Align(
      alignment: e.mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.78),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          decoration: BoxDecoration(
            color: Kc.panel,
            border: Border.all(color: color.withValues(alpha: 0.6)),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (named && !e.mine) Text(from, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
            Text(e.body, style: const TextStyle(fontSize: 15)),
            const SizedBox(height: 2),
            Text(time, style: const TextStyle(color: Kc.dim, fontSize: 11)),
          ]),
        ),
      ),
    );
  }
}

/// Words for their displays' Terminals, as our own Terminal takes them: a
/// letter size, added on a line or in place of what's there, brought on
/// screen or not; and clearing them. Kept for next time while the app runs.
int _size = 0;
bool _append = true;
bool _show = true;

Future<void> showTerminalSheet(BuildContext context, CommController comm, Conversation c) {
  final text = TextEditingController();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheet) => StatefulBuilder(
      builder: (sheet, setState) {
        const sizes = ['AUTO', '8', '16', '24', '32', '40', '48'];
        void send() {
          final t = text.text.trim();
          if (t.isEmpty) return;
          comm.sendCommandTo(
              c, comm.newCommand(OthersCommand.terminal(t, append: _append, show: _show, size: _size)));
          Navigator.pop(sheet);
        }

        // Compact, with Send beside the words, so it all fits over the keyboard
        return Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 8 + MediaQuery.viewInsetsOf(sheet).bottom),
          child: SafeArea(
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const SectionHeader('Their display'),
                Text(
                    "On ${c.kind == ConversationKind.person ? "${c.title}'s display" : 'the displays of ${c.audience}'}, "
                    'as typed: no name is added. Only if they allow you, on their Hive Messages page.',
                    style: const TextStyle(color: Kc.muted, fontSize: 13)),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: text,
                      autofocus: true,
                      maxLength: OthersCommand.messageMax,
                      minLines: 1,
                      maxLines: 3,
                      textCapitalization: TextCapitalization.characters,
                      style: Kc.term(16, color: Kc.green),
                      decoration: const InputDecoration(hintText: 'TYPE A MESSAGE', counterText: '', isDense: true),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    tooltip: 'Send',
                    icon: const Icon(Icons.send),
                    style: IconButton.styleFrom(backgroundColor: Kc.pink, foregroundColor: Kc.bg),
                    onPressed: send,
                  ),
                ]),
                const SizedBox(height: 8),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: [
                    const Icon(Icons.format_size, color: Kc.muted, semanticLabel: 'Letter size'),
                    for (var i = 0; i < sizes.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: ChoiceChip(
                          label: Text(sizes[i]),
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          labelPadding: EdgeInsets.zero,
                          selected: _size == i,
                          onSelected: (_) => setState(() => _size = i),
                        ),
                      ),
                  ]),
                ),
                const SizedBox(height: 8),
                SegmentedButton<bool>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: true, label: Text('ADD A LINE')),
                    ButtonSegment(value: false, label: Text('REPLACE')),
                  ],
                  selected: {_append},
                  onSelectionChanged: (sel) => setState(() => _append = sel.first),
                ),
                Row(children: [
                  TextButton.icon(
                    icon: const Icon(Icons.clear_all),
                    label: const Text('Clear their display'),
                    onPressed: () {
                      comm.sendCommandTo(c, comm.newCommand(OthersCommand.clearTerminal()));
                      Navigator.pop(sheet);
                    },
                  ),
                  const Spacer(),
                  const Text('Switch to it'),
                  Switch(value: _show, onChanged: (on) => setState(() => _show = on)),
                ]),
              ]),
            ),
          ),
        );
      },
    ),
  );
}
