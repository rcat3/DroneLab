/// The Vessel's side of a Guide's toys in a HiveSight session: the Guide's
/// commands (the bytes of an others.h Vibe command, relayed by the sender)
/// go to our unit as our own, but only as the Vibe class's permissions and
/// the HiveSight "Ignore toys" option say: Vibe not off, the Guide allowed
/// there by their key, and toys not ignored.
///
/// Toys must never outlast the session. The unit holds a lease on them
/// (comm message 0x1E): kept up from here every couple of seconds while
/// the Guide has anything playing, and if it lapses, the unit stops every
/// toy itself, whether the app, the phone or the Bluetooth link is what's
/// gone. Leaving, being removed, the session ending and the link to the
/// Guide dropping all stop them at once as well (hivesight/HiveSightActivity.kt).
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import 'board_link.dart';
import 'board_protocol.dart';
import 'comm_controller.dart';
import 'rules.dart';

class VesselToys {
  VesselToys(this.comm, this.guideKey, this._channel) {
    comm.addListener(_report);
    _report();
  }

  final CommController comm;
  final String guideKey; // the Guide's identity key, hex
  final MethodChannel _channel;

  /// How long the unit waits for the lease to be kept up, and how often it is.
  static const leaseSeconds = 6;
  static const refreshEvery = Duration(seconds: 2);

  Timer? _lease;
  bool _disposed = false;
  String? _lastReport;

  /// Whether the unit's here and new enough to hold a lease.
  bool get hasUnit => comm.board.state == BoardState.connected && (comm.board.status?.version ?? 0) >= commVersionLease;

  /// Whether the Guide's toys play now: running a command.
  bool get playing => _lease != null;

  /// Whether the Guide may use our toys, and if not, why.
  (bool, String) get permission {
    final r = comm.permissions.rules;
    if (r.rule(RuleClass.hiveSight).ignore & ignoreToys != 0) return (false, 'ignored');
    if (r.policy(RuleClass.vibe) == Policy.off) return (false, 'off');
    if (!r.allows(guideKey, RuleClass.vibe)) return (false, 'not allowed');
    return (true, '');
  }

  /// What the Guide sees: our unit's channels, and whether it may use them.
  void _report() {
    if (_disposed) return;
    final (ok, why) = permission;
    final unit = hasUnit;
    if (playing && (!ok || !unit)) stop();
    final json = jsonEncode({
      'unit': unit,
      'mapped': unit ? comm.myVibeChannels : 0,
      'allowed': ok,
      'why': why,
    });
    if (json == _lastReport) return;
    _lastReport = json;
    _channel.invokeMethod<void>('toysState', json).catchError((_) {});
  }

  /// A command from the Guide, as base64.
  void onCommand(String b64) {
    if (_disposed) return;
    final Uint8List what;
    try {
      what = base64Decode(b64);
    } catch (_) {
      return;
    }
    if (what.isEmpty || what.length > OthersCommand.whatMax) return;
    switch (what[0]) {
      case OthersCommand.vibeStop:
        stop(); // always, whatever's allowed
      case OthersCommand.vibeSet || OthersCommand.vibePart:
        if (!permission.$1 || !hasUnit) return;
        comm.board.send(commandOwn(what));
        if (what[0] == OthersCommand.vibeSet) _keepLease();
    }
  }

  void _keepLease() {
    if (_lease != null) return;
    comm.board.send(toyLeaseMessage(leaseSeconds));
    _lease = Timer.periodic(refreshEvery, (_) => comm.board.send(toyLeaseMessage(leaseSeconds)));
  }

  /// Everything the Guide has playing stops, on the unit, and the lease ends.
  void stop() {
    if (_lease == null) return;
    _lease!.cancel();
    _lease = null;
    comm.board.send(commandOwn([OthersCommand.vibeStop]));
    comm.board.send(toyLeaseMessage(0));
  }

  void dispose() {
    if (_disposed) return;
    stop();
    _disposed = true;
    comm.removeListener(_report);
  }
}
