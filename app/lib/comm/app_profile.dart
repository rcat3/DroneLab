/// Which of the app's profiles this is, and where its files are kept.
///
/// On Linux, `dronelab --profile NAME` runs the app as another person beside
/// the usual one: its own identity, settings, conversations and recordings,
/// as if on another phone. The window (linux/runner) takes it as part of the
/// application id, io.github.rcat3.dronelab.profile_NAME, which the app's
/// own folder (`~/.local/share/ID`) is named for, so settings and the
/// identity's seed, kept there, are its own without more. Elsewhere there's
/// only the one.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// A profile's name: letters, digits and _, as the runner checks it (what
/// an application id's part can be).
final profileName = RegExp(r'^[A-Za-z0-9_]{1,32}$');

class AppProfile {
  /// The profile's name; null for the usual one.
  static String? name;

  /// Takes it from the app's arguments (`--profile NAME` or
  /// `--profile=NAME`; "default" is the usual one).
  static void init(List<String> args) {
    if (!Platform.isLinux) return;
    for (var i = 0; i < args.length; i++) {
      String? v;
      if (args[i] == '--profile' && i + 1 < args.length) {
        v = args[i + 1];
      } else if (args[i].startsWith('--profile=')) {
        v = args[i].substring('--profile='.length);
      }
      if (v != null && v != 'default' && profileName.hasMatch(v)) name = v;
    }
  }

  /// Added to names that are the profile's own, like its developer socket.
  static String get suffix => name == null ? '' : '-$name';

  static Future<Directory>? _files;

  /// Where conversations, photos and recordings are kept: the app's own
  /// documents folder on a phone; on Linux the profile's folder, as the
  /// documents folder there is the user's own ~/Documents.
  static Future<Directory> files() => _files ??= _findFiles();

  static Future<Directory> _findFiles() async {
    if (!Platform.isLinux && !Platform.isWindows) return getApplicationDocumentsDirectory();
    final dir = await getApplicationSupportDirectory();
    if (name == null && Platform.isLinux) await _moveFromDocuments(dir);
    return dir;
  }

  /// What the usual profile kept in ~/Documents before, moved to [to] once.
  static Future<void> _moveFromDocuments(Directory to) async {
    Directory docs;
    try {
      docs = await getApplicationDocumentsDirectory();
    } catch (_) {
      return;
    }
    if (docs.path == to.path) return;
    for (final n in const ['conversations.json', 'photos', 'Recordings']) {
      final from = '${docs.path}/$n', dest = '${to.path}/$n';
      try {
        final type = await FileSystemEntity.type(from, followLinks: false);
        if (type == FileSystemEntityType.notFound) continue;
        if (await FileSystemEntity.type(dest, followLinks: false) != FileSystemEntityType.notFound) continue;
        if (type == FileSystemEntityType.file) {
          await _moveFile(File(from), dest);
        } else if (type == FileSystemEntityType.directory) {
          await _moveDirectory(Directory(from), dest);
        }
      } catch (e) {
        debugPrint('profile: $n not moved: $e');
      }
    }
  }

  /// Renamed, or copied where it can't be (another file system): then the
  /// old one's left where it was.
  static Future<void> _moveFile(File f, String dest) async {
    try {
      await f.rename(dest);
    } on FileSystemException {
      await f.copy(dest);
    }
  }

  static Future<void> _moveDirectory(Directory d, String dest) async {
    try {
      await d.rename(dest);
    } on FileSystemException {
      final out = await Directory('$dest.new').create(recursive: true);
      await for (final e in d.list(followLinks: false)) {
        if (e is File) await e.copy('${out.path}/${e.uri.pathSegments.last}');
      }
      await out.rename(dest);
    }
  }
}
