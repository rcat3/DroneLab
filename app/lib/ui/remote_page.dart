import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../comm/board_link.dart';
import '../comm/board_protocol.dart';
import '../comm/comm_controller.dart';
import 'people.dart';
import 'theme.dart';

/// The phone remote: the board's own remote page (core/app/remote_page.html),
/// with its requests going to the board over Bluetooth instead of the
/// board's WiFi hotspot, so the phone keeps its internet for the comm
/// channel.
///
/// The page comes from the board, as soon as it connects, so it always
/// matches the board's firmware, however old the app is. The last one is
/// kept, and only sent again when it changes. The copy built into the app is
/// for a board too old to send it.
/// Who may send you commands (kind 0, the Lovense devices) or put words on
/// your display (kind 1, the Terminal): the Remote tab, at that tab's
/// From others.
void showRemotePermissions(BuildContext context, int kind) {
  Navigator.of(context).popUntil((r) => r.isFirst);
  appTab.value = tabRemote;
  _jump.value = null;
  _jump.value = kind;
}

final _jump = ValueNotifier<int?>(null);

class RemotePage extends StatefulWidget {
  final CommController comm;
  const RemotePage({super.key, required this.comm});

  @override
  State<RemotePage> createState() => _RemotePageState();
}

/// Put in front of the page's own script: fetch() for /api/ goes to the app
/// (window.DroneLab), which answers through __droneLabAnswer.
const _bridge = r'''
<script>
(function () {
  const pending = new Map();
  let next = 1;
  window.droneLabApp = "APP_VERSION";
  window.__droneLabAnswer = function (id, status, text) {
    const p = pending.get(id);
    if (!p) return;
    pending.delete(id);
    if (status === 0) { p.reject(new TypeError("The board isn't connected")); return; }
    p.resolve(new Response(text, { status: status, headers: { "Content-Type": "application/json" } }));
  };
  const realFetch = window.fetch.bind(window);
  window.fetch = function (input, init) {
    const u = new URL(typeof input === "string" ? input : input.url, location.href);
    if (!u.pathname.startsWith("/api/")) return realFetch(input, init);
    const id = next++;
    return new Promise(function (resolve, reject) {
      pending.set(id, { resolve: resolve, reject: reject });
      DroneLab.postMessage(JSON.stringify({
        id: id,
        method: (init && init.method) || "GET",
        target: u.pathname + u.search,
        body: init && typeof init.body === "string" ? init.body : "",
      }));
    });
  };
})();
</script>
''';

class _RemotePageState extends State<RemotePage> {
  WebViewController? _web;
  String? _lastState; // the board says "304" when the state hasn't changed
  bool _wasConnected = false;
  bool _tooOld = false;    // the board's firmware can't do the remote over Bluetooth

  BoardLink get _board => widget.comm.board;

  @override
  void initState() {
    super.initState();
    _board.addListener(_onBoard);
    _onBoard();
    _jump.addListener(_onJump);
  }

  /// To a kind's From others (showRemotePermissions): again a moment later,
  /// in case the page was still coming
  void _onJump() {
    final kind = _jump.value;
    if (kind == null) return;
    final js = 'showTab("${kind == 0 ? 'toys' : 'term'}");'
        'var b = document.getElementById("others$kind-box"); if (b) b.scrollIntoView({block: "start"});';
    _web?.runJavaScript(js).catchError((_) {});
    Future.delayed(const Duration(milliseconds: 800), () => _web?.runJavaScript(js).catchError((_) {}));
  }

  @override
  void dispose() {
    _board.removeListener(_onBoard);
    _jump.removeListener(_onJump);
    super.dispose();
  }

  /// Load the page afresh whenever the board connects, so it asks for the
  /// board's lists again.
  void _onBoard() {
    final connected = _board.state == BoardState.connected && _board.status != null;
    if (connected && !_wasConnected) {
      _tooOld = _board.status!.version < commVersionRemote;
      if (!_tooOld) _load();
    }
    if (connected != _wasConnected) setState(() => _wasConnected = connected);
  }

  /// The page: the board's, or the one kept from last time if the board says
  /// it's the same, or the app's own.
  Future<String> _page() async {
    final prefs = await SharedPreferences.getInstance();
    final kept = prefs.getString('remotePage');
    final keptHash = kept == null ? '' : fnv1a(utf8.encode(kept)).toRadixString(16).padLeft(8, '0');
    try {
      final a = await _board.request('GET', '/remote.html?h=$keptHash', '', const Duration(seconds: 30));
      if (a.status == 304 && kept != null) return kept;
      if (a.status == 200 && a.body.isNotEmpty) {
        await prefs.setString('remotePage', a.body);
        return a.body;
      }
    } catch (_) {}
    return kept ?? await rootBundle.loadString('assets/remote_page.html');
  }

  Future<void> _load() async {
    var html = await _page();
    final head = html.indexOf('<head>');
    final bridge = _bridge.replaceFirst('APP_VERSION', _board.appVersion.replaceAll('"', ''));
    html = head < 0 ? bridge + html : html.replaceRange(head + 6, head + 6, bridge);
    _lastState = null;
    final web = _web ??= WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..addJavaScriptChannel('DroneLab', onMessageReceived: (m) => _onRequest(m.message));
    // Any https address will do: it lets the page keep its settings, and
    // nothing's fetched from it.
    await web.loadHtmlString(html, baseUrl: 'https://remote.dronelab/');
  }

  Future<void> _onRequest(String message) async {
    final r = jsonDecode(message) as Map<String, dynamic>;
    final id = r['id'] as int;
    final method = r['method'] as String;
    final target = r['target'] as String;
    var status = 0;
    var text = '';
    try {
      final answer = await _board.request(method, target, r['body'] as String? ?? '');
      status = answer.status;
      text = answer.body;
      if (status == 304) {
        status = _lastState == null ? 0 : 200;
        text = _lastState ?? '';
      } else if (status == 200 && (target.startsWith('/api/state') || method == 'POST')) {
        _lastState = text; // commands answer with the state too
      }
    } catch (_) {
      status = 0;
    }
    await _web?.runJavaScript('__droneLabAnswer($id, $status, ${jsonEncode(text)})');
  }

  @override
  Widget build(BuildContext context) {
    final web = _web;
    return Scaffold(
      appBar: AppBar(
        title: const Row(children: [
          Icon(Icons.phone_android, color: Kc.green, size: 22),
          SizedBox(width: 10),
          Text('Remote'),
        ]),
        actions: const [Padding(padding: EdgeInsets.only(right: 16), child: Text('over Bluetooth'))],
      ),
      body: _wasConnected && _tooOld
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  "The board's firmware is too old for the remote in the app. Update the board, "
                  'or use its WiFi remote (Settings, Phone Remote).',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : _wasConnected && web != null
          ? WebViewWidget(controller: web)
          : const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'Connect to the board first: tap the status strip at the top.\n\n'
                  'The remote runs the board over Bluetooth, as the board\'s own WiFi remote does, '
                  'so the phone keeps its internet.',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
    );
  }
}
