import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../comm/board_link.dart';
import '../comm/board_protocol.dart' show soundMaxMs;
import '../comm/comm_controller.dart';
import '../comm/phone_mic.dart' show thisDevice;
import '../comm/recorder.dart';
import 'people.dart' show appTab, tabRecord;
import 'phone_mic_ui.dart';
import 'setup_page.dart';
import 'sound_sheet.dart';
import 'theme.dart';
import 'widgets.dart';

/// Recording the voice effect to files on the phone: to share, for videos
/// and the like, or to send to someone's speaker. From the mic that talks
/// (Setup's Mic, chosen here too), through the effect picked here, with the
/// unit's speaker on or off. Comms stop while it records. The record button
/// stays put at the bottom, as the Voice tab's talk button does.
class RecordPage extends StatefulWidget {
  final CommController comm;
  const RecordPage({super.key, required this.comm});

  @override
  State<RecordPage> createState() => _RecordPageState();
}

class _RecordPageState extends State<RecordPage> with WidgetsBindingObserver {
  CommController get comm => widget.comm;

  @override
  void initState() {
    super.initState();
    comm.loadRecordings();
    WidgetsBinding.instance.addObserver(this);
    appTab.addListener(_watch);
  }

  @override
  void dispose() {
    appTab.removeListener(_watch);
    WidgetsBinding.instance.removeObserver(this);
    comm.watchRecordLevel(false);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _watch();

  /// The meter's live while the tab's in front, the app too: from the mic
  /// that records, as it changes.
  void _watch() {
    final front = WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    comm.watchRecordLevel(mounted && front && appTab.value == tabRecord);
  }

  static String _time(Duration d) {
    final m = d.inMinutes, s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  Future<void> _toggle() async {
    if (comm.recording) {
      await comm.stopRecording();
      return;
    }
    final why = await comm.startRecording();
    if (why != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(why)));
    }
  }

  /// A setting's row, tight: its name, then its control.
  Widget _row(String label, Widget control, {String? help}) {
    final row = Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 12, 4),
      child: Row(children: [
        SizedBox(width: 64, child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600))),
        Expanded(child: Align(alignment: Alignment.centerRight, child: control)),
      ]),
    );
    if (help == null) return row;
    return Explained(
      help: help,
      builder: (context, info) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
        child: Row(children: [
          SizedBox(width: 64, child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600))),
          Expanded(child: Align(alignment: Alignment.centerRight, child: control)),
          info,
        ]),
      ),
    );
  }

  /// A switch with its name beside it, half a row: faded, name and all,
  /// while it can't be changed.
  Widget _toggleChip(String label, bool value, ValueChanged<bool>? onChanged) => Expanded(
        child: Opacity(
          opacity: onChanged == null ? 0.45 : 1,
          child: Row(children: [
            Flexible(child: Text(label, style: TextStyle(color: onChanged == null ? Kc.muted : Kc.text))),
            Switch(value: value, onChanged: onChanged),
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: comm,
      builder: (context, _) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _watch());     // the mic may have changed
        final rec = comm.recording;
        final boardUp = comm.board.state == BoardState.connected;
        // From the mic that talks: the phone's needs no unit
        final phone = rec ? comm.recordingFromPhone : comm.phoneMicTalks;
        final canRecord = boardUp || phone;
        final settings = boardUp ? comm.boardSettings : null;
        final speaker = boardUp && (settings?.hasSpeaker ?? false) ? comm.unitSpeakerOn : null;
        final effects = comm.recordEffects;
        final effect = comm.recordEffectShown;
        return Scaffold(
          appBar: AppBar(
            // The tab's own icon, as on the others
            title: Row(children: [
              const Icon(Icons.fiber_manual_record_outlined, color: Kc.green, size: 22),
              const SizedBox(width: 10),
              const Text('Record'),
              const Spacer(),
              if (rec) Text('REC', style: Kc.term(16, color: Kc.red, shadows: Kc.glow(Kc.red))),
            ]),
            actions: [
              IconButton(
                tooltip: 'Setup',
                icon: const Icon(Icons.settings),
                onPressed: () =>
                    Navigator.of(context).push(MaterialPageRoute(builder: (_) => SetupPage(comm: comm))),
              ),
            ],
          ),
          body: Column(children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                children: [
                  Panel(children: [
                    // The same settings as Setup's, here to hand
                    if (MicSourceRow.shown(boardUp))
                      _row('Mic', MicSourceRow(comm: comm, unitUp: boardUp, compact: true, enabled: !rec)),
                    if (speaker != null)
                      _row(
                        'Speaker',
                        Switch(value: speaker, onChanged: rec ? null : comm.setUnitSpeaker),
                        help: "The voice effect on the unit's speaker, as you hear it. Off, it can't feed back "
                            'into the mic and spoil the recording.',
                      ),
                    if (effect != null)
                      _row(
                        'Effect',
                        DropdownButton<String>(
                          value: effect,
                          isDense: true,
                          underline: const SizedBox.shrink(),
                          dropdownColor: Kc.raised,
                          onChanged: rec ? null : comm.setRecordEffect,
                          items: [for (final e in effects) DropdownMenuItem(value: e, child: Text(e))],
                        ),
                        help: "The voice effect the recording goes through. It starts as the one you're using, "
                            'and is kept for recordings after. Your own effect comes back once it stops.',
                      ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
                      child: Row(children: [
                        _toggleChip('Stop at 10 s', comm.recordForSending,
                            rec ? null : (on) => comm.setRecordOptions(forSending: on)),
                        const SizedBox(width: 8),
                        // The unit beeps it, and puts it in its own recording
                        _toggleChip('Sync beep', comm.recordBeep && !phone,
                            rec || phone ? null : (on) => comm.setRecordOptions(beep: on)),
                      ]),
                    ),
                    MicMeter(
                      comm: comm,
                      level: comm.recordLevel,
                      hint: phone
                          ? 'As it records, through the effect. Peaks in the green band are right; yellow is loud.'
                          : 'As it records, through the effect. The unit evens its level out: check it moves as '
                              'you talk.',
                    ),
                  ]),
                  const SectionHeader('Recordings'),
                  Panel(children: [
                    if (comm.recordings.isEmpty) const PanelRow(title: 'None yet'),
                    for (final r in comm.recordings) _recordingRow(context, r),
                  ]),
                  const SizedBox(height: 8),
                  const Text(
                      'Stop at 10 s makes a recording you can send to play from someone\'s speaker; the sync beep '
                      'lines a recording up with video. Mic and speaker are the same as in Setup.',
                      style: TextStyle(color: Kc.muted, fontSize: 12)),
                ],
              ),
            ),
            _dock(rec, canRecord, phone),
          ]),
        );
      },
    );
  }

  Widget _recordingRow(BuildContext context, Recording r) {
    final playing = comm.playing?.path == r.file.path;
    final sendable = r.length <= const Duration(milliseconds: soundMaxMs);
    return PanelRow(
      leading: IconButton(
        tooltip: playing ? 'Stop' : 'Play',
        color: Kc.pink,
        icon: Icon(playing ? Icons.stop_circle : Icons.play_circle),
        onPressed: () => playing ? comm.stopPlaying() : comm.play(r),
      ),
      title: r.name,
      subtitle: sendable ? _time(r.length) : '${_time(r.length)}, too long to send',
      trailing: [
        IconButton(
          tooltip: 'Send to someone\'s speaker',
          color: Kc.pink,
          icon: const Icon(Icons.volume_up_outlined),
          onPressed: sendable ? () => showSendRecording(context, comm, r) : null,
        ),
        PopupMenuButton<String>(
          tooltip: 'More',
          icon: const Icon(Icons.more_vert, color: Kc.muted),
          onSelected: (what) => what == 'share'
              ? SharePlus.instance.share(ShareParams(files: [XFile(r.file.path)]))
              : _delete(context, r),
          itemBuilder: (context) => const [
            PopupMenuItem(value: 'share', child: ListTile(leading: Icon(Icons.share), title: Text('Share'))),
            PopupMenuItem(value: 'delete', child: ListTile(leading: Icon(Icons.delete_outline), title: Text('Delete'))),
          ],
        ),
      ],
    );
  }

  /// The record button, always in reach at the bottom, with what it'll do.
  Widget _dock(bool rec, bool canRecord, bool phone) {
    final fg = rec ? Colors.white : canRecord ? Kc.softRed : Kc.off;
    final note = rec
        ? 'HiveMind Comms paused for recording.'
        : canRecord
            ? 'HiveMind Comms pause while recording.'
            : 'Connect to the board, or pick the $thisDevice\'s mic';
    // The whole width, sitting on the tab bar, which leaves room for the
    // phone's own buttons below it
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(color: Kc.dock, border: Border(top: BorderSide(color: Kc.line))),
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: MediaQuery.removePadding(
        context: context,
        removeBottom: true,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(note, textAlign: TextAlign.center, style: const TextStyle(color: Kc.muted, fontSize: 12)),
          const SizedBox(height: 4),
          Semantics(
            button: true,
            enabled: canRecord || rec,
            label: rec ? 'Stop recording, ${_time(comm.recordingLength)}' : 'Record',
            excludeSemantics: true,
            child: GestureDetector(
              onTap: canRecord || rec ? _toggle : null,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: 88,
                height: 88,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: rec ? Kc.red : Kc.panel,
                  border: Border.all(color: canRecord || rec ? Kc.red : Kc.line, width: 2),
                  boxShadow: rec ? [BoxShadow(color: Kc.red.withValues(alpha: 0.6), blurRadius: 32)] : null,
                ),
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(rec ? Icons.stop_rounded : Icons.fiber_manual_record, size: 34, color: fg),
                  Text(rec ? _time(comm.recordingLength) : 'RECORD', style: Kc.term(14, color: fg)),
                ]),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Future<void> _delete(BuildContext context, Recording r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${r.name}?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true) await comm.deleteRecording(r);
  }
}
