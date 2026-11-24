/// Playing a pattern on the wearer's own toys, through their unit, while
/// it's edited: each channel's level set as it changes (POST /api/level),
/// one request at a time, the latest levels going next. A pattern of one
/// row plays on every channel; one of more, its first row on V1, and so on.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'board_link.dart';
import 'board_protocol.dart';
import 'patterns.dart';

class PatternPreview extends ChangeNotifier {
  final BoardLink board;
  PatternPreview(this.board);

  static const _tick = Duration(milliseconds: 40);

  VibePattern? _pattern;
  String? _builtIn;
  int _speed = 100;
  final Stopwatch _clock = Stopwatch();
  Timer? _timer;
  bool onToys = true;

  final Map<int, int> _sent = {};       // by channel
  Map<int, int> _wanted = {};
  bool _busy = false;

  bool get playing => _timer != null;
  bool get boardUp => board.state == BoardState.connected && board.status != null;

  /// How far in it is, in ms, at the pattern's own speed.
  int get positionMs => _clock.elapsedMilliseconds * _speed ~/ 100;

  /// Play [pattern] (or the built-in one [builtIn]) from the start.
  void play({VibePattern? pattern, String? builtIn, int speed = 100}) {
    _pattern = pattern;
    _builtIn = builtIn;
    _speed = speed;
    _clock
      ..reset()
      ..start();
    _sent.clear();
    if (onToys && boardUp) {
      // Nothing else driving them meanwhile
      _request('/api/play?c=${OthersCommand.allChannels}&p=-1');
      _request('/api/react?c=${OthersCommand.allChannels}&m=0');
    }
    _timer ??= Timer.periodic(_tick, (_) => _step());
    notifyListeners();
  }

  /// A pattern changed while it plays: carry on where it is.
  void update(VibePattern pattern) => _pattern = pattern;

  void stop() {
    if (_timer == null) return;
    _timer?.cancel();
    _timer = null;
    _clock.stop();
    if (boardUp && _sent.values.any((v) => v != 0)) {
      _wanted = {for (var c = 0; c < OthersCommand.vibeChannels; c++) c: 0};
      _pump();
    }
    notifyListeners();
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }

  void _step() {
    final ms = positionMs;
    final wanted = <int, int>{};
    final p = _pattern;
    if (p != null) {
      final rows = p.rowCount;
      for (var c = 0; c < OthersCommand.vibeChannels; c++) {
        final row = rows == 1 ? 0 : c;
        if (row >= rows) {
          wanted[c] = 0;
          continue;
        }
        wanted[c] = ((p.level(row, ms) ?? 0) * VibePattern.top).round();
      }
    } else if (_builtIn != null) {
      for (var c = 0; c < OthersCommand.vibeChannels; c++) {
        wanted[c] = (builtInLevel(_builtIn!, c, ms / 1000) * VibePattern.top).round().clamp(0, VibePattern.top);
      }
    }
    _wanted = wanted;
    notifyListeners();
    if (onToys && boardUp) _pump();
  }

  /// The levels that have changed, those the same together.
  Future<void> _pump() async {
    if (_busy) return;
    _busy = true;
    try {
      while (true) {
        final byLevel = <int, int>{};
        _wanted.forEach((c, v) {
          if (_sent[c] != v) byLevel[v] = (byLevel[v] ?? 0) | (1 << c);
        });
        if (byLevel.isEmpty) break;
        final (v, mask) = byLevel.entries.map((e) => (e.key, e.value)).first;
        await _request('/api/level?c=$mask&v=$v');
        for (var c = 0; c < OthersCommand.vibeChannels; c++) {
          if (mask & (1 << c) != 0) _sent[c] = v;
        }
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> _request(String path) async {
    try {
      await board.request('POST', path);
    } catch (_) {}
  }
}
