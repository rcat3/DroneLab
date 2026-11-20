/// The remote on a computer: the board's remote page served on this
/// computer only (127.0.0.1), for a browser, with its /api/ requests passed on
/// to the board over Bluetooth, as the app's own Remote tab does on a phone.
///
/// Only the browser that opened [openUrl] can use it: that address sets a
/// cookie, kept from other sites (SameSite=Strict), which every request has
/// to bring. The Host is checked as well, so a site can't reach it through a
/// name of its own that points here.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'board_link.dart';
import 'board_protocol.dart';

/// The port it tries first. A browser keeps a page's settings by address,
/// port and all, so the same port each time keeps the remote's.
const _port = 47380;

/// The board's remote page: the board's, or the one kept from last time if
/// the board says it's the same, or the app's own for a board too old to
/// send it.
Future<String> remotePageHtml(BoardLink board) async {
  final prefs = await SharedPreferences.getInstance();
  final kept = prefs.getString('remotePage');
  final keptHash = kept == null ? '' : fnv1a(utf8.encode(kept)).toRadixString(16).padLeft(8, '0');
  try {
    final a = await board.request('GET', '/remote.html?h=$keptHash', '', const Duration(seconds: 30));
    if (a.status == 304 && kept != null) return kept;
    if (a.status == 200 && a.body.isNotEmpty) {
      await prefs.setString('remotePage', a.body);
      return a.body;
    }
  } catch (_) {}
  return kept ?? await rootBundle.loadString('assets/remote_page.html');
}

class RemoteServer {
  final BoardLink board;
  RemoteServer(this.board);

  HttpServer? _server;
  final String _token = List.generate(16, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  String? _lastState; // the board says "304" when the state hasn't changed

  /// Where a browser opens the remote: it sets the cookie, then goes to it.
  Future<Uri> openUrl() async {
    final s = await _start();
    return Uri.parse('http://127.0.0.1:${s.port}/open/$_token');
  }

  Future<HttpServer> _start() async {
    final running = _server;
    if (running != null) return running;
    HttpServer s;
    try {
      s = await HttpServer.bind(InternetAddress.loopbackIPv4, _port);
    } on SocketException {
      s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    }
    _server = s;
    s.listen(_handle);
    return s;
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      if (req.headers.host != '127.0.0.1' || req.headers.port != _server!.port) {
        res.statusCode = HttpStatus.forbidden;
        return;
      }
      final path = req.uri.path;
      if (path == '/open/$_token') {
        res.headers.add('Set-Cookie', 'dronelab=$_token; Path=/; HttpOnly; SameSite=Strict');
        res.statusCode = HttpStatus.seeOther;
        res.headers.set('Location', '/');
        return;
      }
      if (!req.cookies.any((c) => c.name == 'dronelab' && c.value == _token)) {
        res.statusCode = HttpStatus.forbidden;
        res.write('Open the remote from the DroneLab app.');
        return;
      }
      if (path == '/') {
        var html = await remotePageHtml(board);
        final head = html.indexOf('<head>');
        final app = '<script>window.droneLabApp = ${jsonEncode(board.appVersion)};</script>';
        html = head < 0 ? app + html : html.replaceRange(head + 6, head + 6, app);
        _lastState = null;
        res.headers.contentType = ContentType.html;
        res.headers.set('Cache-Control', 'no-store');
        res.write(html);
        return;
      }
      if (path.startsWith('/api/')) {
        final body = await utf8.decoder.bind(req).join();
        final target = req.uri.toString();
        var status = HttpStatus.serviceUnavailable;
        var text = '';
        if (board.state == BoardState.connected) {
          try {
            final a = await board.request(req.method, target, body);
            status = a.status;
            text = a.body;
            if (status == 304) {
              status = _lastState == null ? HttpStatus.serviceUnavailable : 200;
              text = _lastState ?? '';
            } else if (status == 200 && (target.startsWith('/api/state') || req.method == 'POST')) {
              _lastState = text; // commands answer with the state too
            }
          } catch (_) {
            status = HttpStatus.serviceUnavailable;
          }
        }
        res.statusCode = status;
        res.headers.contentType = ContentType.json;
        res.headers.set('Cache-Control', 'no-store');
        res.write(text);
        return;
      }
      res.statusCode = HttpStatus.notFound;
    } catch (_) {
      res.statusCode = HttpStatus.internalServerError;
    } finally {
      await res.close();
    }
  }
}
