/// How the app reaches a unit: over Bluetooth LE (a real one), or over a
/// local socket (a virtual unit on this computer). BoardLink keeps the
/// protocol and the reconnecting; a transport only opens a link, passes
/// messages each way whole, and says when it's dropped.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:universal_ble/universal_ble.dart';

import 'board_protocol.dart';

class FoundBoard {
  final String id;
  final String name;
  int rssi;

  /// On this computer (a virtual unit), not over Bluetooth.
  final bool local;
  FoundBoard(this.id, this.name, this.rssi, {this.local = false});
}

/// Why a link couldn't be opened, in words for the wearer.
class TransportFailure implements Exception {
  final String message;

  /// The unit wasn't found: worth looking for it again (findAgain) first.
  final bool notFound;
  TransportFailure(this.message, {this.notFound = false});
  @override
  String toString() => message;
}

/// The wearer wouldn't give the pairing code.
class PairingDeclined implements Exception {}

abstract class BoardTransport {
  /// Null if it can be used now, or why not.
  Future<String?> ready();

  /// Look for units, telling [onFound] about each, again as they're heard.
  Future<void> startScan(void Function(FoundBoard) onFound);
  Future<void> stopScan();

  /// Look for the unit at [id] for a while: true once it's seen.
  Future<bool> findAgain(String id);

  /// Open the link to [id]: [onMessage] gets each message the unit sends,
  /// and [onDropped] is called (with why, if it's known) if the link goes.
  /// Throws TransportFailure or PairingDeclined. [overtaken] says whether a
  /// newer try has taken this one's place, so it stops where it is.
  Future<void> open(String id,
      {required void Function(Uint8List) onMessage,
      required void Function(String? why) onDropped,
      required bool Function() overtaken});

  /// What the link agreed to carry in one go (ATT MTU); the longest message
  /// is 3 less.
  int get mtu;

  /// Whether the unit has to be paired before it talks: a link dropped
  /// before the first status is then taken to be one it wouldn't pair.
  bool get pairs;

  /// Send one message, waiting for it to be taken. Throws if it isn't.
  Future<void> write(Uint8List msg);

  /// Send without waiting: false if there's no room just now.
  Future<bool> writeFast(Uint8List msg);

  /// The link's signal strength now, in dBm; null if it can't be read.
  Future<int?> readRssi();

  /// Let go of the link, whatever state it's in.
  Future<void> close();
}

// ----- Bluetooth LE -----

class BleTransport implements BoardTransport {
  /// Pairs with the board before it's used, where the system doesn't by
  /// itself (Linux: linux_pairing.dart): true once it's paired, false if it
  /// didn't, and null if the wearer turned it down.
  Future<bool?> Function(String id)? pairFirst;

  String? _id;
  @override
  int mtu = 23;
  StreamSubscription<BleDevice>? _scanSub;
  bool get scanning => _scanSub != null;
  StreamSubscription<Uint8List>? _valueSub;
  StreamSubscription<BleConnectionChange>? _connSub;

  @override
  bool get pairs => true;

  @override
  Future<String?> ready() async {
    if (!await UniversalBle.hasPermissions()) {
      await UniversalBle.requestPermissions();
      if (!await UniversalBle.hasPermissions()) return 'Bluetooth permission is needed to find the board';
    }
    final avail = await UniversalBle.getBluetoothAvailabilityState();
    if (avail != AvailabilityState.poweredOn) {
      return avail == AvailabilityState.poweredOff ? 'Bluetooth is off' : 'Bluetooth is not available';
    }
    return null;
  }

  @override
  Future<void> startScan(void Function(FoundBoard) onFound) async {
    _scanSub = UniversalBle.scanStream
        .listen((d) => onFound(FoundBoard(d.deviceId, d.name ?? d.deviceId, d.rssi ?? -100)));
    await UniversalBle.startScan(scanFilter: ScanFilter(withServices: [serviceUuid]));
  }

  @override
  Future<void> stopScan() async {
    await _scanSub?.cancel();
    _scanSub = null;
    try {
      await UniversalBle.stopScan();
    } catch (_) {}
  }

  /// Not while the wearer's scanning themselves.
  @override
  Future<bool> findAgain(String id) async {
    if (_scanSub != null) return false;
    final seen = Completer<bool>();
    final sub = UniversalBle.scanStream.listen((d) {
      if (d.deviceId.toUpperCase() == id.toUpperCase() && !seen.isCompleted) seen.complete(true);
    });
    try {
      await UniversalBle.startScan(scanFilter: ScanFilter(withServices: [serviceUuid]));
      return await seen.future.timeout(const Duration(seconds: 10), onTimeout: () => false);
    } catch (_) {
      return false;
    } finally {
      await sub.cancel();
      try {
        await UniversalBle.stopScan();
      } catch (_) {}
    }
  }

  @override
  Future<void> open(String id,
      {required void Function(Uint8List) onMessage,
      required void Function(String? why) onDropped,
      required bool Function() overtaken}) async {
    _id = id;
    await _connSub?.cancel();
    _connSub = UniversalBle.connectionChangeStream(id).listen((c) {
      if (!c.isConnected) onDropped(c.error);
    });
    try {
      await UniversalBle.connect(id, timeout: const Duration(seconds: 15));
      if (overtaken()) return;
      await UniversalBle.discoverServices(id).timeout(const Duration(seconds: 15));
      if (overtaken()) return;
      final pairFirst = this.pairFirst;
      if (pairFirst != null) {
        final paired = await pairFirst(id);
        if (overtaken()) return;
        if (paired == null) throw PairingDeclined();
        if (!paired) {
          throw TransportFailure("The board didn't pair. On the board, open Settings, Paired Phones, "
              'and tap Pair a phone, then type the code it shows');
        }
      }
      try {
        mtu = await UniversalBle.requestMtu(id, 247);
      } catch (_) {}
      if (defaultTargetPlatform == TargetPlatform.android) {
        try {
          await UniversalBle.requestConnectionPriority(id, BleConnectionPriority.highPerformance);
        } catch (_) {}
      }
      if (overtaken()) return;
      await _valueSub?.cancel();
      _valueSub = UniversalBle.characteristicValueStream(id, toPhoneUuid).listen(onMessage);
      await UniversalBle.subscribeNotifications(id, serviceUuid, toPhoneUuid).timeout(const Duration(seconds: 10));
    } on UniversalBleException catch (e) {
      debugPrint('board: failed $e');
      // Linux only connects to a board it's seen lately: after it's been
      // forgotten (or the computer's started again), look for it first
      final notFound = e.code == UniversalBleErrorCode.deviceNotFound;
      throw TransportFailure(
          notFound ? 'The board is out of range, or its Phone App is off' : "Couldn't connect to the board",
          notFound: notFound);
    } on TransportFailure {
      rethrow;
    } on PairingDeclined {
      rethrow;
    } catch (e) {
      debugPrint('board: failed $e');
      throw TransportFailure("Couldn't connect to the board");
    }
  }

  @override
  Future<void> write(Uint8List msg) async {
    final id = _id;
    if (id == null) throw StateError('The board is not connected');
    await UniversalBle.write(id, serviceUuid, fromPhoneUuid, msg);
  }

  @override
  Future<bool> writeFast(Uint8List msg) async {
    final id = _id;
    if (id == null) return false;
    try {
      await UniversalBle.write(id, serviceUuid, fromPhoneUuid, msg, withoutResponse: true);
      return true;
    } catch (_) {
      return false;   // its buffer's full
    }
  }

  @override
  Future<int?> readRssi() async {
    final id = _id;
    if (id == null) return null;
    try {
      return await UniversalBle.readRssi(id);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> close() async {
    // Stop hearing about this link first (cancelling stops it at once):
    // letting go of one that's already down says it's disconnected again,
    // which would put off the retry, over and over, for good
    final conn = _connSub, value = _valueSub;
    _connSub = _valueSub = null;
    await conn?.cancel();
    await value?.cancel();
    // Let go of what's left of the link, or Android can keep it half open,
    // and the board, thinking it's still connected, stops advertising
    final id = _id;
    if (id != null) {
      try {
        await UniversalBle.disconnect(id);
      } catch (_) {}
    }
  }
}

// ----- A local socket -----

/// The ids of units reached over a local socket start with this, then the
/// socket's path.
const socketIdPrefix = 'unix:';

/// A virtual unit listens on a Unix socket in the runtime directory (only
/// its owner can reach it): $XDG_RUNTIME_DIR/dronelab-unit*.sock. One app at
/// a time; while it's connected, it's as if the phone were connected, paired
/// and had notifications on. Each message goes as its length (2 bytes,
/// little-endian) and then itself, up to [socketMessageMax] bytes, the same
/// messages as over Bluetooth.
const socketMessageMax = 244;

/// Where to look for virtual units: null where there's no runtime directory.
String? socketDirectory() =>
    Platform.isLinux ? Platform.environment['XDG_RUNTIME_DIR'] : null;

final _socketName = RegExp(r'^dronelab-unit(.*)\.sock$');

/// What to call the unit at the socket [path].
String socketUnitName(String path) {
  final m = _socketName.firstMatch(path.split('/').last);
  final rest = (m?.group(1) ?? '').replaceFirst(RegExp(r'^[-_.]'), '');
  return rest.isEmpty ? 'Virtual unit' : 'Virtual unit $rest';
}

/// Splits what comes off a socket into the messages it carries.
class FrameReader {
  final void Function(Uint8List) onMessage;
  final _buf = BytesBuilder(copy: false);
  Uint8List _pending = Uint8List(0);
  FrameReader(this.onMessage);

  /// Takes more bytes; throws FormatException at a message too long, as the
  /// stream can't be trusted after that.
  void add(List<int> data) {
    _buf.add(_pending);
    _buf.add(data);
    var b = _buf.takeBytes();
    var at = 0;
    while (b.length - at >= 2) {
      final len = b[at] | b[at + 1] << 8;
      if (len > socketMessageMax) throw const FormatException('message too long');
      if (b.length - at - 2 < len) break;
      onMessage(Uint8List.sublistView(b, at + 2, at + 2 + len));
      at += 2 + len;
    }
    _pending = Uint8List.fromList(Uint8List.sublistView(b, at));
  }
}

Uint8List frameMessage(Uint8List msg) {
  if (msg.length > socketMessageMax) throw ArgumentError('message too long');
  return Uint8List(2 + msg.length)
    ..[0] = msg.length & 0xFF
    ..[1] = msg.length >> 8
    ..setRange(2, 2 + msg.length, msg);
}

class SocketTransport implements BoardTransport {
  Socket? _socket;
  StreamSubscription<Uint8List>? _sub;
  Timer? _scanTimer;

  @override
  int get mtu => socketMessageMax + 3;

  @override
  bool get pairs => false;

  @override
  Future<String?> ready() async => null;

  /// The sockets virtual units are listening on just now.
  static Future<List<String>> listening() async {
    final dir = socketDirectory();
    if (dir == null) return [];
    final found = <String>[];
    try {
      await for (final e in Directory(dir).list(followLinks: false)) {
        if (!_socketName.hasMatch(e.path.split('/').last)) continue;
        if (await FileSystemEntity.type(e.path, followLinks: false) != FileSystemEntityType.unixDomainSock) continue;
        found.add(e.path);
      }
    } catch (_) {}
    found.sort();
    return found;
  }

  @override
  Future<void> startScan(void Function(FoundBoard) onFound) async {
    Future<void> look() async {
      for (final path in await listening()) {
        onFound(FoundBoard('$socketIdPrefix$path', socketUnitName(path), 0, local: true));
      }
    }

    await stopScan();
    _scanTimer = Timer.periodic(const Duration(seconds: 2), (_) => look());
    await look();
  }

  @override
  Future<void> stopScan() async {
    _scanTimer?.cancel();
    _scanTimer = null;
  }

  @override
  Future<bool> findAgain(String id) async => false;

  @override
  Future<void> open(String id,
      {required void Function(Uint8List) onMessage,
      required void Function(String? why) onDropped,
      required bool Function() overtaken}) async {
    await close();
    final path = id.substring(socketIdPrefix.length);
    final Socket s;
    try {
      s = await Socket.connect(InternetAddress(path, type: InternetAddressType.unix), 0,
          timeout: const Duration(seconds: 5));
    } catch (e) {
      debugPrint('board: failed $e');
      throw TransportFailure("The virtual unit isn't running");
    }
    if (overtaken()) {
      s.destroy();
      return;
    }
    _socket = s;
    final reader = FrameReader(onMessage);
    var dropped = false;
    void drop(String? why) {
      if (dropped || _socket != s) return;
      dropped = true;
      onDropped(why);
    }

    s.done.then((_) {}, onError: (_) => drop('The virtual unit stopped'));
    _sub = s.listen((data) {
      try {
        reader.add(data);
      } on FormatException {
        s.destroy();
        drop("The virtual unit sent something it shouldn't");
      }
    }, onError: (_) => drop('The virtual unit stopped'), onDone: () => drop('The virtual unit stopped'));
  }

  @override
  Future<void> write(Uint8List msg) async {
    final s = _socket;
    if (s == null) throw StateError('The unit is not connected');
    s.add(frameMessage(msg));
  }

  @override
  Future<bool> writeFast(Uint8List msg) async {
    final s = _socket;
    if (s == null) return false;
    try {
      s.add(frameMessage(msg));
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<int?> readRssi() async => null;

  @override
  Future<void> close() async {
    final s = _socket;
    _socket = null;
    await _sub?.cancel();
    _sub = null;
    s?.destroy();
  }
}
