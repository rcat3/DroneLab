/// Vibe patterns (core/app/patterns.h): the board's six built-in ones, and
/// custom ones, made here or sent us, each known by its hash.
///
/// A custom pattern has up to six rows: played on some channels, its first
/// row drives the first of them (the lowest), its second the next, and so
/// on. Each row is a block of steps (levels 0 to 20), each lasting the
/// block's step length, repeating at its own length. It goes to others'
/// boards in parts (OthersCommand.patternParts), with the command that
/// plays it after.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'app_profile.dart';

/// The board's built-in patterns, as it names them.
const builtInPatterns = ['Wave', 'Pulse', 'Heartbeat', 'Climb', 'Surge', 'Wander'];

/// How hard a built-in pattern runs, 0 to 1, [s] seconds in, on a row: as
/// patterns.c works it out, for pictures and previews.
double builtInLevel(String name, int row, double s) {
  double wrap(double x, double p) => x - p * (x / p).floorToDouble();
  double offset(double p) => row.isOdd ? p / 2 : 0;
  switch (name) {
    case 'Pulse':
      return wrap(s + offset(0.8), 0.8) < 0.4 ? 1 : 0;
    case 'Wave':
      return 0.5 - 0.5 * math.cos(2 * math.pi * wrap(s + offset(4), 4) / 4);
    case 'Heartbeat':
      final p = wrap(s, 1.1);
      var beat = math.exp(-p * 18);
      if (p > 0.25) beat += 0.7 * math.exp(-(p - 0.25) * 18);
      return math.min(1, beat);
    case 'Climb':
      return wrap(s, 8) / 8;
    case 'Surge':
      final p = wrap(s, 23);
      if (p > 20) return 0;
      return (0.25 + 0.75 * p / 20) * (0.55 + 0.45 * math.sin(2 * math.pi * (p + offset(1.5)) / 1.5));
    case 'Wander':
      double noise(int n) {
        var h = (n * 2654435761 + row * 40503) & 0xFFFFFFFF;
        h ^= h >> 15;
        h = (h * 2246822519) & 0xFFFFFFFF;
        h ^= h >> 13;
        return (h & 0xFFFF) / 65535;
      }
      final x = s * 3;
      final n = x.floor();
      var f = x - n;
      f = f * f * (3 - 2 * f);
      return noise(n) + (noise(n + 1) - noise(n)) * f;
  }
  return 0;
}

/// How long a built-in pattern takes to repeat, in ms, for pictures.
int builtInLengthMs(String name) => switch (name) {
      'Pulse' => 800,
      'Wave' => 4000,
      'Heartbeat' => 1100,
      'Climb' => 8000,
      'Surge' => 23000,
      _ => 10000,
    };

/// A block of a pattern: steps, each [stepMs] long, on the rows in [rows]
/// (a bit for each, row 1 the lowest; 0 for all of them).
class PatternBlock {
  int stepMs;
  int rows;
  List<int> levels;
  PatternBlock(this.stepMs, this.rows, this.levels);

  PatternBlock copy() => PatternBlock(stepMs, rows, List.of(levels));

  int get lengthMs => stepMs * levels.length;
}

class VibePattern {
  static const format = 1;
  static const top = 20;              // a step's highest level
  static const rowsMax = 6;
  static const nameMax = 24;          // bytes of UTF-8 (PATTERNS_NAME_MAX)
  static const minStepMs = 100, maxStepMs = 60000;
  static const partMax = 106;         // PATTERNS_PART_MAX
  static const partsMax = 6;
  static const sizeMax = partMax * partsMax;
  static const hashLength = 8;

  String name;
  List<PatternBlock> blocks;
  VibePattern(this.name, this.blocks);

  VibePattern copy({String? name}) => VibePattern(name ?? this.name, [for (final b in blocks) b.copy()]);

  /// The name, cut to fit, without cutting a character in two.
  static List<int> nameBytes(String name) {
    final b = utf8.encode(name.trim().isEmpty ? 'Pattern' : name.trim());
    if (b.length <= nameMax) return b;
    var n = nameMax;
    while (n > 0 && (b[n] & 0xC0) == 0x80) {
      n--;
    }
    return b.sublist(0, n);
  }

  /// Its definition, as it's sent (patterns.h).
  Uint8List encode() {
    final name = nameBytes(this.name);
    final out = <int>[format, name.length, ...name, blocks.length];
    for (final b in blocks) {
      final ms = b.stepMs.clamp(minStepMs, maxStepMs);
      out.addAll([ms & 0xFF, ms >> 8, b.rows & 0x3F, b.levels.length & 0xFF, b.levels.length >> 8]);
      var bits = 0, have = 0;
      for (final v in b.levels) {
        bits |= v.clamp(0, top) << have;
        have += 5;
        while (have >= 8) {
          out.add(bits & 0xFF);
          bits >>= 8;
          have -= 8;
        }
      }
      if (have > 0) out.add(bits & 0xFF);
    }
    return Uint8List.fromList(out);
  }

  /// One from its definition; null if it's no good.
  static VibePattern? decode(List<int> d) {
    if (d.length < 3 || d[0] != format || d[1] == 0 || d[1] > nameMax) return null;
    var at = 2 + d[1];
    if (at >= d.length) return null;
    final name = utf8.decode(d.sublist(2, at), allowMalformed: true);
    final count = d[at++];
    if (count == 0 || count > rowsMax) return null;
    final blocks = <PatternBlock>[];
    for (var i = 0; i < count; i++) {
      if (at + 5 > d.length) return null;
      final ms = d[at] | (d[at + 1] << 8), rows = d[at + 2], n = d[at + 3] | (d[at + 4] << 8);
      at += 5;
      final bytes = (5 * n + 7) ~/ 8;
      if (n == 0 || at + bytes > d.length) return null;
      final levels = <int>[];
      var bits = 0, have = 0;
      for (var s = 0; s < n; s++) {
        while (have < 5) {
          bits |= d[at++] << have;
          have += 8;
        }
        levels.add(math.min(top, bits & 0x1F));
        bits >>= 5;
        have -= 5;
      }
      blocks.add(PatternBlock(ms.clamp(minStepMs, maxStepMs), rows, levels));
    }
    if (at != d.length) return null;
    return VibePattern(name, blocks);
  }

  static Uint8List hashOf(List<int> definition) =>
      Uint8List.fromList(sha256.convert(definition).bytes.sublist(0, hashLength));

  Uint8List get hash => hashOf(encode());
  String get hashHex => hex(hash);
  static String hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  /// Its definition's size, in bytes, against [sizeMax].
  int get size => encode().length;
  bool get fits => size <= sizeMax;

  /// How many rows it drives: the highest one any block names, or 1.
  int get rowCount {
    var n = 1;
    for (final b in blocks) {
      for (var r = 0; r < rowsMax; r++) {
        if (b.rows & (1 << r) != 0) n = math.max(n, r + 1);
      }
    }
    return n;
  }

  /// The block that drives a row: the last one that does, as the board has it.
  PatternBlock? blockFor(int row) {
    PatternBlock? found;
    for (final b in blocks) {
      if (b.rows == 0 || b.rows & (1 << row) != 0) found = b;
    }
    return found;
  }

  /// How hard a row runs, 0 to 1, [ms] in; null where nothing drives it.
  double? level(int row, int ms) {
    final b = blockFor(row);
    if (b == null || b.levels.isEmpty) return null;
    return b.levels[(ms ~/ b.stepMs) % b.levels.length] / top;
  }

  /// How long until it all repeats: the longest block's length.
  int get lengthMs => blocks.fold(0, (m, b) => math.max(m, b.lengthMs));

  /// Whether every block's steps are the same length, and they're all as long.
  bool get sharedTiming =>
      blocks.every((b) => b.stepMs == blocks.first.stepMs && b.levels.length == blocks.first.levels.length);

  // ----- Lovense's text format -----

  /// From Lovense's pattern format, e.g. "V:1;F:v,r;S:100#5,10;6,11;...":
  /// one or more headers, each up to '#', then that part's steps, ';'
  /// between, with a level for each of F's motors in each step, ',' between.
  /// F's motors with a number (v2) drive that row; without, the motors take
  /// rows in turn. Levels are 0 to 20. Null if there's nothing in it.
  static VibePattern? fromLovense(String text, {String name = 'Imported'}) {
    final blocks = <PatternBlock>[];
    final parts = RegExp(r'([Vv]:[^#]*)#([^Vv]*)').allMatches(text);
    for (final m in parts) {
      var stepMs = 100;
      var motors = <int>[];      // each motor's row, or -1 for the next
      for (final field in m.group(1)!.split(';')) {
        if (field.length < 2 || field[1] != ':') continue;
        final value = field.substring(2).trim();
        switch (field[0].toUpperCase()) {
          case 'S':
            stepMs = (int.tryParse(value) ?? 100).clamp(minStepMs, maxStepMs);
          case 'F':
            motors = [
              for (final f in value.split(','))
                if (f.trim().isNotEmpty) (int.tryParse(f.trim().substring(1)) ?? 0) - 1,
            ];
        }
      }
      if (motors.isEmpty) motors = [-1];
      final steps = m.group(2)!.split(';').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
      final columns = List.generate(motors.length, (_) => <int>[]);
      for (final s in steps) {
        final values = s.split(',').map((v) => int.tryParse(v.trim()) ?? 0).toList();
        for (var i = 0; i < motors.length; i++) {
          columns[i].add((i < values.length ? values[i] : values.first).clamp(0, top));
        }
      }
      if (steps.isEmpty) continue;
      var next = blocks.fold(0, (n, b) => math.max(n, _highestRow(b.rows) + 1));
      for (var i = 0; i < motors.length && blocks.length < rowsMax; i++) {
        final row = motors[i] >= 0 && motors[i] < rowsMax ? motors[i] : (motors.length == 1 && motors[i] < 0 ? -1 : next++);
        blocks.add(PatternBlock(stepMs, row < 0 ? 0 : 1 << math.min(row, rowsMax - 1), columns[i]));
      }
    }
    if (blocks.isEmpty) return null;
    return VibePattern(name, blocks);
  }

  static int _highestRow(int rows) {
    var h = -1;
    for (var r = 0; r < rowsMax; r++) {
      if (rows & (1 << r) != 0) h = r;
    }
    return h;
  }

  /// In Lovense's format: with shared timing, one part with a level for
  /// each row in each step; otherwise a part for each block.
  String toLovense() {
    final rows = rowCount;
    if (sharedTiming && blocks.isNotEmpty && rows > 1) {
      final f = [for (var r = 0; r < rows; r++) 'v${r + 1}'].join(',');
      final n = blocks.first.levels.length;
      final steps = [
        for (var s = 0; s < n; s++) [for (var r = 0; r < rows; r++) blockFor(r)?.levels[s] ?? 0].join(','),
      ];
      return 'V:1;F:$f;S:${blocks.first.stepMs}#${steps.join(';')};';
    }
    final out = StringBuffer();
    for (final b in blocks) {
      final f = b.rows == 0 ? 'v' : [for (var r = 0; r < rowsMax; r++) if (b.rows & (1 << r) != 0) 'v${r + 1}'].join(',');
      out.write('V:1;F:$f;S:${b.stepMs}#${b.levels.join(';')};');
      if (blocks.length > 1) out.write('\n');
    }
    return out.toString();
  }
}

/// A pattern in the library.
class PatternEntry {
  static const mine = 'mine', received = 'received';
  final VibePattern pattern;
  final String kind;
  final String from;          // who sent it, for one received
  bool favourite;
  final int added;            // ms since the epoch
  PatternEntry(this.pattern, this.kind, {this.from = '', this.favourite = false, int? added})
      : added = added ?? DateTime.now().millisecondsSinceEpoch;

  late final String hash = pattern.hashHex;

  Map<String, dynamic> toJson() => {
        'def': base64.encode(pattern.encode()),
        'kind': kind,
        if (from.isNotEmpty) 'from': from,
        if (favourite) 'fav': true,
        'added': added,
      };

  static PatternEntry? fromJson(Map<String, dynamic> j) {
    final p = VibePattern.decode(base64.decode(j['def'] as String? ?? ''));
    if (p == null) return null;
    return PatternEntry(p, j['kind'] as String? ?? mine,
        from: j['from'] as String? ?? '', favourite: j['fav'] as bool? ?? false, added: j['added'] as int?);
  }
}

/// The patterns kept on the phone: the wearer's own, and those others have
/// sent (played on their toys, or shared in a message), each by its hash.
class PatternLibrary extends ChangeNotifier {
  static const _receivedKept = 50;
  static const _assemblyFor = Duration(seconds: 90);

  /// The one library, for describing commands by a pattern's name.
  static PatternLibrary? instance;

  final List<PatternEntry> entries = [];
  File? _file;
  Timer? _save;

  PatternLibrary() {
    instance = this;
  }

  Iterable<PatternEntry> get mine => entries.where((e) => e.kind == PatternEntry.mine);
  Iterable<PatternEntry> get received => entries.where((e) => e.kind == PatternEntry.received);
  Iterable<PatternEntry> get favourites => entries.where((e) => e.favourite);

  PatternEntry? byHash(String hashHex) {
    for (final e in entries) {
      if (e.hash == hashHex) return e;
    }
    return null;
  }

  Future<void> load() async {
    try {
      _file = File('${(await AppProfile.files()).path}/patterns.json');
      if (!await _file!.exists()) return;
      final list = jsonDecode(await _file!.readAsString()) as List<dynamic>;
      for (final j in list) {
        final e = PatternEntry.fromJson(j as Map<String, dynamic>);
        if (e != null && byHash(e.hash) == null) entries.add(e);
      }
      notifyListeners();
    } catch (_) {
      // A damaged file: start afresh
    }
  }

  void _changed() {
    notifyListeners();
    _save?.cancel();
    _save = Timer(const Duration(seconds: 1), () async {
      final file = _file;
      if (file == null) return;
      try {
        final tmp = File('${file.path}.new');
        await tmp.writeAsString(jsonEncode([for (final e in entries) e.toJson()]));
        await tmp.rename(file.path);
      } catch (e) {
        debugPrint('patterns: $e');
      }
    });
  }

  /// Keep one of ours, in place of [replacing] (an entry's hash) if given.
  PatternEntry saveMine(VibePattern p, {String? replacing}) {
    final at = replacing == null ? -1 : entries.indexWhere((e) => e.hash == replacing);
    final old = at >= 0 ? entries[at] : null;
    final e = PatternEntry(p.copy(), PatternEntry.mine, favourite: old?.favourite ?? false);
    final same = byHash(e.hash);
    if (same != null && same != old) entries.remove(same);
    if (at >= 0) {
      entries[entries.indexOf(old!)] = e;
    } else {
      entries.add(e);
    }
    _changed();
    return e;
  }

  /// Keep one someone sent, unless we have it already.
  PatternEntry? keepReceived(VibePattern p, String from) {
    final hash = p.hashHex;
    final had = byHash(hash);
    if (had != null) return had;
    final e = PatternEntry(p, PatternEntry.received, from: from);
    entries.add(e);
    // The oldest received go, but favourites stay
    final old = received.where((r) => !r.favourite).toList()..sort((a, b) => a.added.compareTo(b.added));
    for (var i = 0; i < old.length - _receivedKept; i++) {
      entries.remove(old[i]);
    }
    _changed();
    return e;
  }

  void remove(PatternEntry e) {
    entries.remove(e);
    _changed();
  }

  void setFavourite(PatternEntry e, bool on) {
    e.favourite = on;
    _changed();
  }

  // ----- Parts heard -----

  final Map<String, (DateTime, int, Map<int, Uint8List>)> _assembling = {};

  /// A part of a pattern someone's playing on our toys (OthersCommand
  /// .vibePart, from its hash on): kept once all of it's here and it comes
  /// to its hash.
  void heardPart(Uint8List part, String from) {
    if (part.length < VibePattern.hashLength + 3) return;
    final hash = VibePattern.hex(part.sublist(0, VibePattern.hashLength));
    if (byHash(hash) != null) return;
    final index = part[VibePattern.hashLength], count = part[VibePattern.hashLength + 1];
    if (count == 0 || count > VibePattern.partsMax || index >= count) return;
    final now = DateTime.now();
    _assembling.removeWhere((_, v) => now.difference(v.$1) > _assemblyFor);
    final a = _assembling.putIfAbsent(hash, () => (now, count, <int, Uint8List>{}));
    if (a.$2 != count) return;
    a.$3[index] = Uint8List.fromList(part.sublist(VibePattern.hashLength + 2));
    if (a.$3.length < count) return;
    _assembling.remove(hash);
    final def = [for (var i = 0; i < count; i++) ...a.$3[i]!];
    if (VibePattern.hex(VibePattern.hashOf(def)) != hash) return;
    final p = VibePattern.decode(def);
    if (p != null) keepReceived(p, from);
  }

  /// A pattern's name by its hash, for saying what a command did.
  static String? nameOf(List<int> hash) => instance?.byHash(VibePattern.hex(hash))?.pattern.name;
}
