import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../comm/board_protocol.dart';
import '../comm/card_media.dart';
import '../comm/remote_model.dart';
import '../comm/unit_storage.dart';
import 'avatar_crop.dart';
import 'theme.dart';
import 'widgets.dart';

/// Saving pictures and sounds to the unit's SD card, from the Remote's
/// Screen and Sound tabs: a row to add one, the ones on the card to look at
/// and delete, and what's on its way. The file goes in the background
/// ([UnitStorage]), so the wearer can go elsewhere meanwhile.

String _stem(String file) {
  final dot = file.lastIndexOf('.');
  return dot > 0 ? file.substring(0, dot) : file;
}

/// What's coming, and what came of the last file: nothing when there's neither.
class SaveStatus extends StatelessWidget {
  final UnitStorage saver;
  const SaveStatus({super.key, required this.saver});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: saver,
      builder: (context, _) {
        final job = saver.current;
        if (job == null && saver.lastError == null) return const SizedBox.shrink();
        if (job == null) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text("${saver.lastName ?? 'The file'} didn't get to the unit: ${saver.lastError}",
                style: const TextStyle(color: Kc.softRed, fontSize: 13)),
          );
        }
        final more = saver.waiting;
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Panel(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(
                    child: Text(
                        '${saver.paused ? 'Waiting for the voice to finish' : 'Saving'}: ${job.name}'
                        '${more > 0 ? '  (+$more)' : ''}',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                  ),
                  TextButton(onPressed: saver.cancel, child: const Text('Cancel')),
                ]),
                LinearProgressIndicator(value: saver.progress, color: Kc.green, backgroundColor: Kc.line),
                const SizedBox(height: 4),
                const Text('It carries on if you leave this page.', style: TextStyle(color: Kc.muted, fontSize: 12)),
              ]),
            ),
          ]),
        );
      },
    );
  }
}

String _space(RemoteModel m) {
  final free = m.storage['free_kb'] as int? ?? 0;
  if (free <= 0) return '';
  return free >= 1024 * 1024
      ? '${(free / (1024 * 1024)).toStringAsFixed(1)} GB free'
      : free >= 1024
          ? '${free ~/ 1024} MB free'
          : '$free KB free';
}

/// Whether to say anything: the unit's firmware has it, and it's been asked.
bool _supported(RemoteModel m) => m.storageSupported;

// ----- Pictures -----

/// Screen tab: the card's pictures, and a row to save one.
List<Widget> cardPictures(BuildContext context, RemoteModel m) {
  if (!_supported(m)) return const [];
  final saver = m.saver!;
  final pictures = m.cardPictures;
  return [
    const SectionHeader('Pictures on the SD card'),
    SaveStatus(saver: saver),
    Panel(children: [
      if (!m.cardPresent)
        const PanelRow(title: 'No SD card in the unit', subtitle: 'Put one in, and restart the unit.')
      else ...[
        PanelRow(
          title: 'Save a picture to the unit',
          subtitle: _space(m),
          leading: const Icon(Icons.add_photo_alternate_outlined, color: Kc.pink),
          onTap: () => _savePicture(context, m),
        ),
        for (final name in pictures)
          PanelRow(
            title: _stem(name),
            subtitle: name.substring(name.lastIndexOf('.') + 1).toUpperCase(),
            leading: const Icon(Icons.image_outlined, color: Kc.dim),
            onTap: () => _showPicture(m, name),
            trailing: [
              IconButton(
                tooltip: 'Delete',
                icon: const Icon(Icons.delete_outline, color: Kc.softRed),
                onPressed: () => _deleteFile(context, m, storagePicture, name),
              ),
            ],
          ),
      ],
    ]),
    const Padding(
      padding: EdgeInsets.only(top: 6),
      child: Text('Pictures saved here stay on the unit, in its Images, in order of name, even when it is off.',
          style: TextStyle(color: Kc.muted, fontSize: 12)),
    ),
  ];
}

void _showPicture(RemoteModel m, String file) {
  final stem = _stem(file).toLowerCase();
  final fs = m.features;
  for (var f = 0; f < fs.length; f++) {
    if (fs[f].$1 != 'Images') continue;
    final p = fs[f].$2.indexWhere((n) => n.toLowerCase() == stem);
    if (p >= 0) m.show(f, p);
  }
}

Future<void> _deleteFile(BuildContext context, RemoteModel m, int kind, String name) async {
  final messenger = ScaffoldMessenger.of(context);
  final yes = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text('Delete this ${kind == storagePicture ? 'picture' : 'sound'}?'),
      content: Text('"${_stem(name)}" goes from the unit\'s SD card. It is not kept anywhere else.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep')),
        TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
      ],
    ),
  );
  if (yes != true) return;
  final why = await m.deleteFromCard(kind, name);
  if (why != null) messenger.showSnackBar(SnackBar(content: Text(why)));
  if (kind == storagePicture) m.refreshScreen();
}

Future<void> _savePicture(BuildContext context, RemoteModel m) async {
  final messenger = ScaffoldMessenger.of(context);
  final source = await showModalBottomSheet<ImageSource>(
    context: context,
    builder: (pick) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(
          leading: const Icon(Icons.photo_camera_outlined),
          title: const Text('Take a photo'),
          onTap: () => Navigator.pop(pick, ImageSource.camera),
        ),
        ListTile(
          leading: const Icon(Icons.photo_library_outlined),
          title: const Text('Choose a picture'),
          onTap: () => Navigator.pop(pick, ImageSource.gallery),
        ),
      ]),
    ),
  );
  if (source == null || !context.mounted) return;
  final XFile? file;
  try {
    file = await ImagePicker().pickImage(source: source, requestFullMetadata: false);
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text("Couldn't open a picture: $e")));
    return;
  }
  if (file == null || !context.mounted) return;
  final bytes = await file.readAsBytes();
  if (!context.mounted) return;
  final gif = bytes.length > 3 && bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46;
  final stem = _stem(file.name.split('/').last).trim();
  final choice = await showDialog<_PictureChoice>(
    context: context,
    builder: (c) => _PictureDialog(bytes: bytes, gif: gif, name: stem.isEmpty ? 'picture' : stem, taken: m.cardPictures),
  );
  if (choice == null || !context.mounted) return;

  var data = bytes;
  var flatten = false;
  if (choice.crop) {
    try {
      final got = await cropForDisplay(context, bytes);
      if (got == null) return;
      data = got.picture;
      flatten = true;
    } on FormatException {
      messenger.showSnackBar(const SnackBar(content: Text("That isn't a picture")));
      return;
    }
  }
  final made = await compute(pictureForCard, (data, flatten));
  if (made.bytes == null) {
    messenger.showSnackBar(SnackBar(content: Text(made.why ?? "That picture can't be saved")));
    return;
  }
  if (!context.mounted) return;
  await _queue(context, m, storagePicture, cardFileName(choice.name, made.ext), made.bytes!, choice.showNow);
}

typedef _PictureChoice = ({String name, bool crop, bool showNow});

class _PictureDialog extends StatefulWidget {
  final Uint8List bytes;
  final bool gif;
  final String name;
  final List<String> taken;
  const _PictureDialog({required this.bytes, required this.gif, required this.name, required this.taken});

  @override
  State<_PictureDialog> createState() => _PictureDialogState();
}

class _PictureDialogState extends State<_PictureDialog> {
  late final _name = TextEditingController(text: widget.name);
  bool _crop = true;
  bool _showNow = true;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final crop = _crop && !widget.gif;
    return AlertDialog(
      title: const Text('Save a picture to the unit'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Center(
            child: SizedBox(height: 120, child: Image.memory(widget.bytes, fit: BoxFit.contain, gaplessPlayback: true)),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _name,
            maxLength: 40,
            decoration: const InputDecoration(labelText: 'Name', counterText: '', isDense: true),
          ),
          if (!widget.gif) ...[
            const SizedBox(height: 8),
            SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: true, label: Text('CROP')),
                ButtonSegment(value: false, label: Text('AS IT IS')),
              ],
              selected: {_crop},
              onSelectionChanged: (v) => setState(() => _crop = v.first),
            ),
            const SizedBox(height: 4),
            Text(
                crop
                    ? 'You pick the part that fills the display, next.'
                    : 'The whole picture, made no bigger than the display.',
                style: const TextStyle(color: Kc.muted, fontSize: 12)),
          ] else
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('A GIF is saved as it is, to play.', style: TextStyle(color: Kc.muted, fontSize: 12)),
            ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Show it when it is saved'),
            value: _showNow,
            onChanged: (v) => setState(() => _showNow = v),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        TextButton(
          onPressed: () => Navigator.pop<_PictureChoice>(
              context, (name: _name.text.trim().isEmpty ? widget.name : _name.text.trim(), crop: crop, showNow: _showNow)),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

// ----- Sounds -----

/// Sound tab: the card's sounds, and a row to save one.
List<Widget> cardSounds(BuildContext context, RemoteModel m) {
  if (!_supported(m)) return const [];
  final saver = m.saver!;
  return [
    const SectionHeader('Sounds on the SD card'),
    SaveStatus(saver: saver),
    Panel(children: [
      if (!m.cardPresent)
        const PanelRow(title: 'No SD card in the unit', subtitle: 'Put one in, and restart the unit.')
      else
        PanelRow(
          title: 'Save a sound to the unit',
          subtitle: _space(m),
          leading: const Icon(Icons.library_music_outlined, color: Kc.pink),
          onTap: () => _saveSound(context, m),
        ),
    ]),
    const Padding(
      padding: EdgeInsets.only(top: 6),
      child: Text('WAV, MP3 or FLAC, up to 3 MB. Sounds saved here are tracks in the player, after the ones already '
          'there. Delete one with the bin beside it in the list below.',
          style: TextStyle(color: Kc.muted, fontSize: 12)),
    ),
  ];
}

/// The file on the card for track [name] (shown without its extension), or
/// null if it isn't one the app can delete (a sound others sent).
String? cardSoundFor(RemoteModel m, int index) {
  if (index >= m.tracks.length - m.tracksSent) return null;
  final stem = m.tracks[index].toLowerCase();
  for (final f in m.cardSounds) {
    if (_stem(f).toLowerCase() == stem) return f;
  }
  return null;
}

Future<void> deleteCardSound(BuildContext context, RemoteModel m, String file) =>
    _deleteFile(context, m, storageSound, file);

Future<void> _saveSound(BuildContext context, RemoteModel m) async {
  final messenger = ScaffoldMessenger.of(context);
  const sounds = XTypeGroup(
    label: 'Sounds',
    extensions: ['wav', 'mp3', 'flac'],
    mimeTypes: ['audio/wav', 'audio/x-wav', 'audio/mpeg', 'audio/flac', 'audio/x-flac'],
    uniformTypeIdentifiers: ['public.audio'],
  );
  final XFile? file;
  try {
    file = await openFile(acceptedTypeGroups: [sounds]);
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text("Couldn't open a file: $e")));
    return;
  }
  if (file == null || !context.mounted) return;
  final Uint8List bytes;
  try {
    bytes = await file.readAsBytes();
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text("Couldn't read that file: $e")));
    return;
  }
  final made = await compute(soundForCard, bytes);
  if (made.bytes == null) {
    messenger.showSnackBar(SnackBar(content: Text(made.why ?? "That sound can't be saved")));
    return;
  }
  if (!context.mounted) return;
  final stem = _stem(file.name.split('/').last).trim();
  final choice = await showDialog<({String name, bool playNow})>(
    context: context,
    builder: (c) => _SoundDialog(size: made.bytes!.length, name: stem.isEmpty ? 'sound' : stem),
  );
  if (choice == null || !context.mounted) return;
  await _queue(context, m, storageSound, cardFileName(choice.name, made.ext), made.bytes!, choice.playNow);
}

class _SoundDialog extends StatefulWidget {
  final int size;
  final String name;
  const _SoundDialog({required this.size, required this.name});

  @override
  State<_SoundDialog> createState() => _SoundDialogState();
}

class _SoundDialogState extends State<_SoundDialog> {
  late final _name = TextEditingController(text: widget.name);
  bool _play = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final seconds = (widget.size / 1024 / 40).round();     // a rough 40 KB/s over the link
    return AlertDialog(
      title: const Text('Save a sound to the unit'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        TextField(
          controller: _name,
          maxLength: 40,
          decoration: const InputDecoration(labelText: 'Name', counterText: '', isDense: true),
        ),
        const SizedBox(height: 8),
        Text('${(widget.size / 1024).round()} KB: about ${seconds < 5 ? 'a few seconds' : '$seconds s'} to send.',
            style: const TextStyle(color: Kc.muted, fontSize: 12)),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Play it when it is saved'),
          value: _play,
          onChanged: (v) => setState(() => _play = v),
        ),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        TextButton(
          onPressed: () => Navigator.pop(
              context, (name: _name.text.trim().isEmpty ? widget.name : _name.text.trim(), playNow: _play)),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

// ----- Both -----

/// Queue the file, settling a name that's taken first: replace the one on the
/// card, keep both, or give up.
Future<void> _queue(BuildContext context, RemoteModel m, int kind, String name, Uint8List bytes, bool showNow) async {
  final messenger = ScaffoldMessenger.of(context);
  final saver = m.saver!;
  final isPicture = kind == storagePicture;
  // The unit won't have two pictures with a name's start in common, so those are compared without extensions
  String key(String n) => (isPicture ? _stem(n) : n).toLowerCase();
  final on = isPicture ? m.cardPictures : m.cardSounds;
  final same = on.where((n) => key(n) == key(name)).toList();
  if (same.isNotEmpty || saver.has(name)) {
    final how = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('That name is taken'),
        content: Text('The unit already has "${_stem(name)}". Replace it, or keep both?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(c, 'both'), child: const Text('Keep both')),
          TextButton(onPressed: () => Navigator.pop(c, 'replace'), child: const Text('Replace')),
        ],
      ),
    );
    if (how == null) return;
    if (how == 'replace') {
      for (final old in same) {
        final why = await m.deleteFromCard(kind, old);
        if (why != null) {
          messenger.showSnackBar(SnackBar(content: Text(why)));
          return;
        }
      }
      // The speaker's task takes a moment to let a sound's file go
      if (!isPicture) await Future<void>.delayed(const Duration(milliseconds: 600));
    } else {
      // Compared by name without the extension for pictures, as the unit does
      final ext = name.substring(name.lastIndexOf('.'));
      name = freeCardName(name, isPicture ? on.map((n) => '${_stem(n)}$ext') : on);
    }
  }
  final job = SaveJob(kind, name, bytes)..showAfter = showNow;
  saver.enqueue(job);
  messenger.showSnackBar(SnackBar(content: Text('Saving "${_stem(name)}" to the unit')));
}
