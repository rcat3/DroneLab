/// The Guide's words for a HiveSight session: phrase lists and their timing.
///
/// The Guide page does the timing: a cue is three settings sent in order
/// (words.fade_s, words.text, then words.seq, which counts up on every cue
/// so the same phrase can be cued again); the Vessel fades what's showing
/// out and the new phrase in over that cue's fade. The lists are kept on
/// this computer.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One phrase, and how long it takes to fade in and out.
class WordsPhrase {
  String text;
  double fadeS;
  WordsPhrase(this.text, [this.fadeS = 1.0]);

  Map<String, Object?> toJson() => {'text': text, 'fade': fadeS};
  factory WordsPhrase.fromJson(Map<String, dynamic> j) =>
      WordsPhrase(j['text'] as String? ?? '', (j['fade'] as num?)?.toDouble() ?? 1.0);
}

class WordsList {
  String name;
  final List<WordsPhrase> phrases;
  WordsList(this.name, [List<WordsPhrase>? phrases]) : phrases = phrases ?? [];

  Map<String, Object?> toJson() => {
    'name': name,
    'phrases': [for (final p in phrases) p.toJson()],
  };
  factory WordsList.fromJson(Map<String, dynamic> j) => WordsList(j['name'] as String? ?? 'List', [
    for (final p in j['phrases'] as List<dynamic>? ?? const []) WordsPhrase.fromJson(p as Map<String, dynamic>),
  ]);
}

/// A phrase's longest length, as the sender keeps it.
const wordsMaxLength = 600;

/// How long a phrase stays, the slider's stops: seconds, 0 for until the
/// Guide moves on.
const wordsHolds = [5, 10, 15, 30, 60, 120, 300, 0];

String wordsHoldLabel(int seconds) => seconds == 0
    ? 'Until I move on'
    : seconds < 60
    ? '$seconds s'
    : '${seconds ~/ 60} min';

class GuideWords extends ChangeNotifier {
  /// Sends the settings of one cue, in order, none of them held back.
  final void Function(List<(String, Object)>) _send;
  final bool Function() _linked;
  GuideWords(this._send, this._linked);

  List<WordsList> lists = [];
  int listIndex = 0;

  /// The phrase on screen (or last cued), or -1.
  int current = -1;
  int hold = 3; // an index into [wordsHolds]
  bool auto = false; // go on to the next phrase when the time's up
  bool loop = true; // and from the last back to the first
  int _seq = 0;
  Timer? _timer;
  DateTime? cuedAt;

  WordsList? get list => lists.isEmpty ? null : lists[listIndex.clamp(0, lists.length - 1)];
  int get holdSeconds => wordsHolds[hold];

  // ----- Saved -----

  SharedPreferences? _prefs;

  Future<void> load() async {
    if (_prefs != null) return;
    _prefs = await SharedPreferences.getInstance();
    try {
      final j = jsonDecode(_prefs!.getString('hiveSightWords') ?? '{}') as Map<String, dynamic>;
      lists = [for (final l in j['lists'] as List<dynamic>? ?? const []) WordsList.fromJson(l as Map<String, dynamic>)];
      listIndex = (j['list'] as int? ?? 0).clamp(0, lists.isEmpty ? 0 : lists.length - 1);
      hold = (j['hold'] as int? ?? 3).clamp(0, wordsHolds.length - 1);
      auto = j['auto'] == true;
      loop = j['loop'] != false;
    } catch (_) {}
    if (lists.isEmpty) lists = [WordsList('Words')];
    notifyListeners();
  }

  void _save() {
    _prefs?.setString(
      'hiveSightWords',
      jsonEncode({
        'lists': [for (final l in lists) l.toJson()],
        'list': listIndex,
        'hold': hold,
        'auto': auto,
        'loop': loop,
      }),
    );
  }

  void _changed() {
    _save();
    notifyListeners();
  }

  // ----- Lists and phrases -----

  void selectList(int i) {
    listIndex = i.clamp(0, lists.length - 1);
    _stopTimer();
    current = -1;
    _changed();
  }

  void addList(String name) {
    lists.add(WordsList(name.trim().isEmpty ? 'Words' : name.trim()));
    selectList(lists.length - 1);
  }

  void renameList(String name) {
    if (name.trim().isEmpty) return;
    list?.name = name.trim();
    _changed();
  }

  void deleteList() {
    if (lists.length <= 1) {
      lists = [WordsList('Words')];
    } else {
      lists.removeAt(listIndex);
    }
    selectList(0);
  }

  void addPhrase(String text, double fadeS) {
    final t = text.trim();
    if (t.isEmpty) return;
    list?.phrases.add(WordsPhrase(t.length > wordsMaxLength ? t.substring(0, wordsMaxLength) : t, fadeS));
    _changed();
  }

  void editPhrase(int i, String text, double fadeS) {
    final p = list?.phrases[i];
    if (p == null || text.trim().isEmpty) return;
    p.text = text.trim().length > wordsMaxLength ? text.trim().substring(0, wordsMaxLength) : text.trim();
    p.fadeS = fadeS;
    _changed();
  }

  void removePhrase(int i) {
    final l = list;
    if (l == null) return;
    l.phrases.removeAt(i);
    if (current == i) {
      current = -1;
      _stopTimer();
    } else if (current > i) {
      current--;
    }
    _changed();
  }

  void movePhrase(int i, int by) {
    final l = list;
    if (l == null) return;
    final j = i + by;
    if (j < 0 || j >= l.phrases.length) return;
    l.phrases.insert(j, l.phrases.removeAt(i));
    if (current == i) {
      current = j;
    } else if (current == j) {
      current = i;
    }
    _changed();
  }

  void setHold(int i) {
    hold = i.clamp(0, wordsHolds.length - 1);
    if (current >= 0 && cuedAt != null) _arm(); // from now
    _changed();
  }

  void setAuto(bool on) {
    auto = on;
    _changed();
  }

  void setLoop(bool on) {
    loop = on;
    _changed();
  }

  // ----- Cues -----

  void _cue(String text, double fadeS) {
    _seq = (_seq + 1) & 0x3fffffff;
    _send([('words.fade_s', fadeS), ('words.text', text), ('words.seq', _seq)]);
    cuedAt = DateTime.now();
  }

  /// Shows phrase [i] of the list, and times it.
  void cue(int i) {
    final l = list;
    if (l == null || i < 0 || i >= l.phrases.length || !_linked()) return;
    current = i;
    _cue(l.phrases[i].text, l.phrases[i].fadeS);
    _arm();
    notifyListeners();
  }

  /// Shows [text] once, outside the list, with [fadeS], and times it.
  void show(String text, double fadeS) {
    final t = text.trim();
    if (t.isEmpty || !_linked()) return;
    current = -1;
    _cue(t.length > wordsMaxLength ? t.substring(0, wordsMaxLength) : t, fadeS);
    _arm();
    notifyListeners();
  }

  void next() {
    final l = list;
    if (l == null || l.phrases.isEmpty) return;
    final n = current + 1;
    if (n < l.phrases.length) {
      cue(n);
    } else if (loop) {
      cue(0);
    } else {
      clear();
    }
  }

  void previous() {
    final l = list;
    if (l == null || l.phrases.isEmpty) return;
    cue(current <= 0 ? (loop ? l.phrases.length - 1 : 0) : current - 1);
  }

  /// Fades what's showing out (over the last phrase's fade).
  void clear() {
    _stopTimer();
    final l = list;
    final fade = current >= 0 && l != null && current < l.phrases.length ? l.phrases[current].fadeS : 1.0;
    if (_linked()) _cue('', fade);
    cuedAt = null;
    notifyListeners();
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  void _arm() {
    _stopTimer();
    final s = holdSeconds;
    if (s == 0) return;
    _timer = Timer(Duration(seconds: s), () {
      _timer = null;
      if (!_linked()) return;
      if (auto && current >= 0) {
        next();
      } else {
        clear();
      }
    });
  }

  /// The link's gone: nothing more to time.
  void stopTiming() {
    _stopTimer();
    cuedAt = null;
    current = -1;
    notifyListeners();
  }

  @override
  void dispose() {
    _stopTimer();
    super.dispose();
  }
}
