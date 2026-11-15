/// The comm channel on the phone: the board's voice goes to the Mumble
/// server as it is (no decoding or encoding), and everyone else's comes back
/// through the jitter buffers and the mixer to the headphones.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'audio_out.dart';
import 'avatars.dart';
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

/// The board's comm settings, as on its Comm Setup page (GET /api/comm).
class BoardCommSettings {
  final bool muteSpeaker;     // the speaker's off while it sends
  final int show;             // when it comes to the Comm screen: 1 sending, 2 hearing, 3 both
  const BoardCommSettings(this.muteSpeaker, this.show);
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

  /// Who's talking on the channel, in the order they started. Counted from
  /// when their voice arrives, so the board's screen shows them at once.
  Set<int> talking = {};
  final Map<int, int> _heardAt = {};
  static const _talkingFor = 300;     // ms after their last packet

  /// Our own avatar, a square JPEG, sent to the server (and from there to
  /// everyone) and to the board.
  Uint8List? avatar;
  late final BoardAvatars _boardAvatars = BoardAvatars(board, _updateBoardScreen);

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
    final a = p.getString('avatar');
    avatar = a == null ? null : base64Decode(a);
    muted.addAll(p.getStringList('muted') ?? const []);
    channel = p.getString('channel');
    mixer.targetMs = bufferMs;
    board.addListener(_onBoardChanged);
    _soundSub = board.sounds.listen(_onBoardSound);
    await loadOpus();
    notifyListeners();
  }

  /// Pick a new avatar from [picture] (any image), or take it away with null.
  /// Returns false if it isn't a picture.
  Future<bool> setAvatar(Uint8List? picture) async {
    Uint8List? a;
    if (picture != null) {
      a = await compute(avatarForMumble, picture);
      if (a == null) return false;
    }
    avatar = a;
    if (a == null) {
      await _prefs?.remove('avatar');
    } else {
      await _prefs?.setString('avatar', base64Encode(a));
    }
    mumble?.setAvatar(a);
    _updateBoardScreen();
    notifyListeners();
    return true;
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
    _updateBoardScreen();
    _updateBoardSettings();
    notifyListeners();
  }

  // ----- The board's Comm Setup -----

  BoardCommSettings? boardSettings;
  Timer? _settingsTimer;

  /// Read them once the board's said its version, and every few seconds
  /// after, as they can be changed on the board too.
  void _updateBoardSettings() {
    final ready = board.state == BoardState.connected && board.firmware != null;
    if (!ready) {
      _settingsTimer?.cancel();
      _settingsTimer = null;
      boardSettings = null;
      return;
    }
    if (_settingsTimer == null) {
      _settingsTimer = Timer.periodic(const Duration(seconds: 5), (_) => _boardSettingsRequest('GET', ''));
      _boardSettingsRequest('GET', '');
    }
  }

  Future<void> _boardSettingsRequest(String method, String query) async {
    try {
      final a = await board.request(method, '/api/comm$query');
      if (a.status != 200) return;
      final v = jsonDecode(a.body) as Map<String, dynamic>;
      if (v['available'] != 1) return;
      boardSettings = BoardCommSettings(v['mute'] == 1, (v['show'] as num?)?.toInt() ?? 0);
      notifyListeners();
    } catch (_) {}
  }

  /// Change the board's: the speaker off while it sends, and when it shows
  /// the Comm screen (1 sending, 2 hearing, 3 both).
  Future<void> setBoardSettings({bool? muteSpeaker, int? show}) => _boardSettingsRequest('POST', [
        '?',
        if (muteSpeaker != null) 'mute=${muteSpeaker ? 1 : 0}&',
        if (show != null) 'show=$show',
      ].join());

  // ----- Channels -----

  /// The channel picked, by its path ("Root / Group A"), joined each time
  /// the app connects; null for wherever the server puts it.
  String? channel;
  bool _channelTried = false;     // this connection

  Future<void> joinChannel(int id) async {
    final m = mumble;
    if (m == null) return;
    channel = id == 0 ? null : m.channelPath(id);
    if (channel == null) {
      await _prefs?.remove('channel');
    } else {
      await _prefs?.setString('channel', channel!);
    }
    _channelTried = true;
    m.joinChannel(id);
    notifyListeners();
  }

  /// Once connected, go to the picked channel, if it's there.
  void _joinPickedChannel(MumbleClient m) {
    final want = channel;
    if (_channelTried || want == null || m.state != MumbleState.connected || m.mySession == null) return;
    for (final id in m.channels.keys) {
      if (m.channelPath(id) == want) {
        _channelTried = true;
        if (m.myChannel != id) m.joinChannel(id);
        return;
      }
    }
  }

  // ----- Muting people, here only -----

  /// The names of those muted: they aren't played, nor shown talking on the
  /// board. Kept by name, as their session changes each time they connect.
  final Set<String> muted = {};

  Future<void> setMuted(String name, bool mute) async {
    if (mute ? !muted.add(name) : !muted.remove(name)) return;
    await _prefs?.setStringList('muted', muted.toList()..sort());
    final m = mumble;
    if (mute && m != null) {
      // Stop them now, mid-sentence
      for (final u in m.users.values.where((u) => u.name == name)) {
        mixer.remove(u.session);
        _heardAt.remove(u.session);
      }
      _updateTalking(DateTime.now().millisecondsSinceEpoch);
    }
    notifyListeners();
  }

  bool isMuted(String name) => muted.contains(name);

  // ----- The board's Comm screen -----

  Uint8List? _sentServer;
  Uint8List? _sentHearing;

  /// Tell the board how the server's doing and who's talking, when it
  /// changes, and all of it when the board's newly there. Avatars go as
  /// they're needed: ours and those talking first, then everyone else's.
  void _updateBoardScreen() {
    _boardAvatars.update();
    if (board.state != BoardState.connected || board.status == null) {
      _sentServer = _sentHearing = null;
      return;
    }
    final m = mumble;
    final link = m == null
        ? (_serverWanted ? ServerLink.connecting : ServerLink.off)
        : m.state == MumbleState.connected
            ? ServerLink.connected
            : m.state == MumbleState.connecting || _serverWanted
                ? ServerLink.connecting
                : ServerLink.off;
    final connected = link == ServerLink.connected;
    final talkers = [
      if (connected)
        for (final s in talking)
          Talker(m!.users[s]?.name ?? '?', _boardAvatars.slotFor(m.users[s]?.texture, soon: true))
    ];
    final server = serverMessage(link,
        udp: connected && m!.udpActive,
        others: connected ? m!.channelUsers.length : 0,
        channel: connected ? (m!.channels[m.myChannel] ?? '') : '',
        ownAvatar: _boardAvatars.slotFor(avatar, soon: true));
    if (connected) {
      for (final u in m!.channelUsers) {
        _boardAvatars.slotFor(u.texture);   // ready for when they talk
      }
    }
    if (_sentServer == null || !listEquals(server, _sentServer)) {
      _sentServer = server;
      board.send(server);
    }
    final hearing = hearingMessage(talkers);
    if (_sentHearing == null || !listEquals(hearing, _sentHearing)) {
      _sentHearing = hearing;
      board.send(hearing);
    }
  }

  /// Someone's voice came: they're talking, from now if they weren't.
  void _heard(int session, bool last) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (last) {
      _heardAt.remove(session);
    } else {
      _heardAt[session] = now;
    }
    _updateTalking(now);
  }

  void _updateTalking(int now) {
    _heardAt.removeWhere((_, at) => now - at > _talkingFor);
    final next = <int>{
      for (final s in talking)
        if (_heardAt.containsKey(s)) s,
      for (final s in _heardAt.keys)
        if (!talking.contains(s)) s,
    };
    if (!setEquals(next, talking)) {
      talking = next;
      _updateBoardScreen();
      notifyListeners();
    }
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

  /// The app's Hold to talk. Letting go stops the talking however it
  /// started, the headphones' button included, so the button's next press
  /// starts afresh.
  void holdToTalk(bool held) {
    if (held) {
      board.setTalk(true);
    } else if (headsetTalking) {
      _setHeadsetTalking(false);    // sets the board's talk off too
    } else {
      board.setTalk(false);
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
        host: server.host, port: server.port, username: server.username, password: server.password)
      ..avatar = avatar;
    mumble = m;
    serverError = null;
    _updateBoardScreen();
    _mumbleSubs.add(m.changes.listen((_) => _onMumbleChanged(m)));
    _mumbleSubs.add(m.voice.listen((v) {
      if (muted.isNotEmpty && muted.contains(m.users[v.session]?.name)) return;
      mixer.receive(v.session, v.seq, v.opus, v.last, DateTime.now().millisecondsSinceEpoch);
      _heard(v.session, v.last);
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
      _talkingTimer ??= Timer.periodic(const Duration(milliseconds: 100), (_) {
        _updateTalking(DateTime.now().millisecondsSinceEpoch);
        _updateBoardScreen();   // and whether it's UDP, which changes by itself
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
    if (m.state != MumbleState.connected) _channelTried = false;
    _joinPickedChannel(m);
    // Forget those who left
    for (final session in mixer.speakers.keys.toList()) {
      if (!m.users.containsKey(session)) mixer.remove(session);
    }
    _updateHeadset();
    _updateBoardScreen();
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
    _heardAt.clear();
    _updateBoardScreen();
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
