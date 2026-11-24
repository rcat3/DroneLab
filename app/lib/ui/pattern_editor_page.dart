import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../comm/comm_controller.dart';
import '../comm/pattern_preview.dart';
import '../comm/patterns.dart';
import 'theme.dart';
import 'widgets.dart';

/// Making or changing a custom pattern (patterns.dart): its rows as graphs,
/// time across and level (0 to 20) up, the first row playing on the first
/// channel it's played on, and so on. Draw with a finger or tap steps;
/// select steps for the shape tools, copy, repeat and delete; play it on
/// your own toys while it's made. A built-in pattern, or one someone sent,
/// is saved as a new one of yours.
class PatternEditorPage extends StatefulWidget {
  final CommController comm;
  final PatternEntry? entry; // one in the library
  final VibePattern? start; // a new one: imported, duplicated, or blank
  final String? builtIn; // a built-in one, to make one from
  const PatternEditorPage({super.key, required this.comm, this.entry, this.start, this.builtIn});

  @override
  State<PatternEditorPage> createState() => _PatternEditorPageState();
}

/// A row: its steps, each [stepMs] long, repeating at its own length.
class _Row {
  int stepMs;
  List<int> levels;
  _Row(this.stepMs, this.levels);
  _Row copy() => _Row(stepMs, List.of(levels));
  int get lengthMs => stepMs * levels.length;
}

enum _Mode { draw, select }

class _PatternEditorPageState extends State<PatternEditorPage> {
  static const _rowGap = 22.0, _pad = 6.0;
  static const _top = VibePattern.top;

  late final TextEditingController _name;
  late List<_Row> _rows;
  bool _shared = true;
  _Mode _mode = _Mode.draw;
  bool _dirty = false;

  // The view: how many pixels a ms takes, and where it starts
  double? _pxPerMs;
  double _offsetMs = 0;
  double _viewWidth = 300;

  // A selection: a time, and the rows in it
  int? _selFrom, _selTo;
  Set<int> _selRows = {};
  List<List<int>>? _clipboard;

  final List<(List<_Row>, bool)> _undo = [];
  int? _drawRow, _lastStep;
  bool _moved = false;

  /// Rows shorter when there are many, so they all fit on a phone.
  double get _rowHeight => _rows.length > 3 ? 72 : 96;

  late final PatternPreview _preview = PatternPreview(widget.comm.board);

  bool get _ours => widget.entry?.kind == PatternEntry.mine;

  @override
  void initState() {
    super.initState();
    final p = widget.entry?.pattern ?? widget.start ?? (widget.builtIn != null ? _fromBuiltIn(widget.builtIn!) : null);
    if (p == null) {
      _rows = [_Row(100, List.filled(40, 10))];
      _name = TextEditingController(text: 'New pattern');
    } else {
      _rows = _rowsOf(p);
      _shared = _rows.every((r) => r.stepMs == _rows.first.stepMs && r.levels.length == _rows.first.levels.length);
      _name = TextEditingController(text: widget.builtIn != null ? '${p.name} copy' : p.name);
    }
    _dirty = widget.entry == null;
    _name.addListener(() => _dirty = true);
  }

  @override
  void dispose() {
    _preview.dispose();
    _name.dispose();
    super.dispose();
  }

  /// A built-in pattern, as steps: once round, 100 ms a step.
  static VibePattern _fromBuiltIn(String name) {
    final n = math.max(1, builtInLengthMs(name) ~/ 100);
    return VibePattern(name, [
      PatternBlock(100, 0, [for (var i = 0; i < n; i++) (builtInLevel(name, 0, i / 10) * _top).round().clamp(0, _top)]),
    ]);
  }

  /// A pattern's rows, one for each it drives.
  static List<_Row> _rowsOf(VibePattern p) {
    final n = p.rowCount;
    return [
      for (var r = 0; r < n; r++)
        if (p.blockFor(r) case final b?) _Row(b.stepMs, List.of(b.levels)) else _Row(100, List.filled(10, 0)),
    ];
  }

  /// The pattern as it is: one row drives every channel it's played on;
  /// rows that are the same go as one block.
  VibePattern get _pattern {
    if (_rows.length == 1) return VibePattern(_name.text, [PatternBlock(_rows[0].stepMs, 0, List.of(_rows[0].levels))]);
    final blocks = <PatternBlock>[];
    for (var r = 0; r < _rows.length; r++) {
      final row = _rows[r];
      final same = blocks.where((b) => b.stepMs == row.stepMs && listEquals(b.levels, row.levels));
      if (same.isNotEmpty) {
        same.first.rows |= 1 << r;
      } else {
        blocks.add(PatternBlock(row.stepMs, 1 << r, List.of(row.levels)));
      }
    }
    return VibePattern(_name.text, blocks);
  }

  int get _totalMs => _rows.fold(1, (m, r) => math.max(m, r.lengthMs));

  // ----- Changing it -----

  void _keepForUndo() {
    _undo.add(([for (final r in _rows) r.copy()], _shared));
    if (_undo.length > 60) _undo.removeAt(0);
  }

  void _changed() {
    _dirty = true;
    if (_preview.playing) _preview.update(_pattern);
    setState(() {});
  }

  void _undoLast() {
    if (_undo.isEmpty) return;
    final (rows, shared) = _undo.removeLast();
    _rows = rows;
    _shared = shared;
    _clearSelection();
    _changed();
  }

  void _clearSelection() {
    _selFrom = _selTo = null;
    _selRows = {};
  }

  bool get _hasSelection => _selFrom != null && _selTo != null && _selTo! > _selFrom! && _selRows.isNotEmpty;

  /// The steps of a row in the selection: from and to (not including).
  (int, int) _selectedSteps(int r) {
    final row = _rows[r];
    final from = (_selFrom! / row.stepMs).ceil().clamp(0, row.levels.length);
    final to = (_selTo! / row.stepMs).ceil().clamp(from, row.levels.length);
    return (from, to);
  }

  /// Shape the selection: each selected row's steps from [shape], 0 to 1
  /// at each step's place in it.
  void _shape(double Function(int i, int n, int stepMs) shape) {
    if (!_hasSelection) return;
    _keepForUndo();
    for (final r in _selRows) {
      final (from, to) = _selectedSteps(r);
      final n = to - from;
      for (var i = 0; i < n; i++) {
        _rows[r].levels[from + i] = (shape(i, n, _rows[r].stepMs) * _top).round().clamp(0, _top);
      }
    }
    _changed();
  }

  void _smooth() {
    if (!_hasSelection) return;
    _keepForUndo();
    for (final r in _selRows) {
      final (from, to) = _selectedSteps(r);
      final l = _rows[r].levels, was = List.of(l);
      for (var i = from; i < to; i++) {
        final a = was[math.max(0, i - 1)], b = was[i], c = was[math.min(was.length - 1, i + 1)];
        l[i] = ((a + 2 * b + c) / 4).round();
      }
    }
    _changed();
  }

  void _copy() {
    if (!_hasSelection) return;
    final rows = _selRows.toList()..sort();
    setState(
      () => _clipboard = [
        for (final r in rows)
          if (_selectedSteps(r) case (final from, final to)) _rows[r].levels.sublist(from, to),
      ],
    );
  }

  /// Steps put in after the selection (or at the end): for each row, from
  /// [pieces] in turn. With shared timing every row takes them, so they
  /// stay as long as each other.
  void _insert(List<List<int>> pieces, {int? atMs}) {
    if (pieces.isEmpty) return;
    _keepForUndo();
    final rows = _shared
        ? List.generate(_rows.length, (i) => i)
        : (_selRows.isEmpty ? [0] : (_selRows.toList()..sort()));
    final sel = _selRows.toList()..sort();
    var room = VibePattern.sizeMax - _pattern.size;
    for (var k = 0; k < rows.length; k++) {
      final r = rows[k];
      final row = _rows[r];
      // The row's own piece if it was copied, else the first one's length of 0s
      final i = sel.indexOf(r);
      final piece = i >= 0 && i < pieces.length ? pieces[i] : (_shared ? pieces[k % pieces.length] : pieces.first);
      final at = atMs == null ? row.levels.length : (atMs / row.stepMs).ceil().clamp(0, row.levels.length);
      final fits = math.min(piece.length, room * 8 ~/ 5);
      row.levels.insertAll(at, piece.take(fits));
      room -= (fits * 5 + 7) ~/ 8;
    }
    _changed();
  }

  void _paste() {
    final c = _clipboard;
    if (c != null) _insert(c, atMs: _hasSelection ? _selTo : null);
  }

  void _repeat() {
    if (!_hasSelection) return;
    final rows = _shared ? List.generate(_rows.length, (i) => i) : (_selRows.toList()..sort());
    final pieces = [
      for (final r in rows)
        if (_selectedSteps(r) case (final from, final to)) _rows[r].levels.sublist(from, to),
    ];
    final was = _selRows;
    _selRows = rows.toSet();
    _insert(pieces, atMs: _selTo);
    _selRows = was;
  }

  void _delete() {
    if (!_hasSelection) return;
    _keepForUndo();
    final rows = _shared ? List.generate(_rows.length, (i) => i) : _selRows.toList();
    for (final r in rows) {
      final (from, to) = _selectedSteps(r);
      if (to - from >= _rows[r].levels.length) {
        _rows[r].levels = [0]; // a row keeps a step
      } else {
        _rows[r].levels.removeRange(from, to);
      }
    }
    _clearSelection();
    _changed();
  }

  void _setShared(bool on) {
    _keepForUndo();
    if (on) {
      final first = _rows.first;
      for (final r in _rows.skip(1)) {
        r.stepMs = first.stepMs;
        r.levels = [for (var i = 0; i < first.levels.length; i++) i < r.levels.length ? r.levels[i] : 0];
      }
    }
    _shared = on;
    _changed();
  }

  void _setStepMs(int? row, int ms) {
    _keepForUndo();
    ms = ms.clamp(VibePattern.minStepMs, VibePattern.maxStepMs);
    for (var r = 0; r < _rows.length; r++) {
      if (row == null || row == r) _rows[r].stepMs = ms;
    }
    _changed();
  }

  void _setLength(int? row, int steps) {
    steps = math.max(1, steps);
    _keepForUndo();
    for (var r = 0; r < _rows.length; r++) {
      if (row != null && row != r) continue;
      final l = _rows[r].levels;
      if (steps < l.length) {
        l.removeRange(steps, l.length);
      } else {
        l.addAll(List.filled(steps - l.length, l.isEmpty ? 0 : l.last));
      }
    }
    _changed();
  }

  void _addRow() {
    if (_rows.length >= VibePattern.rowsMax) return;
    _keepForUndo();
    final last = _rows.last;
    _rows.add(_Row(last.stepMs, List.filled(last.levels.length, 0)));
    _changed();
  }

  void _removeRow(int r) {
    if (_rows.length <= 1) return;
    _keepForUndo();
    _rows.removeAt(r);
    _selRows = {
      for (final s in _selRows)
        if (s != r) s > r ? s - 1 : s,
    };
    _changed();
  }

  // ----- The graph's gestures -----

  double get _scale => _pxPerMs ?? _fitScale;
  double get _fitScale => _viewWidth / _totalMs;
  double get _maxScale => 0.6; // 60 px for a step of 100 ms

  int _rowAt(double y) => (y / (_rowHeight + _rowGap)).floor().clamp(0, _rows.length - 1);
  double _msAt(double x) => _offsetMs + x / _scale;

  int _levelAt(int row, double y) {
    final inRow = y - row * (_rowHeight + _rowGap) - _pad;
    return ((1 - inRow / (_rowHeight - 2 * _pad)) * _top).round().clamp(0, _top);
  }

  void _drawAt(Offset p, {required bool start}) {
    final r = start ? _rowAt(p.dy) : (_drawRow ?? _rowAt(p.dy));
    final row = _rows[r];
    final step = (_msAt(p.dx) / row.stepMs).floor();
    final level = _levelAt(r, p.dy);
    if (step < 0 || step >= row.levels.length) {
      _lastStep = null;
      return;
    }
    if (start) {
      _keepForUndo();
      _drawRow = r;
    }
    // Every step between this and the last, so a quick stroke leaves no gaps
    final last = _lastStep;
    if (last != null && last != step) {
      final from = row.levels[last];
      final dir = step > last ? 1 : -1;
      for (var s = last + dir; s != step; s += dir) {
        row.levels[s] = (from + (level - from) * (s - last) / (step - last)).round();
      }
    }
    row.levels[step] = level;
    _lastStep = step;
    _changed();
  }

  void _selectFrom(Offset p) {
    final r = _rowAt(p.dy);
    final step = _rows[r].stepMs;
    final t = (_msAt(p.dx) / step).floor() * step;
    setState(() {
      _selFrom = t.clamp(0, _totalMs);
      _selTo = (t + step).clamp(0, _totalMs);
      _selRows = {r};
      _drawRow = r;
    });
  }

  void _selectTo(Offset p) {
    final r = _rowAt(p.dy), first = _drawRow ?? r;
    final step = _rows[r].stepMs;
    final t = ((_msAt(p.dx) / step).floor() + 1) * step;
    setState(() {
      _selTo = t.clamp(0, _totalMs);
      _selRows = {for (var i = math.min(first, r); i <= math.max(first, r); i++) i};
    });
  }

  void _zoom(double by) {
    final centre = _offsetMs + _viewWidth / 2 / _scale;
    final s = (_scale * by).clamp(_fitScale, math.max(_fitScale, _maxScale)).toDouble();
    setState(() {
      _pxPerMs = s;
      _offsetMs = (centre - _viewWidth / 2 / s).clamp(0, math.max(0, _totalMs - _viewWidth / s)).toDouble();
    });
  }

  // ----- Saving, exporting -----

  Future<void> _save() async {
    final p = _pattern;
    final messenger = ScaffoldMessenger.of(context);
    if (!p.fits) {
      messenger.showSnackBar(SnackBar(content: Text('Too big by ${p.size - VibePattern.sizeMax} bytes: shorten it')));
      return;
    }
    if (_name.text.trim().isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('Give it a name')));
      return;
    }
    widget.comm.patterns.saveMine(p, replacing: _ours ? widget.entry!.hash : null);
    _dirty = false;
    if (mounted) Navigator.pop(context, true);
  }

  Future<void> _export() async {
    final text = _pattern.toLovense();
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text("Copied in Lovense's pattern format"),
        action: SnackBarAction(
          label: 'Share',
          onPressed: () => SharePlus.instance.share(ShareParams(text: text)),
        ),
      ),
    );
  }

  Future<bool> _discard() async {
    if (!_dirty) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Discard changes?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Keep editing')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Discard')),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<int?> _askNumber(String title, int value, String unit) async {
    final c = TextEditingController(text: '$value');
    final v = await showDialog<int>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: c,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(suffixText: unit),
          onSubmitted: (s) => Navigator.pop(d, int.tryParse(s)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(d, int.tryParse(c.text)), child: const Text('Set')),
        ],
      ),
    );
    c.dispose();
    return v;
  }

  // ----- The page -----

  Widget _number(String label, int value, String unit, {required int step, required ValueChanged<int> onChanged}) =>
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.remove, size: 18),
            onPressed: () => onChanged(value - step),
          ),
          InkWell(
            onTap: () async {
              final v = await _askNumber(label, value, unit);
              if (v != null) onChanged(v);
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
              child: Text('$value $unit', style: Kc.term(15, color: Kc.pink)),
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.add, size: 18),
            onPressed: () => onChanged(value + step),
          ),
        ],
      );

  Widget _tool(IconData icon, String label, VoidCallback? onPressed) => Tooltip(
    message: label,
    child: ActionChip(
      avatar: Icon(icon, size: 16, color: onPressed == null ? Kc.dim : Kc.pink),
      label: Text(label),
      onPressed: onPressed,
      visualDensity: VisualDensity.compact,
    ),
  );

  Widget _graph() => LayoutBuilder(
    builder: (context, box) {
      _viewWidth = box.maxWidth;
      final scale = _scale.clamp(_fitScale, math.max(_fitScale, _maxScale)).toDouble();
      final visibleMs = _viewWidth / scale;
      final maxOffset = math.max(0.0, _totalMs - visibleMs);
      if (_offsetMs > maxOffset) _offsetMs = maxOffset;
      final height = _rows.length * (_rowHeight + _rowGap);
      return Column(
        children: [
          // Its touches are its own at once, so drawing up and down
          // doesn't scroll the page
          RawGestureDetector(
            gestures: {
              EagerGestureRecognizer: GestureRecognizerFactoryWithHandlers<EagerGestureRecognizer>(
                EagerGestureRecognizer.new,
                (_) {},
              ),
            },
            child: Listener(
              onPointerDown: (e) {
                _moved = false;
                _lastStep = null;
                _mode == _Mode.draw ? _drawAt(e.localPosition, start: true) : _selectFrom(e.localPosition);
              },
              onPointerMove: (e) {
                _moved = true;
                _mode == _Mode.draw ? _drawAt(e.localPosition, start: false) : _selectTo(e.localPosition);
              },
              onPointerUp: (_) {
                if (_mode == _Mode.select && !_moved) setState(_clearSelection);
                if (_mode == _Mode.draw) _drawRow = null;
                _lastStep = null;
              },
              child: ListenableBuilder(
                listenable: _preview,
                builder: (context, _) => CustomPaint(
                  size: Size(_viewWidth, height),
                  painter: _GraphPainter(
                    rows: _rows,
                    scale: scale,
                    offsetMs: _offsetMs,
                    rowHeight: _rowHeight,
                    rowGap: _rowGap,
                    pad: _pad,
                    selFrom: _selFrom,
                    selTo: _selTo,
                    selRows: _selRows,
                    playheadMs: _preview.playing ? _preview.positionMs : null,
                  ),
                ),
              ),
            ),
          ),
          Row(
            children: [
              IconButton(tooltip: 'Zoom out', icon: const Icon(Icons.zoom_out), onPressed: () => _zoom(1 / 1.6)),
              IconButton(tooltip: 'Zoom in', icon: const Icon(Icons.zoom_in), onPressed: () => _zoom(1.6)),
              Expanded(
                child: maxOffset <= 0
                    ? const SizedBox.shrink()
                    : Slider(
                        value: _offsetMs.clamp(0, maxOffset),
                        max: maxOffset,
                        onChanged: (v) => setState(() => _offsetMs = v),
                      ),
              ),
            ],
          ),
        ],
      );
    },
  );

  String _ordinal(int n) => switch (n) {
    1 => '1st',
    2 => '2nd',
    3 => '3rd',
    _ => '${n}th',
  };

  Widget _meter() {
    final p = _pattern;
    final size = p.size;
    final left = math.max(0, (VibePattern.sizeMax - size) * 8 ~/ 5);
    final over = size > VibePattern.sizeMax;
    final shareable = PatternShare.fits(p);
    return Panel(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LinearProgressIndicator(
                value: (size / VibePattern.sizeMax).clamp(0, 1),
                color: over ? Kc.softRed : Kc.pink,
                backgroundColor: Kc.raised,
              ),
              const SizedBox(height: 6),
              Text(
                over
                    ? 'Too big by ${size - VibePattern.sizeMax} bytes: shorten it to send it'
                    : '$size of ${VibePattern.sizeMax} bytes · room for about $left more steps',
                style: TextStyle(color: over ? Kc.softRed : Kc.muted, fontSize: 13),
              ),
              Text(
                shareable ? 'Fits in a message, to share' : 'Too long to share as a message, but it plays',
                style: const TextStyle(color: Kc.muted, fontSize: 13),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _timing() => Panel(
    children: [
      Explained(
        help:
            'With shared timing, every row has the same step length and number of steps, so they stay in step, '
            'and a selection covers the same moments on each row. Turn it off to give each row its own: rows '
            'of different lengths drift against each other as they repeat.',
        builder: (context, info) => PanelRow(
          title: 'Rows share timing',
          trailing: [
            info,
            Switch(value: _shared, onChanged: _setShared),
          ],
        ),
      ),
      if (_shared)
        PanelRow(
          title: 'Each step',
          trailing: [_number('Each step', _rows.first.stepMs, 'ms', step: 50, onChanged: (v) => _setStepMs(null, v))],
        ),
      if (_shared)
        PanelRow(
          title: 'Steps',
          subtitle: '${(_rows.first.lengthMs / 1000).toStringAsFixed(1)} s before it repeats',
          trailing: [_number('Steps', _rows.first.levels.length, '', step: 1, onChanged: (v) => _setLength(null, v))],
        ),
      for (var r = 0; r < _rows.length; r++) ...[
        PanelRow(
          title: 'Row ${r + 1}',
          subtitle: _rows.length == 1
              ? 'Plays on every channel it goes on'
              : 'Plays on the ${_ordinal(r + 1)} channel it goes on'
                    '${_shared ? '' : ' · ${(_rows[r].lengthMs / 1000).toStringAsFixed(1)} s'}',
          trailing: [
            if (_rows.length > 1)
              IconButton(
                tooltip: 'Remove row ${r + 1}',
                icon: const Icon(Icons.delete_outline),
                onPressed: () => _removeRow(r),
              ),
          ],
        ),
        if (!_shared)
          Padding(
            padding: const EdgeInsets.only(left: 8, bottom: 4),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _number('Row ${r + 1}: each step', _rows[r].stepMs, 'ms', step: 50, onChanged: (v) => _setStepMs(r, v)),
                _number(
                  'Row ${r + 1}: steps',
                  _rows[r].levels.length,
                  'steps',
                  step: 1,
                  onChanged: (v) => _setLength(r, v),
                ),
              ],
            ),
          ),
      ],
      if (_rows.length < VibePattern.rowsMax)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(onPressed: _addRow, icon: const Icon(Icons.add), label: const Text('Add a row')),
        ),
    ],
  );

  Widget _previewBar() => ListenableBuilder(
    listenable: _preview,
    builder: (context, _) => Panel(
      children: [
        PanelRow(
          title: _preview.playing ? 'Playing' : 'Preview',
          subtitle: _preview.boardUp
              ? (_preview.onToys ? "On your unit's toys" : 'Only here, not on your toys')
              : 'Connect your unit to feel it on your toys',
          trailing: [
            if (_preview.boardUp)
              Switch(
                value: _preview.onToys,
                onChanged: (on) {
                  if (!on && _preview.playing) _preview.stop();
                  setState(() => _preview.onToys = on);
                },
              ),
            IconButton.filled(
              tooltip: _preview.playing ? 'Stop' : 'Play',
              icon: Icon(_preview.playing ? Icons.stop : Icons.play_arrow),
              onPressed: () => _preview.playing ? _preview.stop() : _preview.play(pattern: _pattern),
            ),
          ],
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final sel = _hasSelection;
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (popped, _) async {
        if (popped) return;
        if (await _discard() && context.mounted) {
          _dirty = false;
          Navigator.pop(context);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            widget.builtIn != null
                ? 'From ${widget.builtIn}'
                : _ours
                ? 'Edit pattern'
                : 'New pattern',
          ),
          actions: [
            IconButton(tooltip: 'Undo', icon: const Icon(Icons.undo), onPressed: _undo.isEmpty ? null : _undoLast),
            IconButton(tooltip: "Copy in Lovense's format", icon: const Icon(Icons.ios_share), onPressed: _export),
            IconButton(tooltip: 'Save', icon: const Icon(Icons.check), onPressed: _save),
          ],
        ),
        body: SafeArea(
          top: false,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TextField(
                controller: _name,
                maxLength: VibePattern.nameMax,
                decoration: const InputDecoration(labelText: 'Name', counterText: ''),
              ),
              const SizedBox(height: 12),
              SegmentedButton<_Mode>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: _Mode.draw, icon: Icon(Icons.draw_outlined), label: Text('DRAW')),
                  ButtonSegment(value: _Mode.select, icon: Icon(Icons.select_all), label: Text('SELECT')),
                ],
                selected: {_mode},
                onSelectionChanged: (s) => setState(() => _mode = s.first),
              ),
              const SizedBox(height: 4),
              Text(
                _mode == _Mode.draw
                    ? 'Draw across a row, or tap a step, to set its levels'
                    : 'Drag across steps to select them, down over rows for more rows; tap to clear',
                style: const TextStyle(color: Kc.muted, fontSize: 13),
              ),
              const SizedBox(height: 8),
              _graph(),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  _tool(Icons.trending_up, 'Ramp up', sel ? () => _shape((i, n, _) => n < 2 ? 1 : i / (n - 1)) : null),
                  _tool(
                    Icons.trending_down,
                    'Ramp down',
                    sel ? () => _shape((i, n, _) => n < 2 ? 1 : 1 - i / (n - 1)) : null,
                  ),
                  _tool(
                    Icons.waves,
                    'Wave',
                    sel ? () => _shape((i, n, _) => 0.5 - 0.5 * math.cos(2 * math.pi * i / n)) : null,
                  ),
                  _tool(Icons.more_horiz, 'Pulse', sel ? () => _shape((i, n, _) => (i ~/ 2).isEven ? 1 : 0) : null),
                  _tool(
                    Icons.favorite_border,
                    'Heartbeat',
                    sel ? () => _shape((i, n, ms) => builtInLevel('Heartbeat', 0, i * ms / 1000)) : null,
                  ),
                  _tool(
                    Icons.shuffle,
                    'Random',
                    sel
                        ? () {
                            final rnd = math.Random();
                            _shape((i, n, _) => rnd.nextDouble());
                          }
                        : null,
                  ),
                  _tool(Icons.blur_on, 'Smooth', sel ? _smooth : null),
                  _tool(Icons.layers_clear_outlined, 'Off', sel ? () => _shape((i, n, _) => 0) : null),
                  _tool(Icons.copy, 'Copy', sel ? _copy : null),
                  _tool(Icons.content_paste, 'Paste', _clipboard != null ? _paste : null),
                  _tool(Icons.repeat, 'Repeat', sel ? _repeat : null),
                  _tool(Icons.backspace_outlined, 'Delete', sel ? _delete : null),
                ],
              ),
              const SizedBox(height: 12),
              _previewBar(),
              const SizedBox(height: 12),
              _meter(),
              const SizedBox(height: 12),
              _timing(),
            ],
          ),
        ),
      ),
    );
  }
}

/// The rows as graphs: each step a bar up to its level, the selection
/// lit, and the playhead where each row is in its own repeat.
class _GraphPainter extends CustomPainter {
  final List<_Row> rows;
  final double scale, offsetMs, rowHeight, rowGap, pad;
  final int? selFrom, selTo, playheadMs;
  final Set<int> selRows;
  _GraphPainter({
    required this.rows,
    required this.scale,
    required this.offsetMs,
    required this.rowHeight,
    required this.rowGap,
    required this.pad,
    required this.selFrom,
    required this.selTo,
    required this.selRows,
    required this.playheadMs,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final label = TextPainter(textDirection: TextDirection.ltr);
    for (var r = 0; r < rows.length; r++) {
      final row = rows[r];
      final top = r * (rowHeight + rowGap) + rowGap - 4;
      final area = Rect.fromLTWH(0, top, size.width, rowHeight);
      canvas.drawRRect(RRect.fromRectAndRadius(area, const Radius.circular(8)), Paint()..color = Kc.panel);
      label
        ..text = TextSpan(
          text: 'ROW ${r + 1} · ${row.stepMs} ms',
          style: const TextStyle(color: Kc.muted, fontSize: 11),
        )
        ..layout();
      label.paint(canvas, Offset(4, top - 16));
      canvas.save();
      canvas.clipRect(area);
      final grid = Paint()..color = Kc.line;
      for (final f in [0.0, 0.5, 1.0]) {
        final y = top + pad + (rowHeight - 2 * pad) * f;
        canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
      }
      // The selection
      if (selFrom != null && selTo != null && selRows.contains(r)) {
        canvas.drawRect(
          Rect.fromLTRB((selFrom! - offsetMs) * scale, top, (selTo! - offsetMs) * scale, top + rowHeight),
          Paint()..color = Kc.green.withValues(alpha: 0.16),
        );
      }
      // The steps that show
      final w = row.stepMs * scale;
      final first = math.max(0, (offsetMs / row.stepMs).floor());
      final bar = Paint()..color = Kc.pink;
      for (var s = first; s < row.levels.length; s++) {
        final x = (s * row.stepMs - offsetMs) * scale;
        if (x > size.width) break;
        final h = (rowHeight - 2 * pad) * row.levels[s] / VibePattern.top;
        final y = top + rowHeight - pad - h;
        canvas.drawRect(Rect.fromLTWH(x, y, math.max(1, w - (w > 4 ? 1 : 0)), math.max(1.5, h)), bar);
      }
      // Where the row ends
      final end = (row.lengthMs - offsetMs) * scale;
      if (end < size.width) {
        canvas.drawRect(
          Rect.fromLTRB(end, top, size.width, top + rowHeight),
          Paint()..color = Kc.bg.withValues(alpha: 0.7),
        );
      }
      if (playheadMs != null && row.lengthMs > 0) {
        final x = (playheadMs! % row.lengthMs - offsetMs) * scale;
        canvas.drawLine(
          Offset(x, top),
          Offset(x, top + rowHeight),
          Paint()
            ..color = Kc.green
            ..strokeWidth = 2,
        );
      }
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_GraphPainter old) => true;
}
