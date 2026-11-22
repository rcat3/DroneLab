/// Invitations to a server, sent as a text: to a direct channel, or to one
/// person. The text says in words where it is, and carries a line the app
/// reads, with the address, port and server password, for a Join button
/// that sets the app up for it and connects. An app too old to know it
/// shows the text as it is, which has all that's needed to join by hand.
library;

class ServerInvite {
  final String host;
  final int port;
  final String password;
  const ServerInvite(this.host, this.port, this.password);

  /// As shown: the address, and the port if it isn't Mumble's own.
  String get address => port == 64738 ? host : '$host:$port';

  /// The text that carries it.
  String get text {
    final link = Uri(scheme: 'dronelab', host: 'join', queryParameters: {
      'h': host,
      'p': '$port',
      if (password.isNotEmpty) 'k': password,
    });
    return 'Join me on the server $address\n$link';
  }

  /// The invitation in a text, or null if it isn't one.
  static ServerInvite? parse(String text) {
    for (final line in text.split('\n')) {
      final l = line.trim();
      if (!l.startsWith('dronelab://join?')) continue;
      final u = Uri.tryParse(l);
      if (u == null) return null;
      final q = u.queryParameters;
      final host = q['h']?.trim() ?? '';
      final port = int.tryParse(q['p'] ?? '') ?? 64738;
      if (host.isEmpty || port < 1 || port > 65535) return null;
      return ServerInvite(host, port, q['k'] ?? '');
    }
    return null;
  }

  /// A text, as shown where the whole of it isn't, as in the list of
  /// conversations and notifications: an invitation in words, without its
  /// password.
  static String preview(String text) {
    final i = parse(text);
    return i == null ? text : 'Invitation to the server ${i.address}';
  }
}
