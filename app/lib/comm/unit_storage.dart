import 'dart:async';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'board_link.dart';
import 'board_protocol.dart';

/// A picture or sound to save to the unit's SD card.
class SaveJob {
  final int kind;             // [storagePicture] or [storageSound]
  final String name;          // the file's, with its extension
  final Uint8List bytes;
  final List<int> hash;
  int sent = 0;               // how much the unit has
  bool showAfter = false;     // show the picture, or play the sound, once it's there
  SaveJob(this.kind, this.name, this.bytes) : hash = sha256.convert(bytes).bytes;

  bool get isPicture => kind == storagePicture;
}

/// Saves pictures and sounds to the unit's SD card (core/app/storage_save.h,
/// commVersion 24), one file at a time, in the background: it goes on while
/// the wearer's elsewhere in the app, with its progress and a way to cancel.
///
/// It's throttled: it waits while voice is on ([voiceBusy]: talking,
/// someone's voice, a call), so the file doesn't take the link from it, and
/// carries on after. A piece the unit left out (the ack says how far it's got)
/// is sent again from there.
class UnitStorage extends ChangeNotifier {
  final BoardLink board;
  final bool Function() voiceBusy;
  UnitStorage(this.board, {required this.voiceBusy, this.ackWait = const Duration(seconds: 6)});

  /// How long to wait for the unit's say-so before asking again.
  final Duration ackWait;

  final List<SaveJob> _queue = [];
  SaveJob? current;
  bool _running = false;
  bool _cancel = false;

  /// Waiting for voice to finish, now.
  bool paused = false;

  /// What came of the last file: null once it's saved, or why not; and a
  /// count that goes up with each file saved, for lists to ask again.
  String? lastError;
  String? lastName;
  SaveJob? lastSaved;
  int saved = 0;

  bool get active => current != null || _queue.isNotEmpty;
  int get waiting => _queue.length;

  double get progress {
    final c = current;
    return c == null || c.bytes.isEmpty ? 0 : (c.sent / c.bytes.length).clamp(0.0, 1.0);
  }

  /// Whether a file's coming or waiting under this name.
  bool has(String name) =>
      (current?.name.toLowerCase() == name.toLowerCase()) || _queue.any((j) => j.name.toLowerCase() == name.toLowerCase());

  void enqueue(SaveJob job) {
    lastError = null;
    _queue.add(job);
    notifyListeners();
    if (!_running) _run();
  }

  /// Give up on what's coming and what's waiting. The unit deletes what it
  /// has of the one coming when it sees no more is.
  void cancel() {
    _queue.clear();
    _cancel = true;
    notifyListeners();
  }

  Future<void> _run() async {
    _running = true;
    try {
      while (_queue.isNotEmpty) {
        final job = _queue.removeAt(0);
        current = job;
        _cancel = false;
        notifyListeners();
        String? why;
        try {
          why = await _send(job);
        } catch (e) {
          debugPrint('storage: $e');
          why = 'The file didn\'t get to the unit';
        }
        lastName = job.name;
        // The unit deletes what it has, and lets go of the card
        if (_cancel || why != null) await board.sendFast(storageAbort(), tries: 2);
        if (_cancel) {
          why = null;
          lastName = null;
        } else if (why == null) {
          lastSaved = job;
          saved++;
        }
        lastError = why;
        current = null;
        paused = false;
        _cancel = false;
        notifyListeners();
        if (why != null) _queue.clear();   // the rest would likely fail the same way
      }
    } finally {
      _running = false;
      notifyListeners();
    }
  }

  static const _endWait = Duration(seconds: 40);   // it puts a picture in its lists first
  static const _window = 8;

  Future<StorageAck?> _roundTrip(Uint8List msg, Duration wait) async {
    final ack = board.storageAcks.first.timeout(wait);
    if (!await board.sendFast(msg)) {
      ack.ignore();
      return null;
    }
    try {
      return await ack;
    } on TimeoutException {
      return null;
    }
  }

  /// Why not, or null once it's saved.
  Future<String?> _send(SaveJob job) async {
    if (board.state != BoardState.connected || (board.status?.version ?? 0) < commVersionStorage) {
      return 'The unit needs newer firmware to save files';
    }
    if (board.maxWrite < 7 + 32 + job.name.length) return "The link to the unit can't take that yet";
    final start = await _roundTrip(storageStart(job.kind, job.bytes.length, job.hash, job.name), ackWait);
    if (start == null) return "The unit didn't answer";
    if (!start.ok) return StorageResult.text(start.result);

    var at = 0;
    var tries = 0;
    while (at < job.bytes.length) {
      if (_cancel) return null;
      // Voice first
      var quiet = 0;
      while (voiceBusy() && !_cancel) {
        if (!paused) {
          paused = true;
          notifyListeners();
        }
        await Future<void>.delayed(const Duration(milliseconds: 300));
        // The unit drops a file that's gone quiet for 20 s
        if (++quiet % 16 == 0) await board.sendFast(storageKeepAlive(), tries: 2);
      }
      if (_cancel) return null;
      if (paused) {
        paused = false;
        notifyListeners();
      }
      if (board.state != BoardState.connected) return 'The link to the unit dropped';
      final ack = board.storageAcks.first.timeout(ackWait);
      var next = at;
      var ok = true;
      for (var i = 0; i < _window && next < job.bytes.length; i++) {
        final last = i == _window - 1;
        final piece = storagePiece(job.bytes, next, board.maxWrite, ack: last);
        final end = next + (piece.length - 6);
        final through = end >= job.bytes.length;
        // The last of the file asks too
        if (through && !last) piece[1] = 4;
        if (!await board.sendFast(piece)) {
          ok = false;
          break;
        }
        next = end;
        if (through || last) break;
      }
      if (!ok) {
        ack.ignore();
        return 'The link to the unit dropped';
      }
      try {
        final a = await ack;
        if (!a.ok) return StorageResult.text(a.result);
        at = a.received;     // where the unit's got to: pieces it left out go again
        job.sent = at;
        tries = 0;
        notifyListeners();
      } on TimeoutException {
        if (++tries > 3) return "The unit stopped answering";
        // Ask where it's got to, by sending the piece it should have next
        at = job.sent;
      }
      await Future<void>.delayed(const Duration(milliseconds: 15));
    }
    if (_cancel) return null;
    final end = await _roundTrip(storageEnd(), _endWait);
    if (end == null) return "The unit didn't say it had it";
    if (!end.ok) return StorageResult.text(end.result);
    job.sent = job.bytes.length;
    return null;
  }
}
