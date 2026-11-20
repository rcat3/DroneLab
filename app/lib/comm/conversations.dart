import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'board_protocol.dart';

/// What a conversation is with: everyone who can hear us, a channel (on the
/// server or over direct comms), or one person.
enum ConversationKind { everyone, server, direct, person }

/// A line in a conversation: a text, or a command for a Terminal or Lovense
/// devices, ours or someone else's.
class ConversationEntry {
  static const text = 'text', terminal = 'terminal', lovense = 'lovense';
  static const photo = 'photo';     // body: the picture's file, in Conversations.photosPath

  final DateTime time;
  final String from;        // who sent it ('' for ours): their name, then
  String who;               // and who they are (KnownPerson.id), '' if not known
  final bool mine;
  final String kind;        // text, terminal or lovense
  final String body;        // the text, or what the command did, in words
  final bool done;          // a command: taken by the board it went to
  DateTime updated;         // a Lovense entry's last level, for running them together

  ConversationEntry(
      {required this.from,
      this.who = '',
      required this.mine,
      required this.kind,
      required this.body,
      this.done = true,
      DateTime? time})
      : time = time ?? DateTime.now(),
        updated = time ?? DateTime.now();

  Map<String, dynamic> toJson() =>
      {'t': time.millisecondsSinceEpoch, 'f': from, if (who.isNotEmpty) 'w': who, 'm': mine, 'k': kind, 'b': body, 'd': done};

  static ConversationEntry fromJson(Map<String, dynamic> j) => ConversationEntry(
        time: DateTime.fromMillisecondsSinceEpoch((j['t'] as num).toInt()),
        from: j['f'] as String? ?? '',
        who: j['w'] as String? ?? '',
        mine: j['m'] == true,
        kind: j['k'] as String? ?? text,
        body: j['b'] as String? ?? '',
        done: j['d'] != false,
      );
}

class Conversation {
  final String key;
  final ConversationKind kind;
  String title;
  final List<ConversationEntry> entries;
  int unread;
  Conversation(this.key, this.kind, this.title, [List<ConversationEntry>? entries, this.unread = 0])
      : entries = entries ?? [];

  DateTime? get last => entries.isEmpty ? null : entries.last.updated;

  Map<String, dynamic> toJson() => {
        'key': key,
        'kind': kind.name,
        'title': title,
        'unread': unread,
        'entries': [for (final e in entries) e.toJson()],
      };

  static Conversation? fromJson(Map<String, dynamic> j) {
    final kind = ConversationKind.values.where((k) => k.name == j['kind']);
    if (kind.isEmpty) return null;
    return Conversation(j['key'] as String, kind.first, j['title'] as String? ?? '', [
      for (final e in j['entries'] as List<dynamic>? ?? const []) ConversationEntry.fromJson(e as Map<String, dynamic>)
    ], (j['unread'] as num?)?.toInt() ?? 0);
  }

  /// Who it reaches, for "To ...": a person's name, or everyone in it.
  String get audience => switch (kind) {
        ConversationKind.person => title,
        ConversationKind.everyone => 'everyone who can hear you',
        _ => 'everyone in $title',
      };

  static String everyoneKey() => 'everyone';
  static String serverKey(String channel) => 'server:$channel';
  static String directKey(String groupId) => 'direct:$groupId';
  static String personKey(String name) => 'person:$name';
}

/// Every conversation, kept on the phone between starts.
class Conversations extends ChangeNotifier {
  static const _keep = 300;             // entries each
  static const _runTogether = Duration(seconds: 5);

  final Map<String, Conversation> all = {};

  /// The one on screen: what comes in for it isn't counted unread.
  String? open;

  /// Told when a conversation's read or deleted, to take its notification away.
  void Function(String key)? onSeen;

  Timer? _save;
  File? _file;

  /// Where photos sent and received are kept, a file each.
  String? photosPath;

  /// Keep a photo, returning its file's name for an entry's body.
  Future<String?> savePhoto(Uint8List bytes, String ext) async {
    final dir = photosPath;
    if (dir == null) return null;
    try {
      await Directory(dir).create(recursive: true);
      final name = '${DateTime.now().microsecondsSinceEpoch}.$ext';
      await File('$dir/$name').writeAsBytes(bytes);
      return name;
    } catch (_) {
      return null;
    }
  }

  File? photoFile(ConversationEntry e) =>
      e.kind == ConversationEntry.photo && photosPath != null ? File('$photosPath/${e.body}') : null;

  Future<void> load() async {
    try {
      final docs = (await getApplicationDocumentsDirectory()).path;
      photosPath = '$docs/photos';
      _file = File('$docs/conversations.json');
      if (!await _file!.exists()) return;
      final list = jsonDecode(await _file!.readAsString()) as List<dynamic>;
      for (final j in list) {
        final c = Conversation.fromJson(j as Map<String, dynamic>);
        if (c != null) all[c.key] = c;
      }
      notifyListeners();
    } catch (_) {
      // A damaged file: start afresh
    }
  }

  void _saveSoon() {
    _save?.cancel();
    _save = Timer(const Duration(seconds: 2), () async {
      try {
        await _file?.writeAsString(jsonEncode([for (final c in all.values) c.toJson()]));
      } catch (_) {}
    });
  }

  /// The conversation by its key, made if it's new; its title kept current.
  Conversation get(String key, ConversationKind kind, String title) {
    final c = all.putIfAbsent(key, () => Conversation(key, kind, title));
    if (title.isNotEmpty && c.title != title) c.title = title;
    return c;
  }

  void add(Conversation c, ConversationEntry e) {
    final prev = c.entries.isEmpty ? null : c.entries.last;
    // A run of Lovense levels from one person, as a slider's dragged, as one
    if (prev != null &&
        e.kind == ConversationEntry.lovense &&
        prev.kind == ConversationEntry.lovense &&
        prev.mine == e.mine &&
        prev.from == e.from &&
        prev.who == e.who &&
        e.time.difference(prev.updated) < _runTogether) {
      c.entries[c.entries.length - 1] = ConversationEntry(
          from: e.from, who: e.who, mine: e.mine, kind: e.kind, body: e.body, done: e.done, time: prev.time)
        ..updated = e.time;
    } else {
      c.entries.add(e);
      if (c.entries.length > _keep) photoFile(c.entries.removeAt(0))?.delete().catchError((_) => File(''));
      if (!e.mine && open != c.key) c.unread++;
    }
    notifyListeners();
    _saveSoon();
  }

  /// A conversation that's to be known by another key now, as when someone
  /// known by their certificate shows their identity: joined to any there
  /// is by that key already.
  void rekey(String oldKey, String newKey) {
    final old = all.remove(oldKey);
    if (old == null) return;
    final into = all[newKey];
    if (into == null) {
      all[newKey] = Conversation(newKey, old.kind, old.title, old.entries, old.unread);
    } else {
      into.entries
        ..addAll(old.entries)
        ..sort((a, b) => a.time.compareTo(b.time));
      if (into.entries.length > _keep) into.entries.removeRange(0, into.entries.length - _keep);
      into.unread += old.unread;
    }
    onSeen?.call(oldKey);
    notifyListeners();
    _saveSoon();
  }

  /// Someone's to be known by another id now: the lines they sent follow.
  void renameWho(String oldId, String newId) {
    var any = false;
    for (final c in all.values) {
      for (final e in c.entries) {
        if (e.who == oldId) {
          e.who = newId;
          any = true;
        }
      }
    }
    if (any) _saveSoon();
  }

  void markRead(Conversation c) {
    onSeen?.call(c.key);
    if (c.unread == 0) return;
    c.unread = 0;
    notifyListeners();
    _saveSoon();
  }

  void delete(Conversation c) {
    onSeen?.call(c.key);
    // Its photos go with it
    for (final e in c.entries) {
      photoFile(e)?.delete().catchError((_) => File(''));
    }
    all.remove(c.key);
    notifyListeners();
    _saveSoon();
  }

  int get unread => all.values.fold(0, (n, c) => n + c.unread);
}

/// What a command did, in words, for a conversation: [op] is the command
/// from what to do on, as the board passes it on. [mine] for ones we sent
/// ("their"), else for ones sent us ("your").
String describeCommand(Uint8List op, {required bool mine}) {
  if (op.isEmpty) return 'sent a command';
  final your = mine ? 'their' : 'your';
  String motor(int k) => switch (k) {
        OthersCommand.vibrate => 'vibrate',
        OthersCommand.rotate => 'rotate',
        OthersCommand.air => 'pump',
        OthersCommand.oscillate => 'thrust',
        _ => 'motors',
      };
  const reactions = ['nothing', 'voice', 'moving', 'stillness', 'motion', 'tilt'];
  switch (op[0]) {
    case OthersCommand.stop:
      return 'stopped $your toys';
    case OthersCommand.level:
      return op.length >= 3 ? 'set $your ${motor(op[1])} to ${op[2]}' : 'set $your toys';
    case OthersCommand.pattern:
      final name = utf8.decode(op.sublist(1), allowMalformed: true);
      return name.isEmpty ? 'stopped $your patterns' : 'played $name on $your toys';
    case OthersCommand.speed:
      return op.length >= 3 ? "set $your patterns' speed to ${op[1] | (op[2] << 8)}%" : 'set $your patterns';
    case OthersCommand.react:
      final r = op.length >= 2 && op[1] < reactions.length ? reactions[op[1]] : 'something';
      return op.length >= 2 && op[1] == 0 ? 'stopped $your toys reacting' : 'set $your toys to react to $r';
    case OthersCommand.message:
      final text = op.length > 3 ? utf8.decode(op.sublist(3), allowMalformed: true) : '';
      return 'put “$text” on $your display';
    case OthersCommand.clear:
      return 'cleared $your display';
    default:
      return 'sent a command';
  }
}
