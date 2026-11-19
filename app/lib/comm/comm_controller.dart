/// The comm channel on the phone: the board's voice goes to the Mumble
/// server as it is (no decoding or encoding), and everyone else's comes back
/// through the jitter buffers and the mixer to the headphones.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'audio_out.dart';
import 'avatars.dart';
import 'background.dart';
import 'board_link.dart';
import 'board_protocol.dart';
import 'conversations.dart';
import 'firmware_update.dart';
import 'jitter.dart';
import 'media_buttons.dart';
import 'recorder.dart';
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
  final int channel;
  final bool longRange;
  final bool scanning;        // listening to the other channels for groups
  const DirectSettings(this.on, this.keyed, this.group, this.name, this.id, this.channel, this.longRange, this.scanning);
}

/// A direct comms group kept in the app: one made here, or joined.
class DirectGroup {
  final String name;
  final String passphrase;
  final String key;           // 32 hex digits, from the two
  final bool mine;            // made here
  final int channel;          // 1, 6 or 11
  final bool longRange;
  const DirectGroup(this.name, this.passphrase, this.key, this.mine, [this.channel = 6, this.longRange = true]);

  String get id => directGroupId(key);

  Map<String, Object> toJson() =>
      {'name': name, 'passphrase': passphrase, 'key': key, 'mine': mine, 'channel': channel, 'lr': longRange};
  static DirectGroup fromJson(Map<String, dynamic> j) => DirectGroup(j['name'] as String, j['passphrase'] as String,
      j['key'] as String, j['mine'] == true, (j['channel'] as num?)?.toInt() ?? 6, j['lr'] as bool? ?? true);
}

/// How a channel's radio is set up, to show: "frequency 6, Long Range".
String radioText(int channel, bool longRange) => 'frequency $channel${longRange ? ', Long Range' : ''}';

/// A group heard about over direct comms.
class HeardGroup {
  final String id;
  String name;
  int rssi;
  int boards;
  int channel;
  bool longRange;
  int seenMs;
  HeardGroup(this.id, this.name, this.rssi, this.boards, this.channel, this.longRange, this.seenMs);
}

/// A server text message's HTML, as plain text.
String plainText(String html) => html
    .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
    .replaceAll(RegExp(r'<[^>]*>'), '')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&amp;', '&')
    .trim();

/// A board heard over direct comms.
class NearbyBoard {
  final int id;
  String name;
  int rssi;
  bool talking;
  int seenMs;
  String firmware;    // its version, '' if not known
  String app;         // its phone's app's version, '' for none or not known
  NearbyBoard(this.id, this.name, this.rssi, this.talking, this.seenMs, [this.firmware = '', this.app = '']);
}

class CommController extends ChangeNotifier {
  final BoardLink board = BoardLink();
  ServerSettings server = ServerSettings();
  int bufferMs = 60;

  MumbleClient? mumble;
  bool _serverWanted = false;
  Timer? _reconnect;
  String? serverError;

  /// Texts and commands, to and from others, a conversation for each who
  /// with (see conversations.dart).
  final Conversations conversations = Conversations();

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

  // ----- The board's firmware -----

  /// The firmware the app carries, if it does (see firmware_update.dart).
  BundledFirmware? bundledFirmware;
  late final FirmwareUpdate firmwareUpdate = FirmwareUpdate(board);

  /// How the board's firmware stands against the app's, once it's said.
  FirmwareStanding get firmwareStanding {
    final status = board.status;
    if (board.state != BoardState.connected || status == null) return FirmwareStanding.unknown;
    // Older than the app can update: only the web installer will do
    if (status.version < commVersionUpdate) return FirmwareStanding.needsInstaller;
    final b = bundledFirmware;
    final mine = releaseOf(board.firmware);
    final theirs = b == null ? null : releaseOf(b.version);
    if (board.firmware == null || mine == null || b == null || theirs == null || board.model != b.board) {
      return FirmwareStanding.unknown;
    }
    final c = compareReleases(mine, theirs);
    if (c < 0) return board.canUpdate ? FirmwareStanding.canUpdate : FirmwareStanding.needsInstaller;
    return c > 0 ? FirmwareStanding.newer : FirmwareStanding.current;
  }

  Future<void> updateFirmware() async {
    final b = bundledFirmware;
    if (b != null) await firmwareUpdate.run(b);
  }

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
    bundledFirmware = await BundledFirmware.load();
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
    _recordSub = board.recorded.listen((s) => _recorder?.add(s));
    recordSpeakerVoice = p.getBool('recordSpeakerVoice') ?? true;
    recordBeep = p.getBool('recordBeep') ?? false;
    _directPeerSub = board.directPeers.listen(_onDirectPeer);
    _directAvatarSub = board.directAvatars.listen(_onDirectAvatar);
    _heardSub = board.heard.listen(_onHeard);
    await conversations.load();
    // Who's talking, kept up to date whether the voices come from the server
    // or over direct comms
    _talkingTimer ??= Timer.periodic(const Duration(milliseconds: 100), (_) {
      final now = DateTime.now().millisecondsSinceEpoch;
      _updateTalking(now);
      nearby.removeWhere((_, b) => now - b.seenMs > _nearbyFor);
      // Groups on other channels are only heard while scanning: keep them a while
      heardGroups.removeWhere((_, g) => now - g.seenMs > _heardGroupFor);
      _updateBoardScreen();   // and whether it's UDP, which changes by itself
    });
    mixer.targetMs = bufferMs;
    board.addListener(_onBoardChanged);
    _soundSub = board.sounds.listen(_onBoardSound);
    await loadOpus();
    notifyListeners();
    // Back to the server and the board from last time, unless they were
    // disconnected on purpose
    if (server.complete && (p.getBool('serverWanted') ?? false)) connectServer();
    final id = lastBoardId;
    if (id != null && (p.getBool('boardWanted') ?? true)) {
      await board.connect(id, lastBoardName ?? 'Board');
      await _updateBackground();
    }
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
    await _prefs?.setBool('boardWanted', true);
    await board.connect(id, name);
    await _updateBackground();
  }

  Future<void> disconnectBoard() async {
    await _prefs?.setBool('boardWanted', false);
    await board.disconnect();
    await _updateBackground();
  }

  void _onBoardChanged() {
    if (recording && board.state != BoardState.connected) stopRecording();    // the board's gone
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
      _boardNameSent = null;
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
                  d['id'] as String? ?? '', (d['channel'] as num?)?.toInt() ?? 6, d['lr'] == 1, d['scanning'] == 1),
          (v['voice'] as num?)?.toInt() ?? -1,
          [for (final n in (v['voices'] as List<dynamic>? ?? const [])) n as String],
          (v['talk'] as num?)?.toInt() ?? talkServer);
      notifyListeners();
      _nameBoard();
    } catch (_) {}
  }

  /// The name sent to the board for direct comms, this connection.
  String? _boardNameSent;

  /// Have the board go by our server name over direct comms too, in
  /// whichever channel it's in: it's only told along with a channel
  /// otherwise, so one left in the open channel goes by its Bluetooth name.
  void _nameBoard() {
    final want = server.username;
    final have = boardSettings?.direct?.name;
    if (have == null || want.isEmpty || want == have || want == _boardNameSent) return;
    _boardNameSent = want;     // once: older firmware ignores it
    _boardSettingsRequest('POST', '?name=${Uri.encodeQueryComponent(want)}');
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
  static const _heardGroupFor = 60000;

  StreamSubscription<DirectSound>? _directSoundSub;
  StreamSubscription<DirectPeer>? _directPeerSub;
  StreamSubscription<Heard>? _heardSub;
  StreamSubscription<DirectAvatarPiece>? _directAvatarSub;

  /// The avatars of boards heard over direct comms, as PNGs, by board id.
  final Map<int, Uint8List> directAvatars = {};
  final Map<int, ({Uint8List pixels, Set<int> got, int size, int pieces})> _avatarsComing = {};

  void _onDirectAvatar(DirectAvatarPiece p) {
    var a = _avatarsComing[p.id];
    if (a == null || a.size != p.size || a.pieces != p.pieces || p.piece == 0) {
      a = (pixels: Uint8List(p.size * p.size * 2), got: <int>{}, size: p.size, pieces: p.pieces);
      _avatarsComing[p.id] = a;
    }
    final at = p.piece * 200;
    if (at >= a.pixels.length) return;
    a.pixels.setRange(at, min(at + p.pixels.length, a.pixels.length), p.pixels);
    a.got.add(p.piece);
    if (a.got.length < a.pieces) return;
    _avatarsComing.remove(p.id);
    compute(directAvatarPng, (a.pixels, a.size)).then((png) {
      directAvatars[p.id] = png;
      notifyListeners();
    });
  }
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

  Future<void> joinOpenGroup() => _setBoardGroup('', '', 6, true);

  /// Listen to the other channels for a few seconds, for the groups there.
  Future<void> scanDirect() async {
    await _boardSettingsRequest('POST', '?scan=1');
    // Catch up as it finishes: a couple of seconds a channel
    for (final s in const [3, 6, 9]) {
      Timer(Duration(seconds: s), () => _boardSettingsRequest('GET', ''));
    }
  }

  /// Join a group: by its name and passphrase. If it was heard over the air
  /// ([expectId]), the passphrase is checked against it first. Returns why
  /// not, or null once it's joined.
  Future<String?> joinGroup(String name, String passphrase,
      {String? expectId, bool mine = false, int channel = 6, bool longRange = true}) async {
    name = name.trim();
    if (name.isEmpty) return 'It needs a name';
    if (utf8.encode(name).length > 15) return 'That name is too long';
    if (passphrase.isEmpty) return 'It needs a passphrase';
    final key = await compute(directKey, (name, passphrase));
    final g = DirectGroup(name, passphrase, key, mine, channel, longRange);
    if (expectId != null && g.id != expectId) return "That's not the passphrase";
    groups.removeWhere((o) => o.id == g.id);
    groups.add(g);
    await _saveGroups();
    await _setBoardGroup(key, name, channel, longRange);
    return null;
  }

  /// Make a new group, with a passphrase for the others to join with.
  Future<String?> createGroup(String name, String passphrase, int channel, bool longRange) async {
    final clash = heardGroups.values.any((h) => h.name == name.trim());
    if (clash) return 'A channel by that name is about already';
    return joinGroup(name, passphrase, mine: true, channel: channel, longRange: longRange);
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

  Future<void> _setBoardGroup(String key, String name, int channel, bool longRange) {
    String q(String v) => Uri.encodeQueryComponent(v);
    return _boardSettingsRequest(
        'POST', '?key=$key&group=${q(name)}&name=${q(server.username)}&ch=$channel&lr=${longRange ? 1 : 0}');
  }

  void _onDirectGroup(DirectGroupHeard h) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final g = heardGroups[h.id];
    if (g == null) {
      heardGroups[h.id] = HeardGroup(h.id, h.name, h.rssi, h.boards, h.channel, h.longRange, now);
    } else {
      g
        ..name = h.name
        ..rssi = h.rssi
        ..boards = h.boards
        ..channel = h.channel
        ..longRange = h.longRange
        ..seenMs = now;
    }
    notifyListeners();
  }

  void _onDirectPeer(DirectPeer p) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final b = nearby[p.id];
    if (b == null) {
      nearby[p.id] = NearbyBoard(p.id, p.name, p.rssi, p.talking, now, p.firmware, p.app);
    } else {
      b
        ..name = p.name
        ..firmware = p.firmware.isNotEmpty ? p.firmware : b.firmware
        ..app = p.app
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

  // ----- Recording -----

  /// Record the speaker's voice effect (or the comm voice), with a sync beep
  /// to start (or not). Kept for next time.
  bool recordSpeakerVoice = true;
  bool recordBeep = false;

  Recorder? _recorder;
  StreamSubscription<BoardSound>? _recordSub;
  Timer? _recordTick;
  bool _resumeServer = false;
  bool _resumeDirect = false;
  bool get recording => _recorder != null;
  Duration get recordingLength => _recorder?.length ?? Duration.zero;

  /// The recording last made, and those before it.
  List<Recording> recordings = [];

  Future<void> setRecordOptions({bool? speakerVoice, bool? beep}) async {
    if (speakerVoice != null) recordSpeakerVoice = speakerVoice;
    if (beep != null) recordBeep = beep;
    await _prefs?.setBool('recordSpeakerVoice', recordSpeakerVoice);
    await _prefs?.setBool('recordBeep', recordBeep);
    notifyListeners();
  }

  Future<void> loadRecordings() async {
    recordings = await listRecordings();
    notifyListeners();
  }

  /// Start recording. Comms stop meanwhile (the server and direct comms),
  /// and start again afterwards. Returns why not, or null.
  Future<String?> startRecording() async {
    if (recording) return null;
    if (board.state != BoardState.connected || board.status == null) return 'Connect to the board first';
    if (board.status!.version < 3) return "The board's firmware is too old to record";
    holdToTalk(false);
    _resumeServer = _serverWanted;
    _resumeDirect = boardSettings?.direct?.on ?? false;
    if (_serverWanted) await disconnectServer(forGood: false);
    if (_resumeDirect) await setDirect(false);
    _recorder = await Recorder.start(OpusVoiceDecoder());
    await board.send(recordMessage(true, speakerVoice: recordSpeakerVoice, beep: recordBeep));
    _recordTick = Timer.periodic(const Duration(milliseconds: 250), (_) => notifyListeners());
    notifyListeners();
    return null;
  }

  /// Stop, finish the file, and start comms again as they were.
  Future<void> stopRecording() async {
    final r = _recorder;
    if (r == null) return;
    await board.send(recordMessage(false));
    await Future<void>.delayed(const Duration(milliseconds: 300));   // the last few packets
    _recorder = null;
    _recordTick?.cancel();
    await r.finish();
    if (_resumeDirect && board.state == BoardState.connected) await setDirect(true);
    if (_resumeServer) await connectServer();
    await loadRecordings();
  }

  /// The recording playing, if one is.
  File? playing;
  Timer? _playTimer;

  Future<void> play(Recording r) async {
    stopPlaying();
    final samples = await readRecording(r.file);
    await _audio.start();
    mixer.playTone(samples);
    playing = r.file;
    _playTimer = Timer(Duration(milliseconds: samples.length * 1000 ~/ outputRate + 200), stopPlaying);
    notifyListeners();
  }

  void stopPlaying() {
    if (playing == null) return;
    mixer.stopTones();
    playing = null;
    _playTimer?.cancel();
    notifyListeners();
  }

  Future<void> deleteRecording(Recording r) async {
    if (playing?.path == r.file.path) stopPlaying();
    await r.file.delete();
    await loadRecordings();
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

  // ----- Commands for others' boards (core/app/others.h) -----

  /// What commands are called in Mumble's plugin data.
  static const commandDataId = 'dronelab-command';

  final int _commandSource = Random.secure().nextInt(0xFFFFFFFF);
  int _commandSeq = 0;

  /// True if the board takes commands for others.
  bool get boardTakesCommands =>
      board.state == BoardState.connected && (board.status?.version ?? 0) >= commVersionCommands;

  /// A new command, from [make], with its source and the next seq.
  OthersCommand newCommand(OthersCommand Function(int source, int seq) make) =>
      make(_commandSource, _commandSeq = (_commandSeq + 1) & 0xFFFF);

  /// A command from someone on the server: on to the board, which decides
  /// whether to do it.
  void _onPluginData(MumbleClient m, MumblePluginData d) {
    if (d.id != commandDataId || !boardTakesCommands) return;
    final name = m.users[d.sender]?.name ?? '';
    if (name.isEmpty || d.data.length > othersCommandMax) return;
    board.send(commandFromServer(name, d.data));
  }

  // ----- Conversations -----

  bool get _serverUp => mumble?.state == MumbleState.connected;
  bool get _directUp => boardTakesCommands && (boardSettings?.direct?.on ?? false);

  /// Everyone who can hear us, by any means.
  Conversation get everyoneConversation =>
      conversations.get(Conversation.everyoneKey(), ConversationKind.everyone, 'Broadcast');

  /// Our channel on the server, and our direct comms channel, while we're
  /// on them.
  Conversation? get serverConversation {
    final m = mumble;
    if (m == null || !_serverUp) return null;
    final channel = m.channelPath(m.myChannel);
    return conversations.get(Conversation.serverKey(channel), ConversationKind.server, channel);
  }

  Conversation? get directConversation {
    final d = boardSettings?.direct;
    if (!_directUp || d == null) return null;
    return conversations.get(Conversation.directKey(d.id), ConversationKind.direct, d.keyed ? d.group : 'Open channel');
  }

  Conversation personConversation(String name) =>
      conversations.get(Conversation.personKey(name), ConversationKind.person, name);

  static String personOf(Conversation c) => c.key.substring('person:'.length);

  /// Someone, by name: on the server (anywhere on it), or heard nearby.
  MumbleUser? serverUser(String name) {
    final m = mumble;
    if (m == null || !_serverUp) return null;
    for (final u in m.users.values) {
      if (u.name == name && u.session != m.mySession) return u;
    }
    return null;
  }

  NearbyBoard? directBoard(String name) {
    if (!_directUp) return null;
    for (final b in nearby.values) {
      if (b.name == name) return b;
    }
    return null;
  }

  /// Whether a conversation can be sent to now.
  bool isOnline(Conversation c) => switch (c.kind) {
        ConversationKind.everyone => _serverUp || _directUp,
        ConversationKind.server => serverConversation?.key == c.key,
        ConversationKind.direct => directConversation?.key == c.key,
        ConversationKind.person => serverUser(personOf(c)) != null || directBoard(personOf(c)) != null,
      };

  static int _scopeOf(Conversation c) => switch (c.kind) {
        ConversationKind.everyone => OthersCommand.scopeEveryone,
        ConversationKind.server || ConversationKind.direct => OthersCommand.scopeChannel,
        ConversationKind.person => OthersCommand.scopeOne,
      };

  static String _html(String text) =>
      text.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('\n', '<br>');

  void _toDirect(OthersCommand cmd, List<int> targets) =>
      board.send(commandToDirect(targets.take(directCommandTargets).toList(), cmd.bytes));

  /// Text a conversation: over the server as a Mumble text message (to the
  /// channel, or to one person), and over direct comms as one of ours.
  /// Returns false if it couldn't go anywhere.
  bool sendText(Conversation c, String text) {
    text = text.trim();
    if (text.isEmpty) return false;
    final m = mumble;
    var sent = false;
    OthersCommand direct() => newCommand((source, seq) => OthersCommand.sendText(source, seq, text)).withScope(_scopeOf(c));
    switch (c.kind) {
      case ConversationKind.everyone:
        if (_serverUp) {
          m!.sendText(_html(text) + _everyoneMark);
          sent = true;
        }
        if (_directUp) {
          _toDirect(direct(), const []);
          sent = true;
        }
      case ConversationKind.server:
        if (serverConversation?.key == c.key) {
          m!.sendText(_html(text));
          sent = true;
        }
      case ConversationKind.direct:
        if (directConversation?.key == c.key) {
          _toDirect(direct(), const []);
          sent = true;
        }
      case ConversationKind.person:
        final u = serverUser(personOf(c));
        final b = u == null ? directBoard(personOf(c)) : null;
        if (u != null) {
          m!.sendTextTo(u.session, _html(text));
          sent = true;
        } else if (b != null) {
          _toDirect(direct(), [b.id]);
          sent = true;
        }
    }
    if (sent) conversations.add(c, ConversationEntry(from: '', mine: true, kind: ConversationEntry.text, body: text));
    return sent;
  }

  /// Send a command (for their Terminals or Lovense devices) to a
  /// conversation: everyone in it, whichever ways reach them. Returns false
  /// if it couldn't go anywhere.
  bool sendCommandTo(Conversation c, OthersCommand command, {bool log = true}) {
    final cmd = command.withScope(_scopeOf(c));
    final m = mumble;
    var sent = false;
    void toServer(List<int> sessions) {
      if (sessions.isEmpty) return;
      m!.sendPluginData(sessions, commandDataId, cmd.bytes);
      sent = true;
    }
    void toDirect(List<int> targets) {
      _toDirect(cmd, targets);
      sent = true;
    }
    final channelSessions = _serverUp ? [for (final u in m!.channelUsers) u.session] : const <int>[];
    switch (c.kind) {
      case ConversationKind.everyone:
        if (_serverUp) toServer(channelSessions);
        if (_directUp) toDirect(const []);
      case ConversationKind.server:
        if (serverConversation?.key == c.key) toServer(channelSessions);
      case ConversationKind.direct:
        if (directConversation?.key == c.key) toDirect(const []);
      case ConversationKind.person:
        final u = serverUser(personOf(c));
        final b = u == null ? directBoard(personOf(c)) : null;
        if (u != null) {
          toServer([u.session]);
        } else if (b != null) {
          toDirect([b.id]);
        }
    }
    if (sent && log) {
      final op = Uint8List.sublistView(cmd.bytes, 8);
      conversations.add(c, ConversationEntry(
          from: '', mine: true, kind: _kindOf(op), body: describeCommand(op, mine: true)));
    }
    return sent;
  }

  static String _kindOf(Uint8List op) => op.isNotEmpty && (op[0] == OthersCommand.message || op[0] == OthersCommand.clear)
      ? ConversationEntry.terminal
      : ConversationEntry.lovense;

  /// Texts lately, by who and what, so one sent to everyone who can hear
  /// them, which comes both over the server and directly, shows once.
  final Map<String, int> _recentTexts = {};
  static const _sameTextFor = 10000;   // ms

  bool _seenText(String from, String text) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _recentTexts.removeWhere((_, at) => now - at > _sameTextFor);
    return _recentTexts.putIfAbsent('$from\n$text', () => now) != now;
  }

  /// Marks a server text as one for everyone who can hear us, for others'
  /// apps; Mumble's own apps don't show it.
  static const _everyoneMark = '<!-- everyone -->';

  /// A text message on the server: to our channel, or to us alone.
  void _onServerText(MumbleText t) {
    final text = plainText(t.message);
    if (_seenText(t.from, text)) return;
    final c = t.private
        ? personConversation(t.from)
        : t.message.contains(_everyoneMark)
            ? everyoneConversation
            : (serverConversation ?? everyoneConversation);
    conversations.add(c, ConversationEntry(from: t.from, mine: false, kind: ConversationEntry.text, body: text));
  }

  /// What someone sent our board, as it passes it on: into the conversation
  /// it was for.
  void _onHeard(Heard h) {
    final c = switch (h.scope) {
      OthersCommand.scopeOne => personConversation(h.from),
      OthersCommand.scopeChannel => (h.direct ? directConversation : serverConversation) ?? everyoneConversation,
      _ => everyoneConversation,
    };
    if (h.what == Heard.text && _seenText(h.from, h.textOf)) return;
    final e = h.what == Heard.text
        ? ConversationEntry(from: h.from, mine: false, kind: ConversationEntry.text, body: h.textOf)
        : ConversationEntry(
            from: h.from,
            mine: false,
            kind: h.what == Heard.terminal ? ConversationEntry.terminal : ConversationEntry.lovense,
            body: describeCommand(h.data, mine: false),
            done: h.done);
    conversations.add(c, e);
  }

  // ----- The server -----

  Future<void> connectServer() async {
    if (!server.complete) return;
    _serverWanted = true;
    await _prefs?.setBool('serverWanted', true);
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
    _mumbleSubs.add(m.texts.listen(_onServerText));
    _mumbleSubs.add(m.pluginData.listen((d) => _onPluginData(m, d)));
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

  /// Leave the server: for good, to stay off when the app starts next, or
  /// just for now, as for a recording.
  Future<void> disconnectServer({bool forGood = true}) async {
    _serverWanted = false;
    if (forGood) await _prefs?.setBool('serverWanted', false);
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
    _heardSub?.cancel();
    _directAvatarSub?.cancel();
    _directGroupSub?.cancel();
    _recordSub?.cancel();
    _talkingTimer?.cancel();
    disconnectServer(forGood: false);
    board.disconnect();
    super.dispose();
  }
}

/// The board's firmware, against the one the app carries.
enum FirmwareStanding {
  unknown,          // not said yet, a development build, another kind of board, or the app carries none
  current,          // the same release
  canUpdate,        // older, and the app can update it
  needsInstaller,   // older, and too old for the app to update: the web installer
  newer,            // newer than the app's: the app wants updating
}
