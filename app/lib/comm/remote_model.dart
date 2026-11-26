import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'board_link.dart';

/// The unit's remote, for the app's own Remote tab: what the board's remote
/// page (core/app/remote_page.html) keeps, as the board's API gives it
/// (core/app/remote.c), over Bluetooth.
///
/// It keeps the board's state (/api/state) and lists (/api/info), asks for
/// them while [active], sends commands, and fetches snapshots of the screen.
class RemoteModel extends ChangeNotifier {
  final BoardLink board;
  RemoteModel(this.board) {
    _sub = board.states.listen(_onState);
    board.addListener(_onBoard);
    _timer = Timer.periodic(const Duration(milliseconds: 700), (_) => _tick());
    _onBoard();
  }

  StreamSubscription<String>? _sub;
  Timer? _timer;
  Timer? _snapLater;

  Map<String, dynamic> state = const {};
  Map<String, dynamic> info = const {};
  List<String> tracks = const [];
  int? _tracksSeen;
  bool _asking = false;
  bool _askingInfo = false;
  bool _askingTracks = false;
  bool _wasUp = false;

  /// Whether the remote is on screen: only then does it keep asking.
  bool active = false;

  /// Whether the Screen tab is showing, which wants the snapshot.
  bool screenShown = false;

  bool get up => board.state == BoardState.connected && board.status != null;
  bool get hasState => state.isNotEmpty && info.isNotEmpty;

  // ----- State -----

  void _onBoard() {
    if (up && !_wasUp) {
      _wasUp = true;
      info = const {};
      state = const {};
      _tracksSeen = null;
      _askInfo();
      _askState(full: true);
    } else if (!up && _wasUp) {
      _wasUp = false;
      notifyListeners();
    }
  }

  void _tick() {
    if (!active || !up) return;
    _askState();
    if (screenShown) {
      final every = _lastSnap == null || DateTime.now().difference(_lastSnap!) > const Duration(seconds: 4);
      if (every) refreshScreen();
    }
  }

  void _onState(String json) {
    try {
      final s = jsonDecode(json) as Map<String, dynamic>;
      if (s.containsKey('channels')) _take(s);
    } catch (_) {}
  }

  void _take(Map<String, dynamic> s) {
    final before = state['screen']?.toString();
    state = s;
    _checkLists();
    if (screenShown && before != null && before != s['screen']?.toString()) _snapSoon();
    notifyListeners();
  }

  Future<void> _askState({bool full = false}) async {
    if (_asking) return;
    _asking = true;
    try {
      // A command with nothing in it answers with the state in full, where a
      // GET may be "the same as last time" (304) for someone else's copy
      final a = full ? await board.request('POST', '/api/display') : await board.request('GET', '/api/state');
      if (a.status == 200) _take(jsonDecode(a.body) as Map<String, dynamic>);
    } catch (_) {
    } finally {
      _asking = false;
    }
  }

  Future<void> _askInfo() async {
    if (_askingInfo) return;
    _askingInfo = true;
    try {
      final a = await board.request('GET', '/api/info', '', const Duration(seconds: 15));
      if (a.status == 200) {
        info = jsonDecode(a.body) as Map<String, dynamic>;
        notifyListeners();
      }
    } catch (_) {
    } finally {
      _askingInfo = false;
    }
  }

  /// The lists that change while it runs: the pages (a picture someone
  /// sent), and the tracks (a sound someone sent).
  void _checkLists() {
    final pages = state['pages'];
    final features = info['features'];
    if (pages is List && features is List && !_askingInfo) {
      var same = pages.length == features.length;
      for (var i = 0; same && i < pages.length; i++) {
        same = pages[i] == (features[i][1] as List).length;
      }
      if (!same) _askInfo();
    }
    final sound = state['sound'];
    if (sound is Map && sound['tracks'] != _tracksSeen && !_askingTracks) {
      _askingTracks = true;
      final seen = sound['tracks'] as int?;
      board.request('GET', '/api/tracks', '', const Duration(seconds: 10)).then((a) {
        if (a.status != 200) return;
        tracks = [for (final t in (jsonDecode(a.body) as Map<String, dynamic>)['tracks'] as List) t as String];
        _tracksSeen = seen;
        notifyListeners();
      }).catchError((_) {}).whenComplete(() => _askingTracks = false);
    }
  }

  // ----- Commands -----

  /// POST `/api/path?params`, with a body if there is one; the state it
  /// answers with is taken on.
  Future<void> command(String path, [Map<String, Object> params = const {}, String body = '']) async {
    final q = params.entries.map((e) => '${e.key}=${Uri.encodeQueryComponent('${e.value}')}').join('&');
    try {
      final a = await board.request('POST', '/api/$path${q.isEmpty ? '' : '?$q'}', body, const Duration(seconds: 8));
      if (a.status == 200) _take(jsonDecode(a.body) as Map<String, dynamic>);
    } catch (_) {}
  }

  // Sliders: one request at a time, with the newest value for each, so a
  // fast drag doesn't pile requests up.
  final _pending = <String, (String, Map<String, Object>)>{};
  bool _sending = false;

  bool isPending(String key) => _pending.containsKey(key);

  void queue(String key, String path, Map<String, Object> params) {
    _pending[key] = (path, params);
    _sendPending();
  }

  Future<void> _sendPending() async {
    if (_sending || _pending.isEmpty) return;
    _sending = true;
    final key = _pending.keys.first;
    final (path, params) = _pending.remove(key)!;
    await command(path, params);
    _sending = false;
    _sendPending();
  }

  /// Stop every toy, and drop any level still waiting to be sent, which
  /// would start one again.
  void stop() {
    _pending.clear();
    command('stop');
  }

  // ----- The screen -----

  ui.Image? screen;
  DateTime? _lastSnap;
  bool _snapping = false;

  void _snapSoon() {
    _snapLater?.cancel();
    _snapLater = Timer(const Duration(milliseconds: 600), refreshScreen);
  }

  /// Ask for a new snapshot, in pieces that each fit an answer.
  Future<void> refreshScreen() async {
    if (_snapping || !up) return;
    _snapping = true;
    try {
      final bytes = BytesBuilder();
      var w = 0, h = 0, n = 1;
      for (var p = 0; p < n; p++) {
        final a = await board.request('GET', '/api/screen?p=$p', '', const Duration(seconds: 8));
        if (a.status != 200) return;
        final d = jsonDecode(a.body) as Map<String, dynamic>;
        w = d['w'] as int;
        h = d['h'] as int;
        n = d['n'] as int;
        if (n == 0) return;
        bytes.add(base64Decode(d['d'] as String));
      }
      final raw = bytes.takeBytes();
      if (raw.length < w * h * 2) return;
      final rgba = Uint8List(w * h * 4);
      for (var i = 0; i < w * h; i++) {
        final c = raw[2 * i] | (raw[2 * i + 1] << 8);
        final r = (c >> 11) & 0x1f, g = (c >> 5) & 0x3f, b = c & 0x1f;
        rgba[4 * i] = (r << 3) | (r >> 2);
        rgba[4 * i + 1] = (g << 2) | (g >> 4);
        rgba[4 * i + 2] = (b << 3) | (b >> 2);
        rgba[4 * i + 3] = 255;
      }
      final done = Completer<ui.Image>();
      ui.decodeImageFromPixels(rgba, w, h, ui.PixelFormat.rgba8888, done.complete);
      screen?.dispose();
      screen = await done.future;
      _lastSnap = DateTime.now();
      notifyListeners();
    } catch (_) {
    } finally {
      _snapping = false;
      _lastSnap ??= DateTime.now();
    }
  }

  /// One step as a swipe would: 'l', 'r', 'u' or 'd'.
  Future<void> step(String direction) async {
    await command('nav', {'d': direction});
    _snapSoon();
  }

  Future<void> show(int feature, int page) async {
    await command('show', {'f': feature, 'p': page});
    _snapSoon();
  }

  // ----- What the board has -----

  List<(String name, List<String> pages)> get features => [
        for (final f in (info['features'] as List? ?? const []))
          (f[0] as String, [for (final p in f[1] as List) p as String]),
      ];

  (int, int) get current {
    final s = state['screen'];
    return s is List && s.length == 2 ? (s[0] as int, s[1] as int) : (0, 0);
  }

  bool isReceived(int feature, int page) {
    final r = state['recv'];
    return r is List && r.any((e) => e is List && e[0] == feature && e[1] == page);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _timer?.cancel();
    _snapLater?.cancel();
    board.removeListener(_onBoard);
    screen?.dispose();
    super.dispose();
  }
}
