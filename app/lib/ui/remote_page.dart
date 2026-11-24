import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../comm/board_link.dart';
import '../comm/board_protocol.dart';
import '../comm/comm_controller.dart';
import '../comm/remote_server.dart';
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
  }

  @override
  void dispose() {
    _board.removeListener(_onBoard);
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

  /// On a computer there's no web view: the remote opens in the browser,
  /// served by the app (remote_server.dart).
  static final _desktop = Platform.isLinux;
  RemoteServer? _server;

  Future<void> _openInBrowser() async {
    final url = await (_server ??= RemoteServer(_board)).openUrl();
    await launchUrl(url);
  }

  Future<void> _load() async {
    if (_desktop) return;
    var html = await remotePageHtml(_board);
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
          : _wasConnected && _desktop
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Text(
                    'The remote opens in your browser, and runs the board over Bluetooth through the app. '
                    'It works while the app is open.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: _openInBrowser,
                    icon: const Icon(Icons.open_in_browser),
                    label: const Text('Open the remote'),
                  ),
                ]),
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
