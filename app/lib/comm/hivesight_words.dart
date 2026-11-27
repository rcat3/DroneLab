/// The Guide's words for a HiveSight session: phrase lists, how each phrase
/// looks and moves, and their timing.
///
/// A cue is a `words` message for one of eight layers on the Vessel's view
/// (the sender relays it as it is); the Vessel fades what's on that layer
/// out and the new phrase in over the cue's fade. The Guide page does the
/// timing, so a phrase's time on screen ends with a `words_clear` for its
/// layer. The lists are kept on this computer.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A phrase's longest length, as the sender and the Vessel keep it.
const wordsMaxLength = 600;

/// Phrases on screen at once.
const wordsLayers = 8;

/// How long a phrase stays, the slider's stops: seconds, 0 for until the
/// Guide moves on.
const wordsHolds = [5, 10, 15, 30, 60, 120, 300, 0];

String wordsHoldLabel(int seconds) => seconds == 0
    ? 'Until I move on'
    : seconds < 60
    ? '$seconds s'
    : '${seconds ~/ 60} min';

const wordsFonts = [
  ('sans', 'Sans'),
  ('serif', 'Serif'),
  ('mono', 'Monospace'),
  ('condensed', 'Condensed'),
  ('cursive', 'Cursive'),
  ('casual', 'Casual'),
];

const wordsModes = [
  ('still', 'Still'),
  ('breathe', 'Breathe'),
  ('drift', 'Drift'),
  ('pulse', 'Pulse with the beat'),
  ('spiral', 'Follow the spiral'),
  ('orbit', 'Orbit'),
  ('approach', 'Come and go'),
  ('tumble', 'Tumble'),
  ('sway', 'Sway'),
];

const wordsDistortions = [
  ('none', 'None'),
  ('wave', 'Wave'),
  ('ripple', 'Ripple'),
  ('wobble', 'Wobble'),
  ('glitch', 'Glitch'),
];

/// How a phrase looks and moves.
class WordsLook {
  String font = 'sans';
  bool bold = false, italic = false, underline = false, outline = false;
  int color = 0xFFFFFF; // RGB
  double size = 0.12, opacity = 1.0, fade = 1.0;
  String mode = 'still';
  double speed = 0.5;
  double depth = 0.0; // 0 as far as the lenses go, 1 nearest
  double x = 0, y = 0; // -1..1
  double yaw = 0, pitch = 0, roll = 0; // degrees
  String distort = 'none';
  double distAmount = 0.5, distFreq = 0.5, distSpeed = 1.0;
  bool crt = false, cursor = false;

  /// Types itself out letter by letter, [typeSpeed] letters a second to begin with.
  bool typing = false;
  double typeSpeed = 25;

  WordsLook();

  WordsLook copy() => WordsLook.fromJson(toJson());

  /// The DroneLab terminal: green on black like the board's screen, in a
  /// monospace font with a glow, scanlines and a blinking cursor.
  void terminal() {
    font = 'mono';
    bold = false;
    italic = false;
    underline = false;
    outline = false;
    color = 0x33FF33;
    size = 0.07;
    crt = true;
    cursor = true;
    typing = true;
  }

  void plain() {
    font = 'sans';
    bold = false;
    italic = false;
    underline = false;
    outline = false;
    color = 0xFFFFFF;
    size = 0.12;
    opacity = 1.0;
    crt = false;
    cursor = false;
    typing = false;
  }

  void whisper() {
    plain();
    size = 0.05;
    opacity = 0.55;
    fade = 3.0;
    mode = 'breathe';
    speed = 0.3;
  }

  void shout() {
    plain();
    bold = true;
    font = 'condensed';
    size = 0.25;
    mode = 'pulse';
    distort = 'wobble';
    distAmount = 0.3;
  }

  /// A named effect's usual settings.
  void setDistortion(String kind) {
    distort = kind;
    switch (kind) {
      case 'wave':
        distAmount = 0.5;
        distFreq = 0.5;
        distSpeed = 1.0;
      case 'ripple':
        distAmount = 0.5;
        distFreq = 0.4;
        distSpeed = 1.0;
      case 'wobble':
        distAmount = 0.5;
        distFreq = 0.3;
        distSpeed = 0.7;
      case 'glitch':
        distAmount = 0.6;
        distFreq = 0.5;
        distSpeed = 1.5;
    }
  }

  String get hex => color.toRadixString(16).padLeft(6, '0');

  Map<String, Object?> toJson() => {
    'font': font,
    'bold': bold,
    'italic': italic,
    'underline': underline,
    'outline': outline,
    'color': '#$hex',
    'size': size,
    'opacity': opacity,
    'fade': fade,
    'mode': mode,
    'speed': speed,
    'depth': depth,
    'x': x,
    'y': y,
    'yaw': yaw,
    'pitch': pitch,
    'roll': roll,
    'distort': distort,
    'dist_amount': distAmount,
    'dist_freq': distFreq,
    'dist_speed': distSpeed,
    'crt': crt,
    'cursor': cursor,
    'typing': typing,
    'type_speed': typeSpeed,
  };

  factory WordsLook.fromJson(Map<String, dynamic> j) {
    final l = WordsLook();
    double d(String k, double or) => (j[k] as num?)?.toDouble() ?? or;
    l.font = j['font'] as String? ?? l.font;
    l.bold = j['bold'] == true;
    l.italic = j['italic'] == true;
    l.underline = j['underline'] == true;
    l.outline = j['outline'] == true;
    l.color = int.tryParse((j['color'] as String? ?? '').replaceAll('#', ''), radix: 16) ?? l.color;
    l.size = d('size', l.size);
    l.opacity = d('opacity', l.opacity);
    l.fade = d('fade', l.fade);
    l.mode = j['mode'] as String? ?? l.mode;
    l.speed = d('speed', l.speed);
    l.depth = d('depth', l.depth);
    l.x = d('x', 0);
    l.y = d('y', 0);
    l.yaw = d('yaw', 0);
    l.pitch = d('pitch', 0);
    l.roll = d('roll', 0);
    l.distort = j['distort'] as String? ?? 'none';
    l.distAmount = d('dist_amount', l.distAmount);
    l.distFreq = d('dist_freq', l.distFreq);
    l.distSpeed = d('dist_speed', l.distSpeed);
    l.crt = j['crt'] == true;
    l.cursor = j['cursor'] == true;
    l.typing = j['typing'] == true;
    l.typeSpeed = d('type_speed', l.typeSpeed);
    return l;
  }
}

/// A phrase, its look, and where and for how long it shows.
class WordsPhrase {
  String text;
  WordsLook look;

  /// Which layer: [replaceAll] the only one (the usual), [addLayer] the next
  /// free one, or 0..7 that one (replacing what's on it).
  int layer;
  static const addLayer = -1, replaceAll = -2;

  /// How long it stays: an index into [wordsHolds], or -1 for the list's.
  int hold;

  WordsPhrase(this.text, {WordsLook? look, this.layer = replaceAll, this.hold = -1}) : look = look ?? WordsLook();

  Map<String, Object?> toJson() => {'text': text, 'look': look.toJson(), 'layer': layer, 'hold': hold};
  factory WordsPhrase.fromJson(Map<String, dynamic> j) => WordsPhrase(
    j['text'] as String? ?? '',
    look: WordsLook.fromJson(j['look'] as Map<String, dynamic>? ?? const {}),
    layer: j['layer'] as int? ?? replaceAll,
    hold: j['hold'] as int? ?? -1,
  );
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

/// What's on one of the Vessel's layers, as far as the Guide knows.
class _Slot {
  final WordsPhrase phrase;
  final DateTime at = DateTime.now();
  Timer? timer;
  _Slot(this.phrase);
}

class GuideWords extends ChangeNotifier {
  /// Sends a message to the sender, which relays it to the Vessels.
  final void Function(String type, Map<String, Object?> more) _command;
  final bool Function() _linked;
  GuideWords(this._command, this._linked);

  List<WordsList> lists = [];
  int listIndex = 0;

  /// The phrase being edited: one in the list, or -1 for [draft].
  int selected = -1;
  final WordsPhrase draft = WordsPhrase('', look: WordsLook()..terminal());

  /// The list's own time on screen, an index into [wordsHolds].
  int hold = 3;
  bool auto = false; // go on to the next phrase when one's time is up
  bool loop = true; // and from the last back to the first

  /// The phrase last cued from the list, for Next and Previous.
  int current = -1;
  Timer? _advance;
  final List<_Slot?> _slots = List.filled(wordsLayers, null);

  WordsList? get list => lists.isEmpty ? null : lists[listIndex.clamp(0, lists.length - 1)];
  int get holdSeconds => wordsHolds[hold];

  /// What the editor is on.
  WordsPhrase get edited {
    final l = list;
    return selected >= 0 && l != null && selected < l.phrases.length ? l.phrases[selected] : draft;
  }

  bool onScreen(WordsPhrase p) => _slots.any((s) => s != null && identical(s.phrase, p));

  // ----- Saved -----

  SharedPreferences? _prefs;

  Future<void> load() async {
    if (_prefs != null) return;
    _prefs = await SharedPreferences.getInstance();
    try {
      final j = jsonDecode(_prefs!.getString('hiveSightWords2') ?? '{}') as Map<String, dynamic>;
      lists = [for (final l in j['lists'] as List<dynamic>? ?? const []) WordsList.fromJson(l as Map<String, dynamic>)];
      listIndex = (j['list'] as int? ?? 0).clamp(0, lists.isEmpty ? 0 : lists.length - 1);
      hold = (j['hold'] as int? ?? 3).clamp(0, wordsHolds.length - 1);
      auto = j['auto'] == true;
      loop = j['loop'] != false;
      final d = j['draft'] as Map<String, dynamic>?;
      if (d != null) {
        final p = WordsPhrase.fromJson(d);
        draft.text = p.text;
        draft.look = p.look;
        draft.layer = p.layer;
        draft.hold = p.hold;
      }
    } catch (_) {}
    if (lists.isEmpty) lists = [WordsList('Words')];
    notifyListeners();
  }

  void _save() {
    _prefs?.setString(
      'hiveSightWords2',
      jsonEncode({
        'lists': [for (final l in lists) l.toJson()],
        'list': listIndex,
        'hold': hold,
        'auto': auto,
        'loop': loop,
        'draft': draft.toJson(),
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
    selected = -1;
    current = -1;
    _advance?.cancel();
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

  void select(int i) {
    selected = i;
    notifyListeners();
  }

  /// Puts the draft in the list (and starts a new one, keeping its look).
  void addDraft() {
    final t = draft.text.trim();
    final l = list;
    if (t.isEmpty || l == null) return;
    l.phrases.add(
      WordsPhrase(
        t.length > wordsMaxLength ? t.substring(0, wordsMaxLength) : t,
        look: draft.look.copy(),
        layer: draft.layer,
        hold: draft.hold,
      ),
    );
    draft.text = '';
    selected = l.phrases.length - 1;
    _changed();
  }

  void removePhrase(int i) {
    final l = list;
    if (l == null) return;
    l.phrases.removeAt(i);
    if (selected == i) {
      selected = -1;
    } else if (selected > i) {
      selected--;
    }
    if (current == i) {
      current = -1;
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
    int follow(int k) => k == i ? j : (k == j ? i : k);
    l.phrases.insert(j, l.phrases.removeAt(i));
    selected = follow(selected);
    current = follow(current);
    _changed();
  }

  void setHold(int i) {
    hold = i.clamp(0, wordsHolds.length - 1);
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

  // ----- Editing: what's on screen follows -----

  Timer? _liveTimer;

  /// The editor changed the edited phrase (call after changing it): it's
  /// kept, and sent to the Vessel as it is if it's on screen.
  void editedChanged() {
    _save();
    notifyListeners();
    final p = edited;
    for (var n = 0; n < wordsLayers; n++) {
      if (_slots[n] != null && identical(_slots[n]!.phrase, p)) {
        _liveTimer?.cancel();
        final layer = n;
        _liveTimer = Timer(const Duration(milliseconds: 60), () {
          if (_slots[layer] != null && identical(_slots[layer]!.phrase, p)) _send(layer, p, update: true);
        });
      }
    }
  }

  // ----- Cues -----

  static String _text(WordsPhrase p) {
    final t = p.text.trim();
    return t.length > wordsMaxLength ? t.substring(0, wordsMaxLength) : t;
  }

  void _send(int layer, WordsPhrase p, {bool update = false}) {
    _command('words', {'layer': layer, 'text': _text(p), ...p.look.toJson(), if (update) 'update': true});
  }

  int _layerFor(WordsPhrase p) {
    if (p.layer == WordsPhrase.replaceAll) return 0;
    if (p.layer >= 0 && p.layer < wordsLayers) return p.layer;
    // The next free one, or the one that's been there longest
    for (var n = 0; n < wordsLayers; n++) {
      if (_slots[n] == null) return n;
    }
    var oldest = 0;
    for (var n = 1; n < wordsLayers; n++) {
      if (_slots[n]!.at.isBefore(_slots[oldest]!.at)) oldest = n;
    }
    return oldest;
  }

  /// Shows [p] now, and times it. [index] is its place in the list, if it's from there.
  void play(WordsPhrase p, {int? index}) {
    final text = p.text.trim();
    if (text.isEmpty || !_linked()) return;
    final layer = _layerFor(p);
    if (p.layer == WordsPhrase.replaceAll) {
      _command('words_clear', {
        'layers': [for (var n = 1; n < wordsLayers; n++) n],
        'fade': p.look.fade,
      });
      for (var n = 1; n < wordsLayers; n++) {
        _slots[n]?.timer?.cancel();
        _slots[n] = null;
      }
    }
    _slots[layer]?.timer?.cancel();
    final slot = _Slot(p);
    _slots[layer] = slot;
    _command('words', {'layer': layer, 'text': _text(p), ...p.look.toJson()});
    final seconds = wordsHolds[p.hold >= 0 ? p.hold : hold];
    if (seconds > 0) {
      slot.timer = Timer(Duration(seconds: seconds), () {
        if (!identical(_slots[layer], slot)) return;
        _slots[layer] = null;
        if (_linked())
          _command('words_clear', {
            'layers': [layer],
            'fade': p.look.fade,
          });
        notifyListeners();
      });
    }
    if (index != null) {
      current = index;
      _advance?.cancel();
      if (auto && seconds > 0) {
        _advance = Timer(Duration(seconds: seconds), () {
          if (_linked()) next();
        });
      }
    }
    notifyListeners();
  }

  void cue(int i) {
    final l = list;
    if (l == null || i < 0 || i >= l.phrases.length) return;
    play(l.phrases[i], index: i);
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

  /// Fades everything out.
  void clear() {
    _advance?.cancel();
    var fade = 1.0;
    for (var n = 0; n < wordsLayers; n++) {
      final s = _slots[n];
      if (s == null) continue;
      s.timer?.cancel();
      if (s.phrase.look.fade > fade) fade = s.phrase.look.fade;
      _slots[n] = null;
    }
    if (_linked()) _command('words_clear', {'fade': fade});
    notifyListeners();
  }

  /// The link's gone: nothing more to time.
  void stopTiming() {
    _advance?.cancel();
    for (var n = 0; n < wordsLayers; n++) {
      _slots[n]?.timer?.cancel();
      _slots[n] = null;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _advance?.cancel();
    _liveTimer?.cancel();
    stopTiming();
    super.dispose();
  }
}
