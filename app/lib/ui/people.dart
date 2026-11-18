import 'package:flutter/material.dart';

import '../comm/board_link.dart';
import '../comm/comm_controller.dart';
import '../comm/mumble_client.dart';

/// The tab showing: [tabHiveMind] and so on. Kept here so a sheet can move to
/// another tab.
final appTab = ValueNotifier<int>(tabHiveMind);
const tabHiveMind = 0;
const tabTerminal = 1;
const tabControl = 2;
const tabRecord = 3;
const tabRemote = 4;

/// Someone in the hive: on the server, in our channel, or a board heard over
/// direct comms.
class Person {
  final String key;           // 's<session>' or 'd<board id>'
  final String name;
  final MumbleUser? user;
  final NearbyBoard? board;
  final bool talking;
  final bool mutedByMe;
  const Person(this.key, this.name, {this.user, this.board, this.talking = false, this.mutedByMe = false});

  bool get onServer => user != null;
}

/// Everyone about: those in our server channel, then the boards heard over
/// direct comms, if it's on.
List<Person> hivePeople(CommController comm) {
  final m = comm.mumble;
  final users = m != null && m.state == MumbleState.connected ? m.channelUsers : const <MumbleUser>[];
  final directOn = comm.board.state == BoardState.connected && (comm.boardSettings?.direct?.on ?? false);
  final boards = directOn ? (comm.nearby.values.toList()..sort((a, b) => b.rssi.compareTo(a.rssi))) : <NearbyBoard>[];
  return [
    for (final u in users)
      Person('s${u.session}', u.name,
          user: u, talking: comm.talking.contains(u.session), mutedByMe: comm.isMuted(u.name)),
    for (final b in boards)
      Person('d${b.id}', b.name, board: b, talking: b.talking, mutedByMe: comm.isMuted(b.name)),
  ];
}

/// Who commands and messages go to, shared by the Control and Terminal tabs:
/// everyone, or those picked.
class Recipients extends ChangeNotifier {
  final Set<String> picked = {};

  bool get everyone => picked.isEmpty;
  List<int> get serverSessions => [for (final k in picked) if (k.startsWith('s')) int.parse(k.substring(1))];
  List<int> get directIds => [for (final k in picked) if (k.startsWith('d')) int.parse(k.substring(1))];

  void pickEveryone() {
    if (picked.isEmpty) return;
    picked.clear();
    notifyListeners();
  }

  void toggle(String key) {
    picked.contains(key) ? picked.remove(key) : picked.add(key);
    notifyListeners();
  }

  void only(String key) {
    picked
      ..clear()
      ..add(key);
    notifyListeners();
  }

  /// Forget those who've gone.
  void keepOnly(Iterable<String> keys) {
    final present = keys.toSet();
    picked.retainWhere(present.contains);
  }

  /// Who they are, to show: "EVERYONE" or their names.
  String describe(List<Person> people) => everyone
      ? 'EVERYONE'
      : [for (final p in people) if (picked.contains(p.key)) p.name.toUpperCase()].join(', ');
}

final recipients = Recipients();

/// Everyone, and each person about, to pick from.
class RecipientChips extends StatelessWidget {
  final CommController comm;
  const RecipientChips({super.key, required this.comm});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([comm, recipients]),
      builder: (context, _) {
        final people = comm.canSendCommands ? hivePeople(comm) : const <Person>[];
        recipients.keepOnly(people.map((p) => p.key));
        return SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              FilterChip(
                label: const Text('Everyone'),
                selected: recipients.everyone,
                onSelected: (_) => recipients.pickEveryone(),
              ),
              for (final p in people) ...[
                const SizedBox(width: 8),
                FilterChip(
                  avatar: Icon(p.onServer ? Icons.cloud_outlined : Icons.settings_input_antenna, size: 16),
                  label: Text(p.name),
                  selected: recipients.picked.contains(p.key),
                  onSelected: (_) => recipients.toggle(p.key),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
