import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../comm/board_link.dart';
import '../comm/comm_controller.dart';
import '../comm/known_people.dart';
import '../comm/mumble_client.dart';

/// The tab showing: [tabVoice] and so on. Kept here so a sheet can move to
/// another tab.
final appTab = ValueNotifier<int>(tabVoice);
const tabVoice = 0;
const tabText = 1;
const tabRecord = 2;
const tabRemote = 3;

/// Someone in the hive: on the server, in our channel, or a board heard over
/// direct comms.
class Person {
  final String key;           // 's<session>' or 'd<board id>'
  final KnownPerson who;      // who they are
  final String name;
  final MumbleUser? user;
  final NearbyBoard? board;
  final bool talking;
  final bool mutedByMe;
  final Uint8List? picture;     // their avatar, if it's come
  const Person(this.key, this.who, this.name,
      {this.user, this.board, this.talking = false, this.mutedByMe = false, this.picture});

  bool get onServer => user != null;
  String get id => who.id;
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
      if (comm.personOfUser(u) case final who)
        Person('s${u.session}', who, u.name,
            user: u, talking: comm.talking.contains(u.session), mutedByMe: who.muted, picture: u.texture),
    for (final b in boards)
      if (comm.personOfBoard(b) case final who)
        Person('d${b.id}', who, b.name,
            board: b, talking: b.talking, mutedByMe: who.muted, picture: comm.directAvatars[b.id]),
  ];
}

/// Everyone about, each once: someone on the server and heard directly is
/// one person, with both. In the order [hivePeople] has them.
List<Person> peopleOnce(CommController comm) {
  final byId = <String, Person>{};
  for (final p in hivePeople(comm)) {
    final had = byId[p.id];
    byId[p.id] = had == null
        ? p
        : Person('p${p.id}', p.who, had.name,
            user: had.user ?? p.user,
            board: had.board ?? p.board,
            talking: had.talking || p.talking,
            mutedByMe: had.mutedByMe,
            picture: had.picture ?? p.picture);
  }
  return byId.values.toList();
}
