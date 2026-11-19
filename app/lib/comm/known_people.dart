/// Everyone we've come across, known by who they are rather than what they
/// call themselves: by their identity key (identity.dart), once they've
/// shown it; until then by their Mumble certificate, which the server
/// vouches for; and only by name where there's nothing else (direct comms,
/// for now, and Mumble clients without a certificate). Names are labels,
/// kept up to date, and a name that turns up on someone new is a warning
/// ([KnownPeople.clashes]). Their mute is kept here too.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'identity.dart';

class KnownPerson {
  /// `k:` and their key's id for those with a key, `c:` and its hash for
  /// those with only a certificate, `n:` and their name for those with
  /// neither.
  final String id;
  final Uint8List? key;
  final Set<String> certs;        // their certificates' hashes
  String name;
  bool muted;
  final int firstSeen;            // ms since the epoch: who had a name first

  KnownPerson(this.id, this.name, {this.key, Set<String>? certs, this.muted = false, int? firstSeen})
      : certs = certs ?? {},
        firstSeen = firstSeen ?? DateTime.now().millisecondsSinceEpoch;

  /// Known by something better than a name.
  bool get identified => !id.startsWith('n:');

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (key != null) 'key': base64.encode(key!),
        if (certs.isNotEmpty) 'certs': certs.toList(),
        if (muted) 'muted': true,
        'first': firstSeen,
      };

  static KnownPerson fromJson(Map<String, dynamic> j) => KnownPerson(
        j['id'] as String,
        j['name'] as String? ?? '',
        key: j['key'] == null ? null : base64.decode(j['key'] as String),
        certs: {for (final c in j['certs'] as List<dynamic>? ?? const []) c as String},
        muted: j['muted'] == true,
        firstSeen: (j['first'] as num?)?.toInt(),
      );

  static String keyId(List<int> key) => 'k:${Identity.idOf(key)}';
  static String certId(String hash) => 'c:$hash';
  static String nameId(String name) => 'n:$name';
}

class KnownPeople {
  static const _keep = 300;

  final Map<String, KnownPerson> _all = {};
  final Map<String, String> _byCert = {};

  /// To keep them: called, a little after they change, with what to store.
  final void Function(String json) save;

  /// When someone known by their certificate shows their key, and so gets a
  /// new id: for their conversation to follow them.
  void Function(String oldId, String newId)? onRenamed;

  KnownPeople(this.save);

  void load(String? json) {
    if (json == null) return;
    try {
      for (final j in jsonDecode(json) as List<dynamic>) {
        _put(KnownPerson.fromJson(j as Map<String, dynamic>));
      }
    } catch (_) {
      // damaged: start afresh
    }
  }

  void _put(KnownPerson p) {
    _all[p.id] = p;
    for (final c in p.certs) {
      _byCert[c] = p.id;
    }
  }

  Iterable<KnownPerson> get all => _all.values;
  KnownPerson? operator [](String id) => _all[id];

  /// Someone on the server, by their certificate (or their name, without
  /// one), made if they're new; their name kept up to date.
  KnownPerson onServer(String? certHash, String name) {
    if (certHash == null) return named(name);
    final id = _byCert[certHash];
    final known = id == null ? null : _all[id];
    if (known != null) return _label(known, name);
    final p = KnownPerson(KnownPerson.certId(certHash), name, certs: {certHash});
    _put(p);
    _changed();
    return p;
  }

  /// Someone by their key, as a signed command or a board's checked hello
  /// gives it, made if they're new; their name kept up to date.
  KnownPerson byKey(Uint8List key, String name) {
    final id = KnownPerson.keyId(key);
    final known = _all[id];
    if (known != null) return _label(known, name);
    final p = KnownPerson(id, name, key: Uint8List.fromList(key));
    _put(p);
    _changed();
    return p;
  }

  /// Someone known only by name.
  KnownPerson named(String name) {
    final id = KnownPerson.nameId(name);
    final known = _all[id];
    if (known != null) return known;
    final p = KnownPerson(id, name);
    _put(p);
    _changed();
    return p;
  }

  /// Someone's shown their key, signed for their certificate: from now on
  /// they're known by it, whatever they were known by before.
  KnownPerson bind(Uint8List key, String certHash, String name) {
    final id = KnownPerson.keyId(key);
    final oldId = _byCert[certHash];
    var p = _all[id];
    if (p == null) {
      // As long known as they were by their certificate
      p = KnownPerson(id, name, key: key, firstSeen: oldId == null ? null : _all[oldId]?.firstSeen);
      _put(p);
    }
    if (oldId != null && oldId != id) {
      final old = _all.remove(oldId);
      if (old != null) {
        p.muted |= old.muted;
        p.certs.addAll(old.certs);
        for (final c in old.certs) {
          _byCert[c] = id;
        }
        onRenamed?.call(oldId, id);
      }
    }
    p.certs.add(certHash);
    _byCert[certHash] = id;
    _label(p, name);
    _changed();
    return p;
  }

  KnownPerson _label(KnownPerson p, String name) {
    if (name.isNotEmpty && p.name != name) {
      p.name = name;
      _changed();
    }
    return p;
  }

  /// [newId] is who [oldId] was, as when someone's reinstalled the app
  /// without their backup code and has a new identity: it takes the old
  /// one's place (as long known, muted if it was), and the old one's
  /// forgotten, so the name's theirs again.
  void replace(String oldId, String newId) {
    final old = _all[oldId], p = _all[newId];
    if (old == null || p == null || oldId == newId) return;
    _all.remove(oldId);
    old.certs.forEach(_byCert.remove);
    _all[newId] = KnownPerson(p.id, p.name,
        key: p.key, certs: p.certs, muted: p.muted || old.muted, firstSeen: min(p.firstSeen, old.firstSeen));
    onRenamed?.call(oldId, newId);
    _changed();
  }

  void setMuted(String id, bool muted) {
    final p = _all[id];
    if (p == null || p.muted == muted) return;
    p.muted = muted;
    _changed();
  }

  Iterable<KnownPerson> get muted => _all.values.where((p) => p.muted);

  /// The one who had this name before [p]: someone else, so [p] may be
  /// using it to pass as them. Only between those known by more than a
  /// name, as a name's all there is to go on for the rest.
  KnownPerson? clashes(KnownPerson p) {
    if (!p.identified) return null;
    final name = p.name.toLowerCase();
    KnownPerson? first;
    for (final q in _all.values) {
      if (q.id != p.id && q.identified && q.name.toLowerCase() == name && q.firstSeen < p.firstSeen) {
        if (first == null || q.firstSeen < first.firstSeen) first = q;
      }
    }
    return first;
  }

  Timer? _saveTimer;

  void _changed() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 1), () {
      // Too many: the oldest who aren't muted go
      if (_all.length > _keep) {
        final drop = _all.values.where((p) => !p.muted).toList()..sort((a, b) => a.firstSeen.compareTo(b.firstSeen));
        for (final p in drop.take(_all.length - _keep)) {
          _all.remove(p.id);
          p.certs.forEach(_byCert.remove);
        }
      }
      save(jsonEncode([for (final p in _all.values) p.toJson()]));
    });
  }
}
