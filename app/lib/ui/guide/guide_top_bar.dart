/// The Guide page's top bar, always in view: the session's state, BLACKOUT,
/// the mic (mute, level, push-to-talk), STOP TOYS and the layouts. Room
/// stays at the right for recording (Phase 7).
library;

import 'package:flutter/material.dart';

import '../../comm/hivesight_guide.dart';
import '../../comm/hivesight_invite.dart';
import '../theme.dart';
import 'guide_layout.dart';

class GuideTopBar extends StatelessWidget {
  final HiveSightGuide g;

  /// Push-to-talk's on: the mic's muted but while the button or Space is held.
  final bool ptt;
  final void Function(bool on) onPttMode;
  final void Function(bool held) onTalk;
  final bool compact;
  const GuideTopBar(
    this.g, {
    super.key,
    required this.ptt,
    required this.onPttMode,
    required this.onTalk,
    required this.compact,
  });

  @override
  Widget build(BuildContext context) {
    final live = g.linked;
    final muted = g.flag('voice.mute');
    const pad = EdgeInsets.symmetric(horizontal: 12);
    final toysOn = live && g.vessels.isNotEmpty;
    return Row(
      children: [
        if (!compact) ...[const Text('HiveSight Guide', style: TextStyle(fontSize: 18)), const SizedBox(width: 20)],
        Flexible(child: _Status(g, compact: compact)),
        const Spacer(),
        Tooltip(
          message: 'BLACKOUT: fade to black and stop the light pulse',
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: g.blackedOut ? Kc.red : Kc.raised,
              foregroundColor: Kc.text,
              minimumSize: Size(compact ? 0 : 150, 48),
              padding: pad,
            ),
            onPressed: live ? g.blackout : null,
            icon: Icon(g.blackedOut ? Icons.visibility_off : Icons.visibility),
            label: Text(g.blackedOut && !compact ? 'BLACKED OUT' : 'BLACKOUT'),
          ),
        ),
        const SizedBox(width: 8),
        Tooltip(
          message: muted ? 'Mic muted' : 'Mic live',
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(
              minimumSize: Size(compact ? 48 : 130, 48),
              padding: pad,
              foregroundColor: muted ? Kc.softRed : Kc.green,
            ),
            onPressed: live && !ptt ? () => g.set('voice.mute', !muted) : null,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(muted ? Icons.mic_off : Icons.mic, size: 20),
                if (!compact) ...[const SizedBox(width: 8), Text(muted ? 'MIC MUTED' : 'MIC LIVE')],
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        MicMeter(g, width: compact ? 40 : 80),
        const SizedBox(width: 8),
        GestureDetector(
          onTapDown: live && ptt ? (_) => onTalk(true) : null,
          onTapUp: live && ptt ? (_) => onTalk(false) : null,
          onTapCancel: live && ptt ? () => onTalk(false) : null,
          child: Tooltip(
            message: 'Push-to-talk: hold this or Space',
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(minimumSize: Size(compact ? 48 : 130, 48), padding: pad),
              onPressed: live && ptt ? () {} : null,
              child: compact
                  ? const Icon(Icons.record_voice_over_outlined, size: 20)
                  : Text(ptt ? 'HOLD TO TALK' : 'PUSH-TO-TALK OFF'),
            ),
          ),
        ),
        Switch(value: ptt, onChanged: live ? onPttMode : null),
        const SizedBox(width: 8),
        Tooltip(
          message: toysOn ? "Stop every Vessel's toys" : 'No Vessel in the session',
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red.shade700,
              foregroundColor: Colors.white,
              disabledBackgroundColor: Kc.raised,
              minimumSize: Size(compact ? 0 : 130, 48),
              padding: pad,
            ),
            onPressed: toysOn ? g.toys.stopAll : null,
            icon: const Icon(Icons.stop_circle_outlined),
            label: Text(compact ? 'TOYS' : 'STOP TOYS'),
          ),
        ),
        const SizedBox(width: 8),
        LayoutMenu(compact: compact),
      ],
    );
  }
}

/// The session in a line: when it ends and how many Vessels are in it, or
/// what the sender's doing.
class _Status extends StatelessWidget {
  final HiveSightGuide g;
  final bool compact;
  const _Status(this.g, {required this.compact});

  @override
  Widget build(BuildContext context) {
    final s = g.session;
    final n = g.vessels.length;
    final (icon, color, text) = switch (g.state) {
      SenderState.running when g.linked && s != null => (
        Icons.radio_button_checked,
        Kc.green,
        'Open until ${HiveSightInvite.clock(s.expires)} · $n ${n == 1 ? 'Vessel' : 'Vessels'}',
      ),
      SenderState.running when g.linked => (Icons.check_circle_outline, Kc.muted, 'No session'),
      SenderState.running || SenderState.starting => (Icons.sync, Kc.muted, 'Starting the sender…'),
      SenderState.failed => (Icons.error_outline, Kc.softRed, 'Sender stopped'),
      SenderState.stopped => (Icons.stop_circle_outlined, Kc.muted, 'Sender off'),
    };
    return Tooltip(
      message: text,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 18),
          if (!compact) ...[
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                text,
                style: TextStyle(color: color),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ] else if (s != null)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text('$n', style: TextStyle(color: color)),
            ),
        ],
      ),
    );
  }
}

/// Layout ▾: the built-in layouts and the Guide's own, one click to switch,
/// and the columns as they are now to keep.
class LayoutMenu extends StatelessWidget {
  final bool compact;
  const LayoutMenu({super.key, required this.compact});

  @override
  Widget build(BuildContext context) {
    final ui = GuideUi.instance;
    return ListenableBuilder(
      listenable: ui,
      builder: (context, _) {
        final current = ui.layoutName;
        return PopupMenuButton<String>(
          tooltip: 'Layout',
          onSelected: (v) async {
            if (v == 'save') {
              await _save(context, ui);
            } else if (v.startsWith('use:')) {
              final name = v.substring(4);
              final l = [...GuideUi.builtIn, ...ui.saved].where((x) => x.name == name).firstOrNull;
              if (l != null) ui.use(l);
            }
          },
          itemBuilder: (menu) => [
            for (final l in GuideUi.builtIn) _item(l.name, current == l.name),
            if (ui.saved.isNotEmpty) const PopupMenuDivider(),
            for (final l in ui.saved)
              PopupMenuItem(
                value: 'use:${l.name}',
                child: Row(
                  children: [
                    _check(current == l.name),
                    Expanded(child: Text(l.name, overflow: TextOverflow.ellipsis)),
                    IconButton(
                      tooltip: 'Delete this layout',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.delete_outline, size: 18),
                      onPressed: () {
                        Navigator.pop(menu);
                        _delete(context, ui, l.name);
                      },
                    ),
                  ],
                ),
              ),
            const PopupMenuDivider(),
            const PopupMenuItem(
              value: 'save',
              child: Row(
                children: [Icon(Icons.save_outlined, size: 18), SizedBox(width: 8), Text('Save this layout…')],
              ),
            ),
          ],
          child: Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              border: Border.all(color: Kc.line),
              borderRadius: BorderRadius.circular(24),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.view_column_outlined, size: 20),
                if (!compact) ...[const SizedBox(width: 8), Text('Layout: ${current ?? 'Custom'}')],
                const Icon(Icons.arrow_drop_down),
              ],
            ),
          ),
        );
      },
    );
  }

  static Widget _check(bool on) =>
      SizedBox(width: 24, child: on ? const Icon(Icons.check, size: 18, color: Kc.green) : null);

  static PopupMenuItem<String> _item(String name, bool on) => PopupMenuItem(
    value: 'use:$name',
    child: Row(children: [_check(on), Text(name)]),
  );

  Future<void> _save(BuildContext context, GuideUi ui) async {
    final c = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Save this layout'),
        content: SizedBox(
          width: 320,
          child: TextField(
            controller: c,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'Name'),
            onSubmitted: (v) => Navigator.pop(d, v),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(d, c.text), child: const Text('Save')),
        ],
      ),
    );
    if (name == null || !context.mounted) return;
    final why = ui.saveLayout(name);
    if (why != null) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(why)));
  }

  Future<void> _delete(BuildContext context, GuideUi ui, String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('Delete the layout $name?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true) ui.deleteLayout(name);
  }
}

/// The Guide's mic level, after the voice chain, and the gate's light.
class MicMeter extends StatelessWidget {
  final HiveSightGuide g;
  final double width;
  const MicMeter(this.g, {super.key, this.width = 80});

  @override
  Widget build(BuildContext context) {
    final level = ((g.outDb + 60) / 60).clamp(0.0, 1.0);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.circle,
          size: 10,
          color: g.gateOpen ? Kc.green : Kc.off,
          semanticLabel: g.gateOpen ? 'Gate open' : 'Gate closed',
        ),
        const SizedBox(width: 6),
        SizedBox(
          width: width,
          height: 10,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(5),
            child: LinearProgressIndicator(
              value: level,
              backgroundColor: Kc.off,
              color: level > 0.9 ? Kc.softRed : Kc.green,
            ),
          ),
        ),
      ],
    );
  }
}
