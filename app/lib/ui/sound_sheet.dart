import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../comm/board_protocol.dart' show soundMaxMs;
import '../comm/capabilities.dart';
import '../comm/comm_controller.dart';
import '../comm/conversations.dart';
import '../comm/recorder.dart';
import '../comm/sent_sounds.dart';
import 'capabilities_ui.dart' show canControl;
import 'people.dart';
import 'theme.dart';
import 'widgets.dart';

/// HiveMind Control's Sounds: a sound played from their units' speakers, at
/// their volume, once, and kept on their unit to play again: one of our
/// recordings (the Record tab's, with our voice effect), or a sound file.
/// Over the server only.
Future<void> showSoundSheet(BuildContext context, CommController comm, Conversation c) {
  Recording? recording;
  XFile? file;
  SentSound? fileSound;     // the file, made ready to send, once it's checked
  String? problem;          // why the last one picked or sent can't go
  var sending = false;
  comm.loadRecordings();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheet) => ListenableBuilder(
      listenable: comm,
      builder: (sheet, _) => StatefulBuilder(
        builder: (sheet, setState) {
          final canSend = comm.canSendPhoto(c);
          const longest = Duration(milliseconds: soundMaxMs);

          Future<void> pickFile() async {
            const sounds = XTypeGroup(
              label: 'Sounds',
              extensions: ['wav', 'mp3', 'flac'],
              mimeTypes: ['audio/wav', 'audio/x-wav', 'audio/mpeg', 'audio/flac', 'audio/x-flac'],
              uniformTypeIdentifiers: ['public.audio'],
            );
            final XFile? got;
            try {
              got = await openFile(acceptedTypeGroups: [sounds]);
            } catch (e) {
              setState(() => problem = "Couldn't open a file: $e");
              return;
            }
            if (got == null || !sheet.mounted) return;
            // Checked straight away, so it says now if it won't go
            setState(() {
              file = got;
              fileSound = null;
              recording = null;
              problem = null;
              sending = true;
            });
            String? why;
            try {
              final (sound, whyNot) = await soundFor(await got.readAsBytes(), maxBytes: comm.soundRoom);
              if (file == got) fileSound = sound;
              why = whyNot;
            } catch (e) {
              why = "Couldn't read that file: $e";
            }
            if (!sheet.mounted) return;
            setState(() {
              sending = false;
              if (file == got) problem = why;
            });
          }

          Future<void> send() async {
            setState(() {
              sending = true;
              problem = null;
            });
            String? why;
            try {
              var sound = recording == null ? fileSound : null;
              if (recording != null) {
                final (made, whyNot) =
                    await soundFor(Uint8List.fromList(await recording!.file.readAsBytes()), maxBytes: comm.soundRoom);
                sound = made;
                why = whyNot;
              }
              if (sound != null) why = await comm.sendSound(c, sound);
            } catch (e) {
              why = "Couldn't send it: $e";
            }
            if (!sheet.mounted) return;
            setState(() {
              sending = false;
              problem = why;
            });
            if (why == null) Navigator.pop(sheet);
          }

          String time(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

          Widget choice({
            required bool selected,
            required bool enabled,
            required String title,
            String? subtitle,
            Widget? leading,
            required VoidCallback onTap,
          }) =>
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                enabled: enabled,
                leading: leading,
                title: Text(title),
                subtitle: subtitle == null ? null : Text(subtitle),
                trailing: Icon(selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                    color: selected ? Kc.pink : Kc.muted),
                onTap: enabled ? onTap : null,
              );

          return Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8 + MediaQuery.viewInsetsOf(sheet).bottom),
            child: SafeArea(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const SectionHeader('Their speaker'),
                Text(
                    'Send a sound to be played from '
                    "${c.kind == ConversationKind.person ? "${c.title}'s unit" : 'the units of ${c.audience}'}, "
                    'if allowed by their permissions.  It plays once, at their volume, for 10 seconds at most, '
                    'and is kept on their unit.  Sounds can only be sent via the cloud server.',
                    style: const TextStyle(color: Kc.muted, fontSize: 13)),
                const SizedBox(height: 8),
                Flexible(
                  child: ListView(shrinkWrap: true, children: [
                    for (final r in comm.recordings)
                      choice(
                        selected: recording?.file.path == r.file.path,
                        enabled: r.length <= longest,
                        title: r.name,
                        subtitle: r.length <= longest ? time(r.length) : '${time(r.length)}, longer than 10 s',
                        leading: IconButton(
                          tooltip: comm.playing?.path == r.file.path ? 'Stop' : 'Play',
                          color: Kc.pink,
                          icon: Icon(comm.playing?.path == r.file.path ? Icons.stop_circle : Icons.play_circle),
                          onPressed: () => comm.playing?.path == r.file.path ? comm.stopPlaying() : comm.play(r),
                        ),
                        onTap: () => setState(() {
                          recording = r;
                          file = null;
                          fileSound = null;
                          problem = null;
                        }),
                      ),
                    if (comm.recordings.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Text('No recordings yet: make one in the Record tab, with Stop at 10 seconds on.',
                            style: TextStyle(color: Kc.muted, fontSize: 13)),
                      ),
                    choice(
                      selected: file != null,
                      enabled: true,
                      title: file?.name ?? 'A sound file',
                      subtitle: 'WAV, MP3 or FLAC',
                      leading: const Padding(
                        padding: EdgeInsets.all(8),
                        child: Icon(Icons.audio_file_outlined, color: Kc.pink),
                      ),
                      onTap: pickFile,
                    ),
                  ]),
                ),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(
                    child: Text(problem ?? (canSend ? '' : 'Not on the server just now'),
                        style: TextStyle(color: problem != null ? Kc.softRed : Kc.muted, fontSize: 13)),
                  ),
                  sending
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)))
                      : IconButton.filled(
                          tooltip: 'Send',
                          icon: const Icon(Icons.send),
                          style: IconButton.styleFrom(backgroundColor: Kc.pink, foregroundColor: Kc.bg),
                          onPressed: canSend && (recording != null || fileSound != null) ? send : null,
                        ),
                ]),
              ]),
            ),
          );
        },
      ),
    ),
  );
}

/// Send one of our recordings to play from someone's speaker, from the
/// Record tab: pick who, a channel or a person on the server (Sounds go
/// over the server only); those who don't let others play sounds (no
/// speaker, or Nobody) are greyed out.
Future<void> showSendRecording(BuildContext context, CommController comm, Recording r) {
  String? problem;
  Conversation? sendingTo;
  final messenger = ScaffoldMessenger.of(context);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheet) => ListenableBuilder(
      listenable: comm,
      builder: (sheet, _) => StatefulBuilder(builder: (sheet, setState) {
        final channel = comm.serverConversation;
        final people = [for (final p in peopleOnce(comm)) if (p.onServer) p]
          ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

        Future<void> send(Conversation c) async {
          setState(() {
            sendingTo = c;
            problem = null;
          });
          String? why;
          try {
            final (sound, whyNot) =
                await soundFor(Uint8List.fromList(await r.file.readAsBytes()), maxBytes: comm.soundRoom);
            why = sound == null ? whyNot : await comm.sendSound(c, sound);
          } catch (e) {
            why = "Couldn't send it: $e";
          }
          if (!sheet.mounted) return;
          setState(() {
            sendingTo = null;
            problem = why;
          });
          if (why == null) {
            Navigator.pop(sheet);
            messenger.showSnackBar(SnackBar(content: Text('Sent ${r.name} to ${c.audience}')));
          }
        }

        Widget target(Conversation c, {required IconData icon, required String title, String? subtitle, bool enabled = true}) =>
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              enabled: enabled && sendingTo == null,
              leading: Icon(icon, color: enabled ? Kc.pink : Kc.muted),
              title: Text(title),
              subtitle: subtitle == null ? null : Text(subtitle),
              trailing: sendingTo?.key == c.key
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : null,
              onTap: () => send(c),
            );

        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: SafeArea(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const SectionHeader('Send to their speaker'),
              Text(
                  '${r.name} plays once from their unit\'s speaker, at their volume, if allowed by their '
                  'permissions, and is kept on their unit. Over the cloud server only.',
                  style: const TextStyle(color: Kc.muted, fontSize: 13)),
              const SizedBox(height: 8),
              if (channel == null)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('Not on the server just now. It comes back once a recording ends.',
                      style: TextStyle(color: Kc.muted)),
                )
              else
                Flexible(
                  child: ListView(shrinkWrap: true, children: [
                    target(comm.everyoneConversation,
                        icon: Icons.campaign_outlined, title: 'Broadcast', subtitle: 'Everyone who can hear you'),
                    target(channel, icon: Icons.forum_outlined, title: channel.title, subtitle: 'Everyone in the channel'),
                    for (final p in people)
                      if (comm.capabilitiesOf(user: p.user, board: p.board) case final caps)
                        target(comm.personConversation(p.id),
                            icon: Icons.person_outline,
                            title: p.name,
                            subtitle: caps == null
                                ? null
                                : canControl(caps, Capabilities.sounds)
                                    ? (caps[Capabilities.sounds] == CapOpen.open ? 'Anyone can' : 'Only people they allow')
                                    : 'Not available',
                            enabled: canControl(caps, Capabilities.sounds)),
                  ]),
                ),
              if (problem != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(problem!, style: const TextStyle(color: Kc.softRed, fontSize: 13)),
                ),
            ]),
          ),
        );
      }),
    ),
  );
}
