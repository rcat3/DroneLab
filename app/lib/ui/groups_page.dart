import 'package:flutter/material.dart';

import '../comm/board_link.dart';
import '../comm/comm_controller.dart';

/// Direct comms' groups: the open group, the groups made here or joined, and
/// the groups heard about nearby, to join with their passphrase.
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
    // Hear about the groups on the other channels too
    if (comm.boardSettings?.direct?.on ?? false) comm.scanDirect();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: comm,
      builder: (context, _) {
        final direct = comm.board.state == BoardState.connected ? comm.boardSettings?.direct : null;
        final currentId = direct != null && direct.keyed ? direct.id : null;
        final saved = comm.groups.toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        final savedIds = {for (final g in saved) g.id};
        final heard = comm.heardGroups.values.where((h) => !savedIds.contains(h.id)).toList()
          ..sort((a, b) => b.rssi.compareTo(a.rssi));
        final title = Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary);
        Widget header(String text) => Padding(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
              child: Text(text, style: title),
            );
        final usable = direct != null;

        final scanning = direct?.scanning ?? false;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Direct Channels'),
            actions: [
              if (usable && direct.on)
                scanning
                    ? const Padding(
                        padding: EdgeInsets.all(16),
                        child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))
                    : IconButton(
                        tooltip: 'Look for channels on every frequency',
                        icon: const Icon(Icons.refresh),
                        onPressed: comm.scanDirect),
            ],
          ),
          floatingActionButton: usable
              ? FloatingActionButton.extended(
                  onPressed: () => createGroup(context, comm),
                  icon: const Icon(Icons.add),
                  label: const Text('Create a channel'),
                )
              : null,
          body: ListView(
            children: [
              if (!usable)
                const ListTile(title: Text('Connect to the board to choose its channel')),
              if (usable && !direct.on)
                ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: const Text('Direct comms is off'),
                  subtitle: const Text('Switch it on to hear the channels nearby'),
                  trailing: Switch(value: false, onChanged: comm.setDirect),
                ),
              header('Open'),
              _choice(
                context,
                selected: usable && !direct.keyed,
                icon: Icons.lock_open,
                title: 'Open channel',
                subtitle: 'Any board nearby can hear it. ${radioText(6, true)}',
                onTap: usable ? comm.joinOpenGroup : null,
              ),
              header('Your channels'),
              if (saved.isEmpty)
                const ListTile(
                    title: Text('None yet'),
                    subtitle: Text('Create one, or join one from those heard nearby')),
              for (final g in saved)
                _choice(
                  context,
                  selected: currentId == g.id,
                  icon: Icons.lock,
                  title: g.name,
                  subtitle: [
                    g.mine ? 'Made here' : 'Joined',
                    radioText(g.channel, g.longRange),
                    if (comm.heardGroups[g.id] case final h?) '${h.boards} nearby',
                  ].join(', '),
                  onTap: usable ? () => joinSavedGroup(context, comm, g) : null,
                  trailing: IconButton(
                    tooltip: 'Delete it',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _delete(context, g),
                  ),
                ),
              if (usable && direct.on) ...[
                header('Heard nearby'),
                if (heard.isEmpty)
                  ListTile(title: Text(scanning ? 'Listening on every frequency...' : 'No other channels heard')),
                for (final h in heard)
                  _choice(
                    context,
                    selected: currentId == h.id,
                    icon: Icons.lock_outline,
                    title: h.name,
                    subtitle: '${h.boards} ${h.boards == 1 ? 'board' : 'boards'}, ${h.rssi} dBm, '
                        '${radioText(h.channel, h.longRange)}. Tap to join',
                    onTap: () => joinHeardGroup(context, comm, h),
                  ),
              ],
              const SizedBox(height: 96),
            ],
          ),
        );
      },
    );
  }

  Widget _choice(BuildContext context,
      {required bool selected,
      required IconData icon,
      required String title,
      required String subtitle,
      VoidCallback? onTap,
      Widget? trailing}) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
          color: selected ? scheme.primary : null),
      title: Row(children: [
        Icon(icon, size: 18),
        const SizedBox(width: 8),
        Flexible(child: Text(title)),
      ]),
      subtitle: Text(subtitle),
      selected: selected,
      onTap: onTap,
      trailing: trailing,
    );
  }

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

/// Join a group heard nearby, asking for its passphrase.
Future<void> joinHeardGroup(BuildContext context, CommController comm, HeardGroup h) async {
  final got = await _ask(context, title: 'Join ${h.name}', askName: false, action: 'Join');
  if (got == null || !context.mounted) return;
  await _busy(context,
      comm.joinGroup(h.name, got.passphrase, expectId: h.id, channel: h.channel, longRange: h.longRange));
}

/// Make a new group, asking for its name and passphrase.
Future<void> createGroup(BuildContext context, CommController comm) async {
  final got = await _ask(context, title: 'Create a channel', askName: true, action: 'Create');
  if (got == null || !context.mounted) return;
  await _busy(context, comm.createGroup(got.name, got.passphrase, got.channel, got.longRange));
}

/// Join one of the groups kept here.
Future<void> joinSavedGroup(BuildContext context, CommController comm, DirectGroup g) =>
    _busy(context, comm.joinGroup(g.name, g.passphrase, mine: g.mine, channel: g.channel, longRange: g.longRange));

/// Wait for a join, which takes a moment to make the key, and say if it
/// didn't work.
Future<void> _busy(BuildContext context, Future<String?> work) async {
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(const SnackBar(content: Text('Joining...'), duration: Duration(seconds: 10)));
  final why = await work;
  messenger.hideCurrentSnackBar();
  if (why != null) messenger.showSnackBar(SnackBar(content: Text(why)));
}

  /// What's typed in to make or join a group.
typedef GroupAnswer = ({String name, String passphrase, int channel, bool longRange});

/// A group's name, channel and Long Range (if [askName], for a new one), and
/// passphrase.
Future<GroupAnswer?> _ask(BuildContext context,
    {required String title, required bool askName, required String action}) {
  final name = TextEditingController();
  final passphrase = TextEditingController();
  var show = false;
  var channel = 6;
  var longRange = true;
  return showDialog<GroupAnswer>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (askName)
                TextField(
                  controller: name,
                  autofocus: true,
                  maxLength: 15,
                  decoration: const InputDecoration(labelText: 'Name', helperText: 'Others nearby see it'),
                ),
              TextField(
                controller: passphrase,
                autofocus: !askName,
                obscureText: !show,
                decoration: InputDecoration(
                  labelText: 'Passphrase',
                  helperText: askName ? 'A few words is best. The others join with it' : null,
                  suffixIcon: IconButton(
                    icon: Icon(show ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setState(() => show = !show),
                  ),
                ),
              ),
              if (askName) ...[
                const SizedBox(height: 16),
                Row(children: [
                  const Expanded(child: Text('Frequency')),
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
                ]),
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text('Another from the open channel (6) keeps the two from crowding each other',
                      style: TextStyle(fontSize: 12)),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Long Range'),
                  subtitle: const Text('Reaches further, but each packet takes twice as long on the air'),
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
