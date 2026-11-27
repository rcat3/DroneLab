import 'package:flutter/material.dart';

import '../comm/capabilities.dart';
import '../comm/comm_controller.dart';
import '../comm/conversations.dart';
import '../comm/rules.dart' show RuleClass;
import 'control_page.dart';
import 'display_sheet.dart';
import 'sound_sheet.dart';
import 'people.dart';
import 'theme.dart';
import 'widgets.dart';

/// HiveMind Control: controlling others, everything there is to control,
/// by area (Toys, the Display unit) and capability (capabilities.dart), how
/// each one shows, and the screens that pick one.

/// The one icon for all of it.
const controlIcon = Icons.settings_remote;

/// HiveMind Control's areas, in the order they're shown.
enum ControlArea {
  toys('Toys'),
  display('Display unit');

  final String name;
  const ControlArea(this.name);
}

/// Something others can control, as this app shows it.
class ControlKind {
  final int id;             // Capabilities.*
  final ControlArea? area;     // null: only in Permissions, not something to control from here
  final String name;
  final IconData icon;
  final String does;
  const ControlKind(this.id, this.area, this.name, this.icon, this.does);
}

/// Each one this app knows, by area, in the order they're shown. New ones
/// (E-stim, Machines) go here.
const controlKinds = [
  ControlKind(Capabilities.vibe, ControlArea.toys, 'Vibe', Icons.vibration, 'Their vibrating toys, by channel'),
  ControlKind(Capabilities.display, ControlArea.display, 'Display', Icons.monitor, 'Put words or pictures on their display'),
  ControlKind(Capabilities.sounds, ControlArea.display, 'Sounds', Icons.volume_up_outlined,
      "Play a sound from their unit's speaker"),
];

/// HiveSight, in Permissions only: a Guide's invitations are joined from
/// Text, and the Vessel's phone goes by these, not the unit.
const hiveSightKinds = [
  ControlKind(RuleClass.hiveSight, null, 'HiveSight', Icons.visibility_outlined,
      'Guide you in a HiveSight session, when you join their invitation'),
  ControlKind(RuleClass.hiveSightPulse, null, 'Light pulse', Icons.flare,
      'Use the flashing light pulse in a HiveSight session they guide'),
];

/// Everything Permissions shows, in order.
const permissionKinds = [...controlKinds, ...hiveSightKinds];

/// Those of one area.
Iterable<ControlKind> kindsOf(ControlArea area) => controlKinds.where((k) => k.area == area);

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
    case Capabilities.display:
      showDisplaySheet(context, comm, c);
    case Capabilities.sounds:
      showSoundSheet(context, comm, c);
    case Capabilities.vibe:
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => ToysPage(comm: comm, target: c)));
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
          for (final a in ControlArea.values) ...[
            _AreaHeader(a),
            for (final k in kindsOf(a)) _KindRow(k, caps),
          ],
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

class _AreaHeader extends StatelessWidget {
  final ControlArea area;
  const _AreaHeader(this.area);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
        child: Text(area.name.toUpperCase(), style: Kc.term(14, color: Kc.muted)),
      );
}

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

/// HiveMind Control, for someone: pick what to control of theirs, by area;
/// what they don't let others control is greyed out. From the Control
/// button on someone's card.
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
            appBar: AppBar(title: const Text('HiveMind Control')),
            body: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                SectionHeader('To ${target.audience}'),
                if (!online)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: Text("They can't be reached just now", style: TextStyle(color: Kc.muted, fontSize: 13)),
                  ),
                for (final a in ControlArea.values) ...[
                  SectionHeader(a.name),
                  Panel(children: [
                    for (final k in kindsOf(a))
                      _KindRow(k, caps,
                          pickable: true, reachable: online, onTap: () => openControl(context, comm, target, k.id)),
                  ]),
                ],
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
