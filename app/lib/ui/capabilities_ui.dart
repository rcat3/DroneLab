import 'package:flutter/material.dart';

import '../comm/capabilities.dart';
import '../comm/comm_controller.dart';
import '../comm/conversations.dart';
import 'control_page.dart';
import 'people.dart';
import 'text_page.dart';
import 'theme.dart';
import 'widgets.dart';

/// Controlling others: everything there is to control, by capability
/// (capabilities.dart), how each one shows, and the screens that pick one.

/// The one icon for all of it.
const controlIcon = Icons.settings_remote;

/// Something others can control, as this app shows it.
class ControlKind {
  final int id;             // Capabilities.*
  final String name;
  final IconData icon;
  final String does;
  const ControlKind(this.id, this.name, this.icon, this.does);
}

/// Each one this app knows, in the order they're shown. New ones go here.
const controlKinds = [
  ControlKind(Capabilities.terminal, 'Terminal', Icons.terminal, 'Put words on their display'),
  ControlKind(Capabilities.lovense, 'Lovense', Icons.tune, 'Control their toys'),
];

/// What someone lets others control, by who they are; null if they haven't
/// said yet, or aren't about.
Capabilities? capabilitiesOfPerson(CommController comm, String id) {
  for (final p in peopleOnce(comm)) {
    if (p.id == id) return comm.capabilitiesOf(user: p.user, board: p.board);
  }
  return null;
}

/// What a conversation's for: someone's, for one person; null for a group,
/// whose people may each let others control different things.
Capabilities? capabilitiesOfConversation(CommController comm, Conversation c) =>
    c.kind == ConversationKind.person ? capabilitiesOfPerson(comm, CommController.personOf(c)) : null;

/// Whether it can be picked: anything, if they haven't said.
bool canControl(Capabilities? caps, int id) => caps == null || caps.has(id);

String _howOpen(Capabilities? caps, int id) => switch (caps?[id]) {
      CapOpen.open => 'Anyone can control it',
      CapOpen.ask => 'Only people they allow',
      null => caps == null ? 'Not known' : 'Not available',
    };

/// Start controlling one of them.
void openControl(BuildContext context, CommController comm, Conversation c, int id) {
  switch (id) {
    case Capabilities.terminal:
      showTerminalSheet(context, comm, c);
    case Capabilities.lovense:
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => ControlPage(comm: comm, target: c)));
  }
}

/// The icons of what's available, for someone's card: "None", or "Not
/// known" if they haven't said.
class CapabilityIcons extends StatelessWidget {
  final Capabilities? caps;
  const CapabilityIcons(this.caps, {super.key});

  @override
  Widget build(BuildContext context) {
    final c = caps;
    final shown = [for (final k in controlKinds) if (c != null && c.has(k.id)) k];
    if (shown.isEmpty) return Text(c == null ? 'Not known' : 'None', style: const TextStyle(color: Kc.muted));
    return Row(mainAxisSize: MainAxisSize.min, children: [
      for (final k in shown)
        Padding(
          padding: const EdgeInsets.only(left: 10),
          child: Icon(k.icon, size: 22, color: Kc.pink, semanticLabel: k.name),
        ),
    ]);
  }
}

/// Everything there is to control, and whether [name] lets others: from
/// their card.
Future<void> showCapabilities(BuildContext context, String name, Capabilities? caps) => showDialog<void>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text('What $name lets others control'),
        contentPadding: const EdgeInsets.fromLTRB(8, 16, 8, 0),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final k in controlKinds) _KindRow(k, caps),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              caps == null
                  ? "Not known: they haven't said yet."
                  : "If it's only people they allow, your first command asks them for permission.",
              style: const TextStyle(color: Kc.muted, fontSize: 13),
            ),
          ),
        ]),
        actions: [TextButton(onPressed: () => Navigator.pop(dialog), child: const Text('OK'))],
      ),
    );

class _KindRow extends StatelessWidget {
  final ControlKind kind;
  final Capabilities? caps;
  final VoidCallback? onTap;
  final bool pickable;
  final bool reachable;
  const _KindRow(this.kind, this.caps, {this.onTap, this.pickable = false, this.reachable = true});

  @override
  Widget build(BuildContext context) {
    final on = reachable && canControl(caps, kind.id);
    final row = PanelRow(
      leading: Icon(kind.icon, color: on ? Kc.pink : Kc.dim),
      title: kind.name,
      subtitle: pickable ? '${kind.does} · ${_howOpen(caps, kind.id)}' : _howOpen(caps, kind.id),
      trailing: [if (pickable && on) const Icon(Icons.chevron_right, color: Kc.muted)],
      onTap: on ? onTap : null,
    );
    return on ? row : Opacity(opacity: 0.45, child: row);
  }
}

/// Pick what to control of theirs: what they don't let others control is
/// greyed out. From the Control button on someone's card.
class ControlChooserPage extends StatelessWidget {
  final CommController comm;
  final Conversation target;
  const ControlChooserPage({super.key, required this.comm, required this.target});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: comm,
        builder: (context, _) {
          final caps = capabilitiesOfConversation(comm, target);
          final online = comm.isOnline(target);
          return Scaffold(
            appBar: AppBar(title: const Text('Control')),
            body: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                SectionHeader('To ${target.audience}'),
                if (!online)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: Text("They can't be reached just now", style: TextStyle(color: Kc.muted, fontSize: 13)),
                  ),
                Panel(children: [
                  for (final k in controlKinds)
                    _KindRow(k, caps,
                        pickable: true, reachable: online, onTap: () => openControl(context, comm, target, k.id)),
                ]),
                const SizedBox(height: 8),
                Text(
                  caps == null
                      ? "They haven't said yet what they let others control. You can try any of these."
                      : "Greyed out: they don't let anyone control it, or don't have it.",
                  style: const TextStyle(color: Kc.muted, fontSize: 13),
                ),
              ],
            ),
          );
        },
      );
}
