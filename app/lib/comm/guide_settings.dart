/// What the Guide's panels need of whatever holds the settings: a path's
/// value, setting one, setting many. [HiveSightGuide] is it for a live
/// session; the timeline editor will be it for "the timeline at the
/// playhead" (Phase 7), so the panels don't care which.
library;

import 'package:flutter/foundation.dart';

abstract interface class GuideSettings implements Listenable {
  /// The value at a dotted path ("spiral.speed"), or null if there's none.
  Object? value(String path);

  num number(String path, [num or = 0]);
  bool flag(String path);
  String text(String path);

  /// Every path there is a value for.
  Iterable<String> get paths;

  /// Whether they can be changed just now (a live session's link is up).
  bool get linked;

  /// Set one: shown at once and sent; a slider's moves are thinned, the last
  /// value always sent.
  void set(String path, Object value);

  /// Set many at once: all shown, and sent as one change.
  void setMany(Map<String, Object> values);

  /// Undo and redo what was changed by hand: a slider's drag is one step,
  /// and so is a preset or a reset.
  bool get canUndo;
  bool get canRedo;
  void undo();
  void redo();
}
