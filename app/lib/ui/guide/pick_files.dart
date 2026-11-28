/// Picking files and folders from anywhere on the computer (a thumb drive,
/// Downloads...), for the Source and Music tabs; the folders the sender
/// lists from are only where it looks by itself.
library;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../comm/hivesight_guide.dart';
import 'guide_widgets.dart';

const _exts = {
  'file': ['mp4', 'mkv', 'mov', 'webm', 'avi', 'm4v', 'ts', 'mts', 'm2ts', 'mpg', 'mpeg', 'wmv', 'flv', 'ogv'],
  'image': ['png', 'jpg', 'jpeg', 'webp', 'bmp', 'gif', 'tif', 'tiff'],
  'music': ['mp3', 'flac', 'ogg', 'oga', 'opus', 'wav', 'm4a', 'aac', 'wma', 'aif', 'aiff'],
};

const _names = {'file': 'Videos', 'image': 'Pictures', 'music': 'Sound'};

/// The files the Guide picks of [kind] ('file', 'image' or 'music'), remembered
/// in the lists too; empty if none.
Future<List<String>> chooseFiles(HiveSightGuide g, String kind) async {
  final list = _exts[kind]!;
  final group = XTypeGroup(label: _names[kind], extensions: [...list, ...list.map((e) => e.toUpperCase())]);
  final files = await openFiles(
    acceptedTypeGroups: [
      group,
      const XTypeGroup(label: 'Any file'),
    ],
  );
  final paths = [for (final f in files) f.path];
  if (paths.isNotEmpty) g.choose(kind, paths);
  return paths;
}

/// The folder the sender lists [kind] from, picked.
Future<void> chooseFolder(HiveSightGuide g, String kind) async {
  final dir = await getDirectoryPath(confirmButtonText: 'Use this folder');
  if (dir == null) return;
  await g.setOptions(kind == 'music' ? g.options.copyWith(musicDir: dir) : g.options.copyWith(mediaDir: dir));
}

/// "Choose files…" and "Folder…", under a list's heading.
class PickRow extends StatelessWidget {
  final HiveSightGuide g;
  final String kind;
  final void Function(List<String>) picked;
  const PickRow(this.g, this.kind, {super.key, required this.picked});

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    children: [
      OutlinedButton.icon(
        onPressed: () async {
          final p = await chooseFiles(g, kind);
          if (p.isNotEmpty) picked(p);
        },
        icon: const Icon(Icons.folder_open, size: 18),
        label: const Text('Choose files…'),
      ),
      TextButton.icon(
        onPressed: () => chooseFolder(g, kind),
        icon: const Icon(Icons.drive_folder_upload_outlined, size: 18),
        label: const Text('Use another folder…'),
      ),
    ],
  );
}

/// Where a list's own files came from, for the heading.
String folderHeading(String what, String dir, String fallback) => '$what in ${dir.isEmpty ? fallback : dir}';

const gPickHint = Text('Files picked from anywhere stay at the top of the list.', style: gSmall);
