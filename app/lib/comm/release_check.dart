import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'firmware_update.dart';

/// Whether a newer release of the app is out, from the project's GitHub
/// releases: asked when the app starts, and once a day while it's open.
/// Only the latest release's version and page are read; nothing's sent but
/// the request itself.
class ReleaseCheck extends ChangeNotifier {
  static const _latest = 'https://api.github.com/repos/rcat3/DroneLab/releases/latest';
  static const _every = Duration(hours: 24);
  static const _dismissedKey = 'releaseDismissed';

  /// The newer release's version ("0.9.7") and page, while there's one to
  /// show: newer than this app, and not dismissed.
  String? version;
  String? page;

  Timer? _timer;
  SharedPreferences? _prefs;

  Future<void> start() async {
    _prefs = await SharedPreferences.getInstance();
    await check();
    _timer = Timer.periodic(_every, (_) => check());
  }

  Future<void> check() async {
    try {
      final mine = releaseOf((await PackageInfo.fromPlatform()).version);
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
      final request = await client.getUrl(Uri.parse(_latest));
      request.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      final response = await request.close().timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        client.close();
        return;
      }
      final j = jsonDecode(await response.transform(utf8.decoder).join()) as Map<String, dynamic>;
      client.close();
      final tag = j['tag_name'] as String? ?? '';
      final theirs = releaseOf(tag);
      if (mine == null || theirs == null || j['draft'] == true || j['prerelease'] == true) return;
      final newer = compareReleases(theirs, mine) > 0;
      final name = tag.startsWith('v') ? tag.substring(1) : tag;
      final dismissed = _prefs?.getString(_dismissedKey) == name;
      version = newer && !dismissed ? name : null;
      page = j['html_url'] as String?;
      notifyListeners();
    } catch (_) {
      // Offline, or GitHub's busy: try again next time
    }
  }

  /// Hide it until a newer one than this comes out.
  void dismiss() {
    final v = version;
    if (v == null) return;
    _prefs?.setString(_dismissedKey, v);
    version = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
