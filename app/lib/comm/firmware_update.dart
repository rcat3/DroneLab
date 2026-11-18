import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'board_link.dart';
import 'board_protocol.dart';

/// The firmware the app carries, to keep the board in step with it
/// (assets/firmware/, put there by tools/release/bundle_firmware.sh when the
/// app's built for a release). A build without it can't update boards.
class BundledFirmware {
  final String version;   // as the board says it (rcat_hal_firmware_version), like "v0.9.7"
  final String board;     // the board it's for (RCAT_BOARD_NAME)
  final int size;
  const BundledFirmware(this.version, this.board, this.size);

  static const _dir = 'assets/firmware';

  /// What's bundled, or null if nothing is.
  static Future<BundledFirmware?> load() async {
    try {
      final j = jsonDecode(await rootBundle.loadString('$_dir/firmware.json')) as Map<String, dynamic>;
      return BundledFirmware(j['version'] as String, j['board'] as String, (j['size'] as num).toInt());
    } catch (_) {
      return null;
    }
  }

  /// The firmware itself: only read when it's needed, as it's several MB.
  Future<Uint8List> bytes() async {
    final data = await rootBundle.load('$_dir/firmware.bin');
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }
}

/// A firmware version's release number, like (0, 9, 7) from "v0.9.7" or
/// "v0.9.7-3-gabc123-dirty", or null if it hasn't one.
(int, int, int)? releaseOf(String? version) {
  final m = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)').firstMatch(version ?? '');
  if (m == null) return null;
  return (int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
}

/// Below 0 if [a] is an older release than [b], 0 the same, above 0 newer.
int compareReleases((int, int, int) a, (int, int, int) b) =>
    a.$1 != b.$1 ? a.$1 - b.$1 : a.$2 != b.$2 ? a.$2 - b.$2 : a.$3 - b.$3;

enum UpdateState { idle, sending, finishing, installing, done, failed }

/// Sends the bundled firmware to the board (commVersion 7, message 0x0E): a
/// few pieces at a time, each few acked, carrying on from wherever the board
/// says it's got to. The board checks it, and restarts into it.
class FirmwareUpdate extends ChangeNotifier {
  final BoardLink board;
  FirmwareUpdate(this.board);

  static const _ackTimeout = Duration(seconds: 5);
  static const _finishTimeout = Duration(seconds: 20);  // the board checks the whole image
  static const _installTimeout = Duration(minutes: 3);  // writing it, restarting, and reconnecting
  static const _maxStalls = 6;  // acks missed in a row before giving up
  // A write that won't go is tried again soon, for up to 2 s: Android's
  // queue can be busy a while, with other links
  static const _writeTries = 1000;
  static const _writeWait = Duration(milliseconds: 2);

  UpdateState state = UpdateState.idle;
  double progress = 0;
  String? problem;

  bool get busy => state == UpdateState.sending || state == UpdateState.finishing || state == UpdateState.installing;

  Future<void> run(BundledFirmware firmware) async {
    if (busy) return;
    state = UpdateState.sending;
    progress = 0;
    problem = null;
    notifyListeners();
    try {
      final bin = await firmware.bytes();
      var ack = await _send(updateStartMessage(bin.length, firmware.board, firmware.version), _ackTimeout, reliable: true);
      if (ack == null || !ack.ok) throw _Failed(ack == null ? 'The unit didn\'t answer' : updateProblem(ack.result));
      final piece = board.maxWrite - 6;
      // Pieces between acks: well within what the board keeps, so none's dropped
      final window = board.msgQueue >= 64 ? 40 : 12;
      var offset = 0;
      var stalls = 0;
      while (offset < bin.length) {
        _check();
        // A few pieces, the last asking for an ack
        var at = offset;
        for (var i = 0; i < window && at < bin.length; i++) {
          final end = (at + piece).clamp(0, bin.length);
          final last = i == window - 1 || end == bin.length;
          final msg = updateDataMessage(at, Uint8List.sublistView(bin, at, end), ack: last);
          if (last) {
            ack = await _send(msg, _ackTimeout);
          } else if (!await board.sendFast(msg, tries: _writeTries, wait: _writeWait)) {
            _check();
            throw _Failed("The phone couldn't keep sending to the unit");
          }
          at = end;
        }
        if (ack == null) {
          if (++stalls >= _maxStalls) throw _Failed('The unit stopped answering');
          continue;   // send the last few again, from where it was
        }
        if (!ack.ok) throw _Failed(updateProblem(ack.result));
        stalls = ack.received > offset ? 0 : stalls + 1;
        if (stalls >= _maxStalls) throw _Failed('The update isn\'t getting through');
        offset = ack.received;   // carry on from wherever the board's got to
        progress = offset / bin.length;
        notifyListeners();
      }
      state = UpdateState.finishing;
      notifyListeners();
      ack = await _send(updateEndMessage(), _finishTimeout, reliable: true);
      if (ack == null) throw _Failed('The unit didn\'t say whether it worked');
      if (!ack.ok) throw _Failed(updateProblem(ack.result));
      progress = 1;
      if (ack.installing) {
        // It's all there: the board writes it to flash, which can drop the
        // link, then restarts into it. Done once it's back with it.
        state = UpdateState.installing;
        notifyListeners();
        await _installed(firmware.version);
      }
      state = UpdateState.done;
    } on _Failed catch (e) {
      problem = e.why;
      state = UpdateState.failed;
    } catch (_) {
      problem = 'The unit went out of range';
      state = UpdateState.failed;
    }
    notifyListeners();
  }

  /// Wait for the board to come back with [version], or say why it won't.
  Future<void> _installed(String version) async {
    UpdateAck? failed;
    final sub = board.updateAcks.listen((a) {
      if (a.done && !a.ok) failed = a;
    });
    try {
      final end = DateTime.now().add(_installTimeout);
      while (DateTime.now().isBefore(end)) {
        final f = failed;
        if (f != null) throw _Failed(updateProblem(f.result));
        if (board.state == BoardState.connected && board.firmware == version) return;
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      throw _Failed("The unit didn't come back with the new firmware. Check its version in Setup");
    } finally {
      await sub.cancel();
    }
  }

  void reset() {
    if (busy) return;
    state = UpdateState.idle;
    problem = null;
    notifyListeners();
  }

  void _check() {
    if (board.state != BoardState.connected) throw _Failed('The unit went out of range');
  }

  /// Send [msg] and wait for the board's next ack, or null if none comes.
  Future<UpdateAck?> _send(Uint8List msg, Duration timeout, {bool reliable = false}) async {
    _check();
    // Listen before it goes, so a quick ack isn't missed. No ack in time
    // (or the stream closing) is null, handled now, so a slow send can't
    // leave the timeout unhandled.
    final next = board.updateAcks.first.timeout(timeout).then<UpdateAck?>((a) => a, onError: (_) => null);
    if (reliable) {
      await board.send(msg);
    } else if (!await board.sendFast(msg, tries: _writeTries, wait: _writeWait)) {
      _check();
      throw _Failed("The phone couldn't keep sending to the unit");
    }
    return next;
  }
}

class _Failed implements Exception {
  final String why;
  _Failed(this.why);
}
