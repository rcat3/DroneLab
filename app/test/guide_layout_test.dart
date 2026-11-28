import 'package:flutter_test/flutter_test.dart';

import 'package:dronelab/comm/guide_presets.dart';
import 'package:dronelab/comm/guide_settings.dart';
import 'package:dronelab/ui/guide/guide_layout.dart';

class _Fake implements GuideSettings {
  final Map<String, Object?> v;
  _Fake(this.v);
  @override
  Object? value(String path) => v[path];
  @override
  num number(String path, [num or = 0]) => v[path] is num ? v[path] as num : or;
  @override
  bool flag(String path) => v[path] == true;
  @override
  String text(String path) => '${v[path] ?? ''}';
  @override
  Iterable<String> get paths => v.keys;
  @override
  bool get linked => true;
  @override
  void set(String path, Object value) => v[path] = value;
  @override
  void setMany(Map<String, Object> values) => v.addAll(values);
  @override
  bool get canUndo => false;
  @override
  bool get canRedo => false;
  @override
  void undo() {}
  @override
  void redo() {}
  @override
  void addListener(listener) {}
  @override
  void removeListener(listener) {}
}

void main() {
  test('a panel covers its prefix less what it leaves out', () {
    final s = _Fake({'voice.gain_db': 1, 'voice.echo_ms': 2, 'voice.preset': 'x', 'fx.fade': 1, 'fx.contrast': 1});
    expect(PresetPanel.voice.pathsIn(s), ['voice.echo_ms']);
    expect(PresetPanel.pictureLook.pathsIn(s), ['fx.contrast']);
  });

  test('presets are kept, compared and refused a built-in name', () {
    final p = GuidePresets()..setBuiltInVoice({'deep': {'voice.pitch': 0.78}});
    final s = _Fake({'voice.pitch': 0.78});
    expect(p.differences(PresetPanel.voice, s, 'deep'), isEmpty);
    s.set('voice.pitch', 1.0);
    expect(p.differences(PresetPanel.voice, s, 'deep'), ['voice.pitch']);
    expect(p.save(PresetPanel.voice, 'deep', {'voice.pitch': 1.0}), isNotNull);
    expect(p.save(PresetPanel.spiral, '  ', {}), isNotNull);
    expect(p.save(PresetPanel.spiral, 'slow', {'spiral.speed': 0.1}), isNull);
    expect(p.mine(PresetPanel.spiral), ['slow']);
    expect(p.differences(PresetPanel.spiral, _Fake({'spiral.speed': 0.1000001}), 'slow'), isEmpty);
  });

  test('layouts are all full length and tabs fall back to the first', () {
    for (final l in GuideUi.builtIn) {
      expect(l.columns.length, GuideUi.maxColumns);
    }
    expect(const ColumnSpec(GuidePanel.sound, 'nope').shownTab, 'voice');
    final ui = GuideUi.instance;
    ui.use(GuideUi.builtIn[1]);
    expect(ui.layoutName, 'Run');
    ui.setPanel(0, GuidePanel.toys);
    expect(ui.layoutName, isNull);
    expect(ui.saveLayout('Run'), isNotNull);
    expect(ui.saveLayout('Mine'), isNull);
    expect(ui.layoutName, 'Mine');
    ui.deleteLayout('Mine');
    expect(ui.layoutName, isNull);
  });
}
