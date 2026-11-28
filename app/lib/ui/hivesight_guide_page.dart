import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../comm/comm_controller.dart';
import '../comm/hivesight_guide.dart';
import 'guide/guide_column.dart';
import 'guide/guide_layout.dart';
import 'guide/guide_quick.dart';
import 'guide/guide_top_bar.dart';
import 'theme.dart';

/// HiveSight's Guide page, on a computer: a top bar that's always there
/// (the session, BLACKOUT, the mic, STOP TOYS, layouts), the preview and
/// quick controls fixed on the left, and the rest in columns of panels, each
/// with a picker for what it shows. Experimental: developer options only.
class HiveSightGuidePage extends StatefulWidget {
  final CommController comm;
  const HiveSightGuidePage({super.key, required this.comm});

  @override
  State<HiveSightGuidePage> createState() => _HiveSightGuidePageState();
}

class _HiveSightGuidePageState extends State<HiveSightGuidePage> {
  late final HiveSightGuide g = HiveSightGuide.of(widget.comm);
  StreamSubscription<String>? _notices;
  final _focus = FocusNode();
  bool _ptt = false; // push-to-talk mode: the mic's live only while held

  /// The windows narrower than this get one column under the preview.
  static const _wide = 900.0;

  /// About how wide a panel column is.
  static const _columnWidth = 400.0;

  @override
  void initState() {
    super.initState();
    _notices = g.notices.stream.listen((t) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));
    });
    g.words.load();
    g.presetStore.load();
    GuideUi.instance.load();
    if (g.cameras.isEmpty) g.listDevices();
    if (g.state == SenderState.stopped) g.start();
  }

  @override
  void dispose() {
    _notices?.cancel();
    _focus.dispose();
    super.dispose();
  }

  void _talk(bool on) {
    if (_ptt) g.set('voice.mute', !on);
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e.logicalKey == LogicalKeyboardKey.space && _ptt) {
      if (e is KeyDownEvent) _talk(true);
      if (e is KeyUpEvent) _talk(false);
      return KeyEventResult.handled;
    }
    // Ctrl+Z undoes, Ctrl+Shift+Z (or Ctrl+Y) redoes: a text field takes its own first
    if (e is KeyDownEvent && HardwareKeyboard.instance.isControlPressed) {
      final shift = HardwareKeyboard.instance.isShiftPressed;
      if (e.logicalKey == LogicalKeyboardKey.keyZ) {
        shift ? g.redo() : g.undo();
        return KeyEventResult.handled;
      }
      if (e.logicalKey == LogicalKeyboardKey.keyY) {
        g.redo();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: g,
    builder: (context, _) => Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Scaffold(
        appBar: AppBar(
          toolbarHeight: 64,
          titleSpacing: 0,
          title: Padding(
            padding: const EdgeInsets.only(right: 16),
            child: DefaultTextStyle(
              style: const TextStyle(fontSize: 14, color: Kc.text),
              child: GuideTopBar(
                g,
                ptt: _ptt,
                compact: MediaQuery.sizeOf(context).width < 1100,
                onTalk: _talk,
                onPttMode: (on) {
                  setState(() => _ptt = on);
                  g.set('voice.mute', on);
                  _focus.requestFocus();
                },
              ),
            ),
          ),
        ),
        body: LayoutBuilder(
          builder: (context, box) {
            final live = g.linked;
            if (box.maxWidth < _wide) {
              // One column: the preview stays in view, the rest scrolls under it
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                    decoration: const BoxDecoration(
                      border: Border(bottom: BorderSide(color: Kc.line)),
                    ),
                    child: GuidePreview(g, enabled: live, maxHeight: box.maxHeight * 0.3),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          GuideQuick(g, enabled: live),
                          const SizedBox(height: 16),
                          GuideColumn(g, 0, scrolls: false),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            }
            final side = (box.maxWidth * 0.32).clamp(420.0, 640.0);
            final rest = box.maxWidth - side;
            final cols = ((rest - 16) / _columnWidth).floor().clamp(1, GuideUi.maxColumns);
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: side,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 4, 0),
                        child: GuidePreview(g, enabled: live, maxHeight: box.maxHeight * 0.42),
                      ),
                      Expanded(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(16, 10, 4, 24),
                          child: GuideQuick(g, enabled: live),
                        ),
                      ),
                    ],
                  ),
                ),
                for (var i = 0; i < cols; i++)
                  Expanded(
                    child: Container(
                      margin: EdgeInsets.fromLTRB(12, 8, i == cols - 1 ? 16 : 0, 0),
                      child: GuideColumn(g, i),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    ),
  );
}
