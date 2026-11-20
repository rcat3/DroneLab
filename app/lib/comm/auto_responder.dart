import 'dart:async';
import 'dart:typed_data';

import 'board_protocol.dart';

/// One transmission heard, as its Opus packets, to send back.
class VoiceTake {
  final int session;
  final bool direct;        // heard over direct comms, and sent back that way; else the server
  final List<Uint8List> packets = [];
  int ms = 0;               // how long it plays, so far
  int heardMs = 0;          // its last packet
  VoiceTake(this.session, this.direct);
}

/// The developer options' voice auto responder: each transmission heard on
/// the channel talked to is kept, as it came (its Opus packets, not decoded),
/// and sent back as a transmission of ours, the same way it came, a second
/// after it ends; at most [capMs] of it. Kept only until it's gone.
///
/// Two responders would answer each other for ever, so a transmission that
/// starts while ours plays, or within [quietMs] after, isn't answered: the
/// other's answer to ours always starts a second after ours ends.
class VoiceResponder {
  static const capMs = 30000;
  static const delayMs = 1000;
  static const endAfterMs = 600;     // nothing heard for this long: it's ended, its end lost
  static const quietMs = 1500;

  /// Send a packet of it: [direct] over direct comms, else the server. An
  /// empty one with [last] ends it. False if that way's not there now: what's
  /// left isn't sent.
  final Future<bool> Function(bool direct, Uint8List opus, {required bool first, required bool last}) send;
  VoiceResponder(this.send);

  /// Told when it starts or stops sending one back.
  void Function()? onChange;

  bool _on = false;
  bool get on => _on;
  set on(bool v) {
    _on = v;
    if (!v) {
      _takes.clear();
      _waiting.clear();
      _ignoring.clear();
      _watch?.cancel();
      _watch = null;
    }
  }

  final Map<int, VoiceTake> _takes = {};      // being heard, by session
  final Map<int, int> _ignoring = {};         // not answered, by session: when last heard
  final List<VoiceTake> _waiting = [];
  Timer? _watch;
  bool _playing = false;
  int _quietUntil = 0;

  /// Whether it's sending one back just now.
  bool get playing => _playing;

  /// A packet of voice heard on the channel talked to.
  void heard(int session, {required bool direct, required Uint8List opus, required bool last}) {
    if (!_on) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    var t = _takes[session];
    if (t == null) {
      if (_ignoring.containsKey(session)) {
        if (last) {
          _ignoring.remove(session);
        } else {
          _ignoring[session] = now;
        }
        return;
      }
      if (last && opus.isEmpty) return;
      if (_playing || now < _quietUntil) {
        if (!last) _ignoring[session] = now;
        return;
      }
      t = _takes[session] = VoiceTake(session, direct);
      _watch ??= Timer.periodic(const Duration(milliseconds: 200), (_) => _check());
    }
    t.heardMs = now;
    if (opus.isNotEmpty && t.ms < capMs && (!direct || opus.length <= directVoiceMax)) {
      t.packets.add(Uint8List.fromList(opus));
      t.ms += opusPacketMs(opus);
    }
    if (last) _ended(t);
  }

  /// Those whose end never came, ended.
  void _check() {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final t in _takes.values.where((t) => now - t.heardMs > endAfterMs).toList()) {
      _ended(t);
    }
    _ignoring.removeWhere((_, at) => now - at > endAfterMs);
    if (_takes.isEmpty && _ignoring.isEmpty) {
      _watch?.cancel();
      _watch = null;
    }
  }

  void _ended(VoiceTake t) {
    _takes.remove(t.session);
    if (t.packets.isEmpty) return;
    Timer(const Duration(milliseconds: delayMs), () {
      if (!_on) return;
      _waiting.add(t);
      _next();
    });
  }

  Future<void> _next() async {
    if (_playing || _waiting.isEmpty) return;
    final t = _waiting.removeAt(0);
    _playing = true;
    onChange?.call();
    try {
      // In time, as it was heard: each packet when the ones before have played
      final clock = Stopwatch()..start();
      var due = 0;
      var ok = true;
      for (final (i, p) in t.packets.indexed) {
        final wait = due - clock.elapsedMilliseconds;
        if (wait > 0) await Future<void>.delayed(Duration(milliseconds: wait));
        if (!_on) break;
        ok = await send(t.direct, p, first: i == 0, last: false);
        if (!ok) break;
        due += opusPacketMs(p);
      }
      if (ok) await send(t.direct, Uint8List(0), first: false, last: true);
    } finally {
      t.packets.clear();      // gone once it's sent
      _playing = false;
      _quietUntil = DateTime.now().millisecondsSinceEpoch + quietMs;
      onChange?.call();
    }
    _next();
  }
}
