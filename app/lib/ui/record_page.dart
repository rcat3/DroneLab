import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../comm/board_link.dart';
import '../comm/comm_controller.dart';
import '../comm/recorder.dart';

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
        final scheme = Theme.of(context).colorScheme;
        final connected = comm.board.state == BoardState.connected;
        final rec = comm.recording;
        return Scaffold(
          appBar: AppBar(title: const Text('Record')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                  'Records the board\'s voice to a file on this phone, for videos and the like. '
                  'Comms stop while it records, and start again after.',
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 16),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: true, label: Text('Speaker voice'), icon: Icon(Icons.campaign)),
                  ButtonSegment(value: false, label: Text('Comm voice'), icon: Icon(Icons.headset_mic)),
                ],
                selected: {comm.recordSpeakerVoice},
                onSelectionChanged: rec ? null : (sel) => comm.setRecordOptions(speakerVoice: sel.first),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Sync beep to start'),
                subtitle: const Text('The board beeps, and the same beep is in the recording, '
                    'to line it up with video'),
                value: comm.recordBeep,
                onChanged: rec ? null : (on) => comm.setRecordOptions(beep: on),
              ),
              const SizedBox(height: 16),
              Center(
                child: GestureDetector(
                  onTap: connected || rec ? _toggle : null,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    width: 140,
                    height: 140,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: !connected && !rec
                          ? scheme.surfaceContainerHighest
                          : rec
                              ? scheme.error
                              : scheme.errorContainer,
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(rec ? Icons.stop : Icons.fiber_manual_record,
                            size: 48, color: rec ? scheme.onError : scheme.onErrorContainer),
                        Text(rec ? _time(comm.recordingLength) : 'Record',
                            style: TextStyle(
                                fontWeight: FontWeight.bold, color: rec ? scheme.onError : scheme.onErrorContainer)),
                      ],
                    ),
                  ),
                ),
              ),
              if (!connected && !rec)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text('Connect to the board on the Comm tab first', textAlign: TextAlign.center),
                ),
              const SizedBox(height: 24),
              Text('Recordings', style: Theme.of(context).textTheme.titleMedium),
              if (comm.recordings.isEmpty) const ListTile(title: Text('None yet')),
              for (final r in comm.recordings)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: IconButton(
                    tooltip: comm.playing?.path == r.file.path ? 'Stop' : 'Play',
                    icon: Icon(comm.playing?.path == r.file.path ? Icons.stop_circle : Icons.play_circle),
                    onPressed: () => comm.playing?.path == r.file.path ? comm.stopPlaying() : comm.play(r),
                  ),
                  title: Text(r.name),
                  subtitle: Text(_time(r.length)),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Share',
                        icon: const Icon(Icons.share),
                        onPressed: () => SharePlus.instance.share(ShareParams(files: [XFile(r.file.path)])),
                      ),
                      IconButton(
                        tooltip: 'Delete',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _delete(context, r),
                      ),
                    ],
                  ),
                ),
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
