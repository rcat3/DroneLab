/// The Bluetooth LE link to the board: finds boards with the comm channel
/// on, connects, and passes on what the board sends. It reconnects by itself
/// if the link drops, until [disconnect].
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:typed_data';

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

/// The board's answer to one of the phone remote's requests.
class RemoteAnswer {
  final int status;   // 200, 304 (the state hasn't changed) or 404
  final String body;
  RemoteAnswer(this.status, this.body);
}

class BoardLink extends ChangeNotifier {
  /// The app's version, told to the board when it connects.
  String appVersion = '';

  /// The board's firmware version (rcat_hal_firmware_version), once it's said.
  String? firmware;

  /// How big the board shows avatars, in pixels, and how many it keeps,
  /// once it's said; 0 if it doesn't.
  int avatarSize = 0;
  int avatarSlots = 0;

  final _avatarAcks = StreamController<AvatarAck>.broadcast();
  final _directSounds = StreamController<DirectSound>.broadcast();
  final _directPeers = StreamController<DirectPeer>.broadcast();
  final _directGroups = StreamController<DirectGroupHeard>.broadcast();
  final _recorded = StreamController<BoardSound>.broadcast();
  Stream<BoardSound> get recorded => _recorded.stream;
  Stream<DirectGroupHeard> get directGroups => _directGroups.stream;
  Stream<DirectSound> get directSounds => _directSounds.stream;
  Stream<DirectPeer> get directPeers => _directPeers.stream;
  final _messages = StreamController<TerminalMessage>.broadcast();
  Stream<TerminalMessage> get messages => _messages.stream;
  final _directAvatars = StreamController<DirectAvatarPiece>.broadcast();
  Stream<DirectAvatarPiece> get directAvatars => _directAvatars.stream;
  Stream<AvatarAck> get avatarAcks => _avatarAcks.stream;

  /// The longest message the board takes.
  int get maxWrite => (status?.version ?? 0) >= 3 ? math.min(boardMaxWriteV3, mtu - 3) : boardMaxWrite;

  BoardState state = BoardState.off;
  String? error;
  String? deviceId;
  String? name;
  BoardStatus? status;
  int mtu = 23;
  final Map<String, FoundBoard> found = {};

  final _sounds = StreamController<BoardSound>.broadcast();
  Stream<BoardSound> get sounds => _sounds.stream;

  // The phone remote's requests, one at a time
  int _requestId = 0;
  Future<void> _requestChain = Future.value();
  Completer<RemoteAnswer>? _answer;
  int _answerId = -1;
  BytesBuilder? _answerBytes;

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
      if (!c.isConnected && _wanted && state != BoardState.off) {
        // Dropped before it ever said how it is: it wouldn't pair
        _lost(state == BoardState.connected && status == null
            ? "The board didn't let this phone pair. On the board, open Settings, Paired Phones, "
                'and tap Pair a phone'
            : c.error ?? 'The board went out of range');
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
    firmware = null;
    avatarSize = avatarSlots = 0;
    notifyListeners();
    _retry?.cancel();
    // Let go of what's left of the link, or Android can keep it half open,
    // and the board, thinking it's still connected, stops advertising
    final id = deviceId;
    if (id != null) UniversalBle.disconnect(id).catchError((_) {});
    if (_wanted) {
      _retry = Timer(const Duration(seconds: 3), _connect);
    }
  }

  void _onValue(Uint8List data) {
    final msg = parseBoardMessage(data);
    if (msg is BoardSound) {
      _sounds.add(msg);
    } else if (msg is AnswerPiece) {
      _onAnswerPiece(msg);
    } else if (msg is AvatarAck) {
      _avatarAcks.add(msg);
    } else if (msg is DirectSound) {
      _directSounds.add(msg);
    } else if (msg is DirectPeer) {
      _directPeers.add(msg);
    } else if (msg is DirectAvatarPiece) {
      _directAvatars.add(msg);
    } else if (msg is TerminalMessage) {
      _messages.add(msg);
    } else if (msg is DirectGroupHeard) {
      _directGroups.add(msg);
    } else if (msg is RecordedSound) {
      _recorded.add(msg.sound);
    } else if (msg is BoardStatus) {
      final old = status;
      status = msg;
      if (old == null && msg.version >= commVersionRemote) {
        // Paired and talking: swap versions
        request('GET', '/version?app=${Uri.encodeQueryComponent(appVersion)}&os=${Platform.isIOS ? 'iPhone' : 'Android'}').then((a) {
          if (a.status == 200) {
            final v = jsonDecode(a.body) as Map<String, dynamic>;
            firmware = v['firmware'] as String?;
            avatarSize = (v['avatar'] as num?)?.toInt() ?? 0;
            avatarSlots = (v['avatars'] as num?)?.toInt() ?? 0;
            notifyListeners();
          }
        }).catchError((_) {});
      }
      if (old == null ||
          old.mode != msg.mode ||
          old.sending != msg.sending ||
          old.hearsVoice != msg.hearsVoice ||
          old.buttonConnected != msg.buttonConnected ||
          old.recording != msg.recording) {
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

  void _onAnswerPiece(AnswerPiece p) {
    if (p.id != _answerId || _answer == null) return;
    if (p.first) _answerBytes = BytesBuilder();
    final b = _answerBytes;
    if (b == null) return;
    b.add(p.data);
    if (p.last) {
      final text = utf8.decode(b.takeBytes(), allowMalformed: true);
      _answerBytes = null;
      final nl = text.indexOf('\n');
      final status = int.tryParse(nl < 0 ? text : text.substring(0, nl)) ?? 500;
      _answer!.complete(RemoteAnswer(status, nl < 0 ? '' : text.substring(nl + 1)));
    }
  }

  /// Ask the board what the phone remote's page would, over Bluetooth:
  /// [target] like "/api/voice?p=3". One request goes at a time.
  Future<RemoteAnswer> request(String method, String target,
      [String body = '', Duration timeout = const Duration(seconds: 5)]) {
    final result = Completer<RemoteAnswer>();
    _requestChain = _requestChain.then((_) async {
      try {
        result.complete(await _send(method, target, body, timeout));
      } catch (e) {
        result.completeError(e);
      }
    });
    return result.future;
  }

  Future<RemoteAnswer> _send(String method, String target, String body, Duration timeout) async {
    final id = deviceId;
    if (id == null || state != BoardState.connected) {
      throw StateError('The board is not connected');
    }
    _requestId = (_requestId + 1) & 0xFF;
    final answer = _answer = Completer<RemoteAnswer>();
    _answerId = _requestId;
    _answerBytes = null;
    final text = Uint8List.fromList(utf8.encode('$method $target\n$body'));
    for (final m in requestMessages(_requestId, text, maxWrite)) {
      await UniversalBle.write(id, serviceUuid, fromPhoneUuid, m);
    }
    try {
      return await answer.future.timeout(timeout);
    } finally {
      _answer = null;
    }
  }

  /// Tell the board about the server and who's talking (commVersion 3).
  Future<void> send(Uint8List msg) => _write(msg);

  /// Send without waiting for the board to say it's got it, for avatars'
  /// pieces. Returns false if the link's gone.
  Future<bool> sendFast(Uint8List msg) async {
    for (var tries = 0; tries < 20; tries++) {
      final id = deviceId;
      if (id == null || state != BoardState.connected) return false;
      try {
        await UniversalBle.write(id, serviceUuid, fromPhoneUuid, msg, withoutResponse: true);
        return true;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 20));   // its buffer's full
      }
    }
    return false;
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
    firmware = null;
    avatarSize = avatarSlots = 0;
    notifyListeners();
  }
}
