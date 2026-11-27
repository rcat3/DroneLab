import 'package:flutter/material.dart';

import '../comm/comm_controller.dart';
import '../comm/permissions.dart';
import '../comm/rules.dart' show RuleClass;
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
                ? 'Choose who can control your unit'
                : n == 1
                    ? '1 request waiting'
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

String _names(Iterable<int> caps) => [for (final k in permissionKinds) if (caps.contains(k.id)) k.name].join(' and ');

Widget _capIcons(Iterable<int> caps, {Color color = Kc.pink}) => Row(mainAxisSize: MainAxisSize.min, children: [
      for (final k in permissionKinds)
        if (caps.contains(k.id))
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Icon(k.icon, size: 18, color: color, semanticLabel: k.name),
          ),
    ]);

/// Say what the unit didn't take, if anything.
void _reportFailed(BuildContext context, String name, Set<int> failed) {
  if (failed.isEmpty || !context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text("Your unit didn't change ${_names(failed)} for $name. Check it's connected.")));
}

/// Pick what to allow someone ([id], their key's id): [initial] ticked.
/// Returns what's picked, or null if it's left. [all] offers Allow all.
Future<Set<int>?> showGrantSheet(BuildContext context, CommController comm,
    {required String title, required String id, required Set<int> initial, String action = 'Allow', bool all = true}) {
  final perms = comm.permissions;
  final picked = {...initial};
  return showModalBottomSheet<Set<int>>(
    context: context,
    isScrollControlled: true,
    builder: (sheet) => StatefulBuilder(
      builder: (sheet, setState) {
        String note(ControlKind k) {
          return switch (perms.policy.caps[k.id]?.policy) {
            Policy.off => '${k.name} is off. This takes effect when you turn it on',
            Policy.anyone => '${k.name} is open to everyone, so this only matters if you change that',
            _ => k.does,
          };
        }

        final allowable = {for (final k in controlKinds) k.id};
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SectionHeader(title),
              Panel(color: Kc.bg, children: [
                for (final k in permissionKinds)
                  CheckboxListTile(
                    value: picked.contains(k.id),
                    onChanged: (on) => setState(() => on == true ? picked.add(k.id) : picked.remove(k.id)),
                    secondary: Icon(k.icon, color: Kc.pink),
                    title: Text(k.name),
                    subtitle: Text(note(k), style: const TextStyle(color: Kc.muted, fontSize: 13)),
                  ),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                if (all) ...[
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(sheet, allowable),
                      child: const Text('Allow all'),
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

/// Who can control what on your unit, a tab each: requests waiting, each
/// feature's setting and who's allowed it, each person and all they're
/// allowed, and who's been declined. The log of commands is a tap away.
class PermissionsPage extends StatelessWidget {
  final CommController comm;
  const PermissionsPage({super.key, required this.comm});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([comm, comm.permissions]),
        builder: (context, _) {
          final perms = comm.permissions;
          final policy = perms.policy;
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
                actions: [
                  IconButton(
                    tooltip: 'Command log',
                    icon: const Icon(Icons.receipt_long),
                    onPressed: () =>
                        Navigator.of(context).push(MaterialPageRoute(builder: (_) => CommandLogPage(comm: comm))),
                  ),
                ],
                bottom: TabBar(
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  tabs: [
                    tab('Requests', perms.requests.length, badge: true),
                    tab('Features', 0),
                    tab('People', policy.everyone.length),
                    tab('Declined', perms.declined.length),
                  ],
                ),
              ),
              body: Column(children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                  child: Row(children: [
                    Icon(
                        switch (perms.sync) {
                          RulesSync.upToDate => Icons.check_circle_outline,
                          RulesSync.sending => Icons.sync,
                          RulesSync.noUnit => Icons.phone_android,
                        },
                        size: 16,
                        color: Kc.muted),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                          switch (perms.sync) {
                            RulesSync.upToDate => "Your unit has these, and goes by them while your phone's away.",
                            RulesSync.sending => 'Sending these to your unit…',
                            RulesSync.noUnit => 'Kept on your phone. Your unit gets them when it connects.',
                          },
                          style: _small),
                    ),
                  ]),
                ),
                Expanded(
                  child: TabBarView(children: [
                    _RequestsTab(comm: comm, policy: policy),
                    _FeaturesTab(comm: comm, policy: policy),
                    _PeopleTab(comm: comm, policy: policy),
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
  final PolicyView policy;
  const _RequestsTab({required this.comm, required this.policy});

  Future<void> _accept(BuildContext context, PermissionRequest r) async {
    final caps = await showGrantSheet(context, comm, title: 'Allow ${r.name} to control', id: r.id, initial: r.caps);
    if (caps == null) return;
    final failed = await comm.permissions.accept(r, caps);
    if (context.mounted) _reportFailed(context, r.name, failed);
  }

  @override
  Widget build(BuildContext context) {
    final perms = comm.permissions;
    return ListView(padding: _tabPadding(context), children: [
      if (perms.requests.isEmpty)
        const Panel(children: [PanelRow(title: 'No requests')])
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
                Text('Wants to control: ${_names(r.caps)}', style: _small),
                if (r.what.isNotEmpty) Text('Last tried: ${r.what}', style: _small),
                const SizedBox(height: 6),
                Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  TextButton(onPressed: () => perms.decline(r), child: const Text('Decline')),
                  const SizedBox(width: 8),
                  FilledButton(
                      onPressed: () => _accept(context, r), child: const Text('Accept')),
                ]),
              ]),
            ),
        ]),
      _note("A request appears when someone who isn't allowed sends you a command for a feature only allowed "
          "people can control. The command isn't carried out, and they aren't told either way. Accept, and "
          'their next commands work.'),
    ]);
  }
}

/// One feature at a time: who can control it, what it ignores, and each
/// person on the unit's list, allowed it or not.
class _FeaturesTab extends StatefulWidget {
  final CommController comm;
  final PolicyView policy;
  const _FeaturesTab({required this.comm, required this.policy});

  @override
  State<_FeaturesTab> createState() => _FeaturesTabState();
}

class _FeaturesTabState extends State<_FeaturesTab> {
  int _cap = permissionKinds.first.id;

  Future<void> _set(ListedPerson u, bool on) async {
    final failed = await widget.comm.permissions.setAllowed(u.id, {_cap: on});
    if (mounted) _reportFailed(context, u.name, failed);
  }

  @override
  Widget build(BuildContext context) {
    final perms = widget.comm.permissions;
    final kind = permissionKinds.firstWhere((k) => k.id == _cap);
    final p = widget.policy.caps[_cap];
    final people = widget.policy.everyone;
    // HiveSight's: kept on the phone, and about invitations, not commands
    final phoneOnly = RuleClass.phoneOnly.contains(_cap);
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
      // Which feature: a chip each, wrapping onto more lines as there are
      // more of them; the icon dimmed for one that's set to Nobody
      Wrap(spacing: 8, runSpacing: 4, children: [
        for (final k in permissionKinds)
          ChoiceChip(
            showCheckmark: false,
            avatar: Icon(k.icon,
                size: 18,
                color: k.id == _cap
                    ? Kc.pink
                    : (widget.policy.caps[k.id]?.policy ?? Policy.off) == Policy.off
                        ? Kc.muted
                        : Kc.text),
            label: Text(k.name.toUpperCase()),
            selected: k.id == _cap,
            onSelected: (_) => setState(() => _cap = k.id),
          ),
      ]),
      SectionHeader('Who can control ${kind.name}'),
      Panel(children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SegmentedButton<Policy>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: Policy.off, label: Text('NOBODY')),
                ButtonSegment(value: Policy.ask, label: Text('ALLOWED')),
                ButtonSegment(value: Policy.anyone, label: Text('ANYONE')),
              ],
              selected: {p?.policy ?? Policy.off},
              onSelectionChanged: p == null ? null : (sel) => perms.setPolicy(_cap, sel.first),
            ),
            const SizedBox(height: 8),
            Text(
              switch (p?.policy) {
                Policy.off => "Nobody. The people you've allowed below are kept for when you turn it back on.",
                Policy.ask when phoneOnly =>
                  "Only the people switched on below. Joining anyone else's invitation asks you first.",
                Policy.ask => 'Only the people switched on below. Commands from anyone else become requests.',
                Policy.anyone => 'Everyone. The switches below make no difference while this is set.',
                null => '',
              },
              style: _small,
            ),
          ]),
        ),
        if (!phoneOnly) ...[
          ignoring('Ignore broadcasts', 'Commands sent to everyone, including on the open direct channel',
              ignoreEveryone),
          ignoring('Ignore channel commands', 'Commands sent to a whole channel rather than just to you',
              ignoreChannel),
        ] else ...[
          ignoring('Ignore light pulses', 'Never show the flashing light pulse in a session, whoever guides you',
              ignoreLightPulse),
          ignoring('Ignore toys', "Never let a Guide use your toys in a session, even if you've allowed them on Vibe",
              ignoreToys),
        ],
      ]),
      const SectionHeader('People'),
      if (people.isEmpty)
        const Panel(children: [PanelRow(title: 'Nobody yet')])
      else
        Panel(children: [
          for (final u in people)
            PanelRow(
              title: u.clash ? '⚠ ${u.name}' : u.name,
              trailing: [
                Switch(
                  value: p?.person(u.id)?.allowed ?? false,
                  onChanged: p == null ? null : (on) => _set(u, on),
                ),
              ],
            ),
        ]),
      _note('Everyone who has sent you a command or been allowed something. Switch someone on to let them '
          'control ${kind.name}.'),
    ]);
  }
}

/// Everyone on the unit's list, and all they're allowed: tap one to change
/// it.
class _PeopleTab extends StatelessWidget {
  final CommController comm;
  final PolicyView policy;
  const _PeopleTab({required this.comm, required this.policy});

  Future<void> _edit(BuildContext context, PolicyView policy, ListedPerson p) async {
    final now = {for (final e in policy.caps.entries) if (e.value.person(p.id)?.allowed ?? false) e.key};
    final caps = await showGrantSheet(context, comm,
        title: 'What ${p.name} can control', id: p.id, initial: now, action: 'Save', all: false);
    if (caps == null) return;
    final failed = await comm.permissions.setAllowed(p.id, {
      for (final k in permissionKinds) k.id: caps.contains(k.id)
    });
    if (context.mounted) _reportFailed(context, p.name, failed);
  }

  Future<void> _forget(BuildContext context, ListedPerson p) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('Remove ${p.name}?'),
        content: const Text('They lose everything they were allowed. If they send you a command again, '
            "they're added back and it comes in as a request."),
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
    final people = policy.everyone;
    return ListView(padding: _tabPadding(context), children: [
      if (people.isEmpty)
        const Panel(children: [PanelRow(title: 'Nobody yet')])
      else
        Panel(children: [
          for (final u in people)
            PanelRow(
              title: u.clash ? '⚠ ${u.name}' : u.name,
              subtitle: u.clash ? 'Not the person who used this name first' : null,
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
      _note('Everyone who has sent you a command or been allowed something. The icons show what each person '
          'is allowed. Tap someone to change it.'),
    ]);
  }
}

/// Those declined: taken off the list, or allowed after all.
class _DeclinedTab extends StatelessWidget {
  final CommController comm;
  final PolicyView policy;
  const _DeclinedTab({required this.comm, required this.policy});

  Future<void> _allow(BuildContext context, PermissionRequest r) async {
    final caps = await showGrantSheet(context, comm, title: 'Allow ${r.name} to control', id: r.id, initial: r.caps);
    if (caps == null) return;
    final failed = await comm.permissions.grant(r.key, r.name, caps);
    if (context.mounted) _reportFailed(context, r.name, failed);
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
              subtitle: 'Declined for ${_names(r.caps)} · ${_ago(r.time)}',
              trailing: [
                IconButton(
                  tooltip: 'Remove from this list',
                  icon: const Icon(Icons.close, color: Kc.muted),
                  onPressed: () => perms.removeDeclined(r),
                ),
                OutlinedButton(
                    onPressed: () => _allow(context, r), child: const Text('Allow')),
              ],
            ),
        ]),
      _note("Commands from these people for what you declined don't make new requests. Remove someone (×) to "
          'let them ask again, or Allow them now.'),
    ]);
  }
}

/// Every command that came, newest first: who, what, how it came and what
/// came of it; and the requests accepted and declined.
class CommandLogPage extends StatelessWidget {
  final CommController comm;
  const CommandLogPage({super.key, required this.comm});

  static String _time(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    final now = DateTime.now();
    final clock = '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
    return t.year == now.year && t.month == now.month && t.day == now.day ? clock : '${t.month}/${t.day} $clock';
  }

  static Color _color(LogEntry e) {
    if (!e.isCommand) return Kc.pink;
    if (e.outcome == 'Done') return Kc.green;
    if (e.outcome.contains('asked for permission') || e.outcome.contains('request is waiting')) return Kc.warn;
    return Kc.softRed;
  }

  Future<void> _clear(BuildContext context) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Clear the log?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(d, true), child: const Text('Clear')),
        ],
      ),
    );
    if (yes == true) comm.permissions.clearLog();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: comm.permissions,
        builder: (context, _) {
          final log = comm.permissions.commandLog;
          return Scaffold(
            appBar: AppBar(
              title: const Text('Command log'),
              actions: [
                IconButton(
                  tooltip: 'Clear',
                  icon: const Icon(Icons.delete_sweep_outlined),
                  onPressed: log.isEmpty ? null : () => _clear(context),
                ),
              ],
            ),
            body: log.isEmpty
                ? const Center(child: Text('No commands yet', style: _small))
                : ListView.separated(
                    padding: EdgeInsets.fromLTRB(16, 8, 16, 24 + MediaQuery.paddingOf(context).bottom),
                    itemCount: log.length,
                    separatorBuilder: (_, _) => const Divider(height: 1, color: Kc.line),
                    itemBuilder: (context, i) {
                      final e = log[i];
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          SizedBox(width: 92, child: Text(_time(e.time), style: Kc.term(13, color: Kc.muted))),
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              if (e.isCommand) Text('${e.who} ${e.what}'),
                              Text(e.outcome,
                                  style: TextStyle(color: _color(e), fontSize: e.isCommand ? 13 : 14)),
                              if (e.via != null) Text('${e.via} · ${e.scope}', style: _small),
                            ]),
                          ),
                        ]),
                      );
                    },
                  ),
          );
        },
      );
}
