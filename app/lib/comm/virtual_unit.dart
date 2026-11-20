/// Starting a virtual unit (platforms/host's dronelab-unit) on this computer,
/// when the app wants one that isn't running. It's a program of its own, in
/// its own window, carried beside the app's: once started, it keeps going
/// until its window's closed, as a board stays on when the phone's app goes.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';

import 'board_transport.dart';

class VirtualUnits {
  static String? _program;
  static bool _looked = false;

  /// The virtual unit's program, beside the app's own (the tarball has it,
  /// and a build of the app picks up build-host's): null if there isn't one.
  static String? get program {
    if (!_looked) {
      _looked = true;
      if (socketDirectory() != null) {
        final f = File('${File(Platform.resolvedExecutable).parent.path}/dronelab-unit');
        if (f.existsSync()) _program = f.path;
      }
    }
    return _program;
  }

  /// Whether the app can start a virtual unit.
  static bool get available => program != null;

  /// The socket virtual unit [unit] listens on.
  static String? socketFor(int unit) {
    final dir = socketDirectory();
    if (dir == null) return null;
    return unit == 1 ? '$dir/dronelab-unit.sock' : '$dir/dronelab-unit-$unit.sock';
  }

  /// Which unit listens on [path]: null if it's not one the app could start.
  static int? unitAt(String path) {
    final m = RegExp(r'/dronelab-unit(?:-(\d+))?\.sock$').firstMatch(path);
    if (m == null) return null;
    final n = m.group(1) == null ? 1 : int.parse(m.group(1)!);
    return n >= 1 && n <= 99 && socketFor(n) == path ? n : null;
  }

  /// The first unit that isn't running: the one a new one would be.
  static Future<int> nextFree() async {
    final running = (await SocketTransport.listening()).map(unitAt).toSet();
    var n = 1;
    while (running.contains(n) && n < 99) {
      n++;
    }
    return n;
  }

  /// Start the unit that listens on [path]: false if it couldn't be. It's
  /// listening a moment later.
  static Future<bool> start(String path) async {
    final prog = program, unit = unitAt(path);
    if (prog == null || unit == null) return false;
    try {
      // Detached: it lives on after the app, until its window's closed
      await Process.start(prog, ['--unit', '$unit'], mode: ProcessStartMode.detached);
      return true;
    } catch (e) {
      debugPrint('virtual unit: not started $e');
      return false;
    }
  }
}
