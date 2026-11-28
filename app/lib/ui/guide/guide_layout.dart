/// The Guide page's layout: which panel each column shows and on which of
/// its tabs, the named layouts (built in, and the Guide's own), and which
/// folded sections are open. Kept in the app's preferences.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The panels a column can show.
enum GuidePanel {
  session('Session', [
    ('session', 'Session'),
    ('vessels', 'Vessels'),
    ('sender', 'Sender'),
    ('calibrate', 'Calibrate'),
  ]),
  picture('Picture', [('source', 'Source'), ('look', 'Look'), ('screen', 'Screen and video')]),
  sound('Sound', [('voice', 'Voice'), ('mix', 'Mix'), ('beats', 'Beats'), ('music', 'Music')]),
  visuals('Visuals', [('spiral', 'Spiral'), ('light', 'Light pulse')]),
  words('Words', [('cues', 'Cues'), ('phrase', 'Phrase')]),
  toys('Toys', [('toys', 'Toys')]),
  scenes('Scenes', [('scenes', 'Scenes')]);

  final String title;
  final List<(String, String)> tabs; // id, label
  const GuidePanel(this.title, this.tabs);

  String get firstTab => tabs.first.$1;
}

/// One column: a panel, on one of its tabs.
class ColumnSpec {
  final GuidePanel panel;
  final String tab;
  const ColumnSpec(this.panel, [String? tab]) : tab = tab ?? '';

  /// The tab as shown: the one asked for, or the panel's first.
  String get shownTab => panel.tabs.any((t) => t.$1 == tab) ? tab : panel.firstTab;

  ColumnSpec withTab(String t) => ColumnSpec(panel, t);

  Map<String, String> toJson() => {'panel': panel.name, 'tab': shownTab};

  static ColumnSpec fromJson(Map<String, dynamic> j) {
    final p = GuidePanel.values.where((x) => x.name == j['panel']).firstOrNull ?? GuidePanel.session;
    return ColumnSpec(p, j['tab'] as String?);
  }

  @override
  bool operator ==(Object other) => other is ColumnSpec && other.panel == panel && other.shownTab == shownTab;

  @override
  int get hashCode => Object.hash(panel, shownTab);
}

class GuideLayout {
  final String name;
  final List<ColumnSpec> columns;
  const GuideLayout(this.name, this.columns);

  Map<String, Object> toJson() => {
    'name': name,
    'columns': [for (final c in columns) c.toJson()],
  };

  static GuideLayout fromJson(Map<String, dynamic> j) => GuideLayout(j['name'] as String? ?? '', [
    for (final c in j['columns'] as List<dynamic>? ?? const []) ColumnSpec.fromJson(c as Map<String, dynamic>),
  ]);
}

class GuideUi extends ChangeNotifier {
  GuideUi._();
  static final GuideUi instance = GuideUi._();

  /// As many columns as the widest window shows: layouts are all this long.
  static const maxColumns = 6;

  /// The built-in layouts: Setup to get a session going, Run for steering
  /// one, Words for working from phrases.
  static const builtIn = [
    GuideLayout('Setup', [
      ColumnSpec(GuidePanel.session, 'session'),
      ColumnSpec(GuidePanel.picture, 'source'),
      ColumnSpec(GuidePanel.sound, 'voice'),
      ColumnSpec(GuidePanel.session, 'calibrate'),
      ColumnSpec(GuidePanel.session, 'sender'),
      ColumnSpec(GuidePanel.scenes),
    ]),
    GuideLayout('Run', [
      ColumnSpec(GuidePanel.sound, 'mix'),
      ColumnSpec(GuidePanel.visuals, 'spiral'),
      ColumnSpec(GuidePanel.toys),
      ColumnSpec(GuidePanel.visuals, 'light'),
      ColumnSpec(GuidePanel.picture, 'look'),
      ColumnSpec(GuidePanel.words, 'cues'),
    ]),
    GuideLayout('Words', [
      ColumnSpec(GuidePanel.words, 'cues'),
      ColumnSpec(GuidePanel.words, 'phrase'),
      ColumnSpec(GuidePanel.visuals, 'spiral'),
      ColumnSpec(GuidePanel.sound, 'voice'),
      ColumnSpec(GuidePanel.toys),
      ColumnSpec(GuidePanel.picture, 'look'),
    ]),
  ];

  static const _key = 'hiveSightGuideUi';

  List<ColumnSpec> columns = List.of(builtIn.first.columns);
  List<GuideLayout> saved = [];
  final Map<String, bool> _open = {};

  SharedPreferences? _prefs;

  Future<void> load() async {
    if (_prefs != null) return;
    _prefs = await SharedPreferences.getInstance();
    try {
      final j = jsonDecode(_prefs!.getString(_key) ?? '{}') as Map<String, dynamic>;
      final cols = [
        for (final c in j['columns'] as List<dynamic>? ?? const []) ColumnSpec.fromJson(c as Map<String, dynamic>),
      ];
      if (cols.isNotEmpty) columns = _filled(cols);
      saved = [
        for (final l in j['saved'] as List<dynamic>? ?? const [])
          if (GuideLayout.fromJson(l as Map<String, dynamic>) case final x when x.name.isNotEmpty)
            GuideLayout(x.name, _filled(x.columns)),
      ];
      (j['open'] as Map<String, dynamic>? ?? const {}).forEach((k, v) => _open[k] = v == true);
    } catch (_) {}
    notifyListeners();
  }

  /// [cols] made [maxColumns] long, with Setup's for the missing ones.
  static List<ColumnSpec> _filled(List<ColumnSpec> cols) => [
    for (var i = 0; i < maxColumns; i++) i < cols.length ? cols[i] : builtIn.first.columns[i],
  ];

  void _save() {
    _prefs?.setString(
      _key,
      jsonEncode({
        'columns': [for (final c in columns) c.toJson()],
        'saved': [for (final l in saved) l.toJson()],
        'open': _open,
      }),
    );
    notifyListeners();
  }

  /// The layout the columns are, if they're one of the named ones.
  String? get layoutName {
    for (final l in [...builtIn, ...saved]) {
      if (listEquals(l.columns, columns)) return l.name;
    }
    return null;
  }

  bool isBuiltIn(String name) => builtIn.any((l) => l.name == name);

  /// Column [i] shows [panel], on its first tab.
  void setPanel(int i, GuidePanel panel) {
    if (columns[i].panel == panel) return;
    columns = [...columns]..[i] = ColumnSpec(panel, panel.firstTab);
    _save();
  }

  void setTab(int i, String tab) {
    columns = [...columns]..[i] = columns[i].withTab(tab);
    _save();
  }

  void use(GuideLayout l) {
    columns = _filled(l.columns);
    _save();
  }

  /// Keep the columns as they are now under [name]: why not, or null.
  String? saveLayout(String name) {
    final n = name.trim();
    if (n.isEmpty) return 'Give it a name';
    if (isBuiltIn(n)) return '"$n" is a built-in layout: pick another name';
    saved = [...saved.where((l) => l.name != n), GuideLayout(n, List.of(columns))];
    _save();
    return null;
  }

  void deleteLayout(String name) {
    saved = [...saved.where((l) => l.name != name)];
    _save();
  }

  /// Whether the folded section [id] is open: as the Guide left it.
  bool isOpen(String id, {bool open = false}) => _open[id] ?? open;

  void setOpen(String id, bool open) {
    _open[id] = open;
    _save();
  }
}
