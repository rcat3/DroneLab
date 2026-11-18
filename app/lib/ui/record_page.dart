import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../comm/board_link.dart';
import '../comm/comm_controller.dart';
import '../comm/recorder.dart';
import 'theme.dart';
import 'widgets.dart';

/// Recording the board's voice effect to files on the phone, to share: for
/// videos and the like. Comms stop while it records.
class RecordPage extends StatefulWidget {
  final CommController comm;
  const RecordPage({super.key, required this.comm});

  @override
  State<RecordPage> createState() => _RecordPageState();
}

class _RecordPageState extends State<RecordPage> {
  CommController get comm => widget.comm;

  @override
  void initState() {
    super.initState();
    comm.loadRecordings();
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

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: comm,
      builder: (context, _) {
        final connected = comm.board.state == BoardState.connected;
        final rec = comm.recording;
        final fg = rec ? Colors.white : connected ? Kc.softRed : Kc.off;
        return Scaffold(
          appBar: AppBar(title: const Text('Record')),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: true, label: Text('SPEAKER VOICE')),
                  ButtonSegment(value: false, label: Text('HIVEMIND VOICE')),
                ],
                selected: {comm.recordSpeakerVoice},
                onSelectionChanged: rec ? null : (sel) => comm.setRecordOptions(speakerVoice: sel.first),
              ),
              const SizedBox(height: 12),
              Panel(children: [
                Explained(
                  help: 'The board beeps, and the same beep is in the file, to line it up with video.',
                  builder: (context, info) => PanelRow(
                    title: 'Sync beep to start',
                    trailing: [
                      info,
                      Switch(value: comm.recordBeep, onChanged: rec ? null : (on) => comm.setRecordOptions(beep: on)),
                    ],
                  ),
                ),
              ]),
              const SizedBox(height: 20),
              Center(
                child: Semantics(
                  button: true,
                  enabled: connected || rec,
                  label: rec ? 'Stop recording, ${_time(comm.recordingLength)}' : 'Record',
                  excludeSemantics: true,
                  child: GestureDetector(
                    onTap: connected || rec ? _toggle : null,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      width: 140,
                      height: 140,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: rec ? Kc.red : Kc.panel,
                        border: Border.all(color: connected || rec ? Kc.red : Kc.line, width: 2),
                        boxShadow: rec ? [BoxShadow(color: Kc.red.withValues(alpha: 0.6), blurRadius: 40)] : null,
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(rec ? Icons.stop_rounded : Icons.fiber_manual_record, size: 44, color: fg),
                          const SizedBox(height: 4),
                          Text(rec ? _time(comm.recordingLength) : 'RECORD', style: Kc.term(16, color: fg)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(connected || rec ? 'HiveMind pauses while it records' : 'Connect to the board first',
                  textAlign: TextAlign.center, style: const TextStyle(color: Kc.muted, fontSize: 13)),
              const SectionHeader('Recordings'),
              Panel(children: [
                if (comm.recordings.isEmpty) const PanelRow(title: 'None yet'),
                for (final r in comm.recordings)
                  PanelRow(
                    leading: IconButton(
                      tooltip: comm.playing?.path == r.file.path ? 'Stop' : 'Play',
                      color: Kc.pink,
                      icon: Icon(comm.playing?.path == r.file.path ? Icons.stop_circle : Icons.play_circle),
                      onPressed: () => comm.playing?.path == r.file.path ? comm.stopPlaying() : comm.play(r),
                    ),
                    title: r.name,
                    subtitle: _time(r.length),
                    trailing: [
                      IconButton(
                        tooltip: 'Share',
                        color: Kc.muted,
                        icon: const Icon(Icons.share),
                        onPressed: () => SharePlus.instance.share(ShareParams(files: [XFile(r.file.path)])),
                      ),
                      IconButton(
                        tooltip: 'Delete',
                        color: Kc.muted,
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _delete(context, r),
                      ),
                    ],
                  ),
              ]),
            ],
          ),
        );
      },
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
