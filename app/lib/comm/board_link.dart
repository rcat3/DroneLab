/// The Bluetooth LE link to the board: finds boards with the comm channel
/// on, connects, and passes on what the board sends. It reconnects by itself
/// if the link drops, until [disconnect].
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:universal_ble/universal_ble.dart';

import 'board_protocol.dart';

enum BoardState { off, scanning, connecting, connected }

class FoundBoard {
  final String id;
  final String name;
  int rssi;
  FoundBoard(this.id, this.name, this.rssi);
}

class BoardLink extends ChangeNotifier {
  BoardState state = BoardState.off;
  String? error;
  String? deviceId;
  String? name;
  BoardStatus? status;
  int mtu = 23;
  final Map<String, FoundBoard> found = {};

  final _sounds = StreamController<BoardSound>.broadcast();
  Stream<BoardSound> get sounds => _sounds.stream;

  StreamSubscription<BleDevice>? _scanSub;
  StreamSubscription<Uint8List>? _valueSub;
  StreamSubscription<BleConnectionChange>? _connSub;
  bool _wanted = false;     // keep reconnecting
  Timer? _retry;

  Future<bool> _ready() async {
    if (!await UniversalBle.hasPermissions()) {
      await UniversalBle.requestPermissions();
      if (!await UniversalBle.hasPermissions()) {
        error = 'Bluetooth permission is needed to find the board';
        notifyListeners();
        return false;
      }
    }
    final avail = await UniversalBle.getBluetoothAvailabilityState();
    if (avail != AvailabilityState.poweredOn) {
      error = avail == AvailabilityState.poweredOff ? 'Bluetooth is off' : 'Bluetooth is not available';
      notifyListeners();
      return false;
    }
    return true;
  }

  /// Look for boards with Comm switched on.
  Future<void> scan() async {
    if (!await _ready()) return;
    await stopScan();
    found.clear();
    error = null;
    if (state == BoardState.off) state = BoardState.scanning;
    notifyListeners();
    _scanSub = UniversalBle.scanStream.listen((d) {
      final b = found[d.deviceId];
      if (b == null) {
        found[d.deviceId] = FoundBoard(d.deviceId, d.name ?? d.deviceId, d.rssi ?? -100);
      } else {
        b.rssi = d.rssi ?? b.rssi;
      }
      notifyListeners();
    });
    await UniversalBle.startScan(scanFilter: ScanFilter(withServices: [serviceUuid]));
  }

  Future<void> stopScan() async {
    await _scanSub?.cancel();
    _scanSub = null;
    try {
      await UniversalBle.stopScan();
    } catch (_) {}
    if (state == BoardState.scanning) {
      state = BoardState.off;
      notifyListeners();
    }
  }

  Future<void> connect(String id, String boardName) async {
    await stopScan();
    if (!await _ready()) return;
    _wanted = true;
    deviceId = id;
    name = boardName;
    await _connect();
  }

  Future<void> _connect() async {
    final id = deviceId;
    if (id == null || !_wanted) return;
    state = BoardState.connecting;
    error = null;
    notifyListeners();
    await _connSub?.cancel();
    _connSub = UniversalBle.connectionChangeStream(id).listen((c) {
      if (!c.isConnected && state == BoardState.connected) {
        _lost(c.error ?? 'The board went out of range');
      }
    });
    try {
      await UniversalBle.connect(id, timeout: const Duration(seconds: 15));
      await UniversalBle.discoverServices(id);
      try {
        mtu = await UniversalBle.requestMtu(id, 247);
      } catch (_) {}
      if (defaultTargetPlatform == TargetPlatform.android) {
        try {
          await UniversalBle.requestConnectionPriority(id, BleConnectionPriority.highPerformance);
        } catch (_) {}
      }
      await _valueSub?.cancel();
      _valueSub = UniversalBle.characteristicValueStream(id, toPhoneUuid).listen(_onValue);
      await UniversalBle.subscribeNotifications(id, serviceUuid, toPhoneUuid);
      state = BoardState.connected;
      notifyListeners();
    } catch (e) {
      _lost("Couldn't connect to the board");
    }
  }

  void _lost(String why) {
    state = _wanted ? BoardState.connecting : BoardState.off;
    error = why;
    status = null;
    notifyListeners();
    _retry?.cancel();
    if (_wanted) {
      _retry = Timer(const Duration(seconds: 3), _connect);
    }
  }

  void _onValue(Uint8List data) {
    final msg = parseBoardMessage(data);
    if (msg is BoardSound) {
      _sounds.add(msg);
    } else if (msg is BoardStatus) {
      final old = status;
      status = msg;
      if (old == null ||
          old.mode != msg.mode ||
          old.sending != msg.sending ||
          old.hearsVoice != msg.hearsVoice) {
        notifyListeners();
      }
    }
  }

  Future<void> _write(Uint8List msg) async {
    final id = deviceId;
    if (id == null || state != BoardState.connected) return;
    try {
      await UniversalBle.write(id, serviceUuid, fromPhoneUuid, msg);
    } catch (_) {}
  }

  Future<void> setTalk(bool talk) => _write(talkMessage(talk));
  Future<void> setMode(BoardMode mode) => _write(modeMessage(mode));

  Future<void> disconnect() async {
    _wanted = false;
    _retry?.cancel();
    final id = deviceId;
    await _valueSub?.cancel();
    _valueSub = null;
    await _connSub?.cancel();
    _connSub = null;
    if (id != null) {
      try {
        await UniversalBle.disconnect(id);
      } catch (_) {}
    }
    state = BoardState.off;
    status = null;
    notifyListeners();
  }
}
