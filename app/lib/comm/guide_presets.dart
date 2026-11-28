/// Presets of a panel's settings, the Guide's own, kept on this computer:
/// a name for a set of values (Voice, Spiral, Light pulse, Picture look,
/// Beats). Voice also has the sender's built-in ones, with what each comes
/// to; the other panels have none. A panel's selected preset can be
/// compared with what it's set to now.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'guide_settings.dart';

/// A panel whose settings can be kept as presets: the paths it covers, by
/// prefix, less those left out.
class PresetPanel {
  final String key, prefix;
  final Set<String> leave; // leaf names left out of its presets
  const PresetPanel(this.key, this.prefix, [this.leave = const {}]);

  /// The mic's own settings: a voice preset leaves them as they are.
  static const micKeys = {'preset', 'mute', 'gain_db', 'denoise', 'gate_db', 'comp_ratio'};

  static const voice = PresetPanel('voice', 'voice.', micKeys);
  static const spiral = PresetPanel('spiral', 'spiral.');
  // The light pulse's own switch isn't kept: loading a preset must not start flashing
  static const lightPulse = PresetPanel('photic', 'photic.', {'on'});
  static const pictureLook = PresetPanel('look', 'fx.', {'fade', 'fade_s', 'screen', 'delay_ms'});
  static const beats = PresetPanel('beats', 'beats.');

  List<String> pathsIn(GuideSettings s) => [
    for (final p in s.paths)
      if (p.startsWith(prefix) && !leave.contains(p.substring(prefix.length))) p,
  ]..sort();
}

class GuidePresets extends ChangeNotifier {
  static const _key = 'hiveSightPresets';

  /// Panel key to preset name to its values.
  final Map<String, Map<String, Map<String, Object>>> _all = {};

  /// The preset each panel last had chosen (not kept between runs: the
  /// settings are whatever the sender has).
  final Map<String, String> selected = {};

  /// What the sender's built-in voice presets come to.
  Map<String, Map<String, Object>> builtInVoice = {};

  SharedPreferences? _prefs;

  Future<void> load() async {
    if (_prefs != null) return;
    _prefs = await SharedPreferences.getInstance();
    try {
      final j = jsonDecode(_prefs!.getString(_key) ?? '{}') as Map<String, dynamic>;
      j.forEach((panel, byName) {
        _all[panel] = {
          for (final e in (byName as Map<String, dynamic>).entries)
            e.key: {for (final v in (e.value as Map<String, dynamic>).entries) v.key: v.value as Object},
        };
      });
    } catch (_) {}
    notifyListeners();
  }

  Future<void> _save() async => _prefs?.setString(_key, jsonEncode(_all));

  /// The Guide's own, by name.
  List<String> mine(PresetPanel p) =>
      [...?_all[p.key]?.keys]..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

  Map<String, Object>? valuesOf(PresetPanel p, String name) =>
      _all[p.key]?[name] ?? (p == PresetPanel.voice ? builtInVoice[name] : null);

  bool isBuiltIn(PresetPanel p, String name) => p == PresetPanel.voice && builtInVoice.containsKey(name);

  /// Keep [values] as [name]: why not (a built-in's name), or null.
  String? save(PresetPanel p, String name, Map<String, Object> values) {
    final n = name.trim();
    if (n.isEmpty) return 'Give it a name';
    if (isBuiltIn(p, n)) return '"$n" is one of the built-in presets: pick another name';
    _all.putIfAbsent(p.key, () => {})[n] = values;
    selected[p.key] = n;
    _save();
    notifyListeners();
    return null;
  }

  void delete(PresetPanel p, String name) {
    _all[p.key]?.remove(name);
    if (selected[p.key] == name) selected.remove(p.key);
    _save();
    notifyListeners();
  }

  /// [name] is the panel's picked preset now.
  void select(PresetPanel p, String name) {
    selected[p.key] = name;
    notifyListeners();
  }

  void setBuiltInVoice(Map<String, Map<String, Object>> v) {
    builtInVoice = v;
    notifyListeners();
  }

  /// Whether [now] is as [want]: numbers to a rounding error, the rest exactly.
  /// A path with no value yet doesn't count against it.
  static bool same(Object? want, Object? now) {
    if (now == null) return true;
    if (want is num && now is num) return (want - now).abs() < 1e-6;
    return want == now;
  }

  /// The paths where [s] isn't as preset [name] has them.
  List<String> differences(PresetPanel p, GuideSettings s, String name) {
    final v = valuesOf(p, name);
    if (v == null) return const [];
    return [
      for (final e in v.entries)
        if (!same(e.value, s.value(e.key))) e.key,
    ];
  }
}
