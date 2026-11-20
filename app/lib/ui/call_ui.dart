import 'package:flutter/material.dart';

import '../comm/calls.dart';
import '../comm/invites.dart';
import '../comm/comm_controller.dart';
import '../main.dart';
import 'people.dart';
import 'theme.dart';
import 'widgets.dart';

/// Whose call's on screen, so the same one isn't shown twice.
String? _showing;

/// Someone's calling: who, with Answer and Decline, over whatever's on
/// screen. It goes by itself once the call's answered, turned down or given
/// up on, from here or anywhere else.
void showIncomingCall(CommController comm, String personId) {
  final context = navigatorKey.currentContext;
  if (context == null || _showing == personId) return;
  _showing = personId;
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialog) => ListenableBuilder(
      listenable: comm,
      builder: (dialog, _) {
        final call = comm.calls[personId];
        if (call == null || call.state != CallState.ringing) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (Navigator.of(dialog).canPop()) Navigator.of(dialog).pop();
          });
        }
        final name = comm.people[personId]?.name ?? '?';
        final busyWith = comm.inCallWith;
        final other = busyWith == null || busyWith == personId ? null : comm.people[busyWith]?.name;
        return AlertDialog(
          insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          backgroundColor: Kc.panel,
          shape: RoundedRectangleBorder(
              side: const BorderSide(color: Kc.green), borderRadius: BorderRadius.circular(16)),
          title: Text(other == null ? '> INCOMING CALL' : '> CALL WAITING',
              style: Kc.term(16, color: Kc.green, shadows: Kc.glow(Kc.green))),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            DroneAvatar(picture: comm.avatarOf(personId), size: 96, talking: true),
            const SizedBox(height: 16),
            Text(name, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(other == null ? 'Calling you, alone' : "Calling you. Answering puts your call with $other on hold",
                textAlign: TextAlign.center, style: const TextStyle(color: Kc.muted)),
          ]),
          // Side by side, each half the width, however narrow the screen
          actions: [
            Row(children: [
              Expanded(
                child: FilledButton.icon(
                  style: _button(Kc.red),
                  onPressed: () {
                    comm.endCall(personId);
                    Navigator.of(dialog).pop();
                  },
                  icon: const Icon(Icons.call_end),
                  label: const _OneLine('Decline'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  style: _button(Kc.darkGreen),
                  onPressed: () {
                    comm.answerCall(personId);
                    appTab.value = tabVoice;
                    Navigator.of(dialog).pop();
                  },
                  icon: const Icon(Icons.call),
                  label: const _OneLine('Answer'),
                ),
              ),
            ]),
          ],
        );
      },
    ),
  ).whenComplete(() {
    if (_showing == personId) _showing = null;
  });
}

/// Room for the words on a narrow phone: less padding than usual.
ButtonStyle _button(Color c) => FilledButton.styleFrom(
    backgroundColor: c,
    foregroundColor: Colors.white,
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12));

/// A button's word, on one line, made smaller rather than broken.
class _OneLine extends StatelessWidget {
  final String text;
  const _OneLine(this.text);

  @override
  Widget build(BuildContext context) =>
      FittedBox(fit: BoxFit.scaleDown, child: Text(text, maxLines: 1, softWrap: false));
}

/// Someone's invited us to a direct channel: join it, or not.
void showInvitation(CommController comm, Invitation inv) {
  final context = navigatorKey.currentContext;
  if (context == null) return;
  showDialog<void>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text('> INVITATION', style: Kc.term(16, color: Kc.green, shadows: Kc.glow(Kc.green))),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${inv.from} invites you to the direct channel', style: const TextStyle(color: Kc.muted)),
        const SizedBox(height: 8),
        Row(children: [
          const Icon(Icons.lock, color: Kc.green, size: 20),
          const SizedBox(width: 8),
          Flexible(child: Text(inv.name, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600))),
        ]),
        const SizedBox(height: 4),
        Text('Frequency ${inv.channel}${inv.longRange ? ', Long Range' : ''}', style: const TextStyle(color: Kc.muted)),
        const SizedBox(height: 12),
        const Text("Joining switches your unit to it, and keeps it under Your channels. You won't need its passphrase.",
            style: TextStyle(color: Kc.muted, fontSize: 13)),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialog), child: const Text('Not now')),
        FilledButton(
          onPressed: () async {
            Navigator.pop(dialog);
            final messenger = messengerKey.currentState;
            final why = await comm.joinGroup(inv.name, inv.passphrase, channel: inv.channel, longRange: inv.longRange);
            if (why == null) await comm.setTalkTo(const TalkTarget.direct());
            messenger?.showSnackBar(SnackBar(content: Text(why ?? 'Joined ${inv.name}')));
          },
          child: const Text('Join'),
        ),
      ],
    ),
  );
}

/// Pick someone to invite to [g]: those about with the app.
Future<void> pickInvitee(BuildContext context, CommController comm, DirectGroup g) async {
  final people = peopleOnce(comm)..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  final picked = await showModalBottomSheet<String>(
    context: context,
    builder: (sheet) => SafeArea(
      child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), children: [
        SectionHeader('Invite to ${g.name}'),
        if (people.isEmpty)
          const Panel(children: [PanelRow(title: 'Nobody about')])
        else
          Panel(color: Kc.bg, children: [
            for (final p in people)
              PanelRow(
                leading: DroneAvatar(picture: p.picture, size: 36),
                title: p.name,
                subtitle: comm.whyNotInvite(p.id),
                onTap: comm.whyNotInvite(p.id) == null ? () => Navigator.pop(sheet, p.id) : null,
                trailing: [
                  if (comm.whyNotInvite(p.id) == null) const Icon(Icons.person_add_alt, color: Kc.pink),
                  const SizedBox(width: 8),
                ],
              ),
          ]),
      ]),
    ),
  );
  if (picked == null || !context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  final why = await comm.invite(picked, g);
  messenger.showSnackBar(SnackBar(content: Text(why ?? 'Invitation sent to ${comm.people[picked]?.name}')));
}
