/// Pairing with the board on Linux. The board shows a code and wants it typed
/// in; on a phone, the phone asks for it. A Linux computer only asks if
/// something is there to ask (a "pairing agent"): GNOME's is only there while
/// its Bluetooth settings are open, and a Raspberry Pi may have none. Without
/// one, BlueZ pairs without a code, which the board turns down.
///
/// So the app pairs the board itself, with an agent of its own, which BlueZ
/// asks only about the pairings the app starts: everything else on the
/// computer pairs as before.
library;

import 'dart:async';

import 'package:bluez/bluez.dart';
import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';

/// Asks the wearer for the code on [boardName]'s screen: null if they don't
/// give it. Once [withdrawn] completes, BlueZ no longer wants the code (the
/// board gave up, or the pairing ended): stop asking.
typedef AskCode = Future<int?> Function(String boardName, Future<void> withdrawn);

class LinuxPairing extends BlueZAgent {
  final AskCode askCode;
  LinuxPairing(this.askCode);

  Future<BlueZClient?>? _starting;

  Future<BlueZClient?> _start() => _starting ??= () async {
        final client = BlueZClient(bus: DBusClient.system());
        try {
          await client.connect();
          await client.registerAgent(this,
              path: DBusObjectPath('/io/github/rcat3/dronelab/agent'),
              capability: BlueZAgentCapability.keyboardOnly);
          return client;
        } catch (e) {
          debugPrint('Pairing agent not started: $e');
          await client.close();
          _starting = null;
          return null;
        }
      }();

  /// Whether the last code asked for was turned down.
  bool cancelled = false;

  /// Pair with the board at [address], if it isn't already: true once it is.
  /// The board's code is asked for with [askCode]. Asked again while it's
  /// pairing (the link drops and comes back meanwhile), it waits for the same
  /// pairing, rather than asking for the code twice.
  Future<bool> pair(String address) => _pairing ??= _pair(address).whenComplete(() => _pairing = null);
  Future<bool>? _pairing;

  Future<bool> _pair(String address) async {
    try {
      return await _pairOnce(address);
    } finally {
      _withdraw();   // a code still being asked for is no use now
    }
  }

  Future<bool> _pairOnce(String address) async {
    cancelled = false;
    final client = await _start();
    if (client == null) return false;
    for (var i = 0; i < 3; i++) {
      final device = client.devices.where((d) => d.address.toUpperCase() == address.toUpperCase()).firstOrNull;
      if (device == null) return false;
      if (device.paired) return true;
      try {
        await device.pair();
        return true;
      } on DBusMethodResponseException catch (e) {
        // BlueZ was already pairing (the board asks as it connects): wait for
        // it, and see
        if (e.errorName != 'org.bluez.Error.InProgress' && e.errorName != 'org.bluez.Error.AlreadyExists') {
          debugPrint('Pairing failed: ${e.errorName}');
          return false;
        }
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
    return client.devices.any((d) => d.address.toUpperCase() == address.toUpperCase() && d.paired);
  }

  /// Wait until BlueZ has the board's services: a board it knows shows the
  /// ones it kept from before as soon as it connects, before they've been
  /// checked, and universal_ble takes those as found. Used then, the MTU
  /// wasn't there yet and subscribing hung. False if it doesn't in [timeout].
  Future<bool> servicesReady(String address, Duration timeout) async {
    final client = await _start();
    final device = client?.devices.where((d) => d.address.toUpperCase() == address.toUpperCase()).firstOrNull;
    if (device == null) return true;   // nothing to wait on: carry on as before
    if (device.servicesResolved) return true;
    try {
      await device.propertiesChanged
          .where((_) => device.servicesResolved || !device.connected)
          .first
          .timeout(timeout);
    } catch (_) {}
    return device.servicesResolved;
  }

  /// Let go of the link to [address], connecting or connected. A connect the
  /// app's stopped waiting for carries on in BlueZ, and until it ends every
  /// new try fails "already in progress": disconnecting stops it too. Not
  /// while pairing, which this would break off.
  Future<void> letGo(String address) async {
    if (_pairing != null) return;
    final client = await _start();
    final device = client?.devices.where((d) => d.address.toUpperCase() == address.toUpperCase()).firstOrNull;
    try {
      await device?.disconnect();
    } catch (_) {}
  }

  /// Completes when BlueZ stops wanting the code being asked for.
  Completer<void>? _asking;

  void _withdraw() {
    final asking = _asking;
    _asking = null;
    if (asking != null && !asking.isCompleted) asking.complete();
  }

  @override
  Future<BlueZAgentPasskeyResponse> requestPasskey(BlueZDevice device) async {
    _withdraw();
    final asking = _asking = Completer<void>();
    final code = await askCode(device.alias.isNotEmpty ? device.alias : device.name, asking.future);
    final withdrawn = asking.isCompleted;
    if (identical(_asking, asking)) _asking = null;
    cancelled = code == null && !withdrawn;
    return code == null ? BlueZAgentPasskeyResponse.canceled() : BlueZAgentPasskeyResponse.success(code);
  }

  /// BlueZ gave up on the code: the board stopped pairing, or took too long.
  @override
  Future<void> cancel() async => _withdraw();
}
