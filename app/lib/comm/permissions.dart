import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'board_link.dart';
import 'capabilities.dart';

/// Who may control what of ours, in one place: the board's own policy for
/// each capability (core/app/others.h: Off, Ask or Anyone, what's ignored,
/// and who's allowed), read from its state and changed through its remote
/// API; requests, from those whose commands it didn't take as they aren't
/// allowed yet; and those whose requests were declined.
///
/// Senders never hear about any of it: they send, and it's done or not.

/// The board's kind of command (others_kind_t) for each capability.
const boardKindOf = {Capabilities.lovense: 0, Capabilities.terminal: 1};

/// Who a capability's taken from, as others_permission_t.
enum Policy {
  off,      // nobody
  ask,      // those allowed
  anyone;

  static Policy of(int v) => v == 2 ? anyone : v == 1 ? ask : off;
}

/// What a capability ignores, whoever it's from (OTHERS_IGNORE_*).
const ignoreEveryone = 0x02, ignoreChannel = 0x04;

/// Someone in the board's list.
class ListedPerson {
  final String id;          // their key's first 8 bytes, in hex
  final String name;
  final bool allowed;
  final bool clash;         // using a name someone listed had first
  const ListedPerson(this.id, this.name, this.allowed, this.clash);
}

/// One capability's policy on the board.
class CapPolicy {
  final Policy policy;
  final int ignore;
  final List<ListedPerson> people;    // who's sent it, or is allowed it
  const CapPolicy(this.policy, this.ignore, this.people);

  ListedPerson? person(String id) {
    for (final p in people) {
      if (p.id == id) return p;
    }
    return null;
  }

  bool allows(String id) => policy == Policy.anyone || (person(id)?.allowed ?? false);
}

/// The board's policy for each capability, from its state.
class BoardPolicy {
  final Map<int, CapPolicy> caps;
  const BoardPolicy(this.caps);

  static BoardPolicy? fromState(String json) {
    try {
      final j = jsonDecode(json);
      if (j is! Map<String, dynamic> || j['others'] is! List) return null;
      final others = j['others'] as List<dynamic>;
      final caps = <int, CapPolicy>{};
      for (final MapEntry(key: cap, value: kind) in boardKindOf.entries) {
        if (kind >= others.length) continue;
        final o = others[kind] as Map<String, dynamic>;
        caps[cap] = CapPolicy(Policy.of((o['permission'] as num?)?.toInt() ?? 0), (o['ignore'] as num?)?.toInt() ?? 0, [
          for (final s in o['senders'] as List<dynamic>? ?? const [])
            ListedPerson(s['id'] as String, s['name'] as String, s['allowed'] == 1, s['clash'] == 1),
        ]);
      }
      return BoardPolicy(caps);
    } catch (_) {
      return null;
    }
  }

  /// Everyone in the list, once each, for any capability: their id and name.
  List<ListedPerson> get everyone {
    final byId = <String, ListedPerson>{};
    for (final c in caps.values) {
      for (final p in c.people) {
        byId.putIfAbsent(p.id, () => p);
      }
    }
    return byId.values.toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }
}

/// Someone asking, by sending commands we didn't take as they aren't
/// allowed: for which capabilities, and what they last tried.
class PermissionRequest {
  final String key;         // their whole public key, in hex
  String name;
  final String who;         // who they are, as known_people has them
  final Set<int> caps;
  DateTime time;
  String what;
  PermissionRequest(this.key, this.name, this.who, this.caps, this.time, this.what);

  String get id => key.substring(0, 16);

  Map<String, Object> toJson() =>
      {'key': key, 'name': name, 'who': who, 'caps': caps.toList(), 'time': time.millisecondsSinceEpoch, 'what': what};
  static PermissionRequest fromJson(Map<String, dynamic> j) => PermissionRequest(
      j['key'] as String,
      j['name'] as String,
      j['who'] as String,
      {for (final c in j['caps'] as List<dynamic>) c as int},
      DateTime.fromMillisecondsSinceEpoch(j['time'] as int),
      j['what'] as String? ?? '');
}

class Permissions extends ChangeNotifier {
  final BoardLink board;
  Permissions(this.board);

  SharedPreferences? _prefs;

  /// The board's, null until it's said (or while there's no board).
  BoardPolicy? policy;

  /// Waiting to be accepted or declined, newest first.
  final List<PermissionRequest> requests = [];

  /// Declined, so their commands don't ask again for those capabilities;
  /// newest first.
  final List<PermissionRequest> declined = [];

  /// A request that's new, or asks for more: for the attention tone and
  /// the notification.
  void Function(PermissionRequest r)? onNew;

  /// The requests are all seen to, for the notification to go.
  VoidCallback? onNone;

  void load(SharedPreferences p) {
    _prefs = p;
    List<PermissionRequest> read(String name) {
      try {
        return [
          for (final r in jsonDecode(p.getString(name) ?? '[]') as List<dynamic>)
            PermissionRequest.fromJson(r as Map<String, dynamic>)
        ];
      } catch (_) {
        return [];
      }
    }

    requests.addAll(read('permissionRequests'));
    declined.addAll(read('permissionDeclined'));
  }

  void _save() {
    _prefs?.setString('permissionRequests', jsonEncode([for (final r in requests) r.toJson()]));
    _prefs?.setString('permissionDeclined', jsonEncode([for (final r in declined) r.toJson()]));
    if (requests.isEmpty) onNone?.call();
    notifyListeners();
  }

  /// The board's state's come: its policy, and requests it's made moot (the
  /// person allowed on the unit itself, or the capability open to anyone).
  void boardState(String json) {
    final p = BoardPolicy.fromState(json);
    if (p == null) return;
    policy = p;
    var changed = false;
    for (final r in requests.toList()) {
      final before = r.caps.length;
      r.caps.removeWhere((c) => p.caps[c]?.allows(r.id) ?? false);
      if (r.caps.length != before) changed = true;
      if (r.caps.isEmpty) requests.remove(r);
    }
    changed ? _save() : notifyListeners();
  }

  void boardGone() {
    policy = null;
    notifyListeners();
  }

  /// A command for [cap] that the board didn't take, from someone not
  /// muted: a request, if it's for want of being allowed (the capability on
  /// Ask, not ignored for how it came, they're not allowed) and they haven't
  /// been declined it. [everyone] is whether it came to everyone who can
  /// hear them, as the board's ignoring has it (a broadcast, or the open
  /// direct channel's).
  void refused(int cap, List<int> key, String name, String who,
      {required bool everyone, required bool channel, required String what}) {
    final c = policy?.caps[cap];
    if (c == null || c.policy != Policy.ask) return;
    if ((everyone && c.ignore & ignoreEveryone != 0) || (channel && !everyone && c.ignore & ignoreChannel != 0)) {
      return;
    }
    final hex = key.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final id = hex.substring(0, 16);
    if (c.person(id)?.allowed ?? false) return;
    if (declined.any((d) => d.key == hex && d.caps.contains(cap))) return;
    final now = DateTime.now();
    for (final r in requests) {
      if (r.key != hex) continue;
      final more = r.caps.add(cap);
      r
        ..name = name
        ..time = now
        ..what = what;
      requests
        ..remove(r)
        ..insert(0, r);
      _save();
      if (more) onNew?.call(r);
      return;
    }
    final r = PermissionRequest(hex, name, who, {cap}, now, what);
    requests.insert(0, r);
    _save();
    onNew?.call(r);
  }

  /// A command that was taken: one refused a moment ago, by the other way it
  /// came (the server or direct comms), wasn't a request after all.
  void taken(int cap, List<int> key) {
    final hex = key.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    for (final r in requests) {
      if (r.key == hex && r.caps.contains(cap) && DateTime.now().difference(r.time) < const Duration(seconds: 5)) {
        r.caps.remove(cap);
        if (r.caps.isEmpty) requests.remove(r);
        _save();
        return;
      }
    }
  }

  bool get boardReady => board.state == BoardState.connected && board.status != null;

  /// Allow someone [caps] on the board: by their whole key, which firmware
  /// from before it ignores and finds them by id instead, for the
  /// capabilities they've sent. Those set to Off keep it for when they're
  /// on again.
  Future<void> grant(String key, String name, Set<int> caps) async {
    final q = 'key=$key&id=${key.substring(0, 16)}&name=${Uri.encodeQueryComponent(name)}';
    for (final cap in caps) {
      await _post('kind=${boardKindOf[cap]}&$q&allow=1');
    }
    requests.removeWhere((r) => r.key == key);
    declined.removeWhere((r) => r.key == key);
    _save();
  }

  Future<void> accept(PermissionRequest r, Set<int> caps) => grant(r.key, r.name, caps);

  void decline(PermissionRequest r) {
    requests.remove(r);
    final had = declined.where((d) => d.key == r.key).firstOrNull;
    if (had != null) {
      had.caps.addAll(r.caps);
      declined.remove(had);
    }
    final d = (had ?? r)..time = DateTime.now();
    declined.insert(0, d);
    _save();
  }

  void removeDeclined(PermissionRequest r) {
    declined.remove(r);
    _save();
  }

  /// Someone in the board's list: allowed or not for each capability.
  Future<void> setAllowed(String id, Map<int, bool> allowed) async {
    for (final MapEntry(key: cap, value: on) in allowed.entries) {
      await _post('kind=${boardKindOf[cap]}&id=$id&allow=${on ? 1 : 0}');
    }
  }

  /// Out of the board's list, for every capability.
  Future<void> forget(String id) async {
    for (final kind in boardKindOf.values) {
      await _post('kind=$kind&id=$id&forget=1');
    }
  }

  Future<void> setPolicy(int cap, Policy p) => _post('kind=${boardKindOf[cap]}&permission=${p.index}');

  Future<void> setIgnore(int cap, int ignore) => _post('kind=${boardKindOf[cap]}&ignore=$ignore');

  /// The answer has the board's state, which comes back through
  /// BoardLink.states.
  Future<void> _post(String query) async {
    try {
      await board.request('POST', '/api/others?$query');
    } catch (_) {}
  }
}
