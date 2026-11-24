import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../comm/board_protocol.dart';
import '../comm/built_in_pictures.dart';
import '../comm/comm_controller.dart';
import '../comm/conversations.dart';
import 'avatar_crop.dart';
import 'theme.dart';
import 'widgets.dart';

/// HiveMind Control's Display: words for their displays' Terminals, as our
/// own Terminal takes them (a letter size, added on a line or in place of
/// what's there), or a picture; each switched to, for a while or until they
/// move on; and clearing what we put there. Kept for next time while the
/// app runs.
int _size = 0;
bool _append = true;
bool _pictures = false;     // the Picture tab, not Text
int _howLong = _durations.length - 1;
BuiltInPicture? _builtIn;

/// How long it stays on their screen, the slider's stops: seconds, 0 for
/// until they move on.
const _durations = [5, 10, 15, 30, 60, 120, 300, 0];

String _durationLabel(int seconds) => seconds == 0
    ? 'Until they move on'
    : seconds < 60
        ? '$seconds s'
        : '${seconds ~/ 60} min';

Future<void> showDisplaySheet(BuildContext context, CommController comm, Conversation c) {
  final text = TextEditingController();
  Uint8List? own;           // a picture of ours, picked
  DisplayCrop? crop;        // the part of it to fill their display with; null to fit it whole
  var cropping = false;
  var sending = false;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheet) => StatefulBuilder(
      builder: (sheet, setState) {
        const sizes = ['AUTO', '8', '16', '24', '32', '40', '48'];
        final seconds = _durations[_howLong];
        final canOwn = comm.canSendPhoto(c);
        final messenger = ScaffoldMessenger.of(context);

        void sendWords() {
          final t = text.text.trim();
          if (t.isEmpty) return;
          comm.sendCommandTo(c, comm.newCommand(OthersCommand.words(t, append: _append, size: _size, seconds: seconds)));
          Navigator.pop(sheet);
        }

        Future<void> sendPicture() async {
          if (own != null) {
            setState(() => sending = true);
            final why = await comm.sendDisplayPicture(c, crop?.picture ?? own!, seconds);
            if (!sheet.mounted) return;
            setState(() => sending = false);
            if (why != null) {
              messenger.showSnackBar(SnackBar(content: Text(why)));
              return;
            }
          } else if (_builtIn != null) {
            comm.sendCommandTo(c, comm.newCommand(OthersCommand.showPicture(builtIn: _builtIn!.name, seconds: seconds)));
          } else {
            return;
          }
          if (sheet.mounted) Navigator.pop(sheet);
        }

        // A GIF goes as it is, to play: not cropped
        bool isGif(Uint8List b) => b.length > 3 && b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46;

        Future<void> cropOwn() async {
          final picture = own;
          if (picture == null || cropping) return;
          setState(() => cropping = true);
          try {
            final got = await cropForDisplay(sheet, picture, area: crop?.area, onFit: () => crop = null);
            if (got != null && own == picture) crop = got;
          } on FormatException {
            messenger.showSnackBar(const SnackBar(content: Text("That isn't a picture")));
          } finally {
            if (sheet.mounted) setState(() => cropping = false);
          }
        }

        Future<void> pickOwn(ImageSource source) async {
          final file = await ImagePicker().pickImage(source: source, requestFullMetadata: false);
          if (file == null) return;
          final bytes = await file.readAsBytes();
          setState(() {
            own = bytes;
            crop = null;
            _builtIn = null;
          });
          if (!isGif(bytes)) await cropOwn();
        }

        Widget thumb({required Widget child, required bool selected, required VoidCallback? onTap, String? label}) =>
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Semantics(
                label: label,
                selected: selected,
                button: true,
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: onTap,
                  child: Container(
                    width: 64,
                    height: 64,
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                        shape: BoxShape.circle, border: Border.all(color: selected ? Kc.pink : Kc.line, width: 2)),
                    child: ClipOval(child: ColoredBox(color: Colors.black, child: child)),
                  ),
                ),
              ),
            );

        final words = [
          Row(children: [
            Expanded(
              child: TextField(
                controller: text,
                autofocus: true,
                maxLength: OthersCommand.messageMax,
                minLines: 1,
                maxLines: 3,
                textCapitalization: TextCapitalization.characters,
                style: Kc.term(16, color: Kc.green),
                decoration: const InputDecoration(hintText: 'TYPE A MESSAGE', counterText: '', isDense: true),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              tooltip: 'Send',
              icon: const Icon(Icons.send),
              style: IconButton.styleFrom(backgroundColor: Kc.pink, foregroundColor: Kc.bg),
              onPressed: sendWords,
            ),
          ]),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              const Icon(Icons.format_size, color: Kc.muted, semanticLabel: 'Letter size'),
              for (var i = 0; i < sizes.length; i++)
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: ChoiceChip(
                    label: Text(sizes[i]),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    labelPadding: EdgeInsets.zero,
                    selected: _size == i,
                    onSelected: (_) => setState(() => _size = i),
                  ),
                ),
            ]),
          ),
          const SizedBox(height: 8),
          SegmentedButton<bool>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: true, label: Text('ADD A LINE')),
              ButtonSegment(value: false, label: Text('REPLACE')),
            ],
            selected: {_append},
            onSelectionChanged: (sel) => setState(() => _append = sel.first),
          ),
        ];

        final picture = [
          SizedBox(
            height: 68,
            child: ListView(scrollDirection: Axis.horizontal, children: [
              thumb(
                label: 'A picture of yours',
                selected: own != null,
                onTap: canOwn
                    ? () async {
                        final source = await showModalBottomSheet<ImageSource>(
                          context: sheet,
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
                        if (source != null) await pickOwn(source);
                      }
                    : null,
                child: own != null
                    ? Image.memory(crop?.picture ?? own!,
                        fit: crop != null ? BoxFit.cover : BoxFit.contain, gaplessPlayback: true)
                    : Icon(Icons.add_photo_alternate_outlined, color: canOwn ? Kc.pink : Kc.muted),
              ),
              for (final b in builtInPictures)
                thumb(
                  label: b.name,
                  selected: own == null && _builtIn == b,
                  onTap: () => setState(() {
                    _builtIn = b;
                    own = null;
                  }),
                  child: Image.asset(b.thumbnail, fit: BoxFit.contain),
                ),
            ]),
          ),
          const SizedBox(height: 4),
          const Text(
              'Custom pictures can only be sent via the cloud server.  Only built-in pictures can be displayed via '
              'direct mode.',
              style: TextStyle(color: Kc.muted, fontSize: 12)),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: Text(
                  own != null
                      ? crop != null
                          ? 'Your picture, cropped'
                          : 'Your picture, whole'
                      : _builtIn?.name ?? 'Pick a picture',
                  style: TextStyle(color: own != null || _builtIn != null ? Kc.text : Kc.muted)),
            ),
            if (own != null && !isGif(own!)) ...[
              IconButton(
                tooltip: 'Crop',
                icon: const Icon(Icons.crop),
                onPressed: cropping || sending ? null : cropOwn,
              ),
              if (crop != null)
                IconButton(
                  tooltip: 'Fit whole picture',
                  icon: const Icon(Icons.fit_screen_outlined),
                  onPressed: sending ? null : () => setState(() => crop = null),
                ),
            ],
            sending
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)))
                : IconButton.filled(
                    tooltip: 'Send',
                    icon: const Icon(Icons.send),
                    style: IconButton.styleFrom(backgroundColor: Kc.pink, foregroundColor: Kc.bg),
                    onPressed: own != null || _builtIn != null ? sendPicture : null,
                  ),
          ]),
        ];

        // Compact, with Send beside the words, so it all fits over the keyboard
        return Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 8 + MediaQuery.viewInsetsOf(sheet).bottom),
          child: SafeArea(
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const SectionHeader('Their display'),
                Text(
                    'Send ${_pictures ? 'a picture' : 'text'} to be shown on '
                    "${c.kind == ConversationKind.person ? "${c.title}'s display" : 'the displays of ${c.audience}'}, "
                    'if allowed by their permissions.  It will be visible to other people.',
                    style: const TextStyle(color: Kc.muted, fontSize: 13)),
                const SizedBox(height: 10),
                SegmentedButton<bool>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: false, label: Text('TEXT'), icon: Icon(Icons.terminal)),
                    ButtonSegment(value: true, label: Text('PICTURE'), icon: Icon(Icons.image_outlined)),
                  ],
                  selected: {_pictures},
                  onSelectionChanged: (sel) => setState(() => _pictures = sel.first),
                ),
                const SizedBox(height: 10),
                ...(_pictures ? picture : words),
                const SizedBox(height: 4),
                Row(children: [
                  const Icon(Icons.timer_outlined, color: Kc.muted, size: 20),
                  const SizedBox(width: 8),
                  Text('On screen: ${_durationLabel(seconds)}'),
                ]),
                Slider(
                  value: _howLong.toDouble(),
                  min: 0,
                  max: (_durations.length - 1).toDouble(),
                  divisions: _durations.length - 1,
                  label: _durationLabel(seconds),
                  semanticFormatterCallback: (v) => _durationLabel(_durations[v.round()]),
                  onChanged: (v) => setState(() => _howLong = v.round()),
                ),
                Text(
                    seconds == 0
                        ? 'It stays until they swipe away.'
                        : 'Then their display goes back to what it was showing, unless they swipe away first.',
                    style: const TextStyle(color: Kc.muted, fontSize: 12)),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    icon: const Icon(Icons.clear_all),
                    label: const Text('Clear their display'),
                    onPressed: () {
                      comm.sendCommandTo(c, comm.newCommand(OthersCommand.clearDisplay()));
                      Navigator.pop(sheet);
                    },
                  ),
                ),
              ]),
            ),
          ),
        );
      },
    ),
  );
}
