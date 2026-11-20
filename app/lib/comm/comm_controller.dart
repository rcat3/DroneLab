/// The comm channel on the phone: the board's voice goes to the Mumble
/// server as it is (no decoding or encoding), and everyone else's comes back
/// through the jitter buffers and the mixer to the headphones.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'audio_out.dart';
import 'avatars.dart';
import 'background.dart';
import 'board_link.dart';
import 'board_protocol.dart';
import 'calls.dart';
import 'invites.dart';
import 'conversations.dart';
import 'notifier.dart';
import 'firmware_update.dart';
import 'identity.dart';
import 'known_people.dart';
import 'jitter.dart';
import 'media_buttons.dart';
import 'recorder.dart';
import 'mumble_client.dart';

/// Who talking goes to: our server channel, our direct channel, or one
/// person, by who they are (KnownPerson.id).
class TalkTarget {
  final TalkTo kind;
  final String? personId;
  const TalkTarget.server()
      : kind = TalkTo.server,
        personId = null;
  const TalkTarget.direct()
      : kind = TalkTo.direct,
        personId = null;
  const TalkTarget.person(String id)
      : kind = TalkTo.person,
        personId = id;

  String get pref => personId == null ? kind.name : 'person:$personId';

  static TalkTarget fromPref(String? p) => p == 'direct'
      ? const TalkTarget.direct()
      : p != null && p.startsWith('person:')
          ? TalkTarget.person(p.substring('person:'.length))
          : const TalkTarget.server();

  @override
  bool operator ==(Object other) => other is TalkTarget && other.kind == kind && other.personId == personId;
  @override
  int get hashCode => Object.hash(kind, personId);
}

/// How talking would go now.
enum TalkRoute { server, direct }

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
  final int talkOn;               // before commVersion 11: the channel talked on, 0 the server's, 1 direct
  final String? housing;          // 'speaker' or 'low-profile'; null from older firmware
  const BoardCommSettings(this.muteSpeaker, this.show, this.direct, this.voice, this.voices, this.talkOn,
      [this.housing]);

  /// Whether the housing has a speaker: not the low-profile model. Older
  /// firmware doesn't say, and is taken to have one, showing everything.
  bool get hasSpeaker => housing != 'low-profile';
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
  Uint8List? key;     // its wearer's public key, checked by our board
  NearbyBoard(this.id, this.name, this.rssi, this.talking, this.seenMs, [this.firmware = '', this.app = '', this.key]);
}

class CommController extends ChangeNotifier {
  final BoardLink board = BoardLink();
  ServerSettings server = ServerSettings();
  int bufferMs = 60;

  MumbleClient? mumble;
  bool _serverWanted = false;

  /// Who we are (identity.dart): null if the phone's secure storage
  /// couldn't be used, and then we're only a name.
  Identity? identity;

  /// Everyone we've come across, by who they are (known_people.dart).
  late final KnownPeople people = KnownPeople((json) => _prefs?.setString('knownPeople', json))
    ..onRenamed = (oldId, newId) {
      conversations.rekey(Conversation.personKey(oldId), Conversation.personKey(newId));
      conversations.renameWho(oldId, newId);
    };
  Timer? _reconnect;
  String? serverError;

  /// Texts and commands, to and from others, a conversation for each who
  /// with (see conversations.dart).
  final Conversations conversations = Conversations();

  /// Notifications: texts that come in, and the unit's battery running low.
  final Notifier notifier = Notifier();
  bool _batteryWarned = false;

  late final Mixer mixer = Mixer(sampleRate: outputRate, newDecoder: OpusVoiceDecoder.new, targetMs: bufferMs);
  late final AudioOut _audio = AudioOut(mixer);
  Timer? _talkingTimer;

  /// Who's talking on the channel, in the order they started. Counted from
  /// when their voice arrives, so the board's screen shows them at once.
  Set<int> talking = {};

  /// Those talking to us alone just now: whispered on the server, or sealed
  /// for us over direct comms.
  Set<int> talkingToUs = {};
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
    _commandCounter = p.getInt('commandCounter') ?? 0;
    server = ServerSettings(
      host: p.getString('host') ?? '',
      port: p.getInt('port') ?? 64738,
      username: p.getString('username') ?? '',
      password: p.getString('password') ?? '',
    );
    bufferMs = p.getInt('bufferMs') ?? 60;
    final a = p.getString('avatar');
    avatar = a == null ? null : base64Decode(a);
    people.load(p.getString('knownPeople'));
    try {
      identity = await Identity.load();
    } catch (e) {
      debugPrint('identity: $e');
    }
    channel = p.getString('channel');
    _talkTo = TalkTarget.fromPref(p.getString('talkTo'));
    talkTones = p.getBool('talkTones') ?? true;
    ringInHeadphones = p.getBool('ringInHeadphones') ?? true;
    ringTone = p.getString('ringTone') ?? 'chirp';
    missedCalls.load(p.getString('missedCalls'));
    // Talking to someone alone takes a call, which doesn't outlast the app
    if (_talkTo.kind == TalkTo.person) _talkTo = const TalkTarget.server();
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
    _talkedSub = board.talked.listen(_onTalked);
    _callTimer = Timer.periodic(const Duration(seconds: 1), (_) => _callTick());
    await conversations.load();
    conversations.onSeen = notifier.clearTexts;
    await notifier.init();
    // Who's talking, kept up to date whether the voices come from the server
    // or over direct comms
    _talkingTimer ??= Timer.periodic(const Duration(milliseconds: 100), (_) {
      final now = DateTime.now().millisecondsSinceEpoch;
      _updateTalking(now);
      _fixTalkTo();
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
    _checkBattery();
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
          (v['talk'] as num?)?.toInt() ?? 0,
          v['housing'] as String?);
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
  StreamSubscription<Talked>? _talkedSub;
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
      nearby[p.id] = NearbyBoard(p.id, p.name, p.rssi, p.talking, now, p.firmware, p.app, p.key);
    } else {
      b
        ..name = p.name
        ..key = p.key
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
    final b = nearby[d.sender];
    if (b != null && personOfBoard(b).muted) return;
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
    final heard = _audible(directSession(d.sender), d.alone);
    _logVoice(directSession(d.sender), d.alone, heard);
    _heard(directSession(d.sender), d.last, alone: d.alone);
    if (!heard) return;
    _audio.start();
    mixer.receive(directSession(d.sender), counted * 2, d.opus, d.last, now, extraMs: _directExtraMs);
    _logDirect(now);
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

  // ----- Who talking goes to -----

  /// Who talking goes to: our channel on the server, our direct channel, or
  /// one person, by who they are. Kept for next time. Firmware from before
  /// commVersion 11 can't talk to one person: it talks to the server's
  /// channel meanwhile.
  TalkTarget get talkTo => _talkTo.kind == TalkTo.person && board.status != null && !boardTalksTo
      ? const TalkTarget.server()
      : _talkTo;
  TalkTarget _talkTo = const TalkTarget.server();

  /// The firmware takes who to talk to (commVersion 11); before it, only
  /// which channel, as "talk on" the server or direct comms.
  bool get boardTalksTo => (board.status?.version ?? 0) >= commVersionTalkTo;

  Future<void> setTalkTo(TalkTarget t) async {
    _talkTo = _picked = t;
    await _prefs?.setString('talkTo', t.pref);
    _updateBoardScreen();
    notifyListeners();
  }

  /// What was picked to talk to, which [talkTo] goes back to once it's
  /// there again after standing in for it.
  TalkTarget? _picked;

  /// Whether talking to it is there to pick: the server's channel while
  /// connected, the direct channel while direct's on, someone while
  /// there's a call with them.
  bool _talkable(TalkTarget t) => switch (t.kind) {
        TalkTo.server => _serverUp,
        TalkTo.direct => _directOn,
        TalkTo.person => calls.containsKey(t.personId),
      };

  /// What's picked went (the server disconnected, direct went off): talk
  /// to the first that's there, the server's channel, then direct, or to
  /// nothing if neither is; and back to what was picked once it's there
  /// again. Every tenth of a second, with the rest.
  void _fixTalkTo() {
    final picked = _picked ?? _talkTo;
    TalkTarget? next;
    if (_talkable(picked)) {
      if (_talkTo != picked) next = picked;
    } else if (!_talkable(_talkTo)) {
      for (final t in const [TalkTarget.server(), TalkTarget.direct()]) {
        if (_talkable(t)) {
          next = t;
          break;
        }
      }
    }
    if (next == null || next == _talkTo) return;
    _talkTo = next;
    _updateBoardScreen();
    notifyListeners();
  }

  /// Whether talking would reach who it's for now, and how: null if nobody
  /// would hear it. One person goes over direct comms if their board's
  /// about, as the board decides, else over the server.
  TalkRoute? get talkRoute {
    final m = mumble;
    switch (talkTo.kind) {
      case TalkTo.server:
        return _serverUp && m!.channelUsers.isNotEmpty ? TalkRoute.server : null;
      case TalkTo.direct:
        return _directOn && nearby.isNotEmpty ? TalkRoute.direct : null;
      case TalkTo.person:
        final id = talkTo.personId!;
        if (!(calls[id]?.connected ?? false)) return null;     // not till they've answered
        final b = directBoard(id);
        if (b != null && b.key != null && boardTalksTo && _pairKeys.containsKey(Identity.idOf(b.key!))) {
          return TalkRoute.direct;
        }
        return serverUser(id) != null ? TalkRoute.server : null;
    }
  }

  bool get _directOn => board.state == BoardState.connected && (boardSettings?.direct?.on ?? false);

  /// What talking goes to, by name: the channel's, or the person's.
  String get talkToName => switch (talkTo.kind) {
        TalkTo.server => mumble?.channels[mumble?.myChannel] ?? 'Server',
        TalkTo.direct => switch (boardSettings?.direct) {
            final d? => d.keyed ? d.group : 'Open channel',
            null => 'Direct',
          },
        TalkTo.person => people[talkTo.personId!]?.name ?? '?',
      };

  Uint8List? _sentTalkTo;
  int? _sentTalkOn;       // to firmware before commVersion 11

  /// Tell the board who talking goes to, when it changes; and the server who
  /// to whisper to, ahead of talking, as it's set over TCP and the voice may
  /// go over UDP.
  void _sendTalkTo() {
    final t = talkTo;
    // One person, once they've answered: till then, nobody, so the board
    // refuses to talk
    final inCall = t.kind == TalkTo.person && (calls[t.personId!]?.connected ?? false);
    final u = inCall ? serverUser(t.personId!) : null;
    mumble?.whisperTo(u == null ? null : [u.session]);
    if (!boardTalksTo) {
      // Older firmware: the channel, as talking on the server or direct
      final on = t.kind == TalkTo.direct ? 1 : 0;
      if (boardSettings != null && boardSettings!.talkOn != on && _sentTalkOn != on) {
        _sentTalkOn = on;
        _boardSettingsRequest('POST', '?talk=$on');
      }
      return;
    }
    final msg = talkToMessage(t.kind,
        key: t.kind == TalkTo.person
            ? (inCall ? people[t.personId!]?.key : null) ?? Uint8List(Identity.keyLength)
            : null,
        onServer: u != null,
        name: talkToName);
    if (_sentTalkTo == null || !listEquals(msg, _sentTalkTo)) {
      _sentTalkTo = msg;
      board.send(msg);
    }
  }

  // ----- Keys shared with one other, for talking to them alone directly -----

  /// Made as their boards are heard, by their key's id; and those the board
  /// has, in the order they were first heard, the oldest going once there
  /// are more than it keeps.
  final Map<String, (Uint8List, Uint8List)> _pairKeys = {};   // their public key, and the one we share
  final Set<String> _pairsMaking = {};
  final List<String> _pairsWanted = [];
  String? _sentPairs;

  void _sendPairs() {
    final me = identity;
    if (me == null || !boardTalksTo) return;
    for (final b in nearby.values) {
      final key = b.key;
      if (key == null) continue;
      final id = Identity.idOf(key);
      if (!_pairsWanted.contains(id)) _pairsWanted.add(id);
      if (!_pairKeys.containsKey(id) && _pairsMaking.add(id)) {
        me.pairKey(key).then((k) {
          _pairsMaking.remove(id);
          if (k != null) _pairKeys[id] = (key, k);
          _updateBoardScreen();
        });
      }
    }
    while (_pairsWanted.length > _pairsMax) {
      _pairsWanted.removeAt(0);
    }
    final pairs = [for (final id in _pairsWanted) ?_pairKeys[id]];
    final now = pairs.map((p) => Identity.idOf(p.$1)).join(',');
    if (now != _sentPairs) {
      _sentPairs = now;
      for (final m in pairsMessages(pairs, board.maxWrite)) {
        board.send(m);
      }
    }
  }

  static const _pairsMax = 12;    // DIRECT_PAIRS_MAX

  // ----- Tones for talking -----

  /// Two short notes up as talking starts, and down as it ends, in the
  /// headphones, for push to talk (not voice mode). Kept for next time.
  bool talkTones = true;

  Future<void> setTalkTones(bool on) async {
    talkTones = on;
    await _prefs?.setBool('talkTones', on);
    notifyListeners();
  }

  /// A transmission started, ended or was refused: tones for it. Refused,
  /// a low buzz, whatever's set, as nobody hears you; but none of them for
  /// voice mode, which starts at each word.
  void _onTalked(Talked t) {
    if (t.byVoice) return;
    final Int16List tone;
    switch (t.what) {
      case Talked.refused:
        tone = mixer.refusedTone();
      case Talked.started || Talked.ended:
        if (!talkTones && !headsetTalking) return;   // the headphones' button always has them
        tone = mixer.chirp(rising: t.what == Talked.started, level: 0.12);
      default:
        return;
    }
    _audio.start();
    mixer.playTone(tone);
  }

  // ----- Whose voice is heard -----

  /// Only the one talked to is heard: the server's channel, the direct
  /// channel, or the person we're in a call with, so it's clear who's to be
  /// answered. [alone] is a voice for us alone (whispered, or sealed with
  /// our pair's key).
  bool _audible(int session, bool alone) {
    final t = talkTo;
    switch (t.kind) {
      case TalkTo.server:
        return !isDirectSession(session) && !alone;
      case TalkTo.direct:
        return isDirectSession(session) && !alone;
      case TalkTo.person:
        return alone && _personOfSession(session) == t.personId && (calls[t.personId!]?.connected ?? false);
    }
  }

  /// Each transmission as it starts: who, whether to us alone, and whether
  /// it's played, in `adb logcat -s flutter`.
  void _logVoice(int session, bool alone, bool heard) {
    if (_heardAt.containsKey(session)) return;
    debugPrint('voice: ${talkerName(session)}${alone ? ' (alone)' : ''} '
        '${heard ? 'played' : 'not played'}, talking to ${talkTo.pref}');
  }

  /// Who a talker is, by who they are, on the server or heard directly.
  String? _personOfSession(int session) {
    if (isDirectSession(session)) {
      for (final b in nearby.values) {
        if (directSession(b.id) == session) return personOfBoard(b).id;
      }
      return null;
    }
    final u = mumble?.users[session];
    return u == null ? null : personOfUser(u).id;
  }

  // ----- Calls (calls.dart) -----

  /// Calls, by who with: ringing, answered, or ours ringing at theirs.
  final Map<String, Call> calls = {};

  /// Calls not answered, by who from, shown by their name till seen to.
  late final MissedCalls missedCalls = MissedCalls((json) => _prefs?.setString('missedCalls', json));

  /// Ring in the headphones too, with this tone (calls.dart's ringTones).
  /// Kept for next time.
  bool ringInHeadphones = true;
  String ringTone = 'chirp';

  /// Someone's started calling: for the app to show it, wherever it is.
  final _incomingCalls = StreamController<Call>.broadcast();
  Stream<Call> get incomingCalls => _incomingCalls.stream;

  /// What happened to a call, to say: declined, no answer, ended.
  final _callNotices = StreamController<String>.broadcast();
  Stream<String> get callNotices => _callNotices.stream;

  Timer? _callTimer;
  late final CallTones _callTones = CallTones(mixer.sampleRate);

  /// Talked to before a call, to go back to after it.
  TalkTarget? _beforeCall;

  /// The same signal comes over the server and directly: once.
  final Map<String, int> _callSignalsSeen = {};

  Future<void> setRing({bool? headphones, String? tone}) async {
    if (headphones != null) {
      ringInHeadphones = headphones;
      await _prefs?.setBool('ringInHeadphones', headphones);
    }
    if (tone != null && ringTones.containsKey(tone)) {
      ringTone = tone;
      await _prefs?.setString('ringTone', tone);
    }
    notifyListeners();
  }

  /// Play the ring tone, to hear what it's like.
  void previewRing(String tone) => _tone(_callTones.ring(tone));

  void _tone(Int16List t) {
    _audio.start();
    mixer.playTone(t);
  }

  /// Whether someone can be called: they've a key to sign for, and are on
  /// the server or nearby. Null if they can, or why not.
  String? whyNotCall(String personId) {
    final name = people[personId]?.name ?? 'They';
    if (serverUser(personId) == null && directBoard(personId) == null) return '$name is out of reach';
    if (isPlainMumble(personId)) return null;     // a whisper line
    if (_keyOf(personId) == null) return "$name can't take calls: their unit's firmware needs updating";
    if (identity == null) return "Calls need this phone's identity, which couldn't be made";
    return null;
  }

  /// Someone on the server with plain Mumble, not the app: no key of
  /// theirs to sign for, so no ringing; a call with them is a whisper line.
  bool isPlainMumble(String personId) => _keyOf(personId) == null && serverUser(personId) != null;

  /// Call someone: their app rings, and talking goes to them once they
  /// answer. Returns why not, or null.
  String? startCall(String personId) {
    final c = calls[personId];
    if (c != null) {
      if (c.state == CallState.ringing) answerCall(personId);
      _goToCall(personId);
      return null;
    }
    final why = whyNotCall(personId);
    if (why != null) return why;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (isPlainMumble(personId)) {
      // Their Mumble can't ring: the line's open at once, whispered
      calls[personId] = Call(personId, 0, CallState.connected, outgoing: true, nowMs: now, plain: true);
      _clearMissed(personId);
      _tone(_callTones.connected());
      _goToCall(personId);
      return null;
    }
    final call = calls[personId] = Call(personId, Random().nextInt(0x7FFFFFFF), CallState.calling, outgoing: true, nowMs: now)
      ..lastSentMs = now;
    _clearMissed(personId);
    _sendCall(personId, CallOp.ring, call.id);
    _tone(_callTones.ringBack());
    _goToCall(personId);
    return null;
  }

  /// Answer someone ringing.
  void answerCall(String personId) {
    final c = calls[personId];
    if (c == null || c.state != CallState.ringing) return;
    c
      ..state = CallState.connected
      ..lastHeardMs = DateTime.now().millisecondsSinceEpoch;
    _sendCall(personId, CallOp.answer, c.id);
    notifier.clearCall(personId);
    mixer.stopTones();
    _tone(_callTones.connected());
    _clearMissed(personId);
    _goToCall(personId);
  }

  /// Hang up, decline, or give up calling.
  void endCall(String personId) {
    final c = calls.remove(personId);
    if (c == null) return;
    _sendCall(personId, c.state == CallState.ringing ? CallOp.decline : CallOp.hangup, c.id);
    notifier.clearCall(personId);
    mixer.stopTones();
    _callOver(personId, null);
  }

  /// Who we're talking to in a call just now, if we are: a call coming in
  /// meanwhile is call waiting.
  String? get inCallWith {
    final t = talkTo;
    return t.kind == TalkTo.person && (calls[t.personId!]?.connected ?? false) ? t.personId : null;
  }

  /// Missed calls from someone, seen to.
  void _clearMissed(String personId) {
    if (missedCalls.clear(personId)) {
      notifier.clearMissed(personId);
      notifyListeners();
    }
  }

  void clearMissed(String personId) => _clearMissed(personId);

  /// Talk to them, from whatever was talked to before.
  void _goToCall(String personId) {
    if (talkTo.kind != TalkTo.person) _beforeCall = talkTo;
    setTalkTo(TalkTarget.person(personId));
  }

  /// A call's over: back to the channel talked to before, if it was being
  /// talked to, and say why if there's a [why].
  void _callOver(String personId, String? why) {
    if (talkTo.kind == TalkTo.person && talkTo.personId == personId) {
      setTalkTo(_beforeCall ?? const TalkTarget.server());
    }
    if (why != null) _callNotices.add(why);
    _updateBoardScreen();
    notifyListeners();
  }

  /// A call's signal, signed for them alone, over both ways that reach them.
  void _sendCall(String personId, int op, int id) =>
      _sendToOne(personId, OthersCommand.callSignal(op, id));

  /// A command for one person alone, signed for them, both ways that reach
  /// them. False if neither does, or they've no key.
  bool _sendToOne(String personId, OthersCommand what) {
    final key = _keyOf(personId);
    if (key == null) return false;
    final cmd = newCommand(what).withScope(OthersCommand.scopeOne);
    final u = serverUser(personId);
    final b = directBoard(personId);
    final direct = b != null && b.key != null && boardTakesCommands;
    if (u != null) _toServer(mumble!, cmd, [u.session], theirKey: key);
    if (direct) _toDirect(cmd, to: b);
    return u != null || direct;
  }

  // ----- Invitations to a direct channel (invites.dart) -----

  /// Someone's invited us: for the app to ask whether to join.
  final _invitations = StreamController<Invitation>.broadcast();
  Stream<Invitation> get invitations => _invitations.stream;
  final Map<String, int> _invitesSeen = {};

  /// The direct channel the board's on, if it's one with a passphrase kept
  /// here, to invite others to.
  DirectGroup? get invitableGroup {
    final d = board.state == BoardState.connected ? boardSettings?.direct : null;
    if (d == null || !d.keyed) return null;
    for (final g in groups) {
      if (g.id == d.id) return g;
    }
    return null;
  }

  /// Whether they can be invited: null if they can, or why not.
  String? whyNotInvite(String personId) {
    final name = people[personId]?.name ?? 'They';
    if (serverUser(personId) == null && directBoard(personId) == null) return '$name is out of reach';
    if (_keyOf(personId) == null) return "$name's app or firmware can't take invitations";
    return null;
  }

  /// Invite them to [g]: they're asked, and join without its passphrase.
  /// Returns why not, or null once it's gone.
  Future<String?> invite(String personId, DirectGroup g) async {
    final why = whyNotInvite(personId);
    if (why != null) return why;
    final pair = await identity?.pairKey(_keyOf(personId)!);
    if (pair == null) return "Couldn't make a key for them";
    final sealed = await sealInvitation(pair, g.name, g.passphrase, g.channel, g.longRange);
    if (sealed == null) return "That channel's name and passphrase are too long to send";
    if (!_sendToOne(personId, OthersCommand.inviteTo(sealed))) return '${people[personId]?.name} is out of reach';
    conversations.add(personConversation(personId),
        ConversationEntry(from: '', mine: true, kind: ConversationEntry.text, body: 'Invited to the direct channel ${g.name}'));
    return null;
  }

  Future<void> _onInvitation(KnownPerson who, Uint8List sealed) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    _invitesSeen.removeWhere((_, at) => now - at > 30000);
    final tag = base64Encode(sealed.sublist(0, sealed.length < 12 ? sealed.length : 12));
    if (_invitesSeen.putIfAbsent(tag, () => now) != now) return;     // the other way's copy
    final key = who.key;
    final pair = key == null ? null : await identity?.pairKey(key);
    if (pair == null) return;
    final got = await openInvitation(pair, sealed);
    if (got == null) {
      debugPrint('invitation from ${who.name}: not one for us');
      return;
    }
    final (name, passphrase, channel, longRange) = got;
    final c = personConversation(who.id);
    conversations.add(c, ConversationEntry(
        from: who.name, who: who.id, mine: false, kind: ConversationEntry.text,
        body: 'Invited you to the direct channel $name'));
    _notifyText(c);
    _invitations.add(Invitation(who.id, who.name, name, passphrase, channel, longRange));
  }

  void _onCallSignal(KnownPerson who, Uint8List data) {
    if (data.length < 5) return;
    final op = data[0];
    final id = data[1] | (data[2] << 8) | (data[3] << 16) | (data[4] << 24);
    final now = DateTime.now().millisecondsSinceEpoch;
    _callSignalsSeen.removeWhere((_, at) => now - at > 2000);
    if (_callSignalsSeen.putIfAbsent('${who.id}:$op:$id', () => now) != now) return;
    final name = who.name;
    var c = calls[who.id];
    if (c != null && c.id == id) c.lastHeardMs = now;
    switch (op) {
      case CallOp.ring:
        if (c != null && c.id == id) {
          if (c.connected) _sendCall(who.id, CallOp.answer, id);    // our answer was lost
          break;
        }
        if (c != null && c.outgoing && c.state == CallState.calling) {
          // Both called at once: take theirs, answered
          calls[who.id] = c = Call(who.id, id, CallState.connected, outgoing: false, nowMs: now);
          _sendCall(who.id, CallOp.answer, id);
          mixer.stopTones();
          _tone(_callTones.connected());
          _goToCall(who.id);
          break;
        }
        calls[who.id] = c = Call(who.id, id, CallState.ringing, outgoing: false, nowMs: now);
        final busyWith = inCallWith;
        notifier.showCall(who.id, name, avatarOf(who.id),
            inCallWith: busyWith == null ? null : people[busyWith]?.name ?? '?');
        if (busyWith != null) {
          _tone(_callTones.waiting());
        } else if (ringInHeadphones) {
          _tone(_callTones.ring(ringTone));
        }
        _incomingCalls.add(c);
      case CallOp.answer:
        if (c != null && c.id == id && c.state == CallState.calling) {
          c.state = CallState.connected;
          mixer.stopTones();
          _tone(_callTones.connected());
        }
      case CallOp.decline || CallOp.hangup:
        if (c == null || c.id != id) break;
        calls.remove(who.id);
        notifier.clearCall(who.id);
        mixer.stopTones();
        if (!c.outgoing && c.state == CallState.ringing) {
          _missed(c);
          break;
        }
        if (c.connected || c.outgoing) _tone(_callTones.ended());
        _callOver(who.id, c.connected ? 'Call with $name ended' : '$name declined the call');
        return;
      case CallOp.hold:
        if (c != null && c.id == id && c.connected) {
          c.theyHoldMs = now;
          if (talkTo.kind == TalkTo.person && talkTo.personId == who.id) _tone(_callTones.hold());
        }
      case CallOp.resume:
        if (c != null && c.id == id) c.theyHoldMs = null;
    }
    _updateBoardScreen();
    notifyListeners();
  }

  /// Someone's call that wasn't answered.
  void _missed(Call c) {
    calls.remove(c.personId);
    notifier.clearCall(c.personId);
    missedCalls.add(c.personId);
    final name = people[c.personId]?.name ?? '?';
    notifier.showMissed(c.personId, name, missedCalls[c.personId]?.$1 ?? 1, avatarOf(c.personId));
    _callOver(c.personId, 'Missed call from $name');
  }

  /// Every second: ring again, give up, say we're away, notice they've gone.
  void _callTick() {
    if (calls.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    var changed = false;
    for (final c in calls.values.toList()) {
      final here = talkTo.kind == TalkTo.person && talkTo.personId == c.personId;
      final name = people[c.personId]?.name ?? '?';
      switch (c.state) {
        case CallState.calling:
          if (now - c.startedMs > CallTiming.giveUpMs) {
            calls.remove(c.personId);
            _sendCall(c.personId, CallOp.hangup, c.id);
            _tone(_callTones.ended());
            _callOver(c.personId, 'No answer from $name');
            continue;
          }
          if (now - c.lastSentMs >= CallTiming.resendMs) {
            c.lastSentMs = now;
            _sendCall(c.personId, CallOp.ring, c.id);
            if (here) _tone(_callTones.ringBack());
          }
        case CallState.ringing:
          if (now - c.lastHeardMs > CallTiming.ringGoneMs) {
            _missed(c);
            continue;
          }
          // Call waiting while we're talking in another call; else the ring
          if (inCallWith != null) {
            if ((now - c.startedMs) % CallTiming.waitingEveryMs < 1000) _tone(_callTones.waiting());
          } else if (ringInHeadphones && (now - c.startedMs) % CallTiming.resendMs < 1000) {
            _tone(_callTones.ring(ringTone));
          }
        case CallState.connected:
          // Away, talking somewhere else: say so every few seconds, for
          // their hold beeps; and once back
          if (!here && now - c.lastSentMs >= CallTiming.holdEveryMs) {
            c
              ..lastSentMs = now
              ..holding = true;
            _sendCall(c.personId, CallOp.hold, c.id);
          } else if (here && c.holding) {
            c.holding = false;
            _sendCall(c.personId, CallOp.resume, c.id);
          }
          if (c.theyHoldMs != null && now - c.theyHoldMs! > CallTiming.holdGoneMs) {
            c.theyHoldMs = null;
            changed = true;
          }
          // Out of reach a while: it's over
          final reachable = serverUser(c.personId) != null || directBoard(c.personId) != null;
          if (reachable) {
            c.lostMs = null;
          } else if ((c.lostMs ??= now) < now - CallTiming.lostForMs) {
            calls.remove(c.personId);
            _tone(_callTones.ended());
            _callOver(c.personId, 'Call with $name dropped: out of reach');
            continue;
          }
      }
    }
    if (changed) notifyListeners();
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

  /// Those muted: they aren't played, nor shown talking on the board. Kept
  /// by who they are (known_people.dart), not their session, which changes
  /// each time they connect.
  Iterable<KnownPerson> get muted => people.muted;

  Future<void> setMuted(String personId, bool mute) async {
    if (people[personId] == null || people[personId]!.muted == mute) return;
    people.setMuted(personId, mute);
    final m = mumble;
    if (mute && m != null) {
      // Stop them now, mid-sentence
      for (final u in m.users.values.where((u) => personOfUser(u).id == personId)) {
        mixer.remove(u.session);
        _heardAt.remove(u.session);
      }
      _updateTalking(DateTime.now().millisecondsSinceEpoch);
    }
    _updateBoardScreen();
    notifyListeners();
  }

  /// Muted: not played, nor shown talking, and their texts and commands
  /// ignored (the board ignores the commands, the app the rest).
  bool isMuted(String personId) => people[personId]?.muted ?? false;

  /// Become whoever an exported code is (Identity.exportCode), in place of
  /// who we were: back on the server as them. Returns what's wrong with the
  /// code, or null.
  Future<String?> importIdentity(String code) async {
    try {
      identity = await Identity.import(code);
    } on FormatException catch (e) {
      return e.message;
    }
    if (_serverWanted) await _connectServer();
    notifyListeners();
    return null;
  }

  // ----- Who people are -----

  /// Someone on the server, by their certificate (known_people.dart).
  KnownPerson personOfUser(MumbleUser u) => people.onServer(u.certHash, u.name);

  /// A board heard over direct comms: by its wearer's key, which their app
  /// signed for it, or only its name without one.
  KnownPerson personOfBoard(NearbyBoard b) => b.key != null ? people.byKey(b.key!, b.name) : people.named(b.name);

  bool _sessionMuted(int session) {
    final u = mumble?.users[session];
    return u != null && personOfUser(u).muted;
  }

  /// Someone known before by the name [p] goes by, who isn't [p]: a warning
  /// that [p] may be passing as them.
  KnownPerson? nameClash(KnownPerson p) => people.clashes(p);

  /// Someone who was [old] has a new identity, [now]: the new one's them
  /// from now on, and the old one's forgotten (see KnownPeople.replace).
  void acceptNewIdentity(KnownPerson old, KnownPerson now) {
    people.replace(old.id, now.id);
    _sentMuted = null;    // the board's list, by key, again
    _updateBoardScreen();
    notifyListeners();
  }

  /// Who a conversation's line is from, as it's shown: their name, with a
  /// warning if it's someone else using a name someone had first.
  String fromLabel(ConversationEntry e) {
    final who = people[e.who];
    return who != null && nameClash(who) != null ? '⚠ ${e.from}' : e.from;
  }

  /// Ours, as sent to everyone on the server, once it's made for this one.
  Uint8List? _announcement;
  MumbleClient? _announcementFor;
  final Set<int> _announcedTo = {};

  /// Tell those on the server who we are, signed, as they're seen: everyone
  /// there as we arrive, then each who comes after.
  Future<void> _announce(MumbleClient m) async {
    final me = identity, fp = m.fingerprint, mine = m.mySession;
    if (me == null || fp == null || mine == null || m.state != MumbleState.connected) return;
    if (_announcementFor != m) {
      _announcementFor = m;
      _announcedTo.clear();
      _announcement = null;
      _announcement = await IdentityAnnouncement.make(me, fp);
    }
    final data = _announcement;
    if (data == null || m != mumble) return;
    final to = [for (final s in m.users.keys) if (s != mine && !_announcedTo.contains(s)) s];
    if (to.isEmpty) return;
    _announcedTo.addAll(to);
    m.sendPluginData(to, IdentityAnnouncement.dataId, data);
  }

  /// Someone's told us who they are: believed if it's signed by the key it
  /// gives, for the certificate the server says they have, on this server.
  Future<void> _onAnnouncement(MumbleClient m, MumblePluginData d) async {
    final a = await IdentityAnnouncement.read(d.data);
    final u = m.users[d.sender];
    if (a == null || u == null || u.certHash != a.certificateHash || a.serverFingerprint != m.fingerprint) {
      debugPrint('identity: a bad announcement from ${u?.name ?? d.sender}');
      return;
    }
    people.bind(a.publicKey, a.certificateHash, u.name);
    notifyListeners();
  }

  // ----- The board's Comm screen -----

  Uint8List? _sentServer;
  Uint8List? _sentHearing;
  String? _sentMuted;
  bool _sentIdentity = false;
  int? _boundId;      // the board's direct id we've signed it's ours for

  /// Tell the board how the server's doing and who's talking, when it
  /// changes, and all of it when the board's newly there. Avatars go as
  /// they're needed: ours and those talking first, then everyone else's.
  void _updateBoardScreen() {
    _boardAvatars.update();
    if (board.state != BoardState.connected || board.status == null) {
      _sentServer = _sentHearing = _sentMuted = _sentTalkTo = null;
      _sentTalkOn = null;
      _sentPairs = null;
      _sentIdentity = false;
      _boundId = null;
      return;
    }
    _sendTalkTo();
    _sendPairs();
    final keys = (board.status?.version ?? 0) >= commVersionKeys;
    // Who we are, and that the board's ours, for its hello over direct comms
    final me = identity;
    if (keys && me != null) {
      if (!_sentIdentity) {
        _sentIdentity = true;
        _boundId = null;
        board.send(identityMessage(me.publicKey));
      }
      final id = board.status?.directId;
      if (id != null && id != _boundId) {
        _boundId = id;
        me.sign(boardBindingSigned(id)).then((sig) {
          if (_boundId == id && board.state == BoardState.connected) board.send(bindingMessage(sig));
        });
      }
    }
    // Who's muted, by key, for the board to ignore their commands too
    final mutedKeys = [for (final p in muted) if (p.key != null) p.key!];
    final mutedNow = (mutedKeys.map(Identity.idOf).toList()..sort()).join('\n');
    if (_sentMuted != mutedNow && keys) {
      _sentMuted = mutedNow;
      for (final piece in mutedMessages(mutedKeys)) {
        board.send(piece);
      }
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
      for (final s in talking.where((s) => _audible(s, talkingToUs.contains(s))))
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
  void _heard(int session, bool last, {bool alone = false}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (alone) {
      talkingToUs.add(session);
    } else {
      talkingToUs.remove(session);
    }
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
    talkingToUs.retainAll(next);
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
    // The board says when it starts and ends (and refuses), for the tones,
    // from commVersion 11; before that, a chirp for each press
    if (chirp && !boardTalksTo) mixer.playTone(mixer.chirp(rising: talk));
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

  /// Our last command's counter: our clock in ms, but always more than the
  /// last, so a board can tell an old one played back. Kept, in case the
  /// clock goes back.
  int _commandCounter = 0;

  /// True if the board takes commands for others.
  bool get boardTakesCommands =>
      board.state == BoardState.connected && (board.status?.version ?? 0) >= commVersionKeys;

  /// A command, numbered: sent again as it is, it's only done once.
  OthersCommand newCommand(OthersCommand cmd) {
    _commandCounter = max(_commandCounter + 1, DateTime.now().millisecondsSinceEpoch);
    _prefs?.setInt('commandCounter', _commandCounter);
    return cmd.withCounter(_commandCounter);
  }

  /// Commands go out in order, each signed as it goes.
  Future<void> _sending = Future.value();

  void _sendSigned(OthersCommand cmd, List<int> context, void Function(Uint8List signed) send) {
    final me = identity;
    if (me == null) return;
    _sending = _sending.then((_) async {
      final body = cmd.body(me.publicKey);
      final sig = await me.sign(OthersCommand.signedPart(context, body));
      send(Uint8List.fromList([...body, ...sig]));
    }).catchError((Object e) => debugPrint('command: $e'));
  }

  static List<int> _unhex(String hex) =>
      [for (var i = 0; i + 1 < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)];

  /// What a command to a channel on the server is signed for: the server's
  /// certificate and the channel.
  List<int> _serverChannelContext(MumbleClient m) =>
      OthersCommand.contextServerChannel(_unhex(m.fingerprint ?? ''), m.myChannel);

  /// A command from someone on the server: checked, then on to the board,
  /// which decides whether to do it.
  void _onPluginData(MumbleClient m, MumblePluginData d) {
    if (d.id == IdentityAnnouncement.dataId) {
      _onAnnouncement(m, d);
      return;
    }
    if (d.id != commandDataId) return;
    final u = m.users[d.sender];
    final cmd = ReadCommand.parse(d.data);
    final me = identity;
    if (u == null || u.name.isEmpty || cmd == null || me == null) return;
    final context = switch (cmd.scope) {
      OthersCommand.scopeEveryone => OthersCommand.contextEveryone(),
      OthersCommand.scopeChannel => _serverChannelContext(m),
      OthersCommand.scopeOne => OthersCommand.contextOne(me.publicKey),
      _ => null,
    };
    if (context == null) return;
    Identity.verify(cmd.key, OthersCommand.signedPart(context, cmd.body), cmd.signature).then((good) {
      if (!good) {
        debugPrint('command: a bad signature from ${u.name}, dropped');
        return;
      }
      final who = people.byKey(cmd.key, u.name);
      if (who.muted) return;
      // A call's signal is the app's own
      const at = OthersCommand.headerLength;
      if (cmd.body.length > at && cmd.body[at] == OthersCommand.call) {
        if (cmd.scope == OthersCommand.scopeOne) _onCallSignal(who, Uint8List.sublistView(cmd.body, at + 1));
        return;
      }
      if (cmd.body.length > at && cmd.body[at] == OthersCommand.invite) {
        if (cmd.scope == OthersCommand.scopeOne) _onInvitation(who, Uint8List.sublistView(cmd.body, at + 1));
        return;
      }
      if (!boardTakesCommands) return;
      board.send(commandFromServer(u.name, cmd.body));
    });
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

  /// Someone's conversation, by who they are (KnownPerson.id).
  Conversation personConversation(String personId) => conversations.get(
      Conversation.personKey(personId), ConversationKind.person, people[personId]?.name ?? '');

  static String personOf(Conversation c) => c.key.substring('person:'.length);

  /// Someone, by who they are: on the server (anywhere on it), or heard
  /// nearby.
  MumbleUser? serverUser(String personId) {
    final m = mumble;
    if (m == null || !_serverUp) return null;
    for (final u in m.users.values) {
      if (u.session != m.mySession && personOfUser(u).id == personId) return u;
    }
    return null;
  }

  NearbyBoard? directBoard(String personId) {
    if (!_directUp) return null;
    for (final b in nearby.values) {
      if (personOfBoard(b).id == personId) return b;
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

  /// Over direct comms: to every board in our group, signed for everyone or
  /// for the group's channel, or to one board, signed for its wearer.
  void _toDirect(OthersCommand cmd, {NearbyBoard? to}) {
    final List<int> context;
    if (to != null) {
      if (to.key == null) return;     // nobody we can sign for
      context = OthersCommand.contextOne(to.key!);
    } else if (cmd.scope == OthersCommand.scopeChannel) {
      context = OthersCommand.contextDirectChannel(_unhex(boardSettings?.direct?.id ?? ''));
    } else {
      context = OthersCommand.contextEveryone();
    }
    _sendSigned(cmd, context, (signed) => board.send(commandToDirect(to == null ? const [] : [to.id], signed)));
  }

  /// Over the server, to these sessions.
  void _toServer(MumbleClient m, OthersCommand cmd, List<int> sessions, {Uint8List? theirKey}) {
    if (sessions.isEmpty) return;
    final context = switch (cmd.scope) {
      OthersCommand.scopeChannel => _serverChannelContext(m),
      OthersCommand.scopeOne => OthersCommand.contextOne(theirKey!),
      _ => OthersCommand.contextEveryone(),
    };
    _sendSigned(cmd, context, (signed) => m.sendPluginData(sessions, commandDataId, signed));
  }

  /// Someone's key, by who they are, if they've one.
  Uint8List? _keyOf(String personId) => people[personId]?.key;

  /// Text a conversation: over the server as a Mumble text message (to the
  /// channel, or to one person), and over direct comms as one of ours.
  /// Returns false if it couldn't go anywhere.
  bool sendText(Conversation c, String text) {
    text = text.trim();
    if (text.isEmpty) return false;
    final m = mumble;
    var sent = false;
    // Over direct comms: in one command, or in parts if it's long
    final textId = Random().nextInt(0x10000);
    void toDirect({NearbyBoard? to}) {
      for (final part in OthersCommand.sendText(text, id: textId)) {
        _toDirect(newCommand(part).withScope(_scopeOf(c)), to: to);
      }
    }
    switch (c.kind) {
      case ConversationKind.everyone:
        if (_serverUp) {
          m!.sendText(_html(text) + _everyoneMark);
          sent = true;
        }
        if (_directUp) {
          toDirect();
          sent = true;
        }
      case ConversationKind.server:
        if (serverConversation?.key == c.key) {
          m!.sendText(_html(text));
          sent = true;
        }
      case ConversationKind.direct:
        if (directConversation?.key == c.key) {
          toDirect();
          sent = true;
        }
      case ConversationKind.person:
        // Both ways they can be reached: they keep the first that comes
        final u = serverUser(personOf(c));
        final b = directBoard(personOf(c));
        if (u != null) {
          m!.sendTextTo(u.session, _html(text));
          sent = true;
        }
        if (b != null && b.key != null) {
          toDirect(to: b);
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
    void toServer(List<int> sessions, {Uint8List? theirKey}) {
      if (sessions.isEmpty) return;
      _toServer(m!, cmd, sessions, theirKey: theirKey);
      sent = true;
    }
    void toDirect({NearbyBoard? to}) {
      _toDirect(cmd, to: to);
      sent = true;
    }
    final channelSessions = _serverUp ? [for (final u in m!.channelUsers) u.session] : const <int>[];
    switch (c.kind) {
      case ConversationKind.everyone:
        if (_serverUp) toServer(channelSessions);
        if (_directUp) toDirect();
      case ConversationKind.server:
        if (serverConversation?.key == c.key) toServer(channelSessions);
      case ConversationKind.direct:
        if (directConversation?.key == c.key) toDirect();
      case ConversationKind.person:
        // Both ways they can be reached, signed for them alone: their board
        // does it once, by whichever way first comes that they allow
        final key = _keyOf(personOf(c));
        final u = serverUser(personOf(c));
        final b = directBoard(personOf(c));
        if (u != null && key != null) toServer([u.session], theirKey: key);
        if (b != null && b.key != null) toDirect(to: b);
    }
    if (sent && log) {
      final op = cmd.what;
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

  /// A text's come in: a notification, unless its conversation's on screen.
  void _notifyText(Conversation c) {
    final visible = WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    if (visible && conversations.open == c.key) return;
    final unread = c.entries.length < c.unread ? c.entries : c.entries.sublist(c.entries.length - c.unread);
    final texts = [
      for (final e in unread)
        if (e.kind == ConversationEntry.text && !e.mine) e
    ];
    final last = texts.length > 6 ? texts.sublist(texts.length - 6) : texts;
    final group = c.kind != ConversationKind.person;
    notifier.showTexts(c.key, c.title, [for (final e in last) (fromLabel(e), e.body, e.time, _avatarByName(e.from))],
        group: group);
  }

  /// Someone's avatar, by who they are: theirs on the server, or their
  /// board's.
  Uint8List? avatarOf(String personId) =>
      serverUser(personId)?.texture ?? (directBoard(personId) == null ? null : directAvatars[directBoard(personId)!.id]);

  /// For a notification, by the name on a text: theirs, if they're about.
  Uint8List? _avatarByName(String name) {
    for (final u in mumble?.users.values ?? const <MumbleUser>[]) {
      if (u.name == name && u.texture != null) return u.texture;
    }
    for (final b in nearby.values) {
      if (b.name == name && directAvatars[b.id] != null) return directAvatars[b.id];
    }
    return null;
  }

  /// The unit's battery: a notification once it's down to 15%, gone again
  /// once it's charging or back over 20%.
  void _checkBattery() {
    final s = board.status;
    final pct = board.state == BoardState.connected ? s?.battery : null;
    if (pct == null) return;
    if (!_batteryWarned && pct <= 15 && !s!.charging) {
      _batteryWarned = true;
      notifier.showBattery(pct);
    } else if (_batteryWarned && (s!.charging || pct > 20)) {
      _batteryWarned = false;
      notifier.clearBattery();
    }
  }

  /// Marks a server text as one for everyone who can hear us, for others'
  /// apps; Mumble's own apps don't show it.
  static const _everyoneMark = '<!-- everyone -->';

  /// A text message on the server: to our channel, or to us alone.
  void _onServerText(MumbleText t) {
    final u = t.session == null ? null : mumble?.users[t.session];
    final who = u == null ? people.named(t.from) : personOfUser(u);
    if (who.muted) return;
    final text = plainText(t.message);
    if (_seenText(who.id, text)) return;
    final c = t.private
        ? personConversation(who.id)
        : t.message.contains(_everyoneMark)
            ? everyoneConversation
            : (serverConversation ?? everyoneConversation);
    conversations.add(c, ConversationEntry(from: t.from, who: who.id, mine: false, kind: ConversationEntry.text, body: text));
    _notifyText(c);
  }

  /// What someone sent our board, as it passes it on: into the conversation
  /// it was for.
  /// Long texts' parts, as they come, by who and the text's id: put back
  /// together once they're all here, or shown as far as they go if some
  /// haven't come after a while, as over direct comms nothing sends a lost
  /// one again.
  final Map<String, PartialText> _textParts = {};
  final Map<String, int> _textsDone = {};       // those shown, so late parts are dropped
  static const _partsFor = Duration(seconds: 30);

  Heard? _textFromParts(Heard h) {
    final d = h.data;
    if (d.length < 4 || d[2] >= d[3]) return null;
    final now = DateTime.now().millisecondsSinceEpoch;
    _textsDone.removeWhere((_, at) => now - at > 2 * _partsFor.inMilliseconds);
    final key = '${Identity.idOf(h.key)}:${d[0] | (d[1] << 8)}';
    if (_textsDone.containsKey(key)) return null;
    final got = _textParts.putIfAbsent(key, () {
      final p = PartialText(h, d[3]);
      p.timer = Timer(_partsFor, () => _flushText(key));
      return p;
    });
    got.parts[d[2]] = Uint8List.sublistView(d, 4);
    if (got.parts.length < got.count) return null;
    (got.timer as Timer?)?.cancel();
    _textParts.remove(key);
    _textsDone[key] = now;
    return got.text();
  }

  /// A long text some of whose parts never came: what did, with a gap for
  /// each run that's missing.
  void _flushText(String key) {
    final got = _textParts.remove(key);
    if (got == null) return;
    _textsDone[key] = DateTime.now().millisecondsSinceEpoch;
    _onHeard(got.text());
  }

  void _onHeard(Heard h) {
    if (h.what == Heard.textPart) {
      final whole = _textFromParts(h);
      if (whole == null) return;
      h = whole;
    }
    // Who, by the key they signed it with
    final who = people.byKey(h.key, h.from);
    if (who.muted) return;
    if (h.what == Heard.call) {
      if (h.scope == OthersCommand.scopeOne) _onCallSignal(who, h.data);
      return;
    }
    if (h.what == Heard.invite) {
      if (h.scope == OthersCommand.scopeOne) _onInvitation(who, h.data);
      return;
    }
    final c = switch (h.scope) {
      OthersCommand.scopeOne => personConversation(who.id),
      OthersCommand.scopeChannel => (h.direct ? directConversation : serverConversation) ?? everyoneConversation,
      _ => everyoneConversation,
    };
    if (h.what == Heard.text && _seenText(who.id, h.textOf)) return;
    final e = h.what == Heard.text
        ? ConversationEntry(from: h.from, who: who.id, mine: false, kind: ConversationEntry.text, body: h.textOf)
        : ConversationEntry(
            from: h.from,
            who: who.id,
            mine: false,
            kind: h.what == Heard.terminal ? ConversationEntry.terminal : ConversationEntry.lovense,
            body: describeCommand(h.data, mine: false),
            done: h.done);
    // Refused by one way, then done when it came the other: done, once
    final last = c.entries.isEmpty ? null : c.entries.last;
    if (e.done &&
        last != null &&
        !last.done &&
        !last.mine &&
        last.who == e.who &&
        last.kind == e.kind &&
        last.body == e.body &&
        e.time.difference(last.time) < const Duration(seconds: 5)) {
      c.entries.removeLast();
      if (c.unread > 0) c.unread--;
    }
    conversations.add(c, e);
    if (h.what == Heard.text) _notifyText(c);
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
        host: server.host,
        port: server.port,
        username: server.username,
        password: server.password,
        identity: identity)
      ..avatar = avatar;
    mumble = m;
    serverError = null;
    _updateBoardScreen();
    _mumbleSubs.add(m.changes.listen((_) => _onMumbleChanged(m)));
    _mumbleSubs.add(m.voice.listen((v) {
      if (_sessionMuted(v.session)) return;
      final heard = _audible(v.session, v.alone);
      _logVoice(v.session, v.alone, heard);
      _heard(v.session, v.last, alone: v.alone);
      if (!heard) return;
      mixer.receive(v.session, v.seq, v.opus, v.last, DateTime.now().millisecondsSinceEpoch);
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
    _announce(m);
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
    _callTimer?.cancel();
    _soundSub?.cancel();
    _directSoundSub?.cancel();
    _directPeerSub?.cancel();
    _heardSub?.cancel();
    _talkedSub?.cancel();
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

