/// The Guide's side of HiveSight, on a computer: the sender
/// (tools/hivesight-sender, a Python/GStreamer program carried beside the
/// app as dronelab-unit is) started as a helper, and the Guide page's link
/// to it.
///
/// The sender listens for the Guide page on 127.0.0.1 only, with a token
/// written to its stdin, and for Vessels over TLS with this identity's
/// HiveSight certificate. The Guide page starts a session (a token and when
/// it ends), and invitations carry that token; ending the session drops
/// every Vessel. Its settings are one tree with dotted keys, the same as
/// the Vessel's Params.kt.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_profile.dart';
import 'comm_controller.dart';
import 'conversations.dart';
import 'hivesight_invite.dart';
import 'hivesight_words.dart';
import 'identity.dart';

/// How the sender's camera, microphone and media are set up: given to it
/// when it starts.
class SenderOptions {
  final String camera; // a V4L2 device; '' for the test pattern
  final String format; // mjpeg or yuyv
  final int width, height, fps;
  final String layout; // sbs or mono
  final String mic; // a PipeWire/PulseAudio source; '' for the default
  final bool audio; // the Guide's voice at all
  final String mediaDir; // '' for ~/Videos

  const SenderOptions({
    this.camera = '',
    this.format = 'mjpeg',
    this.width = 2560,
    this.height = 720,
    this.fps = 30,
    this.layout = 'sbs',
    this.mic = '',
    this.audio = true,
    this.mediaDir = '',
  });

  SenderOptions copyWith({
    String? camera,
    String? format,
    int? width,
    int? height,
    int? fps,
    String? layout,
    String? mic,
    bool? audio,
    String? mediaDir,
  }) => SenderOptions(
    camera: camera ?? this.camera,
    format: format ?? this.format,
    width: width ?? this.width,
    height: height ?? this.height,
    fps: fps ?? this.fps,
    layout: layout ?? this.layout,
    mic: mic ?? this.mic,
    audio: audio ?? this.audio,
    mediaDir: mediaDir ?? this.mediaDir,
  );

  Map<String, Object> toJson() => {
    'camera': camera,
    'format': format,
    'width': width,
    'height': height,
    'fps': fps,
    'layout': layout,
    'mic': mic,
    'audio': audio,
    'mediaDir': mediaDir,
  };

  static SenderOptions fromJson(Map<String, dynamic> j) => SenderOptions(
    camera: j['camera'] as String? ?? '',
    format: j['format'] as String? ?? 'mjpeg',
    width: (j['width'] as num?)?.toInt() ?? 2560,
    height: (j['height'] as num?)?.toInt() ?? 720,
    fps: (j['fps'] as num?)?.toInt() ?? 30,
    layout: j['layout'] as String? ?? 'sbs',
    mic: j['mic'] as String? ?? '',
    audio: j['audio'] as bool? ?? true,
    mediaDir: j['mediaDir'] as String? ?? '',
  );

  List<String> get args => [
    if (camera.isEmpty) '--test-pattern' else ...['--device', camera, '--format', format],
    '--width',
    '$width',
    '--height',
    '$height',
    '--fps',
    '$fps',
    '--layout',
    layout,
    if (!audio) '--no-audio' else if (mic.isNotEmpty) ...['--mic', mic],
    if (mediaDir.isNotEmpty) ...['--media-dir', mediaDir],
  ];
}

/// A camera, as the sender lists them.
class SenderCamera {
  final String path, name;
  final List<({String format, int width, int height, List<int> fps})> modes;
  const SenderCamera(this.path, this.name, this.modes);
}

/// A Vessel connected to the session.
class GuideVessel {
  final String id; // the sender's: their address and port
  final String name; // their phone's own name for itself
  final String addr;
  final Uint8List? key; // their identity, if they signed for it
  final bool verified; // signed for this session by that key
  final bool lightPulse; // they allow us the light pulse
  final Map<String, dynamic> stats;
  const GuideVessel(this.id, this.name, this.addr, this.key, this.verified, this.lightPulse, this.stats);

  /// Who they are, as known_people has them, if they're signed.
  String? get personId => key != null && verified ? 'k:${Identity.idOf(key!)}' : null;
}

enum SenderState { stopped, starting, running, failed }

class HiveSightGuide extends ChangeNotifier {
  final CommController comm;
  HiveSightGuide._(this.comm);

  static HiveSightGuide? _one;
  static HiveSightGuide of(CommController comm) => _one ??= HiveSightGuide._(comm);

  /// The Vessels' TLS port: fixed, so invitations stay good when the sender
  /// restarts.
  static const vesselPort = 8443;

  /// The system's Python: the one with GStreamer's bindings, as distributions
  /// package them (a conda or venv python3 on the PATH usually hasn't).
  static const python = '/usr/bin/python3';

  /// Only on Linux for now: the sender's GStreamer pipelines are Linux's.
  static bool get supported => Platform.isLinux && script != null;

  static String? get script {
    final f = File('${File(Platform.resolvedExecutable).parent.path}/hivesight-sender/hivesight_sender.py');
    return f.existsSync() ? f.path : null;
  }

  // ----- The sender -----

  SenderState state = SenderState.stopped;

  /// Why it isn't running, when it failed.
  String? problem;

  /// What's missing to run it: packages to install.
  List<String> missing = const [];

  /// Its last lines of output, for when something's wrong.
  final List<String> output = [];

  SenderOptions options = const SenderOptions();
  List<SenderCamera> cameras = const [];
  List<({String name, String label})> mics = const [];

  Process? _process;
  bool _stopping = false;
  int _guidePort = 0;
  List<String> addrs = const [];
  final String _guideToken = _randomToken();

  SharedPreferences? _prefs;

  Future<void> _load() async {
    if (_prefs != null) return;
    _prefs = await SharedPreferences.getInstance();
    try {
      final j = _prefs!.getString('hiveSightSender');
      if (j != null) options = SenderOptions.fromJson(jsonDecode(j) as Map<String, dynamic>);
    } catch (_) {}
  }

  /// Use [o] from now on. A new camera, mode, microphone or media folder
  /// changes over while it runs, the Vessels staying connected, and with
  /// [useCamera] the camera's what they see; turning the voice on or off
  /// restarts it (a session carries on).
  Future<void> setOptions(SenderOptions o, {bool useCamera = false}) async {
    await _load();
    final old = options;
    options = o;
    await _prefs!.setString('hiveSightSender', jsonEncode(o.toJson()));
    notifyListeners();
    if (state == SenderState.running && linked && o.audio == old.audio) {
      _send({
        'type': 'capture',
        'device': o.camera,
        'format': o.format,
        'width': o.width,
        'height': o.height,
        'fps': o.fps,
        'layout': o.layout,
        'mic': o.mic,
        'media_dir': o.mediaDir,
      });
      if (useCamera) this.useCamera();
    } else if (state == SenderState.running || state == SenderState.starting) {
      await restart();
    }
  }

  void _say(String line) {
    output.add(line);
    if (output.length > 200) output.removeRange(0, output.length - 200);
  }

  /// What the system's Python lacks for the sender, as packages to install
  /// (Debian/Ubuntu names).
  Future<List<String>> checkMissing() async {
    const probe = '''
import importlib, sys
missing = []
try:
    import gi
    gi.require_version("Gst", "1.0")
    gi.require_version("GstPbutils", "1.0")
    from gi.repository import Gst, GstPbutils
except Exception:
    missing.append("gi")
for m in ("aiohttp", "numpy"):
    try:
        importlib.import_module(m)
    except Exception:
        missing.append(m)
print(" ".join(missing))
''';
    try {
      final r = await Process.run(python, ['-c', probe]);
      if (r.exitCode != 0) return ['python3'];
      final names = (r.stdout as String).trim().split(' ').where((s) => s.isNotEmpty);
      return [
        for (final n in names)
          switch (n) {
            'gi' => 'python3-gi gir1.2-gstreamer-1.0 gir1.2-gst-plugins-base-1.0',
            'aiohttp' => 'python3-aiohttp',
            'numpy' => 'python3-numpy',
            _ => n,
          },
      ];
    } on ProcessException {
      return ['python3'];
    }
  }

  /// The cameras and microphones, as the sender finds them.
  Future<void> listDevices() async {
    final s = script;
    if (s == null) return;
    try {
      final r = await Process.run(python, [s, '--list-devices-json']);
      if (r.exitCode != 0) return;
      final j = jsonDecode((r.stdout as String).trim().split('\n').last) as Map<String, dynamic>;
      cameras = [
        for (final c in j['cameras'] as List<dynamic>)
          SenderCamera(c['path'] as String, c['name'] as String, [
            for (final m in c['modes'] as List<dynamic>)
              (
                format: m['format'] as String,
                width: (m['width'] as num).toInt(),
                height: (m['height'] as num).toInt(),
                fps: [for (final f in m['fps'] as List<dynamic>) (f as num).toInt()],
              ),
          ]),
      ];
      mics = [for (final m in j['mics'] as List<dynamic>) (name: m['name'] as String, label: m['label'] as String)];
      notifyListeners();
    } catch (_) {}
  }

  Future<void> start() async {
    if (state == SenderState.running || state == SenderState.starting) return;
    final s = script, me = comm.identity;
    if (s == null || me == null) {
      _fail(s == null ? "The HiveSight sender isn't in this build of the app" : 'This computer has no identity yet');
      return;
    }
    await _load();
    state = SenderState.starting;
    problem = null;
    output.clear();
    notifyListeners();
    missing = await checkMissing();
    if (missing.isNotEmpty) {
      _fail('Some things the sender needs are missing');
      return;
    }
    final dir = Directory('${(await AppProfile.files()).path}/hivesight');
    await dir.create(recursive: true);
    final cert = me.hiveSightCertificate;
    final certFile = File('${dir.path}/guide-cert.pem'), keyFile = File('${dir.path}/guide-key.pem');
    await certFile.writeAsBytes(cert.certificatePem);
    await keyFile.writeAsBytes(cert.privateKeyPem);
    await Process.run('chmod', ['600', keyFile.path]);
    _stopping = false;
    try {
      final p = await Process.start(python, [
        '-u',
        s,
        '--cert',
        certFile.path,
        '--key',
        keyFile.path,
        '--vessel-port',
        '$vesselPort',
        '--scenes',
        '${dir.path}/scenes.json',
        ...options.args,
      ]);
      _process = p;
      // The session too, if one's on: its Vessels come straight back
      final ss = session;
      p.stdin.writeln(
        jsonEncode({
          'guide_token': _guideToken,
          if (ss != null) 'session': {'token': ss.token, 'expires': ss.expires.millisecondsSinceEpoch / 1000},
        }),
      );
      await p.stdin.flush();
      p.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
        if (line.startsWith('HIVESIGHT ')) {
          try {
            final j = jsonDecode(line.substring(10)) as Map<String, dynamic>;
            _guidePort = (j['guide_port'] as num).toInt();
            addrs = [for (final a in j['addrs'] as List<dynamic>) a as String];
            state = SenderState.running;
            notifyListeners();
            _connect();
          } catch (_) {}
        } else {
          _say(line);
        }
      });
      p.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(_say);
      unawaited(
        p.exitCode.then((code) {
          if (_process != p) return;
          _process = null;
          _closeLink();
          if (_stopping) {
            state = SenderState.stopped;
            notifyListeners();
          } else {
            final last = output.lastWhere((l) => l.trim().isNotEmpty, orElse: () => 'it stopped ($code)');
            _fail('The sender stopped: ${last.replaceFirst(RegExp(r'^\d\d:\d\d:\d\d \w+\s+'), '')}');
          }
        }),
      );
    } on ProcessException catch (e) {
      _fail("Couldn't start the sender: ${e.message}");
    }
  }

  void _fail(String why) {
    state = SenderState.failed;
    problem = why;
    notifyListeners();
  }

  /// Stop it, and end the session unless [keepSession] (a restart: its
  /// Vessels come back on their own, with the same invitation).
  Future<void> stop({bool keepSession = false}) async {
    final p = _process;
    if (p == null) {
      state = SenderState.stopped;
      notifyListeners();
      return;
    }
    _stopping = true;
    if (!keepSession) await endSession();
    _closeLink();
    await p.stdin.close(); // the sender stops when its stdin closes
    final done = await p.exitCode.timeout(
      const Duration(seconds: 4),
      onTimeout: () {
        p.kill();
        return -1;
      },
    );
    if (done == -1) await p.exitCode;
  }

  Future<void> restart() async {
    await stop(keepSession: true);
    await start();
  }

  // ----- The link to it -----

  WebSocket? _ws;
  bool get linked => _ws != null;
  Timer? _retry;

  Future<void> _connect() async {
    _retry?.cancel();
    if (state != SenderState.running) return;
    try {
      final ws = await WebSocket.connect('ws://127.0.0.1:$_guidePort/ws');
      _ws = ws;
      ws.add(jsonEncode({'type': 'hello', 'role': 'guide', 'token': _guideToken}));
      ws.listen(_onMessage, onDone: _onLinkDone, onError: (_) => _onLinkDone());
      final s = session;
      if (s != null) _send({'type': 'session', 'token': s.token, 'expires': s.expires.millisecondsSinceEpoch / 1000});
      notifyListeners();
    } catch (_) {
      _retry = Timer(const Duration(seconds: 1), _connect);
    }
  }

  void _onLinkDone() {
    _ws = null;
    words.stopTiming();
    notifyListeners();
    if (state == SenderState.running && !_stopping) _retry = Timer(const Duration(seconds: 1), _connect);
  }

  void _closeLink() {
    _retry?.cancel();
    _ws?.close();
    _ws = null;
  }

  void _send(Map<String, Object?> m) => _ws?.add(jsonEncode(m));

  // ----- What it says -----

  /// The settings, by dotted key ("spiral.speed").
  final Map<String, Object?> values = {};
  List<GuideVessel> vessels = const [];
  List<String> scenes = const [], presets = const [];
  double micDb = -100, outDb = -100;
  bool gateOpen = false;
  String mediaDir = '';
  List<String> mediaFiles = const [];
  double mediaPosition = 0, mediaDuration = 0;
  bool mediaHasAudio = false;

  /// The latest preview frame from a Vessel (both eyes, flat), JPEG.
  Uint8List? preview;

  /// Something the sender said for the Guide to see.
  final notices = StreamController<String>.broadcast();

  final Map<String, bool> _verified = {};

  void _onMessage(dynamic data) {
    if (data is List<int>) {
      if (data.isNotEmpty && data[0] == 0x01) {
        preview = Uint8List.fromList(data.sublist(1));
        notifyListeners();
      }
      return;
    }
    Map<String, dynamic> m;
    try {
      m = jsonDecode(data as String) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    switch (m['type']) {
      case 'state':
        values.clear();
        (m['state'] as Map<String, dynamic>).forEach((section, v) {
          if (v is Map<String, dynamic>) v.forEach((k, x) => values['$section.$k'] = x);
        });
        notifyListeners();
      case 'set':
        values[m['path'] as String] = m['value'];
        notifyListeners();
      case 'notice':
        notices.add(m['text'] as String? ?? '');
      case 'vessel_left':
        // They used the exit gesture in the headset
        final who = vessels.where((v) => v.id == m['id']);
        notices.add('${who.isEmpty ? 'A Vessel' : nameOf(who.first)} left the session');
      case 'clients':
        _onClients(m);
    }
  }

  void _onClients(Map<String, dynamic> m) {
    final s = _session;
    vessels = [
      for (final c in m['clients'] as List<dynamic>)
        if ((c as Map<String, dynamic>)['role'] == 'vessel') _vessel(c, s),
    ];
    scenes = [for (final x in m['scenes'] as List<dynamic>? ?? const []) x as String];
    presets = [for (final x in m['presets'] as List<dynamic>? ?? const []) x as String];
    micDb = (m['mic_db'] as num?)?.toDouble() ?? -100;
    outDb = (m['out_db'] as num?)?.toDouble() ?? -100;
    gateOpen = m['gate_open'] == true;
    final media = m['media'] as Map<String, dynamic>? ?? const {};
    mediaDir = media['dir'] as String? ?? '';
    mediaFiles = [for (final f in media['files'] as List<dynamic>? ?? const []) f as String];
    mediaPosition = (media['position'] as num?)?.toDouble() ?? 0;
    mediaDuration = (media['duration'] as num?)?.toDouble() ?? 0;
    mediaHasAudio = media['has_audio'] == true;
    // The sender's ended it (its time's up)
    final on = (m['session'] as Map<String, dynamic>?)?['on'] == true;
    if (!on && s != null && s.expires.isBefore(DateTime.now())) _session = null;
    notifyListeners();
  }

  GuideVessel _vessel(Map<String, dynamic> c, ({String token, DateTime expires})? s) {
    final keyHex = c['key'] as String? ?? '', sigHex = c['sig'] as String? ?? '';
    final key = _unhex(keyHex), sig = _unhex(sigHex);
    final me = comm.identity;
    var ok = false;
    if (key != null && sig != null && s != null && me != null) {
      final k = '$keyHex/$sigHex/${s.token}';
      final known = _verified[k];
      if (known == null) {
        _verified[k] = false;
        Identity.verify(key, HiveSightInvite.joinMessage(s.token, me.hiveSightCertificate.fingerprint), sig).then((v) {
          _verified[k] = v;
          notifyListeners();
        });
      } else {
        ok = known;
      }
    }
    final allow = c['allow'] as Map<String, dynamic>? ?? const {};
    return GuideVessel(
      c['id'] as String,
      c['name'] as String? ?? '',
      c['addr'] as String? ?? '',
      key,
      ok,
      allow['light_pulse'] == true,
      c['stats'] as Map<String, dynamic>? ?? const {},
    );
  }

  /// A Vessel's name: theirs as known here, if they signed, or their phone's.
  String nameOf(GuideVessel v) {
    final id = v.personId;
    final p = id == null ? null : comm.people[id];
    return p?.name ?? (v.name.isEmpty ? v.addr : v.name);
  }

  // ----- Changing things -----

  final Map<String, Object> _pending = {};
  final Map<String, Timer> _throttle = {};

  /// Set [path] to [value]: shown at once, and sent, a slider's at most
  /// every 50 ms with its last value sent last.
  void set(String path, Object value) {
    values[path] = value;
    notifyListeners();
    if (_throttle.containsKey(path)) {
      _pending[path] = value;
      return;
    }
    _send({'type': 'set', 'path': path, 'value': value});
    _throttle[path] = Timer(const Duration(milliseconds: 50), () {
      _throttle.remove(path);
      final v = _pending.remove(path);
      if (v != null) set(path, v);
    });
  }

  num number(String path, [num or = 0]) => values[path] is num ? values[path] as num : or;
  bool flag(String path) => values[path] == true;
  String text(String path) => values[path]?.toString() ?? '';

  /// BLACKOUT: the view faded to black and the light pulse stopped, or back.
  bool get blackedOut => number('fx.fade', 1) < 0.5;
  void blackout() {
    if (blackedOut) {
      set('fx.fade', 1.0);
    } else {
      set('fx.fade', 0.0);
      set('photic.on', false);
    }
  }

  /// Words: phrase lists, and their cues timed from here.
  late final GuideWords words = GuideWords(command, () => linked);

  void command(String type, [Map<String, Object?> more = const {}]) => _send({'type': type, ...more});
  void playFile(String name) => command('media_play', {'file': name});
  void useCamera() => command('media_camera');
  void seek(double s) => command('media_seek', {'pos': s});
  void saveScene(String name) => command('scene_save', {'name': name});
  void loadScene(String name) => command('scene_load', {'name': name});
  void deleteScene(String name) => command('scene_delete', {'name': name});
  void remove(GuideVessel v) => command('kick', {'id': v.id});

  // ----- The session -----

  ({String token, DateTime expires})? _session;
  ({String token, DateTime expires})? get session =>
      _session != null && _session!.expires.isAfter(DateTime.now()) ? _session : null;

  /// Start one: [HiveSightInvite.lifetime] from now.
  void startSession() {
    _invited.clear();
    _session = (token: _randomToken(), expires: DateTime.now().add(HiveSightInvite.lifetime));
    _send({'type': 'session', 'token': _session!.token, 'expires': _session!.expires.millisecondsSinceEpoch / 1000});
    notifyListeners();
  }

  /// End it: every Vessel's dropped, and the invitations no longer work.
  Future<void> endSession() async {
    final s = _session;
    if (s == null) return;
    _session = null;
    _send({'type': 'session_end'});
    notifyListeners();
    // Tell those invited, so their invitations lose the Join button (not
    // needed once it's run out: they show that themselves)
    if (s.expires.isAfter(DateTime.now())) {
      for (final key in _invited) {
        final c = comm.conversations.all[key];
        if (c != null) comm.sendText(c, HiveSightInvite.endText(s.token), typed: false);
      }
    }
    _invited.clear();
  }

  /// The conversations invited to this session.
  final Set<String> _invited = {};

  /// Invite a conversation, as a text: false if there's no session, or it
  /// couldn't go.
  Future<bool> invite(Conversation c) async {
    final s = session, me = comm.identity;
    if (s == null || me == null || state != SenderState.running) return false;
    final i = await HiveSightInvite.make(me, hosts: addrs, port: vesselPort, token: s.token, expires: s.expires);
    if (!comm.sendText(c, i.text, typed: false)) return false;
    _invited.add(c.key);
    return true;
  }

  bool get canInvite => session != null && state == SenderState.running && addrs.isNotEmpty;

  /// Invite a conversation, starting the sender and a session first if
  /// need be: why not, or null once it's sent.
  Future<String?> inviteStarting(Conversation c) async {
    if (state != SenderState.running) {
      await start();
      final done = Completer<void>();
      void check() {
        if (state != SenderState.starting && !done.isCompleted) done.complete();
      }

      addListener(check);
      check();
      await done.future.timeout(const Duration(seconds: 20), onTimeout: () {});
      removeListener(check);
      if (state != SenderState.running) return problem ?? "The HiveSight sender didn't start";
    }
    if (addrs.isEmpty) return "This computer isn't on a network the Vessel can reach";
    if (session == null) startSession(); // sent now, or when the link's up
    return await invite(c) ? null : "Couldn't send it: ${c.title} can't be reached just now";
  }

  static String _randomToken() {
    final r = Random.secure();
    return base64Url.encode(List.generate(18, (_) => r.nextInt(256))).replaceAll('=', '');
  }

  static Uint8List? _unhex(String s) {
    if (s.isEmpty || s.length.isOdd) return null;
    try {
      return Uint8List.fromList([for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]);
    } catch (_) {
      return null;
    }
  }
}
