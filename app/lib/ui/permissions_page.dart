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

/// Who may control what of yours, in one place, a tab each: requests
/// waiting, each feature's policy and who's allowed it, everyone on the
/// unit's list and all they're allowed, and who's been declined.
class PermissionsPage extends StatelessWidget {
  final CommController comm;
  const PermissionsPage({super.key, required this.comm});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([comm, comm.permissions]),
        builder: (context, _) {
          final perms = comm.permissions;
          final policy = perms.boardReady ? perms.policy : null;
          Tab tab(String text, int count, {bool badge = false}) => Tab(
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(text),
                  if (count > 0) ...[
                    const SizedBox(width: 6),
                    badge ? RequestsBadge(count, size: 13) : Text('$count', style: const TextStyle(color: Kc.muted)),
                  ],
                ]),
              );
          return DefaultTabController(
            length: 4,
            initialIndex: perms.requests.isEmpty ? 1 : 0,
            child: Scaffold(
              appBar: AppBar(
                title: const Text('Permissions'),
                bottom: TabBar(
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  tabs: [
                    tab('Requests', perms.requests.length, badge: true),
                    tab('Features', 0),
                    tab('Users', policy?.everyone.length ?? 0),
                    tab('Declined', perms.declined.length),
                  ],
                ),
              ),
              body: Column(children: [
                if (policy == null)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 10, 16, 0),
                    child: Text('Connect to your unit to change these: it keeps them.', style: _small),
                  ),
                Expanded(
                  child: TabBarView(children: [
                    _RequestsTab(comm: comm, policy: policy),
                    _FeaturesTab(comm: comm, policy: policy),
                    _UsersTab(comm: comm, policy: policy),
                    _DeclinedTab(comm: comm, policy: policy),
                  ]),
                ),
              ]),
            ),
          );
        },
      );
}

const _small = TextStyle(color: Kc.muted, fontSize: 13);

EdgeInsets _tabPadding(BuildContext context) =>
    EdgeInsets.fromLTRB(16, 8, 16, 24 + MediaQuery.paddingOf(context).bottom);

Widget _note(String text) => Padding(padding: const EdgeInsets.only(top: 8), child: Text(text, style: _small));

class _RequestsTab extends StatelessWidget {
  final CommController comm;
  final BoardPolicy? policy;
  const _RequestsTab({required this.comm, required this.policy});

  Future<void> _accept(BuildContext context, PermissionRequest r) async {
    final caps = await showGrantSheet(context, comm, title: 'Allow ${r.name}', initial: r.caps);
    if (caps != null) await comm.permissions.accept(r, caps);
  }

  @override
  Widget build(BuildContext context) {
    final perms = comm.permissions;
    return ListView(padding: _tabPadding(context), children: [
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
                  Text(_ago(r.time), style: _small),
                ]),
                Text(
                  'Asks for ${r.caps.map((c) => _kind(c).name).join(' and ')}'
                  '${r.what.isEmpty ? '' : ' · ${r.what}'}',
                  style: _small,
                ),
                const SizedBox(height: 6),
                Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  TextButton(onPressed: () => perms.decline(r), child: const Text('Decline')),
                  const SizedBox(width: 8),
                  FilledButton(
                      onPressed: policy == null ? null : () => _accept(context, r), child: const Text('Accept')),
                ]),
              ]),
            ),
        ]),
      _note("Commands from those you haven't allowed, for a feature set to Ask. They're not told: their "
          'commands are just done once you accept.'),
    ]);
  }
}

/// One feature at a time: who it's taken from, what it ignores, and each
/// user on the unit's list, allowed it or not.
class _FeaturesTab extends StatefulWidget {
  final CommController comm;
  final BoardPolicy? policy;
  const _FeaturesTab({required this.comm, required this.policy});

  @override
  State<_FeaturesTab> createState() => _FeaturesTabState();
}

class _FeaturesTabState extends State<_FeaturesTab> {
  int _cap = controlKinds.first.id;

  @override
  Widget build(BuildContext context) {
    final perms = widget.comm.permissions;
    final kind = _kind(_cap);
    final p = widget.policy?.caps[_cap];
    final users = widget.policy?.everyone ?? const <ListedPerson>[];
    Widget ignoring(String title, String subtitle, int bit) => PanelRow(
          title: title,
          subtitle: subtitle,
          trailing: [
            Switch(
              value: p != null && p.ignore & bit != 0,
              onChanged: p == null || p.policy == Policy.off
                  ? null
                  : (on) => perms.setIgnore(_cap, on ? p.ignore | bit : p.ignore & ~bit),
            ),
          ],
        );
    return ListView(padding: _tabPadding(context), children: [
      // Which feature
      SegmentedButton<int>(
        showSelectedIcon: false,
        segments: [
          for (final k in controlKinds)
            ButtonSegment(value: k.id, icon: Icon(k.icon), label: Text(k.name.toUpperCase())),
        ],
        selected: {_cap},
        onSelectionChanged: (sel) => setState(() => _cap = sel.first),
      ),
      const SizedBox(height: 4),
      SectionHeader('Who may'),
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
              onSelectionChanged: p == null ? null : (sel) => perms.setPolicy(_cap, sel.first),
            ),
            const SizedBox(height: 6),
            Text(
              switch (p?.policy) {
                Policy.off => "Nobody. Who you've allowed is kept for when it's on again",
                Policy.ask => "Those you allow below. Others' commands come as requests",
                Policy.anyone => 'Anyone in the hive',
                null => '',
              },
              style: _small,
            ),
          ]),
        ),
        ignoring('Ignore commands to everyone', 'Broadcasts, and the open direct channel', ignoreEveryone),
        ignoring('Ignore commands to a channel', 'Only those to you alone', ignoreChannel),
      ]),
      SectionHeader('Users allowed ${kind.name}'),
      if (users.isEmpty)
        const Panel(children: [PanelRow(title: 'Nobody on your unit\'s list yet')])
      else
        Panel(children: [
          for (final u in users)
            PanelRow(
              title: u.clash ? '⚠ ${u.name}' : u.name,
              subtitle: p?.person(u.id) == null ? "Hasn't sent ${kind.name} commands" : null,
              trailing: [
                Switch(
                  value: p?.person(u.id)?.allowed ?? false,
                  onChanged: p == null ? null : (on) => perms.setAllowed(u.id, {_cap: on}),
                ),
              ],
            ),
        ]),
      _note(switch (p?.policy) {
        Policy.off => "Off, so nobody's commands are taken, allowed or not.",
        Policy.anyone => "Open to anyone, so everyone's commands are taken, allowed or not.",
        _ => "Everyone on your unit's list: those who've sent commands, or are allowed.",
      }),
    ]);
  }
}

/// Everyone on the unit's list, and all they're allowed: tap one to change
/// it.
class _UsersTab extends StatelessWidget {
  final CommController comm;
  final BoardPolicy? policy;
  const _UsersTab({required this.comm, required this.policy});

  Future<void> _edit(BuildContext context, BoardPolicy policy, ListedPerson p) async {
    final now = {for (final e in policy.caps.entries) if (e.value.person(p.id)?.allowed ?? false) e.key};
    final caps =
        await showGrantSheet(context, comm, title: 'Allow ${p.name}', initial: now, action: 'Save', all: false);
    if (caps == null) return;
    await comm.permissions.setAllowed(p.id, {for (final k in controlKinds) k.id: caps.contains(k.id)});
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
    if (yes == true) await comm.permissions.forget(p.id);
  }

  @override
  Widget build(BuildContext context) {
    final policy = this.policy;
    final users = policy?.everyone ?? const <ListedPerson>[];
    return ListView(padding: _tabPadding(context), children: [
      if (policy == null || users.isEmpty)
        const Panel(children: [PanelRow(title: 'Nobody on your unit\'s list yet')])
      else
        Panel(children: [
          for (final u in users)
            PanelRow(
              title: u.clash ? '⚠ ${u.name}' : u.name,
              subtitle: u.clash ? 'Someone else using a name someone listed had first' : null,
              trailing: [
                _capIcons({
                  for (final e in policy.caps.entries)
                    if (e.value.person(u.id)?.allowed ?? false) e.key
                }),
                IconButton(
                  tooltip: 'Remove',
                  icon: const Icon(Icons.person_remove_outlined, color: Kc.muted),
                  onPressed: () => _forget(context, u),
                ),
                const Icon(Icons.chevron_right, color: Kc.muted),
              ],
              onTap: () => _edit(context, policy, u),
            ),
        ]),
      _note("Those who've sent commands, or are allowed: the icons are what they're allowed. Tap one to "
          'change all of it.'),
    ]);
  }
}

/// Those declined: off the list, or granted after all.
class _DeclinedTab extends StatelessWidget {
  final CommController comm;
  final BoardPolicy? policy;
  const _DeclinedTab({required this.comm, required this.policy});

  Future<void> _grant(BuildContext context, PermissionRequest r) async {
    final caps = await showGrantSheet(context, comm, title: 'Allow ${r.name}', initial: r.caps);
    if (caps != null) await comm.permissions.grant(r.key, r.name, caps);
  }

  @override
  Widget build(BuildContext context) {
    final perms = comm.permissions;
    return ListView(padding: _tabPadding(context), children: [
      if (perms.declined.isEmpty)
        const Panel(children: [PanelRow(title: 'Nobody declined')])
      else
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
                    onPressed: policy == null ? null : () => _grant(context, r), child: const Text('Grant')),
              ],
            ),
        ]),
      _note("Their commands don't ask again for what was declined. Taken off this list, they can; or grant "
          'them permissions now, without a new request.'),
    ]);
  }
}
