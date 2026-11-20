import 'package:flutter/material.dart';

import '../comm/board_link.dart';
import '../comm/comm_controller.dart';
import 'call_ui.dart';
import 'theme.dart';
import 'widgets.dart';

/// Direct comms' channels: the one the board's on, those made or joined here,
/// those heard nearby (joined with their passphrase), and the open channel.
class GroupsPage extends StatefulWidget {
  final CommController comm;
  const GroupsPage({super.key, required this.comm});

  @override
  State<GroupsPage> createState() => _GroupsPageState();
}

class _GroupsPageState extends State<GroupsPage> {
  CommController get comm => widget.comm;

  @override
  void initState() {
    super.initState();
    // Hear about the channels on the other frequencies too
    if (comm.boardSettings?.direct?.on ?? false) comm.scanDirect();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: comm,
      builder: (context, _) {
        final direct = comm.board.state == BoardState.connected ? comm.boardSettings?.direct : null;
        final usable = direct != null;
        final on = direct?.on ?? false;
        // The one being switched to shows picked at once
        final joining = comm.joiningDirect;
        final currentId = joining != null ? (joining.isEmpty ? null : joining) : direct != null && direct.keyed ? direct.id : null;
        final saved = comm.groups.toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        final savedIds = {for (final g in saved) g.id};
        final heard = comm.heardGroups.values.where((h) => !savedIds.contains(h.id)).toList()
          ..sort((a, b) => b.rssi.compareTo(a.rssi));
        final scanning = direct?.scanning ?? false;
        const small = TextStyle(color: Kc.muted, fontSize: 13);

        String nearby(String id) {
          final h = comm.heardGroups[id];
          return h == null ? '' : ' · ${h.boards} nearby';
        }

        return Scaffold(
          appBar: AppBar(title: const Text('Direct Channels')),
          body: ListView(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 24 + MediaQuery.paddingOf(context).bottom),
            children: [
              if (!usable)
                const Panel(children: [PanelRow(title: 'Connect to the board to choose its channel')])
              else ...[
                if (!on)
                  Panel(children: [
                    PanelRow(
                      title: 'Direct is off',
                      subtitle: 'Switch it on to hear the channels nearby',
                      trailing: [Switch(value: false, onChanged: comm.setDirect)],
                    ),
                  ]),
                const SectionHeader('On now'),
                Panel(children: [
                  PanelRow(
                    leading: Icon(direct.keyed ? Icons.lock : Icons.lock_open, color: Kc.green),
                    title: joining != null ? 'Switching channel...' : direct.keyed ? direct.group : 'Open channel',
                    subtitle: '${_radio(direct.channel, direct.longRange)}'
                        '${direct.keyed ? nearby(direct.id) : ' · anyone nearby can hear it'}',
                  ),
                ]),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: () => createGroup(context, comm),
                  icon: const Icon(Icons.add),
                  label: const Text('Create a channel'),
                ),
              ],
              const SectionHeader('Your channels'),
              if (saved.isEmpty)
                const Text('None yet. Create one, or join one heard nearby.', style: small)
              else
                Panel(children: [
                  for (final g in saved)
                    _Choice(
                      selected: currentId == g.id,
                      locked: true,
                      title: g.name,
                      subtitle: '${g.mine ? 'Made here' : 'Joined'} · ${_radio(g.channel, g.longRange)}${nearby(g.id)}',
                      onTap: usable && currentId != g.id ? () => joinSavedGroup(context, comm, g) : null,
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        IconButton(
                          tooltip: 'Invite someone to ${g.name}',
                          icon: const Icon(Icons.person_add_alt, color: Kc.pink),
                          onPressed: () => pickInvitee(context, comm, g),
                        ),
                        IconButton(
                          tooltip: 'Delete ${g.name} from this phone',
                          icon: const Icon(Icons.delete_outline, color: Kc.muted),
                          onPressed: () => _delete(context, g),
                        ),
                      ]),
                    ),
                ]),
              if (on) ...[
                SectionHeader(
                  'Heard nearby',
                  trailing: scanning
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)))
                      : IconButton(
                          tooltip: 'Listen again on every frequency',
                          icon: const Icon(Icons.refresh, color: Kc.muted),
                          onPressed: comm.scanDirect),
                ),
                if (heard.isEmpty)
                  Text(scanning ? 'Listening on every frequency...' : 'No other channels heard', style: small)
                else ...[
                  Panel(children: [
                    for (final h in heard)
                      _Choice(
                        selected: currentId == h.id,
                        locked: true,
                        title: h.name,
                        subtitle: '${h.boards} ${h.boards == 1 ? 'board' : 'boards'} · ${_radio(h.channel, h.longRange)}',
                        onTap: currentId == h.id ? null : () => joinHeardGroup(context, comm, h),
                        trailing: const Padding(
                          padding: EdgeInsets.only(right: 8),
                          child: Text('JOIN', style: TextStyle(color: Kc.pink, fontWeight: FontWeight.w700)),
                        ),
                      ),
                  ]),
                  const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: Text('Joining takes the passphrase', style: small),
                  ),
                ],
              ],
              const SectionHeader('Open'),
              Panel(children: [
                _Choice(
                  selected: usable && !direct.keyed,
                  locked: false,
                  title: 'Open channel',
                  subtitle: 'Anyone nearby can hear it · ${_radio(6, true)}',
                  onTap: usable && direct.keyed ? comm.joinOpenGroup : null,
                ),
              ]),
            ],
          ),
        );
      },
    );
  }

  static String _radio(int channel, bool longRange) => 'Frequency $channel${longRange ? ', Long Range' : ''}';

  Future<void> _delete(BuildContext context, DirectGroup g) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${g.name}?'),
        content: Text(g.mine
            ? 'It goes from this phone. Others who joined it keep it, as long as they have the passphrase.'
            : "It goes from this phone. You'll need the passphrase to join it again."),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true) await comm.deleteGroup(g);
  }
}

/// A channel to pick: a dot that's lit for the one the board's on.
class _Choice extends StatelessWidget {
  final bool selected;
  final bool locked;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;
  const _Choice(
      {required this.selected,
      required this.locked,
      required this.title,
      required this.subtitle,
      this.onTap,
      this.trailing});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: selected,
      child: PanelRow(
        leading: Icon(selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
            color: selected ? Kc.pink : Kc.muted),
        title: title,
        subtitle: subtitle,
        onTap: onTap,
        trailing: [
          Icon(locked ? Icons.lock_outline : Icons.lock_open, size: 18, color: Kc.dim),
          const SizedBox(width: 4),
          ?trailing,
        ],
      ),
    );
  }
}

/// Join a channel heard nearby, asking for its passphrase. False if it
/// wasn't given, or was wrong.
Future<bool> joinHeardGroup(BuildContext context, CommController comm, HeardGroup h) async {
  final got = await _ask(context, title: 'Join ${h.name}', askName: false, action: 'Join');
  if (got == null || !context.mounted) return false;
  return _busy(context,
      comm.joinGroup(h.name, got.passphrase, expectId: h.id, channel: h.channel, longRange: h.longRange));
}

/// Make a new channel, asking for its name and passphrase.
Future<void> createGroup(BuildContext context, CommController comm) async {
  final got = await _ask(context, title: 'Create a channel', askName: true, action: 'Create');
  if (got == null || !context.mounted) return;
  await _busy(context, comm.createGroup(got.name, got.passphrase, got.channel, got.longRange));
}

/// Join one of the channels kept here.
Future<bool> joinSavedGroup(BuildContext context, CommController comm, DirectGroup g) =>
    _busy(context, comm.joinGroup(g.name, g.passphrase, mine: g.mine, channel: g.channel, longRange: g.longRange));

/// Wait for a join, which takes a moment to make the key, and say if it
/// didn't work.
Future<bool> _busy(BuildContext context, Future<String?> work) async {
  final messenger = ScaffoldMessenger.of(context);
  final why = await work;
  if (why != null) messenger.showSnackBar(SnackBar(content: Text(why)));
  return why == null;
}

/// What's typed in to make or join a channel.
typedef GroupAnswer = ({String name, String passphrase, int channel, bool longRange});

/// A channel's name, frequency and Long Range (if [askName], for a new one),
/// and passphrase.
Future<GroupAnswer?> _ask(BuildContext context,
    {required String title, required bool askName, required String action}) {
  final name = TextEditingController();
  final passphrase = TextEditingController();
  var show = false;
  var channel = 1;
  var longRange = true;
  const small = TextStyle(color: Kc.muted, fontSize: 13);
  return showDialog<GroupAnswer>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (askName)
                TextField(
                  controller: name,
                  autofocus: true,
                  maxLength: 15,
                  decoration: const InputDecoration(labelText: 'Name', helperText: 'Everyone nearby can see it'),
                ),
              const SizedBox(height: 8),
              TextField(
                controller: passphrase,
                autofocus: !askName,
                obscureText: !show,
                decoration: InputDecoration(
                  labelText: 'Passphrase',
                  helperText: askName ? 'Others need it to join. A few words is best' : null,
                  suffixIcon: IconButton(
                    tooltip: show ? 'Hide it' : 'Show it',
                    icon: Icon(show ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setState(() => show = !show),
                  ),
                ),
              ),
              if (askName) ...[
                const SizedBox(height: 20),
                const Text('Frequency', style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                SegmentedButton<int>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: 1, label: Text('1')),
                    ButtonSegment(value: 6, label: Text('6')),
                    ButtonSegment(value: 11, label: Text('11')),
                  ],
                  selected: {channel},
                  onSelectionChanged: (sel) => setState(() => channel = sel.first),
                ),
                const SizedBox(height: 6),
                const Text("6 is the open channel's. Pick 1 or 11 so you don't share the air with it", style: small),
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Long Range'),
                  subtitle: const Text('Reaches further, but fewer boards can share the channel', style: small),
                  value: longRange,
                  onChanged: (v) => setState(() => longRange = v),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(
                context, (name: name.text, passphrase: passphrase.text, channel: channel, longRange: longRange)),
            child: Text(action),
          ),
        ],
      ),
    ),
  );
}
