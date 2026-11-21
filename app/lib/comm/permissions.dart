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

  /// A command wasn't taken: the board may have added its sender to its
  /// list, so its state's wanted again.
  VoidCallback? onRefused;

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
    try {
      commandLog.addAll([
        for (final e in jsonDecode(p.getString('commandLog') ?? '[]') as List<dynamic>)
          LogEntry.fromJson(e as Map<String, dynamic>)
      ]);
    } catch (_) {}
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

  /// A command for [cap] that came, from [name] ([key] theirs, [who] who
  /// they are): logged, with how it came and what came of it; one the
  /// board didn't take, a request if it was for want of being allowed.
  /// [scope] is OthersCommand.scope*; [openChannel] that it came to the
  /// open direct channel, which anyone nearby hears, so the board takes it
  /// as to everyone.
  void heard(int cap, List<int> key, String name, String who,
      {required bool done,
      required bool muted,
      required bool direct,
      required int scope,
      bool openChannel = false,
      required String what}) {
    final String outcome;
    if (muted) {
      outcome = 'Ignored: you muted them';
    } else if (done) {
      taken(cap, key);
      outcome = 'Done';
    } else {
      outcome = refused(cap, key, name, who,
          everyone: scope == _scopeEveryone || openChannel, channel: scope == _scopeChannel, what: what);
      onRefused?.call();
    }
    log(LogEntry(DateTime.now(), name, what,
        via: direct ? 'Direct' : 'Cloud',
        scope: switch (scope) { _scopeEveryone => 'To everyone', _scopeChannel => 'To the channel', _ => 'To you only' },
        outcome: outcome));
  }

  static const _scopeEveryone = 0, _scopeChannel = 1;    // OthersCommand.scope*

  /// A command for [cap] that the board didn't take: a request, if it's for
  /// want of being allowed (the capability on Ask, not ignored for how it
  /// came, they're not allowed) and they haven't been declined it.
  /// [everyone] is whether it came to everyone who can hear them, as the
  /// board's ignoring has it. Returns why it wasn't taken, for the log.
  String refused(int cap, List<int> key, String name, String who,
      {required bool everyone, required bool channel, required String what}) {
    final c = policy?.caps[cap];
    final feature = capName(cap);
    if (c == null) return 'Not done';
    if (c.policy == Policy.off) return 'Not done: $feature is off';
    if (c.policy == Policy.anyone) return 'Not done';
    if (everyone && c.ignore & ignoreEveryone != 0) return 'Not done: you ignore commands sent to everyone';
    if (channel && !everyone && c.ignore & ignoreChannel != 0) {
      return 'Not done: you ignore commands sent to a channel';
    }
    final hex = _hex(key);
    if (c.person(hex.substring(0, 16))?.allowed ?? false) return 'Not done';
    if (declined.any((d) => d.key == hex && d.caps.contains(cap))) return 'Not done: you declined them before';
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
      return more ? 'Not done: they asked for permission' : 'Not done: their request is waiting';
    }
    final r = PermissionRequest(hex, name, who, {cap}, now, what);
    requests.insert(0, r);
    _save();
    onNew?.call(r);
    return 'Not done: they asked for permission';
  }

  /// A command that was taken: one refused a moment ago, by the other way it
  /// came (the server or direct comms), wasn't a request after all.
  void taken(int cap, List<int> key) {
    final hex = _hex(key);
    for (final r in requests) {
      if (r.key == hex && r.caps.contains(cap) && DateTime.now().difference(r.time) < const Duration(seconds: 5)) {
        r.caps.remove(cap);
        if (r.caps.isEmpty) requests.remove(r);
        _save();
        return;
      }
    }
  }

  static String _hex(List<int> key) => key.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  bool get boardReady => board.state == BoardState.connected && board.status != null;

  /// Allow someone [caps] on the board, by their whole key, added to its
  /// list if they aren't on it. Those set to Off
  /// keep it for when they're on again. Returns those the unit didn't take.
  Future<Set<int>> grant(String key, String name, Set<int> caps, {bool accepting = false}) async {
    final id = key.substring(0, 16);
    final q = 'key=$key&id=$id&name=${Uri.encodeQueryComponent(name)}';
    String? state;
    for (final cap in caps) {
      state = await _post('kind=${boardKindOf[cap]}&$q&allow=1') ?? state;
    }
    final failed = _notAsAsked(state, id, {for (final c in caps) c: true});
    final got = caps.difference(failed);
    requests.removeWhere((r) => r.key == key);
    if (got.isNotEmpty) declined.removeWhere((r) => r.key == key);
    _save();
    final what = got.isEmpty ? 'nothing' : _names(got);
    log(LogEntry(DateTime.now(), name, '',
        outcome: accepting ? "You accepted $name's request, allowing $what" : 'You allowed $name $what'));
    return failed;
  }

  Future<Set<int>> accept(PermissionRequest r, Set<int> caps) => grant(r.key, r.name, caps, accepting: true);

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
    log(LogEntry(DateTime.now(), r.name, '', outcome: "You declined ${r.name}'s request for ${_names(r.caps)}"));
  }

  void removeDeclined(PermissionRequest r) {
    declined.remove(r);
    _save();
  }

  /// Someone in the board's list: allowed or not for each capability.
  /// Returns those the unit didn't take.
  Future<Set<int>> setAllowed(String id, Map<int, bool> allowed) async {
    String? state;
    for (final MapEntry(key: cap, value: on) in allowed.entries) {
      state = await _post('kind=${boardKindOf[cap]}&id=$id&allow=${on ? 1 : 0}') ?? state;
    }
    return _notAsAsked(state, id, allowed);
  }

  /// Those of [want] that the board's [state] doesn't have as asked: all of
  /// them, if it didn't answer.
  Set<int> _notAsAsked(String? state, String id, Map<int, bool> want) {
    final p = state == null ? null : BoardPolicy.fromState(state);
    return {
      for (final MapEntry(key: cap, value: on) in want.entries)
        if (p == null || (p.caps[cap]?.person(id)?.allowed ?? false) != on) cap
    };
  }

  /// Out of the board's list, for every capability.
  Future<void> forget(String id) async {
    for (final kind in boardKindOf.values) {
      await _post('kind=$kind&id=$id&forget=1');
    }
  }

  Future<void> setPolicy(int cap, Policy p) => _post('kind=${boardKindOf[cap]}&permission=${p.index}');

  Future<void> setIgnore(int cap, int ignore) => _post('kind=${boardKindOf[cap]}&ignore=$ignore');

  /// The answer: the board's state, which comes back through
  /// BoardLink.states too. Null if it didn't answer.
  Future<String?> _post(String query) async {
    try {
      final a = await board.request('POST', '/api/others?$query');
      return a.status == 200 ? a.body : null;
    } catch (_) {
      return null;
    }
  }

  static String _names(Iterable<int> caps) => caps.map(capName).join(' and ');

  // ----- The command log -----

  /// Every command that came, and the requests seen to: newest first, the
  /// last [logMax].
  final List<LogEntry> commandLog = [];
  static const logMax = 500;
  bool _logSaving = false;

  void log(LogEntry e) {
    commandLog.insert(0, e);
    if (commandLog.length > logMax) commandLog.removeRange(logMax, commandLog.length);
    notifyListeners();
    // Kept, but not on every slider step
    if (_logSaving) return;
    _logSaving = true;
    Future.delayed(const Duration(seconds: 2), () {
      _logSaving = false;
      _prefs?.setString('commandLog', jsonEncode([for (final e in commandLog) e.toJson()]));
    });
  }

  void clearLog() {
    commandLog.clear();
    _prefs?.remove('commandLog');
    notifyListeners();
  }
}

/// What a capability's called.
String capName(int cap) => switch (cap) {
      Capabilities.terminal => 'Terminal',
      Capabilities.lovense => 'Lovense',
      _ => 'something',
    };

/// A line of the command log: a command that came ([who] [what], how it
/// came, and what came of it), or a request seen to ([outcome] alone).
class LogEntry {
  final DateTime time;
  final String who;
  final String what;
  final String? via;        // 'Cloud' or 'Direct'
  final String? scope;      // to everyone, the channel, or you only
  final String outcome;
  const LogEntry(this.time, this.who, this.what, {this.via, this.scope, required this.outcome});

  bool get isCommand => what.isNotEmpty;

  Map<String, Object?> toJson() =>
      {'t': time.millisecondsSinceEpoch, 'who': who, 'what': what, 'via': via, 'scope': scope, 'out': outcome};
  static LogEntry fromJson(Map<String, dynamic> j) => LogEntry(
      DateTime.fromMillisecondsSinceEpoch(j['t'] as int), j['who'] as String, j['what'] as String,
      via: j['via'] as String?, scope: j['scope'] as String?, outcome: j['out'] as String);
}
