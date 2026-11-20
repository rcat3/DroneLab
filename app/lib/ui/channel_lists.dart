import 'package:flutter/material.dart';

import '../comm/board_link.dart';
import '../comm/board_protocol.dart';
import '../comm/comm_controller.dart';
import '../comm/mumble_client.dart';
import 'groups_page.dart';
import 'theme.dart';
import 'widgets.dart';

/// What's folded away in the channel lists, by key, the same on the Voice
/// and Text tabs, for as long as the app runs. Everything starts open.
final collapsedChannels = ValueNotifier<Set<String>>({});

void _toggle(String key) {
  final s = {...collapsedChannels.value};
  if (!s.remove(key)) s.add(key);
  collapsedChannels.value = s;
}

/// The channels to pick from, under the Channels heading on the Voice and
/// Text tabs alike: the Cloud Server's and Direct's, each with the one
/// we're on first ([serverCurrent], [directCurrent], which are each tab's
/// own) and every channel there is under it, indented as they nest. Tap one
/// to move to it.
class ChannelLists extends StatelessWidget {
  final CommController comm;
  final Widget? serverCurrent;    // null while not on the server
  final Widget? directCurrent;    // null while direct is off

  /// A channel's been picked from a list: which kind, and the server's
  /// channel's id. The Text tab opens its conversation.
  final void Function(TalkTo kind, int? serverChannel)? onPicked;
  const ChannelLists({super.key, required this.comm, this.serverCurrent, this.directCurrent, this.onPicked});

  @override
  Widget build(BuildContext context) {
    final m = comm.mumble;
    final serverUp = serverCurrent != null && m != null && m.state == MumbleState.connected;
    final direct = comm.board.state == BoardState.connected ? comm.boardSettings?.direct : null;
    return ValueListenableBuilder<Set<String>>(
      valueListenable: collapsedChannels,
      builder: (context, collapsed, _) {
        final directItems = direct == null ? null : _directItems(context, comm, direct, collapsed, onPicked);
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (serverUp) ...[
            _SubLabel(
              'Cloud server',
              m.channels.length,
              open: !collapsed.contains('server'),
              onToggle: () => _toggle('server'),
            ),
            Panel(children: [
              serverCurrent!,
              if (!collapsed.contains('server'))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(children: _serverTree(comm, m, collapsed, onPicked)),
                ),
            ]),
          ],
          if (direct != null) ...[
            _SubLabel(
              'Direct',
              directItems!.count,
              open: !collapsed.contains('direct'),
              onToggle: () => _toggle('direct'),
              action: OutlinedButton(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => GroupsPage(comm: comm))),
                child: const Text('Manage'),
              ),
            ),
            Panel(children: [
              directCurrent ??
                  PanelRow(
                    leading: const Icon(Icons.settings_input_antenna, color: Kc.muted),
                    title: 'Direct is off',
                    subtitle: 'Board to board, without the Internet',
                    trailing: [Switch(value: false, onChanged: comm.setDirect)],
                  ),
              if (!collapsed.contains('direct'))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(children: directItems.rows),
                ),
            ]),
          ],
        ]);
      },
    );
  }

  /// The server's channels as they nest, from its root.
  static List<Widget> _serverTree(CommController comm, MumbleClient m, Set<String> collapsed,
      void Function(TalkTo, int?)? onPicked) {
    final children = <int, List<int>>{};
    for (final id in m.channels.keys) {
      if (id == 0) continue;
      children.putIfAbsent(m.channelParents[id] ?? 0, () => []).add(id);
    }
    for (final list in children.values) {
      list.sort((a, b) => (m.channels[a] ?? '').toLowerCase().compareTo((m.channels[b] ?? '').toLowerCase()));
    }
    final counts = m.channelCounts;
    final rows = <Widget>[];
    void add(int id, int depth) {
      if (depth > 8) return;
      final kids = children[id] ?? const [];
      final key = 'server:$id';
      final open = !collapsed.contains(key);
      final here = id == m.myChannel;
      final n = counts[id] ?? 0;
      rows.add(_TreeRow(
        depth: depth,
        title: m.channels[id] ?? '?',
        selected: here,
        open: kids.isEmpty ? null : open,
        onToggle: () => _toggle(key),
        // Move there, and talk to it
        onTap: () {
          if (!here) comm.joinChannel(id);
          comm.setTalkTo(const TalkTarget.server());
          onPicked?.call(TalkTo.server, id);
        },
        semantics: '${m.channels[id]}, $n here${here ? ', you are here' : ''}',
        trailing: n == 0 ? null : _Count(n),
      ));
      if (open) {
        for (final k in kids) {
          add(k, depth + 1);
        }
      }
    }

    if (m.channels.containsKey(0)) {
      add(0, 0);
    } else {
      // No root heard yet: whatever's there, flat
      for (final id in children.values.expand((l) => l)) {
        add(id, 0);
      }
    }
    return rows;
  }

  /// Direct's channels: the open channel, those made or joined here, and
  /// those heard nearby.
  static ({List<Widget> rows, int count}) _directItems(
      BuildContext context, CommController comm, DirectSettings d, Set<String> collapsed,
      void Function(TalkTo, int?)? onPicked) {
    // The one being switched to shows picked at once, with a spinner till
    // the board's on it
    final joining = comm.joiningDirect;
    final currentId = joining != null ? (joining.isEmpty ? null : joining) : d.keyed ? d.id : null;
    final openPicked = joining != null ? joining.isEmpty : !d.keyed;
    void picked() {
      comm.setTalkTo(const TalkTarget.direct());
      onPicked?.call(TalkTo.direct, null);
    }

    final saved = comm.groups.toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final savedIds = {for (final g in saved) g.id};
    final heard = comm.heardGroups.values.where((h) => !savedIds.contains(h.id)).toList()
      ..sort((a, b) => b.rssi.compareTo(a.rssi));
    Widget? nearby(String id) {
      final h = comm.heardGroups[id];
      return h == null ? null : _Count(h.boards);
    }

    final rows = <Widget>[
      _TreeRow(
        depth: 0,
        title: 'Open channel',
        locked: false,
        selected: openPicked,
        busy: joining != null && joining.isEmpty,
        onTap: () {
          if (!openPicked) comm.joinOpenGroup();
          picked();
        },
        semantics: 'Open channel, anyone nearby can hear it${openPicked ? ', you are here' : ''}',
      ),
    ];
    void group(String key, String title, int n, List<Widget> Function() items) {
      if (n == 0) return;
      final open = !collapsed.contains(key);
      rows.add(_TreeRow(
        depth: 0,
        title: title,
        heading: true,
        open: open,
        onToggle: () => _toggle(key),
        onTap: () => _toggle(key),
        semantics: '$title, $n, ${open ? 'shown' : 'hidden'}',
        trailing: Text('$n', style: Kc.term(13, color: Kc.dim)),
      ));
      if (open) rows.addAll(items());
    }

    group('direct:yours', 'Your channels', saved.length, () => [
          for (final g in saved)
            _TreeRow(
              depth: 1,
              title: g.name,
              locked: true,
              selected: currentId == g.id,
              busy: joining == g.id,
              onTap: () {
                if (currentId != g.id) joinSavedGroup(context, comm, g);
                picked();
              },
              semantics: '${g.name}${currentId == g.id ? ', you are here' : ''}',
              trailing: nearby(g.id),
            ),
        ]);
    group('direct:heard', 'Heard nearby', heard.length, () => [
          for (final h in heard)
            _TreeRow(
              depth: 1,
              title: h.name,
              locked: true,
              selected: currentId == h.id,
              busy: joining == h.id,
              onTap: () async {
                // Its passphrase first; then on, if it was right
                if (currentId != h.id && !await joinHeardGroup(context, comm, h)) return;
                picked();
              },
              semantics: '${h.name}, ${h.boards} nearby, needs its passphrase',
              trailing: _Count(h.boards),
            ),
        ]);
    return (rows: rows, count: 1 + saved.length + heard.length);
  }
}

/// "CLOUD SERVER · 2 channels available", over its panel: tap to fold the
/// list away.
class _SubLabel extends StatelessWidget {
  final String text;
  final int count;
  final bool open;
  final VoidCallback onToggle;
  final Widget? action;
  const _SubLabel(this.text, this.count, {required this.open, required this.onToggle, this.action});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 4),
      child: Row(children: [
        Expanded(
          child: Semantics(
            button: true,
            label: '$text, $count ${count == 1 ? 'channel' : 'channels'} available, ${open ? 'shown' : 'hidden'}',
            excludeSemantics: true,
            child: InkWell(
              onTap: onToggle,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 36),
                child: Row(children: [
                  Text(text.toUpperCase(), style: Kc.term(13, color: Kc.darkGreen)),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text('$count ${count == 1 ? 'channel' : 'channels'} available',
                        overflow: TextOverflow.ellipsis, style: const TextStyle(color: Kc.dim, fontSize: 12)),
                  ),
                  Icon(open ? Icons.expand_less : Icons.expand_more, size: 20, color: Kc.dim),
                ]),
              ),
            ),
          ),
        ),
        ?action,
      ]),
    );
  }
}

/// A channel in a list, indented by [depth]: a fold arrow if it has others
/// in it ([open] not null), a dot lit for the one we're on, its name.
class _TreeRow extends StatelessWidget {
  final int depth;
  final String title;
  final bool selected;
  final bool busy;            // being switched to
  final bool heading;         // a group of channels, not one to pick
  final bool? locked;         // a direct channel: whether it takes a passphrase
  final bool? open;
  final VoidCallback? onToggle;
  final VoidCallback? onTap;
  final String semantics;
  final Widget? trailing;
  const _TreeRow(
      {required this.depth,
      required this.title,
      this.selected = false,
      this.busy = false,
      this.heading = false,
      this.locked,
      this.open,
      this.onToggle,
      this.onTap,
      required this.semantics,
      this.trailing});

  @override
  Widget build(BuildContext context) {
    // Indented a step under the row we're on, and a step more each level
    final indent = 16.0 + 20.0 * depth;
    return Semantics(
      button: onTap != null,
      selected: selected,
      label: semantics,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.fromLTRB(indent, 0, 12, 0),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 40),
            child: Row(children: [
              SizedBox(
                width: 32,
                child: open == null
                    ? null
                    : IconButton(
                        padding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                        onPressed: onToggle,
                        icon: Icon(open! ? Icons.expand_more : Icons.chevron_right, size: 20, color: Kc.muted),
                      ),
              ),
              if (!heading) ...[
                busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: Padding(
                            padding: EdgeInsets.all(2),
                            child: CircularProgressIndicator(strokeWidth: 2, color: Kc.pink)))
                    : Icon(selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                        size: 18, color: selected ? Kc.pink : Kc.dim),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Text(
                  heading ? title.toUpperCase() : title,
                  overflow: TextOverflow.ellipsis,
                  style: heading
                      ? Kc.term(12, color: Kc.muted)
                      : TextStyle(color: selected ? Kc.pink : Kc.text, fontSize: 14),
                ),
              ),
              if (locked != null) ...[
                Icon(locked! ? Icons.lock_outline : Icons.lock_open, size: 16, color: Kc.dim),
                const SizedBox(width: 8),
              ],
              ?trailing,
            ]),
          ),
        ),
      ),
    );
  }
}

/// How many are in a channel, or how many boards are on it nearby.
class _Count extends StatelessWidget {
  final int n;
  const _Count(this.n);

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.person_outline, size: 14, color: Kc.muted),
        const SizedBox(width: 2),
        Text('$n', style: Kc.term(13, color: Kc.muted)),
      ]);
}
