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
  final DirectSettings? direct;   // null on boards without direct comms
  final int voice;                // the comm channel's own voice effect, -1 for the speaker's
  final List<String> voices;      // the voice effects
  final int talkOn;               // where talking goes, as chosen: [talkServer] or [talkDirect]
  const BoardCommSettings(this.muteSpeaker, this.show, this.direct, this.voice, this.voices, this.talkOn);
}

/// Direct comms on the board (core/app/direct.h).
class DirectSettings {
  final bool on;
  final bool keyed;           // a group with a key; false for the open group
  final String group;
  final String name;          // what the other boards see it as
  final String id;            // the group's id, 8 hex digits
  const DirectSettings(this.on, this.keyed, this.group, this.name, this.id);
}

/// A direct comms group kept in the app: one made here, or joined.
class DirectGroup {
  final String name;
  final String passphrase;
  final String key;           // 32 hex digits, from the two
  final bool mine;            // made here
  const DirectGroup(this.name, this.passphrase, this.key, this.mine);

  String get id => directGroupId(key);

  Map<String, Object> toJson() => {'name': name, 'passphrase': passphrase, 'key': key, 'mine': mine};
  static DirectGroup fromJson(Map<String, dynamic> j) =>
      DirectGroup(j['name'] as String, j['passphrase'] as String, j['key'] as String, j['mine'] == true);
}

/// A group heard about over direct comms.
class HeardGroup {
  final String id;
  String name;
  int rssi;
  int boards;
  int seenMs;
  HeardGroup(this.id, this.name, this.rssi, this.boards, this.seenMs);
}

/// A board heard over direct comms.
class NearbyBoard {
  final int id;
  String name;
  int rssi;
  bool talking;
  int seenMs;
  NearbyBoard(this.id, this.name, this.rssi, this.talking, this.seenMs);
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
    groups.addAll([
      for (final g in jsonDecode(p.getString('directGroups') ?? '[]') as List<dynamic>)
        DirectGroup.fromJson(g as Map<String, dynamic>)
    ]);
    _directSoundSub = board.directSounds.listen(_onDirectSound);
    _directGroupSub = board.directGroups.listen(_onDirectGroup);
    _directPeerSub = board.directPeers.listen(_onDirectPeer);
    // Who's talking, kept up to date whether the voices come from the server
    // or over direct comms
    _talkingTimer ??= Timer.periodic(const Duration(milliseconds: 100), (_) {
      final now = DateTime.now().millisecondsSinceEpoch;
      _updateTalking(now);
      nearby.removeWhere((_, b) => now - b.seenMs > _nearbyFor);
      heardGroups.removeWhere((_, g) => now - g.seenMs > _nearbyFor);
      _updateBoardScreen();   // and whether it's UDP, which changes by itself
    });
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
      final d = v['direct'] as Map<String, dynamic>?;
      boardSettings = BoardCommSettings(
          v['mute'] == 1,
          (v['show'] as num?)?.toInt() ?? 0,
          d == null
              ? null
              : DirectSettings(d['on'] == 1, d['keyed'] == 1, d['group'] as String? ?? '', d['name'] as String? ?? '',
                  d['id'] as String? ?? ''),
          (v['voice'] as num?)?.toInt() ?? -1,
          [for (final n in (v['voices'] as List<dynamic>? ?? const [])) n as String],
          (v['talk'] as num?)?.toInt() ?? talkServer);
      notifyListeners();
    } catch (_) {}
  }

  /// Change the board's: the speaker off while it sends, when it shows the
  /// Comm screen (1 sending, 2 hearing, 3 both), and the voice effect for
  /// what's sent (-1 for the speaker's).
  Future<void> setBoardSettings({bool? muteSpeaker, int? show, int? voice}) => _boardSettingsRequest('POST', [
        '?',
        if (muteSpeaker != null) 'mute=${muteSpeaker ? 1 : 0}&',
        if (show != null) 'show=$show&',
        if (voice != null) 'voice=$voice',
      ].join());

  // ----- Direct comms -----

  /// Groups made here or joined, kept with their passphrases to join again.
  final List<DirectGroup> groups = [];

  /// Groups heard about over the air, by id.
  final Map<String, HeardGroup> heardGroups = {};

  /// Boards heard over direct comms, by their id.
  final Map<int, NearbyBoard> nearby = {};
  static const _nearbyFor = 7000;

  StreamSubscription<DirectSound>? _directSoundSub;
  StreamSubscription<DirectPeer>? _directPeerSub;
  StreamSubscription<DirectGroupHeard>? _directGroupSub;
  final Map<int, (int, int)> _directSeq = {};     // sender: its last seq, and that counted on

  /// A direct sender's voice, kept apart from the server's sessions.
  static int directSession(int sender) => 0x40000000 | (sender & 0x3FFFFFFF);
  static bool isDirectSession(int session) => session & 0x40000000 != 0;

  /// Direct voice waits this much longer than the server's: a packet lost on
  /// the way comes again with the next one or two, 20 or 40 ms later.
  static const _directExtraMs = 40;

  // How direct comms' voices are doing, in the log every couple of seconds
  static const _logDirectStats = false;   // true to see them in the log
  int _directLogMs = 0;
  int _directPackets = 0;
  void _logDirect(int now) {
    if (!_logDirectStats) return;
    _directPackets++;
    if (now - _directLogMs < 2000) return;
    _directLogMs = now;
    for (final sp in mixer.speakers.values.where((sp) => isDirectSession(sp.session))) {
      debugPrint('direct ${talkerName(sp.session)}: ${sp.packets} packets, ${sp.lost} lost, '
          '${sp.underruns} underruns, ${sp.concealed * 10} ms made up, '
          '${sp.dropped * 1000 ~/ sp.sampleRate} ms dropped, '
          '${sp.queued * 1000 ~/ sp.sampleRate} ms queued ($_directPackets in)');
    }
    _directPackets = 0;
  }

  Future<void> setDirect(bool on) => _boardSettingsRequest('POST', '?direct=${on ? 1 : 0}');

  /// The group the board's in: one of [groups], or null for the open group
  /// or one set from another phone.
  DirectGroup? get currentGroup {
    final d = boardSettings?.direct;
    if (d == null || !d.keyed) return null;
    for (final g in groups) {
      if (g.id == d.id) return g;
    }
    return null;
  }

  Future<void> joinOpenGroup() => _setBoardGroup('', '');

  /// Join a group: by its name and passphrase. If it was heard over the air
  /// ([expectId]), the passphrase is checked against it first. Returns why
  /// not, or null once it's joined.
  Future<String?> joinGroup(String name, String passphrase, {String? expectId, bool mine = false}) async {
    name = name.trim();
    if (name.isEmpty) return 'It needs a name';
    if (utf8.encode(name).length > 15) return 'That name is too long';
    if (passphrase.isEmpty) return 'It needs a passphrase';
    final key = await compute(directKey, (name, passphrase));
    final g = DirectGroup(name, passphrase, key, mine);
    if (expectId != null && g.id != expectId) return "That's not the passphrase";
    groups.removeWhere((o) => o.id == g.id);
    groups.add(g);
    await _saveGroups();
    await _setBoardGroup(key, name);
    return null;
  }

  /// Make a new group, with a passphrase for the others to join with.
  Future<String?> createGroup(String name, String passphrase) async {
    final clash = heardGroups.values.any((h) => h.name == name.trim());
    if (clash) return 'A group by that name is about already';
    return joinGroup(name, passphrase, mine: true);
  }

  /// Forget a group; the board goes back to the open group if it was in it.
  Future<void> deleteGroup(DirectGroup g) async {
    final current = currentGroup?.id == g.id;
    groups.removeWhere((o) => o.id == g.id);
    await _saveGroups();
    if (current) await joinOpenGroup();
    notifyListeners();
  }

  Future<void> _saveGroups() async {
    await _prefs?.setString('directGroups', jsonEncode([for (final g in groups) g.toJson()]));
  }

  Future<void> _setBoardGroup(String key, String name) {
    String q(String v) => Uri.encodeQueryComponent(v);
    return _boardSettingsRequest('POST', '?key=$key&group=${q(name)}&name=${q(server.username)}');
  }

  void _onDirectGroup(DirectGroupHeard h) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final g = heardGroups[h.id];
    if (g == null) {
      heardGroups[h.id] = HeardGroup(h.id, h.name, h.rssi, h.boards, now);
    } else {
      g
        ..name = h.name
        ..rssi = h.rssi
        ..boards = h.boards
        ..seenMs = now;
    }
    notifyListeners();
  }

  void _onDirectPeer(DirectPeer p) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final b = nearby[p.id];
    if (b == null) {
      nearby[p.id] = NearbyBoard(p.id, p.name, p.rssi, p.talking, now);
    } else {
      b
        ..name = p.name
        ..rssi = p.rssi
        ..talking = p.talking
        ..seenMs = now;
    }
    notifyListeners();
  }

  void _onDirectSound(DirectSound d) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final name = nearby[d.sender]?.name;
    if (name != null && muted.contains(name)) return;
    // Its seq wraps at 65536: count on past that, in the server's 10 ms frames
    final prev = _directSeq[d.sender];
    int counted;
    if (prev == null || d.first) {
      counted = d.seq;
    } else {
      var delta = (d.seq - prev.$1) & 0xFFFF;
      if (delta >= 0x8000) delta -= 0x10000;
      counted = prev.$2 + delta;
    }
    _directSeq[d.sender] = (d.seq, counted);
    _audio.start();
    mixer.receive(directSession(d.sender), counted * 2, d.opus, d.last, now, extraMs: _directExtraMs);
    _logDirect(now);
    _heard(directSession(d.sender), d.last);
  }

  /// A talker's name, whether they're on the server or heard directly.
  String talkerName(int session) {
    if (isDirectSession(session)) {
      for (final b in nearby.values) {
        if (directSession(b.id) == session) return b.name;
      }
      return 'Nearby';
    }
    return mumble?.users[session]?.name ?? '?';
  }

  // ----- Talk on: the server or direct comms -----

  static const talkServer = 0;
  static const talkDirect = 1;

  Future<void> setTalkOn(int transport) => _boardSettingsRequest('POST', '?talk=$transport');

  /// Where talking goes now, as the board decides it: the one chosen, unless
  /// nobody's on it to hear and someone's on the other.
  int get talkNow {
    final pref = boardSettings?.talkOn ?? talkServer;
    final m = mumble;
    final serverUp = m != null && m.state == MumbleState.connected;
    final serverHeard = serverUp && m.channelUsers.isNotEmpty;
    final directUp = boardSettings?.direct?.on ?? false;
    final directHeard = directUp && nearby.isNotEmpty;
    if (pref == talkServer) {
      return serverUp && (serverHeard || !directHeard)
          ? talkServer
          : directUp
              ? talkDirect
              : talkServer;
    }
    return directUp && (directHeard || !serverHeard)
        ? talkDirect
        : serverUp
            ? talkServer
            : talkDirect;
  }

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
      for (final s in talking)
        if (isDirectSession(s))
          Talker(talkerName(s), _boardAvatars.slotFor(_textureOf(talkerName(s)), soon: true), true)
        else if (connected)
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

  /// A name's Mumble avatar, for someone heard directly.
  Uint8List? _textureOf(String name) {
    final m = mumble;
    if (m == null) return null;
    for (final u in m.users.values) {
      if (u.name == name) return u.texture;
    }
    return null;
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
      if (!isDirectSession(session) && !m.users.containsKey(session)) mixer.remove(session);
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
    talking = {};
    _heardAt.clear();
    _updateBoardScreen();
    // Direct comms can carry on without the server
    final direct = boardSettings?.direct?.on ?? false;
    if (!direct) await _audio.stop();
    for (final session in mixer.speakers.keys.toList()) {
      if (!isDirectSession(session)) mixer.remove(session);
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
    _directSoundSub?.cancel();
    _directPeerSub?.cancel();
    _directGroupSub?.cancel();
    _talkingTimer?.cancel();
    disconnectServer();
    board.disconnect();
    super.dispose();
  }
}
