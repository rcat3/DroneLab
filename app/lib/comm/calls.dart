/// Calls to one person alone: their state, the signals between the two apps,
/// missed calls, and the tones in the headphones.
///
/// Talking to one person alone takes a call: one rings the other, who
/// answers, and only then do they hear each other. A call stays up while
/// either talks somewhere else, and the one waiting hears two short beeps
/// every few seconds while the other's away, until they come back or one
/// hangs up.
///
/// The signals go as signed commands for them alone ([OthersCommand.call]),
/// both over the server and over direct comms, whichever reach them; each is
/// [CallOp] and the call's id. Ringing and holding are sent again every few
/// seconds while they last, so one lost on the way doesn't matter, and their
/// stopping says the other's gone.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

abstract final class CallOp {
  static const ring = 1;        // calling them: sent again every few seconds until answered
  static const answer = 2;
  static const decline = 3;     // not answered: turned down
  static const hangup = 4;      // ended, or given up on before it was answered
  static const hold = 5;        // talking somewhere else meanwhile: sent again every few seconds
  static const resume = 6;      // back
}

enum CallState { calling, ringing, connected }

class Call {
  final String personId;
  final int id;
  final bool outgoing;
  final bool plain;         // with someone on plain Mumble: a whisper line, no signals
  CallState state;
  final int startedMs;
  int lastHeardMs;          // their last signal
  int lastSentMs = 0;       // our last ring, or hold
  int? theyHoldMs;          // they're away: when they last said so
  bool holding = false;     // we're away, and have said so
  int? lostMs;              // when they went out of reach
  Call(this.personId, this.id, this.state, {required this.outgoing, required int nowMs, this.plain = false})
      : startedMs = nowMs,
        lastHeardMs = nowMs;

  bool get connected => state == CallState.connected;
  bool get theyHold => theyHoldMs != null;
}

/// How long things take.
abstract final class CallTiming {
  static const resendMs = 3000;       // ring again, every
  static const waitingEveryMs = 6000; // the call-waiting beeps, every
  static const giveUpMs = 45000;      // no answer
  static const ringGoneMs = 9000;     // no ring heard for this long: they gave up
  static const holdEveryMs = 4000;
  static const holdGoneMs = 10000;    // no hold heard for this long: they're not away
  static const lostForMs = 60000;     // out of reach this long: the call's over
}

/// Missed calls, by who: how many, and when the last was. Kept.
class MissedCalls {
  final Map<String, (int, DateTime)> _byPerson = {};
  final void Function(String json) _save;
  MissedCalls(this._save);

  void load(String? json) {
    _byPerson.clear();
    if (json == null) return;
    try {
      final m = jsonDecode(json) as Map<String, dynamic>;
      for (final e in m.entries) {
        final v = e.value as Map<String, dynamic>;
        _byPerson[e.key] = ((v['n'] as num).toInt(), DateTime.fromMillisecondsSinceEpoch((v['at'] as num).toInt()));
      }
    } catch (_) {}
  }

  (int, DateTime)? operator [](String personId) => _byPerson[personId];
  bool get isEmpty => _byPerson.isEmpty;

  void add(String personId) {
    final old = _byPerson[personId];
    _byPerson[personId] = ((old?.$1 ?? 0) + 1, DateTime.now());
    _store();
  }

  bool clear(String personId) {
    if (_byPerson.remove(personId) == null) return false;
    _store();
    return true;
  }

  void _store() => _save(jsonEncode({
        for (final e in _byPerson.entries) e.key: {'n': e.value.$1, 'at': e.value.$2.millisecondsSinceEpoch}
      }));
}

/// The ring tones to pick from, for the headphones.
const ringTones = {'classic': 'Classic', 'chirp': 'Chirp', 'pulse': 'Pulse'};

/// Tones for calls, at [rate] samples a second, faded at each end so they
/// don't click. Each is a list of notes: their frequencies together (none
/// for a gap) and how long.
class CallTones {
  final int rate;
  const CallTones(this.rate);

  Int16List _notes(List<(List<double>, int)> notes, double level) {
    final fade = rate * 5 ~/ 1000;
    final out = <int>[];
    for (final (hz, ms) in notes) {
      final n = rate * ms ~/ 1000;
      for (var i = 0; i < n; i++) {
        if (hz.isEmpty) {
          out.add(0);
          continue;
        }
        final edge = math.min(i, n - 1 - i);
        final env = edge >= fade ? 1.0 : edge / fade;
        var v = 0.0;
        for (final f in hz) {
          v += math.sin(2 * math.pi * f * i / rate);
        }
        out.add((v / hz.length * env * level * 32767).round());
      }
    }
    return Int16List.fromList(out);
  }

  /// Someone's calling: the chosen ring.
  Int16List ring(String tone) => switch (tone) {
        'chirp' => _notes([
            ([660.0], 70), ([880.0], 70), ([1320.0], 90), ([], 120),
            ([660.0], 70), ([880.0], 70), ([1320.0], 90),
          ], 0.14),
        'pulse' => _notes([
            for (var i = 0; i < 4; i++) ...[([1040.0], 60), ([], 70)],
          ], 0.13),
        _ => _notes([([440.0, 480.0], 400), ([], 200), ([440.0, 480.0], 400)], 0.14),
      };

  /// Someone else calling while we're talking in a call: two soft, low
  /// beeps, under the conversation rather than over it.
  Int16List waiting() => _notes([([440.0], 150), ([], 150), ([440.0], 150)], 0.08);

  /// It's ringing at theirs.
  Int16List ringBack() => _notes([([440.0, 480.0], 500)], 0.07);

  /// They're away, talking somewhere else: two short beeps.
  Int16List hold() => _notes([([1000.0], 80), ([], 120), ([1000.0], 80)], 0.12);

  /// Answered.
  Int16List connected() => _notes([([660.0], 70), ([990.0], 110)], 0.12);

  /// Over: declined, hung up, or no answer.
  Int16List ended() => _notes([([480.0], 120), ([], 60), ([480.0], 120), ([], 60), ([360.0], 220)], 0.12);
}
