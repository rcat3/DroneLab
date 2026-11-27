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
        final name = Platform.isWindows ? 'dronelab-unit.exe' : 'dronelab-unit';
        final f = File('${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}$name');
        if (f.existsSync()) _program = f.path;
      }
    }
    return _program;
  }

  /// Whether the app can start a virtual unit.
  static bool get available => program != null;

  /// The id of virtual unit [unit].
  static String idFor(int unit) => '$socketIdPrefix$unit';

  /// Which unit [id] is, if it's one the app could start.
  static int? unitAt(String id) {
    final n = socketUnitNumber(id);
    return n != null && n <= 99 ? n : null;
  }

  /// The first unit that isn't running: the one a new one would be.
  static Future<int> nextFree() async {
    final running = (await SocketTransport.listening()).map((e) => e.unit).toSet();
    var n = 1;
    while (running.contains(n) && n < 99) {
      n++;
    }
    return n;
  }

  /// Start unit [unit]: false if it couldn't be. It's listening a moment later.
  static Future<bool> start(int unit) async {
    final prog = program;
    if (prog == null) return false;
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
