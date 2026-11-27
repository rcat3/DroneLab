import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../comm/board_protocol.dart';
import '../comm/comm_controller.dart';
import '../comm/conversations.dart';
import '../comm/hivesight_guide.dart';
import '../comm/hivesight_invite.dart';
import '../comm/patterns.dart';
import '../comm/server_invites.dart';
import 'capabilities_ui.dart';
import 'permissions_page.dart';
import 'message_details.dart';
import 'channel_details.dart';
import 'channel_lists.dart';
import 'hivesight_button.dart';
import 'pattern_sparkline.dart';
import 'patterns_page.dart';
import 'people.dart';
import 'person_sheet.dart';
import 'setup_page.dart';
import 'theme.dart';
import 'utf8_limit.dart';
import 'widgets.dart';

/// HiveMind by text: a conversation for everyone who can hear us, for each
/// channel, and for each person, picked from a list as in a chat app. Each
/// has its own texts, and its own way to put words or pictures on their displays and to
/// control their toys.
class TextPage extends StatelessWidget {
  final CommController comm;
  const TextPage({super.key, required this.comm});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([comm, comm.conversations, collapsedChannels]),
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
            title: const Row(children: [
              Icon(Icons.chat_bubble_outline, color: Kc.green, size: 22),
              SizedBox(width: 10),
              Text('HiveMind Text'),
            ]),
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
              const FoldingHeader('Channels', 'section:channels'),
              if (isFolded('section:channels'))
                const SizedBox.shrink()
              else if (channels.isEmpty)
                const Panel(children: [
                  PanelRow(title: 'Not linked to the hive', subtitle: 'Connect to the server, or switch on Direct'),
                ])
              else ...[
                // Everyone who can hear us, by any means
                if (comm.isOnline(comm.everyoneConversation))
                  Panel(children: [_Row(comm: comm, c: comm.everyoneConversation)]),
                ChannelLists(
                  comm: comm,
                  // Picked from a list: its conversation, once it's moved there
                  onPicked: (kind, id) => _openWhenThere(context, comm, kind, id),
                  serverCurrent: comm.serverConversation == null ? null : _Row(comm: comm, c: comm.serverConversation!),
                  directCurrent: comm.directConversation == null ? null : _Row(comm: comm, c: comm.directConversation!),
                ),
              ],
              const FoldingHeader('People', 'section:people'),
              if (isFolded('section:people'))
                const SizedBox.shrink()
              else if (ids.isEmpty)
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

/// A channel's been picked: once we're on it (the server's said we've
/// moved, or the board's switched), its conversation.
Future<void> _openWhenThere(BuildContext context, CommController comm, TalkTo kind, int? serverChannel) async {
  for (var i = 0; i < 200; i++) {
    final there = kind == TalkTo.server ? comm.mumble?.myChannel == serverChannel : comm.joiningDirect == null;
    if (there) break;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  final c = kind == TalkTo.server ? comm.serverConversation : comm.directConversation;
  if (c != null && context.mounted) openConversation(context, comm, c);
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
        : last.kind == ConversationEntry.text || last.kind == ConversationEntry.photo
            ? '${last.mine ? 'You: ' : c.kind == ConversationKind.person ? '' : '${comm.fromLabel(last)}: '}'
                '${last.kind == ConversationEntry.photo ? '📷 Photo' : PatternShare.preview(ServerInvite.preview(HiveSightInvite.preview(last.body)))}'
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
/// put words or pictures on their displays or control their toys.
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
  bool _sendingPhoto = false;

  /// A line held: react, see its details, copy its words, or delete it
  /// here.
  Future<void> _entryMenu(Conversation c, ConversationEntry e) async {
    final canReact = e.ref.isNotEmpty && comm.isOnline(c);
    final what = await showModalBottomSheet<String>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // A reaction: tap the one you've given to take it back; + for them all
          if (canReact)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
              child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                for (final r in quickReactions) _emojiButton(sheet, r, e.reactions[''] == r),
                IconButton(
                  tooltip: 'All of them',
                  icon: const Icon(Icons.add_reaction_outlined, color: Kc.muted, size: 28),
                  onPressed: () => Navigator.pop(sheet, 'more'),
                ),
              ]),
            ),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('Details'),
            subtitle: e.details == null ? null : const Text('How it came: server or direct, signal, relays'),
            onTap: () => Navigator.pop(sheet, 'details'),
          ),
          if (e.kind == ConversationEntry.text)
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('Copy text'),
              onTap: () => Navigator.pop(sheet, 'copy'),
            ),
          ListTile(
            leading: const Icon(Icons.delete_outline, color: Kc.softRed),
            title: const Text('Delete for me'),
            subtitle: Text(e.kind == ConversationEntry.photo
                ? 'Gone from this phone, photo and all. Others keep theirs'
                : 'Gone from this phone. Others keep theirs'),
            onTap: () => Navigator.pop(sheet, 'delete'),
          ),
        ]),
      ),
    );
    if (!mounted) return;
    if (what == 'more') {
      final r = await _allReactions(e);
      if (r != null && mounted) comm.react(c, e, r);
      return;
    }
    if (what != null && what.startsWith('react:')) {
      comm.react(c, e, what.substring(6));
    } else if (what == 'details') {
      showMessageDetails(context, comm, c, e);
    } else if (what == 'copy') {
      await Clipboard.setData(ClipboardData(text: e.body));
    } else if (what == 'delete') {
      comm.conversations.deleteEntry(c, e);
    }
  }

  Widget _emojiButton(BuildContext sheet, String r, bool mine) => InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: () => Navigator.pop(sheet, 'react:$r'),
        child: Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(shape: BoxShape.circle, color: mine ? Kc.pink.withValues(alpha: 0.25) : null),
          child: Text(r, style: const TextStyle(fontSize: 28)),
        ),
      );

  /// Every reaction, in its groups, to pick one.
  Future<String?> _allReactions(ConversationEntry e) => showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        builder: (sheet) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.6,
          maxChildSize: 0.9,
          builder: (sheet, scroll) => ListView(
            controller: scroll,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              for (final (group, emojis) in reactionGroups) ...[
                SectionHeader(group),
                Wrap(spacing: 2, runSpacing: 2, children: [
                  for (final r in emojis)
                    InkWell(
                      borderRadius: BorderRadius.circular(24),
                      onTap: () => Navigator.pop(sheet, r),
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: e.reactions[''] == r ? Kc.pink.withValues(alpha: 0.25) : null),
                        child: Text(r, style: const TextStyle(fontSize: 30)),
                      ),
                    ),
                ]),
              ],
            ],
          ),
        ),
      );

  /// Take or pick a photo, and send it, over the server.
  Future<void> _photo(Conversation c) async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: const Text('Take a photo'),
            onTap: () => Navigator.pop(sheet, ImageSource.camera),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Choose a photo'),
            onTap: () => Navigator.pop(sheet, ImageSource.gallery),
          ),
        ]),
      ),
    );
    if (source == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final file = await ImagePicker().pickImage(source: source);
    if (file == null) return;
    setState(() => _sendingPhoto = true);
    try {
      final why = await comm.sendPhoto(c, await file.readAsBytes());
      if (why != null) messenger.showSnackBar(SnackBar(content: Text(why)));
    } finally {
      if (mounted) setState(() => _sendingPhoto = false);
    }
  }

  /// Send them an invitation to our server, once it's said what goes with
  /// it: the address, and the password, which anyone nearby can read on the
  /// open direct channel.
  Future<void> _inviteToServer(Conversation c) async {
    final i = comm.serverInvite;
    if (i == null) return;
    final open = comm.readableNearby(c) && i.password.isNotEmpty;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Invite to your server?'),
        content: Text('${c.kind == ConversationKind.person ? c.title : 'Everyone in ${c.title}'} gets a text '
            'with a button to join ${i.address}${i.password.isEmpty ? '' : ', its password and all'}.'
            '${open ? '\n\nOn the open direct channel, anyone nearby can read the password.' : ''}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialog, true), child: const Text('Invite')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    if (!comm.inviteToServer(c)) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text("Couldn't send it: ${c.title} can't be reached just now")));
    }
  }

  /// Invite them to the HiveSight session we're guiding, as a text with a
  /// Join button.
  Future<void> _inviteToHiveSight(Conversation c) async {
    final messenger = ScaffoldMessenger.of(context);
    if (!await HiveSightGuide.of(comm).invite(c)) {
      messenger.showSnackBar(SnackBar(content: Text("Couldn't send it: ${c.title} can't be reached just now")));
    }
  }

  /// Share one of our patterns, as a text with a Save button.
  Future<void> _sharePattern(Conversation c) async {
    final e = await pickPattern(context, comm);
    if (e == null || !mounted) return;
    if (!comm.sendText(c, PatternShare.text(e.pattern), typed: false)) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text("Couldn't send it: ${c.title} can't be reached just now")));
    }
  }

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
            // and for a channel, how many are in it, to tap for its details
            title: Row(children: [
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(c.title, style: Theme.of(context).appBarTheme.titleTextStyle?.copyWith(fontSize: 20)),
                ),
              ),
              if (group) PeopleCount(comm: comm, c: c),
            ]),
            titleSpacing: 0,
            actions: [
              // Everything to control, in one menu; for one person, what they
              // don't let others control is greyed out
              PopupMenuButton<int>(
                tooltip: 'HiveMind Control',
                icon: const Icon(controlIcon),
                enabled: online,
                onSelected: (id) => openControl(context, comm, c, id),
                itemBuilder: (_) {
                  final caps = capabilitiesOfConversation(comm, c);
                  return [
                    for (final a in ControlArea.values) ...[
                      PopupMenuItem(
                        enabled: false,
                        height: 32,
                        child: Text(a.name.toUpperCase(), style: Kc.term(14, color: Kc.muted)),
                      ),
                      for (final k in kindsOf(a))
                      PopupMenuItem(
                        value: k.id,
                        enabled: canControl(caps, k.id),
                        child: ListTile(
                          leading: Icon(k.icon),
                          title: Text(k.name),
                          subtitle: Text(k.does),
                          enabled: canControl(caps, k.id),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    ],
                  ];
                },
              ),
              PopupMenuButton<String>(
                onSelected: (v) => switch (v) {
                  'details' => group
                      ? showChannelDetails(context, comm, c)
                      : showPerson(context, comm, id: CommController.personOf(c), inConversation: true),
                  'invite' => _inviteToServer(c),
                  'hivesight' => _inviteToHiveSight(c),
                  'pattern' => _sharePattern(c),
                  _ => deleteConversation(context, comm, c, leave: true),
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'details', child: Text('Details')),
                  if (comm.canInviteToServer(c))
                    PopupMenuItem(value: 'invite', enabled: online, child: const Text('Invite to your server')),
                  if (canInviteToHiveSight(comm))
                    PopupMenuItem(
                        value: 'hivesight', enabled: online, child: const Text('Invite to your HiveSight session')),
                  PopupMenuItem(value: 'pattern', enabled: online, child: const Text('Share a pattern')),
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
                      // Hold one for what can be done with it
                      itemBuilder: (context, i) => GestureDetector(
                        onLongPress: () => _entryMenu(c, c.entries[i]),
                        child: Column(
                          crossAxisAlignment: c.entries[i].mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                          children: [
                            _Entry(c.entries[i], _time(c.entries[i].time),
                                comm: comm,
                                from: comm.fromLabel(c.entries[i]),
                                named: group,
                                photo: comm.conversations.photoFile(c.entries[i])),
                            if (c.entries[i].reactions.isNotEmpty)
                              _Reactions(comm, c.entries[i],
                                  onTap: comm.isOnline(c) ? (r) => comm.react(c, c.entries[i], r) : null),
                          ],
                        ),
                      ),
                    ),
            ),
            Container(
              decoration: const BoxDecoration(color: Kc.dock, border: Border(top: BorderSide(color: Kc.line))),
              padding: EdgeInsets.fromLTRB(12, 8, 8, 8 + MediaQuery.paddingOf(context).bottom),
              child: online
                  ? Row(children: [
                      // A photo: over the server only
                      if (comm.canSendPhoto(c))
                        _sendingPhoto
                            ? const Padding(
                                padding: EdgeInsets.all(12),
                                child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))
                            : IconButton(
                                tooltip: 'Send a photo',
                                icon: const Icon(Icons.add_photo_alternate_outlined, color: Kc.muted),
                                onPressed: () => _photo(c),
                              ),
                      Expanded(
                        child: TextField(
                          controller: _text,
                          minLines: 1,
                          maxLines: 4,
                          textCapitalization: TextCapitalization.sentences,
                          // Over direct comms, a text's limited in bytes: how
                          // many are left shows near the end
                          inputFormatters: c.kind == ConversationKind.server
                              ? null
                              : [Utf8LengthLimit(OthersCommand.longTextBytes)],
                          buildCounter: (context, {required currentLength, required isFocused, maxLength}) {
                            if (c.kind == ConversationKind.server) return null;
                            final left = OthersCommand.longTextBytes - Utf8LengthLimit.bytes(_text.text);
                            return left > 100
                                ? null
                                : Text(left == 0 ? 'Full' : '$left left',
                                    style: TextStyle(color: left < 20 ? Kc.softRed : Kc.muted, fontSize: 11));
                          },
                          decoration: InputDecoration(
                              hintText: 'Text ${c.kind == ConversationKind.everyone ? 'everyone' : c.title}',
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
  final File? photo;    // a photo's file
  final CommController comm;
  const _Entry(this.e, this.time, {required this.comm, required this.from, required this.named, this.photo});

  @override
  Widget build(BuildContext context) {
    if (e.kind == ConversationEntry.photo) return _photoBubble(context);
    if (e.kind != ConversationEntry.text) {
      // A command: what it did, in the middle
      final what = '${e.mine ? 'You' : from} ${e.body}';
      final blocked = !e.mine && !e.done;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(
              switch (e.kind) {
                ConversationEntry.display => Icons.monitor,
                ConversationEntry.sound => Icons.volume_up_outlined,
                _ => Icons.vibration,
              },
              size: 14,
              color: Kc.muted),
          const SizedBox(width: 6),
          Flexible(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(
                blocked ? '$what (not done)' : what,
                textAlign: TextAlign.center,
                style: TextStyle(color: blocked ? Kc.softRed : Kc.muted, fontSize: 13, fontStyle: FontStyle.italic),
              ),
              // Not taken: to where it's said who may, the Permissions screen
              if (blocked)
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => openPermissions(context, comm),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Text(
                      'Not taken by your permissions: change them ›',
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
            if (ServerInvite.parse(e.body) case final i?)
              _ServerInviteCard(comm, i, mine: e.mine)
            else if (HiveSightInvite.parse(e.body) case final i?)
              HiveSightInviteCard(comm, i, e, from: from)
            else if (PatternShare.parse(e.body) case final p?)
              _PatternCard(comm, p, from: from, mine: e.mine)
            else
              Text(e.body, style: const TextStyle(fontSize: 15)),
            const SizedBox(height: 2),
            Text(time, style: const TextStyle(color: Kc.dim, fontSize: 11)),
          ]),
        ),
      ),
    );
  }
}

extension on _Entry {
  /// A photo, in a bubble as a text's: tap it to see it whole.
  Widget _photoBubble(BuildContext context) {
    final color = e.mine ? Kc.pink : Kc.green;
    final f = photo;
    return Align(
      alignment: e.mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(6),
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.7),
        decoration: BoxDecoration(
          color: Kc.panel,
          border: Border.all(color: color.withValues(alpha: 0.6)),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          if (named && !e.mine)
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 0, 6, 4),
              child: Text(from, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
            ),
          GestureDetector(
            onTap: f == null ? null : () => _viewPhoto(context, f),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: f == null
                  ? const SizedBox(width: 160, height: 120, child: Icon(Icons.broken_image_outlined, color: Kc.dim))
                  : Image.file(f,
                      fit: BoxFit.cover,
                      height: 220,
                      cacheHeight: 440,
                      semanticLabel: e.mine ? 'Your photo' : 'Photo from $from',
                      errorBuilder: (_, _, _) =>
                          const SizedBox(width: 160, height: 120, child: Icon(Icons.broken_image_outlined, color: Kc.dim))),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 4, 6, 0),
            child: Text(time, style: const TextStyle(color: Kc.dim, fontSize: 11)),
          ),
        ]),
      ),
    );
  }
}

/// An invitation to a server, in its text's bubble: where, and for theirs,
/// a button that sets the app up for it and connects.
class _ServerInviteCard extends StatefulWidget {
  final CommController comm;
  final ServerInvite i;
  final bool mine;
  const _ServerInviteCard(this.comm, this.i, {required this.mine});

  @override
  State<_ServerInviteCard> createState() => _ServerInviteCardState();
}

class _ServerInviteCardState extends State<_ServerInviteCard> {
  bool _joining = false;

  Future<void> _join() async {
    final comm = widget.comm, i = widget.i;
    // In place of another server set up here: said first
    if (comm.server.host.isNotEmpty && (comm.server.host != i.host || comm.server.port != i.port)) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text('Join ${i.address}?'),
          content: Text('It takes the place of ${ServerInvite(comm.server.host, comm.server.port, '').address} '
              'in Setup → Server.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(dialog, true), child: const Text('Join')),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _joining = true);
    try {
      final why = await comm.joinServer(i);
      messenger.showSnackBar(SnackBar(content: Text(why ?? 'Connecting to ${i.address}')));
    } finally {
      if (mounted) setState(() => _joining = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final i = widget.i;
    final joined = widget.comm.joinedServer(i);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.cloud_outlined, size: 18, color: Kc.green),
        const SizedBox(width: 6),
        Text(widget.mine ? 'You sent an invitation' : 'Invitation to a server',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
      ]),
      const SizedBox(height: 4),
      Text(i.address, style: const TextStyle(fontSize: 15)),
      Text(i.password.isEmpty ? 'No password' : 'Password included',
          style: const TextStyle(color: Kc.muted, fontSize: 13)),
      if (!widget.mine) ...[
        const SizedBox(height: 8),
        joined
            ? const Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.check, size: 16, color: Kc.green),
                SizedBox(width: 4),
                Text('Joined', style: TextStyle(color: Kc.green)),
              ])
            : FilledButton.icon(
                onPressed: _joining ? null : _join,
                icon: _joining
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.login),
                label: const Text('Join server'),
              ),
      ],
    ]);
  }
}

/// A pattern shared in a text, in its bubble: its shape, and for one sent
/// us, a button to keep it with our patterns.
class _PatternCard extends StatelessWidget {
  final CommController comm;
  final VibePattern p;
  final String from;
  final bool mine;
  const _PatternCard(this.comm, this.p, {required this.from, required this.mine});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: comm.patterns,
        builder: (context, _) {
          final saved = comm.patterns.byHash(p.hashHex) != null;
          return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.graphic_eq, size: 18, color: Kc.pink),
              const SizedBox(width: 6),
              Flexible(
                child: Text(mine ? 'You shared “${p.name}”' : 'Pattern “${p.name}”',
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              ),
            ]),
            const SizedBox(height: 6),
            PatternSparkline(pattern: p, width: 160, height: 36),
            Text(PatternsPage.describe(p), style: const TextStyle(color: Kc.muted, fontSize: 13)),
            if (!mine) ...[
              const SizedBox(height: 8),
              saved
                  ? const Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.check, size: 16, color: Kc.green),
                      SizedBox(width: 4),
                      Text('Saved in your patterns', style: TextStyle(color: Kc.green)),
                    ])
                  : FilledButton.icon(
                      onPressed: () => comm.patterns.keepReceived(p, from),
                      icon: const Icon(Icons.download),
                      label: const Text('Save'),
                    ),
            ],
          ]);
        },
      );
}

/// A message's reactions, under it: each emoji once, with how many gave
/// it, ours lit. Tap one to give it, or take ours back; hold for who.
class _Reactions extends StatelessWidget {
  final CommController comm;
  final ConversationEntry e;
  final void Function(String emoji)? onTap;
  const _Reactions(this.comm, this.e, {this.onTap});

  @override
  Widget build(BuildContext context) {
    final byEmoji = <String, List<String>>{};
    for (final r in e.reactions.entries) {
      byEmoji.putIfAbsent(r.value, () => []).add(r.key);
    }
    String name(String who) => who.isEmpty ? 'You' : comm.people[who]?.name ?? '?';
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Wrap(spacing: 4, runSpacing: 4, children: [
        for (final MapEntry(key: emoji, value: who) in byEmoji.entries)
          Tooltip(
            message: who.map(name).join(', '),
            triggerMode: TooltipTriggerMode.longPress,
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: onTap == null ? null : () => onTap!(emoji),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: Kc.raised,
                  border: Border.all(color: who.contains('') ? Kc.pink : Kc.line),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(who.length == 1 ? emoji : '$emoji ${who.length}', style: const TextStyle(fontSize: 14)),
              ),
            ),
          ),
      ]),
    );
  }
}

/// A photo whole, to zoom and pan, on black.
void _viewPhoto(BuildContext context, File f) => Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(backgroundColor: Colors.black),
          body: InteractiveViewer(maxScale: 6, child: Center(child: Image.file(f))),
        )));
