import 'package:flutter/material.dart';

import '../comm/comm_controller.dart';
import '../comm/conversations.dart';
import 'call_ui.dart';
import 'people.dart';
import 'person_sheet.dart';
import 'theme.dart';
import 'widgets.dart';

/// Who a channel's conversation reaches just now, but us: those in our
/// server channel, the units heard on our direct channel, or for Broadcast,
/// both. Empty while we're not on it.
List<Person> conversationPeople(CommController comm, Conversation c) {
  if (!comm.isOnline(c)) return const [];
  final m = comm.mumble;
  bool inChannel(Person p) => m != null && p.user != null && p.user!.channel == m.myChannel;
  final out = peopleOnce(comm).where((p) => switch (c.kind) {
        ConversationKind.server => inChannel(p),
        ConversationKind.direct => p.board != null,
        ConversationKind.everyone => inChannel(p) || p.board != null,
        ConversationKind.person => false,
      });
  return out.toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
}

/// How many a conversation reaches, by its name at the top: tap for the
/// channel's details.
class PeopleCount extends StatelessWidget {
  final CommController comm;
  final Conversation c;
  const PeopleCount({super.key, required this.comm, required this.c});

  @override
  Widget build(BuildContext context) {
    final n = conversationPeople(comm, c).length;
    return Semantics(
      button: true,
      label: '$n others here: the channel\'s details',
      excludeSemantics: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => showChannelDetails(context, comm, c),
        child: Container(
          margin: const EdgeInsets.only(left: 8),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
              border: Border.all(color: Kc.pink.withValues(alpha: 0.4)), borderRadius: BorderRadius.circular(12)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.people_outline, size: 16, color: Kc.pink),
            const SizedBox(width: 3),
            Text('$n', style: Kc.term(14, color: Kc.pink)),
          ]),
        ),
      ),
    );
  }
}

void showChannelDetails(BuildContext context, CommController comm, Conversation c) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChannelDetailsPage(comm: comm, conversationKey: c.key)));

/// A channel's details: what it is and how it's reached, and who's in it,
/// each to tap for their card.
class ChannelDetailsPage extends StatelessWidget {
  final CommController comm;
  final String conversationKey;
  const ChannelDetailsPage({super.key, required this.comm, required this.conversationKey});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([comm, comm.conversations]),
      builder: (context, _) {
        final c = comm.conversations.all[conversationKey];
        if (c == null) return const Scaffold(body: Center(child: Text('Deleted')));
        final online = comm.isOnline(c);
        final people = conversationPeople(comm, c);
        final m = comm.mumble;
        final d = comm.boardSettings?.direct;
        final g = comm.invitableGroup;
        final texts = c.entries.where((e) => e.kind == ConversationEntry.text).length;
        final first = c.entries.isEmpty ? null : c.entries.first.time;
        return Scaffold(
          appBar: AppBar(title: const Text('Details')),
          body: ListView(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 24 + MediaQuery.paddingOf(context).bottom),
            children: [
              const SectionHeader('Channel'),
              Panel(children: [
                _Fact('Name', c.title),
                _Fact('Type', switch (c.kind) {
                  ConversationKind.server => 'Cloud server',
                  ConversationKind.direct => 'Direct, board to board',
                  ConversationKind.everyone => 'Broadcast: server channel and direct',
                  ConversationKind.person => 'One person',
                }),
                if (!online) const _Fact('Status', 'Not on it just now', color: Kc.softRed),
                // The server's: where, how the voice goes, who we are there
                if (online && c.kind == ConversationKind.server && m != null) ...[
                  _Fact('Server', '${m.host}:${comm.server.port}'),
                  _Fact('Path', m.channelPath(m.myChannel)),
                  _Fact('Voice', m.udpActive ? 'UDP, encrypted' : 'TCP tunnel, encrypted'),
                  _Fact('You are', comm.server.username),
                ],
                // Direct's: the radio, who can hear it, who we are on it
                if (online && c.kind == ConversationKind.direct && d != null) ...[
                  _Fact('Frequency', '${d.channel}'),
                  _Fact('Long Range', d.longRange ? 'On' : 'Off'),
                  _Fact('Access', d.keyed ? 'Passphrase: encrypted' : 'Open: anyone nearby can hear it'),
                  if (d.keyed) _Fact('Channel id', d.id),
                  if (d.keyed && g != null) _Fact('Kept here', g.mine ? 'Made on this phone' : 'Joined'),
                  _Fact('You are', d.name),
                ],
                if (c.kind == ConversationKind.everyone)
                  const _Fact('Reaches', 'Your server channel, and every unit heard nearby'),
                _Fact('Messages', texts == 0 ? 'None yet' : '$texts${first == null ? '' : ' since ${_date(first)}'}'),
              ]),
              if (online && c.kind == ConversationKind.direct && g != null) ...[
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () => pickInvitee(context, comm, g),
                  icon: const Icon(Icons.person_add_alt, size: 18),
                  label: Text('Invite someone to ${g.name}'),
                ),
              ],
              SectionHeader('People · ${people.length + (online ? 1 : 0)}'),
              Panel(children: [
                if (online)
                  PanelRow(
                    leading: DroneAvatar(picture: comm.avatar, size: 40),
                    title: 'You',
                    subtitle: c.kind == ConversationKind.direct ? d?.name : comm.server.username,
                  ),
                for (final p in people)
                  PanelRow(
                    leading: DroneAvatar(picture: p.picture, size: 40, talking: p.talking && !p.mutedByMe),
                    title: p.name,
                    subtitle: p.mutedByMe
                        ? 'Muted by you'
                        : p.talking
                            ? 'TALKING'
                            : [if (p.onServer) 'Server', if (p.board != null) 'Direct'].join(' · '),
                    trailing: [
                      if (p.board != null) SignalBars(p.board!.rssi),
                      const Icon(Icons.chevron_right, color: Kc.muted),
                    ],
                    onTap: () => showPerson(context, comm, id: p.id),
                  ),
                if (!online) const PanelRow(title: 'Not on this channel just now'),
              ]),
            ],
          ),
        );
      },
    );
  }

  static String _date(DateTime t) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${t.day} ${months[t.month - 1]} ${t.year}';
  }
}

class _Fact extends StatelessWidget {
  final String name;
  final String value;
  final Color? color;
  const _Fact(this.name, this.value, {this.color});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Row(children: [
          Text(name, style: const TextStyle(color: Kc.muted)),
          const SizedBox(width: 16),
          Expanded(child: SelectableText(value, textAlign: TextAlign.end, style: Kc.term(15, color: color ?? Kc.text))),
        ]),
      );
}
