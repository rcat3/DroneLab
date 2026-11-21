/// The link to the board: finds boards with the comm channel on, connects,
/// and passes on what the board sends. It reconnects by itself if the link
/// drops, until [disconnect]. The link itself is Bluetooth LE, or a local
/// socket to a virtual unit (board_transport.dart).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'board_protocol.dart';
import 'board_transport.dart';

export 'board_transport.dart' show FoundBoard;

enum BoardState { off, scanning, connecting, connected }

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

  /// The kind of board (RCAT_BOARD_NAME), and whether the app can update its
  /// firmware, once it's said (commVersion 7; null and false before).
  String? model;
  bool canUpdate = false;

  /// The longest message the board takes, and how many it keeps before it
  /// drops the oldest: as it says (commVersion 7), or as before.
  int msgMax = boardMaxWriteV3;
  int msgQueue = 32;

  /// How big the board shows avatars, in pixels, and how many it keeps,
  /// once it's said; 0 if it doesn't.
  int avatarSize = 0;
  int avatarSlots = 0;

  final _avatarAcks = StreamController<AvatarAck>.broadcast();
  final _updateAcks = StreamController<UpdateAck>.broadcast();
  final _directSounds = StreamController<DirectSound>.broadcast();
  final _directPeers = StreamController<DirectPeer>.broadcast();
  final _directGroups = StreamController<DirectGroupHeard>.broadcast();
  final _recorded = StreamController<BoardSound>.broadcast();
  Stream<BoardSound> get recorded => _recorded.stream;
  Stream<DirectGroupHeard> get directGroups => _directGroups.stream;
  Stream<DirectSound> get directSounds => _directSounds.stream;
  Stream<DirectPeer> get directPeers => _directPeers.stream;
  final _heard = StreamController<Heard>.broadcast();
  Stream<Heard> get heard => _heard.stream;
  final _copies = StreamController<HeardCopy>.broadcast();
  Stream<HeardCopy> get copies => _copies.stream;
  final _talked = StreamController<Talked>.broadcast();
  Stream<Talked> get talked => _talked.stream;
  final _directAvatars = StreamController<DirectAvatarPiece>.broadcast();
  Stream<DirectAvatarPiece> get directAvatars => _directAvatars.stream;
  Stream<AvatarAck> get avatarAcks => _avatarAcks.stream;
  Stream<UpdateAck> get updateAcks => _updateAcks.stream;

  /// The longest message the board takes.
  int get maxWrite => (status?.version ?? 0) >= 3 ? math.min(msgMax, mtu - 3) : boardMaxWrite;

  BoardState state = BoardState.off;
  String? error;
  String? deviceId;

  /// Pairs with the board before it's used, where the system doesn't by
  /// itself (Linux: linux_pairing.dart): true once it's paired, false if it
  /// didn't, and null if the wearer turned it down.
  Future<bool?> Function(String id)? get pairFirst => _ble.pairFirst;
  set pairFirst(Future<bool?> Function(String id)? f) => _ble.pairFirst = f;

  /// Lets go of a board's link where the system needs more than
  /// universal_ble does (Linux: linux_pairing.dart).
  set letGo(Future<void> Function(String id)? f) => _ble.letGo = f;

  /// Waits for a board's services where universal_ble doesn't (Linux).
  set servicesReady(Future<bool> Function(String id, Duration timeout)? f) => _ble.servicesReady = f;
  String? name;
  BoardStatus? status;
  int get mtu => _transport.mtu;
  final Map<String, FoundBoard> found = {};

  final _ble = BleTransport();
  final _socket = SocketTransport();
  late BoardTransport _transport = _ble;
  bool _scanning = false;

  /// Whether virtual units are looked for too (Linux).
  bool get _socketsToo => socketDirectory() != null;

  BoardTransport _transportFor(String id) => id.startsWith(socketIdPrefix) ? _socket : _ble;

  /// Whether the board is a virtual unit on this computer.
  bool get local => _transport == _socket;

  final _sounds = StreamController<BoardSound>.broadcast();
  Stream<BoardSound> get sounds => _sounds.stream;

  // The phone remote's requests, one at a time
  int _requestId = 0;
  Future<void> _requestChain = Future.value();
  Completer<RemoteAnswer>? _answer;
  int _answerId = -1;
  BytesBuilder? _answerBytes;
  bool _askingVersion = false;   // the version swap's request is out

  bool _wanted = false;     // keep reconnecting
  Timer? _retry;

  /// Look for boards with Comm switched on, and virtual units where there
  /// can be any. Bluetooth being off only stops the first.
  Future<void> scan() async {
    final why = await _ble.ready();
    if (why != null && !_socketsToo) {
      error = why;
      notifyListeners();
      return;
    }
    await stopScan();
    found.clear();
    error = why;
    if (state == BoardState.off) state = BoardState.scanning;
    notifyListeners();
    _scanning = true;
    if (why == null) await _ble.startScan(_onFound);
    if (_socketsToo) await _socket.startScan(_onFound);
  }

  void _onFound(FoundBoard f) {
    if (!_scanning) return;
    final b = found[f.id];
    if (b == null) {
      found[f.id] = f;
    } else {
      b.rssi = f.rssi;
      b.inUse = f.inUse;
    }
    notifyListeners();
  }

  Future<void> stopScan() async {
    _scanning = false;
    await _ble.stopScan();
    await _socket.stopScan();
    if (state == BoardState.scanning) {
      state = BoardState.off;
      notifyListeners();
    }
  }

  Future<void> connect(String id, String boardName) async {
    await stopScan();
    final t = _transportFor(id);
    final why = await t.ready();
    if (why != null) {
      error = why;
      notifyListeners();
      return;
    }
    if (t != _transport) {
      await _transport.close();
      _transport = t;
    }
    _wanted = true;
    _retry?.cancel();
    deviceId = id;
    name = boardName;
    // Asked for: a virtual unit that isn't running is started
    _socket.startIfStopped = t == _socket;
    await _connect();
  }

  /// Which try at connecting is the current one: one that's been overtaken
  /// (the link dropped meanwhile, as it does while it pairs, and it's being
  /// tried again) stops where it is, instead of carrying on beside the new.
  int _attempt = 0;

  Future<void> _connect() async {
    final id = deviceId;
    if (id == null || !_wanted) return;
    final attempt = ++_attempt;
    bool overtaken() => attempt != _attempt || !_wanted;
    final t = _transport;
    state = BoardState.connecting;
    error = null;
    notifyListeners();
    void dropped(String? why) {
      if (attempt != _attempt || !_wanted || state == BoardState.off) return;
      // Dropped before it ever said how it is: it wouldn't pair
      _lost(state == BoardState.connected && status == null && t.pairs
          ? "The board didn't let this phone pair. On the board, open Settings, Paired Phones, "
              'and tap Pair a phone'
          : why ?? (t.pairs ? 'The board went out of range' : 'The virtual unit stopped'));
    }

    try {
      await t.open(id, onMessage: _onValue, onDropped: dropped, overtaken: overtaken);
      if (overtaken()) return;
      state = BoardState.connected;
      notifyListeners();
    } on PairingDeclined {
      if (overtaken()) return;
      await disconnect();
      error = 'Not paired: the code was not given';
      notifyListeners();
    } on TransportFailure catch (e) {
      if (overtaken()) return;
      if (e.inUse) {
        await disconnect();
        error = e.message;
        notifyListeners();
        return;
      }
      if (e.notFound && await t.findAgain(id) && !overtaken()) {
        _connect();
        return;
      }
      if (overtaken()) return;
      _lost(e.message);
    } catch (e) {
      debugPrint('board: failed $e');
      if (overtaken()) return;
      _lost("Couldn't connect to the board");
    }
  }

  /// The link's signal strength now, in dBm; null if it can't be read, or
  /// it's a virtual unit's.
  Future<int?> readRssi() async {
    if (deviceId == null || state != BoardState.connected) return null;
    return _transport.readRssi();
  }

  void _lost(String why) {
    state = _wanted ? BoardState.connecting : BoardState.off;
    error = why;
    status = null;
    firmware = model = null;
    canUpdate = false;
    msgMax = boardMaxWriteV3;
    msgQueue = 32;
    avatarSize = avatarSlots = 0;
    notifyListeners();
    _retry?.cancel();
    // Stop hearing about this link, and let go of what's left of it
    _transport.close();
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
    } else if (msg is UpdateAck) {
      _updateAcks.add(msg);
    } else if (msg is DirectSound) {
      _directSounds.add(msg);
    } else if (msg is DirectPeer) {
      _directPeers.add(msg);
    } else if (msg is DirectAvatarPiece) {
      _directAvatars.add(msg);
    } else if (msg is Heard) {
      _heard.add(msg);
    } else if (msg is HeardCopy) {
      _copies.add(msg);
    } else if (msg is Talked) {
      _talked.add(msg);
    } else if (msg is DirectGroupHeard) {
      _directGroups.add(msg);
    } else if (msg is RecordedSound) {
      _recorded.add(msg.sound);
    } else if (msg is BoardStatus) {
      final old = status;
      status = msg;
      if (firmware == null && !_askingVersion && state == BoardState.connected && msg.version >= commVersionRemote) {
        // Paired and talking: swap versions. Asked again at the next status
        // until it's answered, as the first can come before the link's up.
        _askingVersion = true;
        request('GET', '/version?app=${Uri.encodeQueryComponent(appVersion)}&os=${Platform.isIOS ? 'iPhone' : Platform.isLinux ? 'Linux' : 'Android'}').then((a) {
          if (a.status == 200) {
            final v = jsonDecode(a.body) as Map<String, dynamic>;
            firmware = v['firmware'] as String?;
            avatarSize = (v['avatar'] as num?)?.toInt() ?? 0;
            avatarSlots = (v['avatars'] as num?)?.toInt() ?? 0;
            model = v['board'] as String?;
            canUpdate = v['update'] == 1;
            msgMax = (v['msgmax'] as num?)?.toInt() ?? boardMaxWriteV3;
            msgQueue = (v['msgs'] as num?)?.toInt() ?? 32;
            notifyListeners();
          }
        }).catchError((_) {}).whenComplete(() => _askingVersion = false);
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
    if (deviceId == null || state != BoardState.connected) return;
    try {
      await _transport.write(msg);
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
    if (deviceId == null || state != BoardState.connected) {
      throw StateError('The board is not connected');
    }
    _requestId = (_requestId + 1) & 0xFF;
    final answer = _answer = Completer<RemoteAnswer>();
    _answerId = _requestId;
    _answerBytes = null;
    final text = Uint8List.fromList(utf8.encode('$method $target\n$body'));
    for (final m in requestMessages(_requestId, text, maxWrite)) {
      await _transport.write(m);
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
  Future<bool> sendFast(Uint8List msg, {int tries = 20, Duration wait = const Duration(milliseconds: 20)}) async {
    for (var i = 0; i < tries; i++) {
      if (deviceId == null || state != BoardState.connected) return false;
      if (await _transport.writeFast(msg)) return true;
      await Future<void>.delayed(wait);   // its buffer's full
    }
    return false;
  }

  Future<void> setTalk(bool talk) => _write(talkMessage(talk));
  Future<void> setMode(BoardMode mode) => _write(modeMessage(mode));

  Future<void> disconnect() async {
    _wanted = false;
    _attempt++;
    _retry?.cancel();
    await _transport.close();
    state = BoardState.off;
    status = null;
    firmware = model = null;
    canUpdate = false;
    msgMax = boardMaxWriteV3;
    msgQueue = 32;
    avatarSize = avatarSlots = 0;
    notifyListeners();
  }
}
