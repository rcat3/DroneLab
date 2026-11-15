/// The comm channel on the phone: the board's voice goes to the Mumble
/// server as it is (no decoding or encoding), and everyone else's comes back
/// through the jitter buffers and the mixer to the headphones.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'audio_out.dart';
import 'background.dart';
import 'board_link.dart';
import 'board_protocol.dart';
import 'jitter.dart';
import 'media_buttons.dart';
import 'mumble_client.dart';

class ServerSettings {
  String host;
  int port;
  String username;
  String password;
  ServerSettings({this.host = '', this.port = 64738, this.username = '', this.password = ''});

  bool get complete => host.isNotEmpty && username.isNotEmpty;
}

class CommController extends ChangeNotifier {
  final BoardLink board = BoardLink();
  ServerSettings server = ServerSettings();
  int bufferMs = 60;

  MumbleClient? mumble;
  bool _serverWanted = false;
  Timer? _reconnect;
  String? serverError;
  final List<MumbleText> texts = [];

  late final Mixer mixer = Mixer(sampleRate: outputRate, newDecoder: OpusVoiceDecoder.new, targetMs: bufferMs);
  late final AudioOut _audio = AudioOut(mixer);
  Timer? _talkingTimer;
  Set<int> talking = {};

  // The board's voice, numbered for Mumble in 10 ms frames, keeping the
  // board's gaps so listeners' decoders fill them in.
  int _seq = 0;
  int? _lastBoardSeq;
  bool _sendingToServer = false;

  StreamSubscription<BoardSound>? _soundSub;
  final List<StreamSubscription<Object?>> _mumbleSubs = [];
  SharedPreferences? _prefs;

  Future<void> init() async {
    board.appVersion = (await PackageInfo.fromPlatform()).version;
    final p = _prefs = await SharedPreferences.getInstance();
    server = ServerSettings(
      host: p.getString('host') ?? '',
      port: p.getInt('port') ?? 64738,
      username: p.getString('username') ?? '',
      password: p.getString('password') ?? '',
    );
    bufferMs = p.getInt('bufferMs') ?? 60;
    mixer.targetMs = bufferMs;
    board.addListener(_onBoardChanged);
    _soundSub = board.sounds.listen(_onBoardSound);
    await loadOpus();
    notifyListeners();
  }

  String? get lastBoardId => _prefs?.getString('boardId');
  String? get lastBoardName => _prefs?.getString('boardName');

  Future<void> saveServer(ServerSettings s, int buffer) async {
    server = s;
    bufferMs = buffer;
    mixer.targetMs = buffer;
    final p = _prefs!;
    await p.setString('host', s.host);
    await p.setInt('port', s.port);
    await p.setString('username', s.username);
    await p.setString('password', s.password);
    await p.setInt('bufferMs', buffer);
    notifyListeners();
  }

  // ----- The board -----

  Future<void> connectBoard(String id, String name) async {
    await _prefs?.setString('boardId', id);
    await _prefs?.setString('boardName', name);
    await board.connect(id, name);
    await _updateBackground();
  }

  Future<void> disconnectBoard() async {
    await board.disconnect();
    await _updateBackground();
  }

  void _onBoardChanged() {
    _updateHeadset();
    notifyListeners();
  }

  // ----- Talking with the headphones' button -----

  static const headsetTalkLimit = Duration(minutes: 2);
  late final MediaButtons _media = MediaButtons(_onHeadsetPress);
  bool headsetTalking = false;
  Timer? _headsetLimit;

  /// The headphones' button works while there's a board to talk through and
  /// a server to talk to, and the app's playing.
  void _updateHeadset() {
    final on = board.state == BoardState.connected && mumble?.state == MumbleState.connected;
    if (on) {
      _media.start();
    } else {
      _media.stop();
      _setHeadsetTalking(false, chirp: false);
    }
  }

  void _onHeadsetPress() {
    if (board.state != BoardState.connected) return;
    // Headphones send a press, not a hold: each press starts or stops
    _setHeadsetTalking(!headsetTalking);
  }

  void _setHeadsetTalking(bool talk, {bool chirp = true}) {
    if (talk == headsetTalking) return;
    headsetTalking = talk;
    board.setTalk(talk);
    if (chirp) mixer.playTone(mixer.chirp(rising: talk));
    _headsetLimit?.cancel();
    if (talk) {
      // In case it's left on: it would keep sending everything
      _headsetLimit = Timer(headsetTalkLimit, () => _setHeadsetTalking(false));
    }
    notifyListeners();
  }

  void _onBoardSound(BoardSound s) {
    final m = mumble;
    if (m == null || m.state != MumbleState.connected) {
      _lastBoardSeq = null;
      return;
    }
    final last = _lastBoardSeq;
    if (last != null) {
      _seq += 2 * ((s.seq - last) & 0xFFFF);
    }
    _lastBoardSeq = s.seq;
    if (s.opus.isEmpty && !s.last) return;
    m.sendVoice(_seq, s.opus, last: s.last);
    final sending = !s.last;
    if (sending != _sendingToServer) {
      _sendingToServer = sending;
      notifyListeners();
    }
  }

  bool get sendingToServer => _sendingToServer;

  // ----- The server -----

  Future<void> connectServer() async {
    if (!server.complete) return;
    _serverWanted = true;
    await _updateBackground();
    await _connectServer();
  }

  Future<void> _connectServer() async {
    _reconnect?.cancel();
    if (!_serverWanted) return;
    _closeMumble();
    final m = MumbleClient(
        host: server.host, port: server.port, username: server.username, password: server.password);
    mumble = m;
    serverError = null;
    _mumbleSubs.add(m.changes.listen((_) => _onMumbleChanged(m)));
    _mumbleSubs.add(m.voice.listen((v) {
      mixer.receive(v.session, v.seq, v.opus, v.last, DateTime.now().millisecondsSinceEpoch);
    }));
    _mumbleSubs.add(m.texts.listen((t) {
      texts.add(t);
      if (texts.length > 50) texts.removeAt(0);
      notifyListeners();
    }));
    notifyListeners();
    try {
      await m.connect(checkCertificate: (fp) => _checkPin(fp));
      await _audio.start();
      _talkingTimer ??= Timer.periodic(const Duration(milliseconds: 150), (_) {
        final now = mixer.talking(DateTime.now().millisecondsSinceEpoch);
        if (!setEquals(now, talking)) {
          talking = now;
          notifyListeners();
        }
      });
    } on MumbleException catch (e) {
      serverError = e.message;
      _scheduleReconnect();
    }
    notifyListeners();
  }

  /// Trust the server's certificate the first time, and refuse it if it
  /// changes after that: someone else could be pretending to be the server.
  bool _checkPin(String fingerprint) {
    final key = 'pin:${server.host}:${server.port}';
    final pinned = _prefs?.getString(key);
    if (pinned == null) {
      _prefs?.setString(key, fingerprint);
      return true;
    }
    return pinned == fingerprint;
  }

  /// Forget the server's certificate, after it really has changed.
  Future<void> forgetCertificate() async {
    await _prefs?.remove('pin:${server.host}:${server.port}');
    serverError = null;
    notifyListeners();
  }

  void _onMumbleChanged(MumbleClient m) {
    if (m != mumble) return;
    // Forget those who left
    for (final session in mixer.speakers.keys.toList()) {
      if (!m.users.containsKey(session)) mixer.remove(session);
    }
    _updateHeadset();
    if (m.state == MumbleState.disconnected && _serverWanted) {
      serverError = m.error;
      _scheduleReconnect();
    }
    notifyListeners();
  }

  void _scheduleReconnect() {
    _reconnect?.cancel();
    if (_serverWanted && !(serverError ?? '').contains('certificate')) {
      _reconnect = Timer(const Duration(seconds: 5), _connectServer);
    }
  }

  void _closeMumble() {
    for (final s in _mumbleSubs) {
      s.cancel();
    }
    _mumbleSubs.clear();
    mumble?.close();
    mumble = null;
  }

  Future<void> disconnectServer() async {
    _serverWanted = false;
    _reconnect?.cancel();
    _closeMumble();
    _updateHeadset();
    _talkingTimer?.cancel();
    _talkingTimer = null;
    talking = {};
    await _audio.stop();
    for (final session in mixer.speakers.keys.toList()) {
      mixer.remove(session);
    }
    await _updateBackground();
    notifyListeners();
  }

  bool get serverWanted => _serverWanted;

  // ----- Running with the screen off -----

  Future<void> _updateBackground() async {
    final on = _serverWanted || board.state != BoardState.off;
    if (on) {
      await startBackground();
    } else {
      await stopBackground();
    }
  }

  @override
  void dispose() {
    _soundSub?.cancel();
    disconnectServer();
    board.disconnect();
    super.dispose();
  }
}
