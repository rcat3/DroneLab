import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'board_link.dart';
import 'board_protocol.dart';
import 'capabilities.dart';
import 'rules.dart';

export 'rules.dart' show Policy, ignoreEveryone, ignoreChannel;

/// Who may control what of ours, in one place: the rules this app owns
/// (rules.dart: each class's policy, what it ignores, and who's allowed),
/// pushed to the unit, which goes by them while the phone's away; requests,
/// from those whose commands weren't taken as they aren't allowed yet; and
/// those whose requests were declined.
///
/// Senders never hear about any of it: they send, and it's done or not.

/// Someone listed.
class ListedPerson {
  final String id;          // their key's first 8 bytes, in hex
  final String key;         // the whole key, in hex
  final String name;
  final bool allowed;
  final bool clash;         // using a name someone known had first
  const ListedPerson(this.id, this.key, this.name, this.allowed, this.clash);
}

/// One class's rule, and everyone listed, allowed it or not.
class CapPolicy {
  final Policy policy;
  final int ignore;
  final List<ListedPerson> people;
  const CapPolicy(this.policy, this.ignore, this.people);

  ListedPerson? person(String id) {
    for (final p in people) {
      if (p.id == id) return p;
    }
    return null;
  }

  bool allows(String id) => policy == Policy.anyone || (person(id)?.allowed ?? false);
}

/// The rules, as Permissions shows them: each class's.
class PolicyView {
  final Map<int, CapPolicy> caps;
  final List<ListedPerson> everyone;
  const PolicyView(this.caps, this.everyone);
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

/// Whether the unit has the rules as they are here.
enum RulesSync { noUnit, sending, upToDate }

class Permissions extends ChangeNotifier {
  final BoardLink board;
  Permissions(this.board);

  SharedPreferences? _prefs;

  /// Ours, kept here and pushed to the unit.
  HiveRules rules = HiveRules();

  /// Whole keys (hex) of those muted, for the rules; and whether someone
  /// listed is using a name someone else had first. From the controller.
  Set<String> Function() mutedKeys = () => const {};
  bool Function(String keyHex) clashOf = (_) => false;

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

  /// The rules have changed: the unit's to have them.
  VoidCallback? onRulesChanged;

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
      final r = p.getString('hiveRules');
      if (r != null) rules = HiveRules.fromJson(jsonDecode(r) as Map<String, dynamic>);
    } catch (_) {}
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

  /// The rules have changed: kept, and on their way to the unit.
  void rulesChanged() {
    rules.owned = true;
    _prefs?.setString('hiveRules', jsonEncode(rules.toJson()));
    notifyListeners();
    onRulesChanged?.call();
  }

  /// The rules, for the Permissions screen: the classes controlKinds show.
  PolicyView get policy {
    final everyone = [
      for (final p in rules.people.values) ListedPerson(p.id, p.key, p.name, false, clashOf(p.key)),
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return PolicyView({
      for (final cls in RuleClass.all)
        cls: CapPolicy(rules.policy(cls), rules.rule(cls).ignore, [
          for (final p in everyone)
            ListedPerson(p.id, p.key, p.name, rules.people[p.key]!.allowed.contains(cls), p.clash),
        ]),
    }, everyone);
  }

  // ----- The unit -----

  /// The unit's rules' hash, and whether its wearer's switched something
  /// Off on it since: as it last said (its /version, and its state).
  String? _unitHash;
  bool _unitEdited = false;
  String? _sentHash;          // pushed, waiting for the unit to say it has them
  bool _askingUnit = false;

  bool get unitHasRules => board.state == BoardState.connected && (board.status?.version ?? 0) >= commVersionRules;

  RulesSync get sync {
    if (!unitHasRules || _unitHash == null) return RulesSync.noUnit;
    return _unitHash == HiveRules.hashOf(rules.encode(mutedKeys())) ? RulesSync.upToDate : RulesSync.sending;
  }

  /// The unit's state's come (or its /version): its rules' hash, and
  /// whether it's changed them.
  void unitSaid(Map<String, dynamic> j) {
    final h = j['rules'];
    if (h is! String) return;
    final edited = j['edited'] == 1;
    if (h == _unitHash && edited == _unitEdited) return;
    _unitHash = h;
    _unitEdited = edited;
    notifyListeners();
    syncUnit();
  }

  void boardState(String json) {
    try {
      final j = jsonDecode(json);
      if (j is Map<String, dynamic>) unitSaid(j);
    } catch (_) {}
  }

  void boardGone() {
    _unitHash = null;
    _unitEdited = false;
    _sentHash = null;
    notifyListeners();
  }

  /// Give the unit our rules if it hasn't them: or first take on its own,
  /// if this app's never had any (a new phone, or the app put back), and
  /// what its wearer's switched Off on it.
  Future<void> syncUnit() async {
    if (!unitHasRules || _unitHash == null || _askingUnit) return;
    if (_unitEdited || (!rules.owned && _unitHash != '00000000')) {
      _askingUnit = true;
      var took = false;
      try {
        final a = await board.request('GET', '/api/rules');
        if (a.status == 200) {
          rules.takeOn(jsonDecode(a.body) as Map<String, dynamic>, all: !rules.owned);
          _unitEdited = false;
          _sentHash = null;
          took = true;
        }
      } catch (_) {
      } finally {
        _askingUnit = false;
      }
      if (took) rulesChanged();     // and back to the unit, as ours now
      return;
    }
    final doc = rules.encode(mutedKeys());
    final hash = HiveRules.hashOf(doc);
    if (hash == _unitHash) {
      _sentHash = hash;
      if (!rules.owned) rulesChanged();
      return;
    }
    if (hash == _sentHash) return;      // on its way
    _sentHash = hash;
    for (final piece in rulesMessages(doc, board.maxWrite)) {
      board.send(piece);
    }
    notifyListeners();
    // For the unit to say it has them
    Future.delayed(const Duration(milliseconds: 600), () {
      if (unitHasRules) board.request('GET', '/api/state').catchError((_) => RemoteAnswer(0, ''));
    });
  }

  // ----- Commands -----

  /// A command for [cap] that came, from [name] ([key] theirs, [who] who
  /// they are): logged, with how it came and what came of it; one the
  /// unit didn't take, a request if it was for want of being allowed.
  /// [scope] is OthersCommand.scope*; [openChannel] that it came to the
  /// open direct channel, which anyone nearby hears, so it's taken as to
  /// everyone.
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
    }
    log(LogEntry(DateTime.now(), name, what,
        via: direct ? 'Direct' : 'Cloud',
        scope: switch (scope) { _scopeEveryone => 'To everyone', _scopeChannel => 'To the channel', _ => 'To you only' },
        outcome: outcome));
  }

  static const _scopeEveryone = 0, _scopeChannel = 1;    // OthersCommand.scope*

  /// A command for [cap] that the unit didn't take: a request, if it's for
  /// want of being allowed and they haven't been declined it. Returns why
  /// it wasn't taken, for the log.
  String refused(int cap, List<int> key, String name, String who,
      {required bool everyone, required bool channel, required String what}) {
    final feature = capName(cap);
    final hex = _hex(key);
    final listed = rules.people.containsKey(hex);
    rules.note(hex, name);
    if (!listed) rulesChanged();
    switch (rules.decide(cap, hex, muted: false, everyone: everyone, channel: channel)) {
      case Decision.off:
        return 'Not done: $feature is off';
      case Decision.ignoredEveryone:
        return 'Not done: you ignore commands sent to everyone';
      case Decision.ignoredChannel:
        return 'Not done: you ignore commands sent to a channel';
      case Decision.taken:
      case Decision.muted:
        return 'Not done';     // the unit hadn't the latest rules
      case Decision.notAllowed:
        break;
    }
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

  // ----- Changing them -----

  /// Allow someone [caps], by their whole key, listed if they aren't.
  /// Those set to Off keep it for when they're on again. Returns those that
  /// couldn't be (none: they're the app's, and go to the unit).
  Future<Set<int>> grant(String key, String name, Set<int> caps, {bool accepting = false}) async {
    rules.note(key, name).allowed.addAll(caps);
    requests.removeWhere((r) => r.key == key);
    if (caps.isNotEmpty) declined.removeWhere((r) => r.key == key);
    _save();
    rulesChanged();
    final what = caps.isEmpty ? 'nothing' : _names(caps);
    log(LogEntry(DateTime.now(), name, '',
        outcome: accepting ? "You accepted $name's request, allowing $what" : 'You allowed $name $what'));
    return const {};
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

  /// Someone listed: allowed or not for each capability.
  Future<Set<int>> setAllowed(String id, Map<int, bool> allowed) async {
    final p = rules.byId(id);
    if (p == null) return allowed.keys.toSet();
    for (final MapEntry(key: cap, value: on) in allowed.entries) {
      on ? p.allowed.add(cap) : p.allowed.remove(cap);
    }
    p.seen = DateTime.now();
    rulesChanged();
    return const {};
  }

  /// Out of the list, and allowed nothing.
  Future<void> forget(String id) async {
    final p = rules.byId(id);
    if (p == null) return;
    rules.people.remove(p.key);
    rulesChanged();
  }

  Future<void> setPolicy(int cap, Policy p) async {
    rules.rule(cap).policy = p;
    rulesChanged();
  }

  Future<void> setIgnore(int cap, int ignore) async {
    rules.rule(cap).ignore = ignore;
    rulesChanged();
  }

  /// Our toys' layout, for Setup → Toys → Pairing and Mapping: the channel an output follows
  /// (-1 for none), of a toy with [outputs] (their channels now), by its
  /// address.
  void mapOutput(String addr, List<int> outputs, int output, int channel) {
    final m = rules.toys[addr] ?? [...outputs];
    while (m.length <= output) {
      m.add(-1);
    }
    m[output] = channel;
    rules.toys[addr] = m;
    rulesChanged();
  }

  /// The unit's screen controls; null for one per mapped channel.
  void setControls(List<ScreenControl>? controls) {
    rules.controls = controls;
    rulesChanged();
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
      Capabilities.vibe => 'Vibe',
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
