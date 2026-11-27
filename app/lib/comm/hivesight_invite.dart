/// Invitations to a HiveSight session, sent as a text like server invites
/// (server_invites.dart): words, then a line the app reads, for a Join
/// button.
///
/// The line carries where the Guide's sender is (its addresses on the LAN
/// and its TLS port), its certificate's SHA-256 for the Vessel to pin, the
/// session's token, when it ends, and the Guide's key, all signed by the
/// Guide's identity. A Vessel takes it only from the person whose key
/// signed it, so a forwarded or altered one doesn't work.
///
/// When a Vessel joins, it signs [joinMessage] with its own identity, and
/// the Guide page checks that, so the Guide sees who has really joined.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'identity.dart';

class HiveSightInvite {
  static const _prefix = 'dronelab://hivesight?';
  static const _context = 'dronelab-hivesight-invite\n';
  static const _joinContext = 'dronelab-hivesight-join\n';

  /// How long a session lasts, at most.
  static const lifetime = Duration(hours: 12);

  final Uint8List guideKey;
  final List<String> hosts; // tried in turn
  final int port;
  final String fingerprint; // the certificate's SHA-256, hex
  final String token;
  final DateTime expires;
  final Uint8List signature;

  HiveSightInvite._(this.guideKey, this.hosts, this.port, this.fingerprint, this.token, this.expires, this.signature);

  String get guideId => Identity.idOf(guideKey);
  bool get expired => !DateTime.now().isBefore(expires);

  static String _signed(List<int> key, List<String> hosts, int port, String fp, String token, DateTime expires) =>
      '$_context${_hex(key)}\n${hosts.join(',')}\n$port\n$fp\n$token\n${expires.millisecondsSinceEpoch ~/ 1000}';

  /// Ours, signed.
  static Future<HiveSightInvite> make(
    Identity me, {
    required List<String> hosts,
    required int port,
    required String token,
    required DateTime expires,
  }) async {
    final fp = me.hiveSightCertificate.fingerprint;
    final exp = DateTime.fromMillisecondsSinceEpoch(expires.millisecondsSinceEpoch ~/ 1000 * 1000);
    final sig = await me.sign(utf8.encode(_signed(me.publicKey, hosts, port, fp, token, exp)));
    return HiveSightInvite._(me.publicKey, hosts, port, fp, token, exp, sig);
  }

  /// Whether the Guide's key signed it as it is.
  Future<bool> verify() =>
      Identity.verify(guideKey, utf8.encode(_signed(guideKey, hosts, port, fingerprint, token, expires)), signature);

  String get link =>
      _prefix +
      [
        'g=${_b64(guideKey)}',
        'h=${hosts.join(',')}',
        'p=$port',
        'f=$fingerprint',
        't=$token',
        'e=${expires.millisecondsSinceEpoch ~/ 1000}',
        's=${_b64(signature)}',
      ].join('&');

  /// The text that carries it.
  String get text => 'Join my HiveSight session as a Vessel, until ${clock(expires)}\n$link';

  static String clock(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  /// The invitation in a text, or null if it isn't one.
  static HiveSightInvite? parse(String text) {
    for (final line in text.split('\n')) {
      final l = line.trim();
      if (!l.startsWith(_prefix)) continue;
      try {
        final q = Uri.splitQueryString(l.substring(_prefix.length));
        final key = _unb64(q['g']!), sig = _unb64(q['s']!);
        final hosts = [
          for (final h in q['h']!.split(','))
            if (h.trim().isNotEmpty) h.trim(),
        ];
        final port = int.parse(q['p']!);
        final fp = q['f']!.toLowerCase();
        final token = q['t']!;
        final exp = DateTime.fromMillisecondsSinceEpoch(int.parse(q['e']!) * 1000);
        if (key.length != Identity.keyLength || sig.length != Identity.signatureLength) return null;
        if (hosts.isEmpty || port < 1 || port > 65535 || !RegExp(r'^[0-9a-f]{64}$').hasMatch(fp)) return null;
        if (token.length < 16) return null;
        return HiveSightInvite._(key, hosts, port, fp, token, exp, sig);
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  /// A text, as shown where the whole of it isn't (the list of
  /// conversations, notifications): an invitation, or its end, in words.
  static String preview(String text) => parse(text) != null
      ? 'Invitation to a HiveSight session'
      : endOf(text) != null
      ? 'HiveSight session ended'
      : text;

  // ----- The session's end -----
  //
  // When the Guide ends a session, each conversation they invited is sent
  // a text saying so, with a line naming the session (its token, no use to
  // anyone now). The invitations before it, from the same person, lose
  // their Join button.

  static const _endPrefix = 'dronelab://hivesight-end?t=';

  /// The text saying the session with [token] has ended.
  static String endText(String token) => 'My HiveSight session has ended\n$_endPrefix$token';

  /// The session a text says has ended, or null if it isn't one.
  static String? endOf(String text) {
    for (final line in text.split('\n')) {
      final l = line.trim();
      if (l.startsWith(_endPrefix) && l.length > _endPrefix.length) return l.substring(_endPrefix.length);
    }
    return null;
  }

  /// The words of an end text, without its line for the app.
  static String endWords(String text) =>
      text.split('\n').where((l) => !l.trim().startsWith(_endPrefix)).join('\n').trim();

  /// What a Vessel signs to say who it is, for this session.
  static List<int> joinMessage(String token, String fingerprint) => utf8.encode('$_joinContext$token\n$fingerprint');

  static String _hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  static String _b64(List<int> b) => base64Url.encode(b).replaceAll('=', '');
  static Uint8List _unb64(String s) => base64Url.decode(s.padRight((s.length + 3) ~/ 4 * 4, '='));
}
