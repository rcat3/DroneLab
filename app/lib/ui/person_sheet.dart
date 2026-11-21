import 'package:flutter/material.dart';

import '../comm/comm_controller.dart';
import '../comm/known_people.dart';
import 'capabilities_ui.dart';
import 'people.dart';
import 'status_strip.dart';
import 'text_page.dart';
import 'theme.dart';
import 'widgets.dart';

/// Someone in the hive: who they are, how they're linked, what they run, and
/// muting them; and shortcuts to message or control them. Found by [key]
/// (one of their links), or by [id], who they are (the first link they're
/// on, or just their name and muting if they're not about).
/// [inConversation] leaves out Message, as it's opened from their
/// conversation.
Future<void> showPerson(BuildContext context, CommController comm,
        {String? key, String? id, bool inConversation = false}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheet) => ListenableBuilder(
        listenable: comm,
        builder: (sheet, _) {
          final found = hivePeople(comm).where((p) => key != null ? p.key == key : p.id == id);
          final known = id == null ? null : comm.people[id];
          if (found.isEmpty && known == null) {
            return const SafeArea(
              child: Padding(padding: EdgeInsets.all(24), child: Text("They've gone", textAlign: TextAlign.center)),
            );
          }
          if (found.isEmpty) return _away(context, sheet, comm, known!, inConversation);
          final p = found.first;
          final clash = comm.nameClash(p.who);
          final talking = p.talking && !p.mutedByMe;
          final b = p.board;
          final m = comm.mumble;
          final direct = comm.boardSettings?.direct;
          final link = p.onServer
              ? 'Server · ${m == null ? '' : m.channelPath(p.user!.channel)}'
              : 'Direct · ${direct == null ? '' : directChannelName(direct)}';
          final caps = capabilitiesOfPerson(comm, p.id);
          final ago = b == null ? null : (DateTime.now().millisecondsSinceEpoch - b.seenMs) ~/ 1000;
          Widget kv(String k, Widget v) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 32),
                  child: Row(children: [
                    Expanded(child: Text(k, style: const TextStyle(color: Kc.muted, fontSize: 14))),
                    v,
                  ]),
                ),
              );
          Widget value(String s) => Flexible(child: Text(s, textAlign: TextAlign.end));
          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [
                    DroneAvatar(picture: p.picture, talking: talking, size: 76),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(p.name, style: Kc.term(24)),
                          const SizedBox(height: 4),
                          Text(
                            p.mutedByMe
                                ? 'Muted by you'
                                : talking
                                    ? 'TALKING'
                                    : p.user?.muted ?? false
                                        ? 'Muted'
                                        : 'Listening',
                            style: talking ? Kc.term(14, color: Kc.green) : const TextStyle(color: Kc.muted),
                          ),
                        ],
                      ),
                    ),
                  ]),
                  const SizedBox(height: 14),
                  Panel(color: Kc.bg, children: [
                    kv('Link', value(link)),
                    if (b != null)
                      kv('Signal', Row(mainAxisSize: MainAxisSize.min, children: [
                        SignalBars(b.rssi),
                        const SizedBox(width: 8),
                        Text('${b.rssi} dBm', style: Kc.term(16)),
                      ])),
                    if (ago != null) kv('Last heard', value(ago < 3 ? 'Now' : '$ago s ago')),
                    if (b != null) kv('Firmware', value(b.firmware.isEmpty ? 'Not known' : b.firmware)),
                    if (b != null) kv('App', value(b.app.isEmpty ? 'None linked' : b.app)),
                    kv('Known by', value(_knownBy(p.who))),
                    InkWell(
                      onTap: () => showCapabilities(context, p.name, caps),
                      child: kv('Lets others control', CapabilityIcons(caps)),
                    ),
                    kv('Mute for me', Switch(value: p.mutedByMe, onChanged: (on) => comm.setMuted(p.id, on))),
                  ]),
                  if (clash != null) _ClashNote(comm: comm, old: clash, now: p.who),
                  const _MuteNote(),
                  const SizedBox(height: 12),
                  Row(children: [
                    if (!inConversation) ...[
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () {
                            Navigator.pop(sheet);
                            openConversation(context, comm, comm.personConversation(p.id));
                          },
                          icon: const Icon(Icons.chat_bubble_outline, size: 18),
                          label: const Text('Message'),
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () {
                          Navigator.pop(sheet);
                          Navigator.of(context).push(MaterialPageRoute(
                              builder: (_) => ControlChooserPage(comm: comm, target: comm.personConversation(p.id))));
                        },
                        icon: const Icon(controlIcon, size: 18),
                        label: const Text('Control'),
                      ),
                    ),
                  ]),
                  // To the direct channel we're on, if it's one with a passphrase
                  if (comm.invitableGroup case final g?) ...[
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: comm.whyNotInvite(p.id) != null
                          ? null
                          : () async {
                              final messenger = ScaffoldMessenger.of(context);
                              final why = await comm.invite(p.id, g);
                              messenger.showSnackBar(SnackBar(content: Text(why ?? 'Invitation sent to ${p.name}')));
                            },
                      icon: const Icon(Icons.person_add_alt, size: 18),
                      label: Text('Invite to ${g.name}'),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );

class _MuteNote extends StatelessWidget {
  const _MuteNote();

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.fromLTRB(4, 6, 4, 0),
        child: Text('Muted, their voice, texts and commands are all ignored.',
            style: TextStyle(color: Kc.muted, fontSize: 13)),
      );
}

/// How we know who someone is.
String _knownBy(KnownPerson who) => who.key != null
    ? 'Identity ${who.id.substring(2, 10)}'
    : who.identified
        ? 'Certificate ${who.id.substring(2, 10)}'
        : 'Name only';

/// Someone's using a name someone else had first: a warning, and, if it
/// really is them with a new identity (a new phone, or the app put back
/// without their backup code), a way to say so.
class _ClashNote extends StatelessWidget {
  final CommController comm;
  final KnownPerson old;    // who had the name first
  final KnownPerson now;    // who's using it
  const _ClashNote({required this.comm, required this.old, required this.now});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.warning_amber, size: 18, color: Kc.softRed),
            const SizedBox(width: 6),
            Expanded(
              child: Text('Not the ${old.name} you knew before: someone else using the name.',
                  style: const TextStyle(color: Kc.softRed, fontSize: 13)),
            ),
          ]),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(onPressed: () => _confirm(context), child: Text("It's ${old.name}, with a new identity")),
          ),
        ]),
      );

  Future<void> _confirm(BuildContext context) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text('Is this ${old.name}?'),
        content: Text(
            "Only if you're sure, say by asking them in person: anyone can use a name. Their new identity takes the "
            "place of the old one here, with your conversation, and the old one's forgotten.\n\n"
            "If you'd allowed them on your unit, allow them again there: it knows them by identity too."),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(dialog, true), child: Text("It's ${old.name}")),
        ],
      ),
    );
    if (yes == true) comm.acceptNewIdentity(old, now);
  }
}

/// Someone not about just now: their name, and muting them.
Widget _away(BuildContext context, BuildContext sheet, CommController comm, KnownPerson who, bool inConversation) =>
    SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            const DroneAvatar(size: 76),
            const SizedBox(width: 16),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(who.name, style: Kc.term(24)),
                const SizedBox(height: 4),
                Text(who.muted ? 'Muted by you' : 'Not about just now',
                    style: const TextStyle(color: Kc.muted)),
              ]),
            ),
          ]),
          const SizedBox(height: 14),
          Panel(color: Kc.bg, children: [
            PanelRow(
              title: 'Mute for me',
              trailing: [Switch(value: who.muted, onChanged: (on) => comm.setMuted(who.id, on))],
            ),
          ]),
          const _MuteNote(),
          if (!inConversation) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () {
                Navigator.pop(sheet);
                openConversation(context, comm, comm.personConversation(who.id));
              },
              icon: const Icon(Icons.chat_bubble_outline, size: 18),
              label: const Text('Message'),
            ),
          ],
        ]),
      ),
    );


/// Everyone in a channel, [inIt] picking them from everyone about, and
/// us first if we're in it ([withYou]), as its count has us; tap one for
/// their card. Kept up to date while it shows.
Future<void> showChannelPeople(
        BuildContext context, CommController comm, String title, bool Function(Person p) inIt,
        {bool withYou = false, String? youAre}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheet) => ListenableBuilder(
        listenable: comm,
        builder: (sheet, _) {
          final people = peopleOnce(comm).where(inIt).toList()
            ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
          return SafeArea(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              children: [
                SectionHeader(title),
                if (people.isEmpty && !withYou)
                  const Panel(children: [PanelRow(title: 'Nobody here')])
                else
                  Panel(color: Kc.bg, children: [
                    if (withYou) PanelRow(leading: DroneAvatar(picture: comm.avatar, size: 36), title: 'You', subtitle: youAre),
                    for (final p in people)
                      PanelRow(
                        leading: DroneAvatar(picture: p.picture, size: 36, talking: p.talking && !p.mutedByMe),
                        title: p.name,
                        subtitle: p.mutedByMe
                            ? 'Muted by you'
                            : p.talking
                                ? 'TALKING'
                                : [if (p.onServer) 'Server', if (p.board != null) 'Direct'].join(' · '),
                        trailing: const [Icon(Icons.chevron_right, color: Kc.muted)],
                        onTap: () => showPerson(context, comm, id: p.id),
                      ),
                  ]),
              ],
            ),
          );
        },
      ),
    );
