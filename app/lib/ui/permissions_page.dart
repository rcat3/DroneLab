import 'package:flutter/material.dart';

import '../comm/comm_controller.dart';
import '../comm/permissions.dart';
import 'capabilities_ui.dart';
import 'theme.dart';
import 'widgets.dart';

/// The icon for requests waiting: a raised hand.
const requestIcon = Icons.front_hand;

/// Requests waiting, as a raised hand and how many: nothing for none.
class RequestsBadge extends StatelessWidget {
  final int count;
  final double size;
  const RequestsBadge(this.count, {super.key, this.size = 16});

  @override
  Widget build(BuildContext context) {
    if (count == 0) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(color: Kc.warn, borderRadius: BorderRadius.circular(size)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(requestIcon, size: size, color: Kc.bg, semanticLabel: 'Permission requests'),
        const SizedBox(width: 3),
        Text('$count', style: Kc.term(size - 2, color: Kc.bg)),
      ]),
    );
  }
}

/// A row that opens the Permissions screen, with its requests' badge: for
/// Setup and the links' sheet.
class PermissionsRow extends StatelessWidget {
  final CommController comm;
  final VoidCallback? before;     // e.g. closing the sheet it's on
  const PermissionsRow({super.key, required this.comm, this.before});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: comm.permissions,
        builder: (context, _) {
          final n = comm.permissions.requests.length;
          return PanelRow(
            leading: const Icon(Icons.admin_panel_settings_outlined, color: Kc.muted),
            title: 'Permissions',
            subtitle: n == 0
                ? 'Who may control what of yours'
                : n == 1
                    ? 'A request waiting'
                    : '$n requests waiting',
            trailing: [RequestsBadge(n), const Icon(Icons.chevron_right, color: Kc.muted)],
            onTap: () {
              before?.call();
              openPermissions(context, comm);
            },
          );
        },
      );
}

void openPermissions(BuildContext context, CommController comm) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => PermissionsPage(comm: comm)));

String _ago(DateTime t) {
  final s = DateTime.now().difference(t).inSeconds;
  if (s < 60) return 'just now';
  if (s < 3600) return '${s ~/ 60} min ago';
  if (s < 86400) return '${s ~/ 3600} h ago';
  return '${s ~/ 86400} d ago';
}

ControlKind _kind(int cap) => controlKinds.firstWhere((k) => k.id == cap);

Widget _capIcons(Iterable<int> caps, {Color color = Kc.pink}) => Row(mainAxisSize: MainAxisSize.min, children: [
      for (final k in controlKinds)
        if (caps.contains(k.id))
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Icon(k.icon, size: 18, color: color, semanticLabel: k.name),
          ),
    ]);

/// Pick what to allow someone: [initial] ticked. Returns what's picked, or
/// null if it's left. [all] offers Grant all.
Future<Set<int>?> showGrantSheet(BuildContext context, CommController comm,
    {required String title, required Set<int> initial, String action = 'Grant', bool all = true}) {
  final picked = {...initial};
  return showModalBottomSheet<Set<int>>(
    context: context,
    isScrollControlled: true,
    builder: (sheet) => StatefulBuilder(
      builder: (sheet, setState) {
        final policy = comm.permissions.policy;
        String? note(int cap) => switch (policy?.caps[cap]?.policy) {
              Policy.off => "Off just now: it's theirs once you switch it on",
              Policy.anyone => 'Open to anyone just now: theirs too if you set it to Ask',
              _ => null,
            };
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SectionHeader(title),
              Panel(color: Kc.bg, children: [
                for (final k in controlKinds)
                  CheckboxListTile(
                    value: picked.contains(k.id),
                    onChanged: (on) => setState(() => on == true ? picked.add(k.id) : picked.remove(k.id)),
                    secondary: Icon(k.icon, color: Kc.pink),
                    title: Text(k.name),
                    subtitle: Text(note(k.id) ?? k.does, style: const TextStyle(color: Kc.muted, fontSize: 13)),
                  ),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                if (all) ...[
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(sheet, {for (final k in controlKinds) k.id}),
                      child: const Text('Grant all'),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: FilledButton(
                    onPressed: !all || picked.isNotEmpty ? () => Navigator.pop(sheet, picked) : null,
                    child: Text(action),
                  ),
                ),
              ]),
            ]),
          ),
        );
      },
    ),
  );
}

/// Who may control what of yours, in one place: requests waiting, each
/// capability's policy on the unit, who's in its list, and who's been
/// declined.
class PermissionsPage extends StatelessWidget {
  final CommController comm;
  const PermissionsPage({super.key, required this.comm});

  Permissions get perms => comm.permissions;

  Future<void> _accept(BuildContext context, PermissionRequest r) async {
    final caps = await showGrantSheet(context, comm, title: 'Allow ${r.name}', initial: r.caps);
    if (caps != null) await perms.accept(r, caps);
  }

  Future<void> _grantDeclined(BuildContext context, PermissionRequest r) async {
    final caps = await showGrantSheet(context, comm, title: 'Allow ${r.name}', initial: r.caps);
    if (caps != null) await perms.grant(r.key, r.name, caps);
  }

  Future<void> _editPerson(BuildContext context, BoardPolicy policy, ListedPerson p) async {
    final now = {for (final e in policy.caps.entries) if (e.value.person(p.id)?.allowed ?? false) e.key};
    final caps =
        await showGrantSheet(context, comm, title: 'Allow ${p.name}', initial: now, action: 'Save', all: false);
    if (caps == null) return;
    await perms.setAllowed(p.id, {for (final k in controlKinds) k.id: caps.contains(k.id)});
  }

  Future<void> _forget(BuildContext context, ListedPerson p) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('Remove ${p.name}?'),
        content: const Text("They're taken off your unit's list, and allowed nothing. If they send again, "
            "they're back on it, and ask again."),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(d, true), child: const Text('Remove')),
        ],
      ),
    );
    if (yes == true) await perms.forget(p.id);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([comm, perms]),
        builder: (context, _) {
          final ready = perms.boardReady;
          final policy = ready ? perms.policy : null;
          const small = TextStyle(color: Kc.muted, fontSize: 13);
          return Scaffold(
            appBar: AppBar(title: const Text('Permissions')),
            body: ListView(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 24 + MediaQuery.paddingOf(context).bottom),
              children: [
                if (policy == null)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: Text('Connect to your unit to change these: it keeps them.', style: small),
                  ),
                SectionHeader('Requests', trailing: RequestsBadge(perms.requests.length)),
                if (perms.requests.isEmpty)
                  const Panel(children: [PanelRow(title: 'None waiting')])
                else
                  Panel(children: [
                    for (final r in perms.requests)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          Row(children: [
                            Expanded(child: Text(r.name, style: const TextStyle(fontWeight: FontWeight.w600))),
                            _capIcons(r.caps),
                            Text(_ago(r.time), style: small),
                          ]),
                          Text(
                            'Asks for ${r.caps.map((c) => _kind(c).name).join(' and ')}'
                            '${r.what.isEmpty ? '' : ' · ${r.what}'}',
                            style: small,
                          ),
                          const SizedBox(height: 6),
                          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                            TextButton(onPressed: () => perms.decline(r), child: const Text('Decline')),
                            const SizedBox(width: 8),
                            FilledButton(
                                onPressed: policy == null ? null : () => _accept(context, r),
                                child: const Text('Accept')),
                          ]),
                        ]),
                      ),
                  ]),
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text(
                      "Commands from those you haven't allowed, for something set to Ask. They're not told: "
                      'their commands are just done once you accept.',
                      style: small),
                ),
                for (final k in controlKinds) _CapSection(comm: comm, kind: k, policy: policy?.caps[k.id]),
                if (policy != null && policy.everyone.isNotEmpty) ...[
                  const SectionHeader('On your unit\'s list'),
                  Panel(children: [
                    for (final p in policy.everyone)
                      PanelRow(
                        title: p.clash ? '⚠ ${p.name}' : p.name,
                        subtitle: p.clash ? 'Someone else using a name someone listed had first' : null,
                        leading: _capIcons({
                          for (final e in policy.caps.entries)
                            if (e.value.person(p.id)?.allowed ?? false) e.key
                        }),
                        trailing: [
                          IconButton(
                            tooltip: 'Remove',
                            icon: const Icon(Icons.person_remove_outlined, color: Kc.muted),
                            onPressed: () => _forget(context, p),
                          ),
                          const Icon(Icons.chevron_right, color: Kc.muted),
                        ],
                        onTap: () => _editPerson(context, policy, p),
                      ),
                  ]),
                  const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: Text("Those who've sent commands, or are allowed: the icons are what they're allowed. "
                        'Tap one to change it.', style: small),
                  ),
                ],
                if (perms.declined.isNotEmpty) ...[
                  const SectionHeader('Declined'),
                  Panel(children: [
                    for (final r in perms.declined)
                      PanelRow(
                        title: r.name,
                        subtitle: 'Declined ${r.caps.map((c) => _kind(c).name).join(' and ')} · ${_ago(r.time)}',
                        trailing: [
                          IconButton(
                            tooltip: 'Take off the list',
                            icon: const Icon(Icons.close, color: Kc.muted),
                            onPressed: () => perms.removeDeclined(r),
                          ),
                          OutlinedButton(
                              onPressed: policy == null ? null : () => _grantDeclined(context, r),
                              child: const Text('Grant')),
                        ],
                      ),
                  ]),
                  const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: Text("Their commands don't ask again for what was declined. Taken off this list, "
                        'they can.', style: small),
                  ),
                ],
              ],
            ),
          );
        },
      );
}

/// One capability's policy: Off, Ask or Anyone, and what it ignores.
class _CapSection extends StatelessWidget {
  final CommController comm;
  final ControlKind kind;
  final CapPolicy? policy;
  const _CapSection({required this.comm, required this.kind, required this.policy});

  @override
  Widget build(BuildContext context) {
    final p = policy;
    final perms = comm.permissions;
    Widget ignoring(String title, String subtitle, int bit) => PanelRow(
          title: title,
          subtitle: subtitle,
          trailing: [
            Switch(
              value: p != null && p.ignore & bit != 0,
              onChanged: p == null || p.policy == Policy.off
                  ? null
                  : (on) => perms.setIgnore(kind.id, on ? p.ignore | bit : p.ignore & ~bit),
            ),
          ],
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionHeader(kind.name, trailing: Icon(kind.icon, color: Kc.muted, size: 20)),
      Panel(children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(kind.does, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            SegmentedButton<Policy>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: Policy.off, label: Text('OFF')),
                ButtonSegment(value: Policy.ask, label: Text('ASK')),
                ButtonSegment(value: Policy.anyone, label: Text('ANYONE')),
              ],
              selected: {p?.policy ?? Policy.off},
              onSelectionChanged: p == null ? null : (sel) => perms.setPolicy(kind.id, sel.first),
            ),
            const SizedBox(height: 6),
            Text(
              switch (p?.policy) {
                Policy.off => "Nobody. Who you've allowed is kept for when it's on again",
                Policy.ask => "Those you've allowed. Others' commands come here as requests",
                Policy.anyone => 'Anyone in the hive',
                null => '',
              },
              style: const TextStyle(color: Kc.muted, fontSize: 13),
            ),
          ]),
        ),
        ignoring('Ignore commands to everyone', 'Broadcasts, and the open direct channel', ignoreEveryone),
        ignoring('Ignore commands to a channel', 'Only those to you alone', ignoreChannel),
      ]),
    ]);
  }
}
