import 'dart:convert';
import 'dart:typed_data';

import 'capabilities.dart';

/// HiveMind Control's rules, which this app owns: who may control what of
/// ours, and how our toys are laid out. They're pushed to each host that
/// runs something others control (our unit now; the phone itself and a
/// Bluetooth bridge are hosts too), which keeps the last it was given and
/// goes by them while the phone's away (core/app/rules.h has the document).
///
/// Every class (a kind of toy, or a function of the Display unit) has a
/// policy: Off, Ask (only those allowed; anyone else's commands become
/// requests, which count as consent as the person answers each), or Anyone.
/// New ones start on Ask, E-stim on Off, and nothing ever starts on Anyone.

/// The classes, by the capabilities' ids (RULES_CLASS_*).
class RuleClass {
  static const display = Capabilities.display, vibe = Capabilities.vibe, sounds = Capabilities.sounds;
  static const estim = 3, machine = 4;    // 5 was to be pictures, which display covers
  static const all = [display, vibe, estim, machine, sounds];

  /// HiveSight's, which the phone goes by and the unit never has: a Guide
  /// guiding you. (The light pulse is one of its ignore options.)
  static const hiveSight = 8;
  static const phoneOnly = {hiveSight};

  /// Every class Permissions shows.
  static const shown = [...all, hiveSight];

  /// Where a class starts, before it's been set.
  static Policy defaultPolicy(int cls) => cls == estim ? Policy.off : Policy.ask;
}

/// Who a class is taken from (RULES_OFF, RULES_ASK, RULES_ANYONE).
enum Policy {
  off,
  ask,
  anyone;

  static Policy of(int v) => v == 2 ? anyone : v == 1 ? ask : off;
}

/// What a class ignores, whoever it's from (OTHERS_IGNORE_*).
const ignoreEveryone = 0x02, ignoreChannel = 0x04;

/// HiveSight's: never show the light pulse, whoever guides. Set to begin with.
const ignoreLightPulse = 0x08;

/// HiveSight's: never let a Guide use our toys in a session, even one we've
/// allowed them on. Not set to begin with: the Vibe class's own permission
/// is the consent.
const ignoreToys = 0x10;

class ClassRule {
  Policy policy;
  int ignore;
  ClassRule(this.policy, [this.ignore = 0]);

  Map<String, Object> toJson() => {'policy': policy.index, 'ignore': ignore};
  static ClassRule fromJson(Map<String, dynamic> j) =>
      ClassRule(Policy.of((j['policy'] as num?)?.toInt() ?? 1), (j['ignore'] as num?)?.toInt() ?? 0);
}

/// Someone in the rules, by their whole key: allowed some classes, or none
/// yet (they've sent a command, or asked).
class RulePerson {
  final String key;       // their public key, in hex
  String name;
  final Set<int> allowed;
  DateTime seen;          // last sent, or was allowed: who goes first when there's no room
  RulePerson(this.key, this.name, Set<int>? allowed, {DateTime? seen})
      : allowed = allowed ?? {},
        seen = seen ?? DateTime.now();

  String get id => key.substring(0, 16);

  Map<String, Object> toJson() => {'key': key, 'name': name, 'allowed': allowed.toList(), 'seen': seen.millisecondsSinceEpoch};
  static RulePerson fromJson(Map<String, dynamic> j) => RulePerson(
        j['key'] as String,
        j['name'] as String? ?? '',
        {for (final c in j['allowed'] as List<dynamic>? ?? const []) (c as num).toInt()},
        seen: DateTime.fromMillisecondsSinceEpoch((j['seen'] as num?)?.toInt() ?? 0),
      );
}

/// A screen control: its label, and the channels it drives together.
class ScreenControl {
  final String label;
  final int channels;
  const ScreenControl(this.label, this.channels);
}

class HiveRules {
  /// The most people a host keeps (RULES_PEOPLE_MAX), and the most this
  /// app lists, allowed or not.
  static const hostPeopleMax = 32, listMax = 64;

  /// Each class's rule; one not set yet is at its default.
  final Map<int, ClassRule> classes = {};

  /// Everyone, by key.
  final Map<String, RulePerson> people = {};

  /// Each toy's outputs' channels (0 for V1, -1 for none), by its Bluetooth
  /// address (12 hex digits); a toy not here has the usual mapping.
  final Map<String, List<int>> toys = {};

  /// The unit's screen controls as laid out; null for one per mapped channel.
  List<ScreenControl>? controls;

  /// Whether they've ever been set or given to a unit: until then, a unit's
  /// own are taken on when it connects (a new phone, or the app put back).
  bool owned = false;

  ClassRule rule(int cls) => classes.putIfAbsent(
    cls,
    () => ClassRule(RuleClass.defaultPolicy(cls), cls == RuleClass.hiveSight ? ignoreLightPulse : 0),
  );
  Policy policy(int cls) => rule(cls).policy;

  bool allows(String keyHex, int cls) => policy(cls) == Policy.anyone || (people[keyHex]?.allowed.contains(cls) ?? false);

  /// Someone who's sent a command: listed, to be allowed if the wearer wants.
  RulePerson note(String keyHex, String name) {
    final p = people.putIfAbsent(keyHex, () => RulePerson(keyHex, name, {}));
    if (name.isNotEmpty) p.name = name;
    p.seen = DateTime.now();
    _trim();
    return p;
  }

  /// Too many listed: those allowed nothing, longest unseen, go first.
  void _trim() {
    if (people.length <= listMax) return;
    final idle = people.values.where((p) => p.allowed.isEmpty).toList()..sort((a, b) => a.seen.compareTo(b.seen));
    for (final p in idle.take(people.length - listMax)) {
      people.remove(p.key);
    }
  }

  RulePerson? byId(String id) {
    for (final p in people.values) {
      if (p.id == id) return p;
    }
    return null;
  }

  // ----- As they're kept -----

  Map<String, Object?> toJson() => {
        'owned': owned,
        'classes': {for (final e in classes.entries) '${e.key}': e.value.toJson()},
        'people': [for (final p in people.values) p.toJson()],
        'toys': toys,
        'controls': controls == null ? null : [for (final c in controls!) {'label': c.label, 'channels': c.channels}],
      };

  static HiveRules fromJson(Map<String, dynamic> j) {
    final r = HiveRules()..owned = j['owned'] == true;
    for (final e in (j['classes'] as Map<String, dynamic>? ?? const {}).entries) {
      r.classes[int.parse(e.key)] = ClassRule.fromJson(e.value as Map<String, dynamic>);
    }
    for (final p in j['people'] as List<dynamic>? ?? const []) {
      final person = RulePerson.fromJson(p as Map<String, dynamic>);
      r.people[person.key] = person;
    }
    for (final e in (j['toys'] as Map<String, dynamic>? ?? const {}).entries) {
      r.toys[e.key] = [for (final c in e.value as List<dynamic>) (c as num).toInt()];
    }
    final c = j['controls'] as List<dynamic>?;
    r.controls = c == null
        ? null
        : [
            for (final x in c)
              ScreenControl((x as Map<String, dynamic>)['label'] as String? ?? '', (x['channels'] as num?)?.toInt() ?? 0)
          ];
    return r;
  }

  // ----- As a host has them -----

  /// The document (core/app/rules.h), with [muted] (whole keys, in hex)
  /// flagged: those allowed something first, then the muted, to
  /// [hostPeopleMax] in all.
  Uint8List encode(Set<String> muted) {
    final sections = <(int, List<int>)>[];
    sections.add((0x01, [
      for (final c in RuleClass.all) ...[c, rule(c).policy.index, rule(c).ignore & 0xFF, 0],
    ]));
    final allowed = [
      for (final p in people.values)
        if (p.allowed.any((c) => !RuleClass.phoneOnly.contains(c)) && !muted.contains(p.key)) p
    ]
      ..sort((a, b) => b.seen.compareTo(a.seen));
    final listed = [
      for (final p in allowed) (p.key, p.name, _bits(p.allowed), 0),
      for (final k in muted) (k, people[k]?.name ?? '', _bits(people[k]?.allowed ?? const {}), 0x01),
    ].take(hostPeopleMax);
    sections.add((0x02, [
      for (final (key, name, bits, flags) in listed) ...[
        ..._unhex(key),
        flags,
        bits & 0xFF,
        bits >> 8,
        ..._name(name),
      ],
    ]));
    if (toys.isNotEmpty) {
      sections.add((0x03, [
        for (final e in toys.entries.take(16)) ...[
          ..._unhex(e.key),
          for (var o = 0; o < 4; o++) o < e.value.length && e.value[o] >= 0 ? e.value[o] : 0xFF,
        ],
      ]));
    }
    final cs = controls;
    if (cs != null) {
      sections.add((0x04, [
        cs.length,
        for (final c in cs) ...[..._utf8(c.label, 11, withLength: true), c.channels & 0x3F],
      ]));
    }
    return Uint8List.fromList([
      1,
      sections.length,
      for (final (id, body) in sections) ...[id, body.length & 0xFF, body.length >> 8, ...body],
    ]);
  }

  static int _bits(Set<int> classes) =>
      classes.fold(0, (b, c) => c >= 0 && c < 16 && !RuleClass.phoneOnly.contains(c) ? b | (1 << c) : b);

  static List<int> _name(String name) => _utf8(name, 15, withLength: true);

  /// [s] in UTF-8, cut to [max] bytes on a character's boundary.
  static List<int> _utf8(String s, int max, {bool withLength = false}) {
    var bytes = utf8.encode(s);
    if (bytes.length > max) {
      var n = max;
      while (n > 0 && (bytes[n] & 0xC0) == 0x80) {
        n--;
      }
      bytes = bytes.sublist(0, n);
    }
    return withLength ? [bytes.length, ...bytes] : bytes;
  }

  static List<int> _unhex(String hex) => [
        for (var i = 0; i + 1 < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16),
      ];

  /// As a host says it (FNV-1a, eight hex digits).
  static String hashOf(List<int> doc) {
    var h = 0x811C9DC5;
    for (final b in doc) {
      h = ((h ^ b) * 0x01000193) & 0xFFFFFFFF;
    }
    return h.toRadixString(16).padLeft(8, '0');
  }

  /// A host's rules (its GET /api/rules), taken on: all of them ([all], for
  /// an app that's never had any), or just what's been switched Off on it.
  /// Returns whether anything changed.
  bool takeOn(Map<String, dynamic> j, {required bool all}) {
    var changed = false;
    for (final c in j['classes'] as List<dynamic>? ?? const []) {
      final m = c as Map<String, dynamic>;
      final id = (m['id'] as num).toInt();
      final p = Policy.of((m['policy'] as num?)?.toInt() ?? 0);
      final ignore = (m['ignore'] as num?)?.toInt() ?? 0;
      final r = rule(id);
      if (all && (r.policy != p || r.ignore != ignore)) {
        r
          ..policy = p
          ..ignore = ignore;
        changed = true;
      } else if (!all && p == Policy.off && r.policy != Policy.off) {
        r.policy = Policy.off;
        changed = true;
      }
    }
    if (all) {
      for (final x in j['people'] as List<dynamic>? ?? const []) {
        final m = x as Map<String, dynamic>;
        final bits = (m['allowed'] as num?)?.toInt() ?? 0;
        final p = note(m['key'] as String, m['name'] as String? ?? '');
        p.allowed.addAll([for (var c = 0; c < 16; c++) if (bits & (1 << c) != 0) c]);
      }
      for (final x in j['toys'] as List<dynamic>? ?? const []) {
        final m = x as Map<String, dynamic>;
        toys[m['addr'] as String] = [for (final c in m['channels'] as List<dynamic>) (c as num).toInt()];
      }
      final cs = j['controls'] as List<dynamic>? ?? const [];
      controls = cs.isEmpty
          ? null
          : [
              for (final x in cs)
                ScreenControl((x as Map<String, dynamic>)['label'] as String? ?? '', (x['channels'] as num?)?.toInt() ?? 0)
            ];
      changed = true;
    }
    return changed;
  }

  // ----- Deciding, as a host does -----

  /// Whether a command for [cls] from [keyHex] is taken, as every host
  /// decides it: and if not, why. [everyone] is that it came to everyone
  /// who can hear them (or to the open direct channel), [channel] that it
  /// came to a whole channel.
  Decision decide(int cls, String keyHex,
      {required bool muted, required bool everyone, required bool channel}) {
    final r = rule(cls);
    if (muted) return Decision.muted;
    if (r.policy == Policy.off) return Decision.off;
    if (everyone && r.ignore & ignoreEveryone != 0) return Decision.ignoredEveryone;
    if (channel && !everyone && r.ignore & ignoreChannel != 0) return Decision.ignoredChannel;
    if (r.policy == Policy.anyone || (people[keyHex]?.allowed.contains(cls) ?? false)) return Decision.taken;
    return Decision.notAllowed;
  }
}

enum Decision { taken, muted, off, ignoredEveryone, ignoredChannel, notAllowed }
