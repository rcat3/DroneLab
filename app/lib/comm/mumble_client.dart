/// A small Mumble client: it logs in, keeps track of who's in our channel,
/// and sends and receives Opus voice inside its TLS connection (Mumble's
/// "UDP tunnel"), so it needs no UDP. Plain Dart, so it can be tested on a
/// computer.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'protobuf.dart';
import 'voice_packet.dart';

// Message types
const _version = 0;
const _udpTunnel = 1;
const _authenticate = 2;
const _ping = 3;
const _reject = 4;
const _serverSync = 5;
const _channelRemove = 6;
const _channelState = 7;
const _userRemove = 8;
const _userState = 9;
const _textMessage = 11;

/// Version 1.4.0: the server then sends, and expects, voice in the older
/// format (see voice_packet.dart).
const _protocolVersion = 0x010400;
const _pingInterval = Duration(seconds: 15); // the server drops a client after 30 s

class MumbleUser {
  final int session;
  String name = '';
  int channel = 0;
  // Muted or deafened, by the server (6, 7) or by themselves (9, 10): the
  // UserState fields, which only come when they change
  final Map<int, bool> _flags = {};
  MumbleUser(this.session);

  bool get muted => _flags.values.any((on) => on);
}

class MumbleText {
  final String from;
  final String message; // may hold HTML
  final DateTime time;
  MumbleText(this.from, this.message) : time = DateTime.now();
}

enum MumbleState { connecting, connected, disconnected }

class MumbleException implements Exception {
  final String message;
  MumbleException(this.message);
  @override
  String toString() => message;
}

class MumbleClient {
  final String host;
  final int port;
  final String username;
  final String password;
  final String clientName;

  SecureSocket? _socket;
  Timer? _pingTimer;
  final BytesBuilder _incoming = BytesBuilder(copy: false);
  Uint8List _pending = Uint8List(0);
  Completer<void>? _synced;

  MumbleState state = MumbleState.disconnected;
  String? error;          // why it disconnected, if it wasn't asked to
  int? mySession;
  String welcome = '';
  String? fingerprint;    // SHA-256 of the server's certificate, hex
  final Map<int, MumbleUser> users = {};
  final Map<int, String> channels = {};

  final _changes = StreamController<void>.broadcast();
  final _voice = StreamController<IncomingVoice>.broadcast();
  final _texts = StreamController<MumbleText>.broadcast();

  /// Anything shown changed: the state, the users or the channels.
  Stream<void> get changes => _changes.stream;
  Stream<IncomingVoice> get voice => _voice.stream;
  Stream<MumbleText> get texts => _texts.stream;

  MumbleClient({
    required this.host,
    this.port = 64738,
    required this.username,
    this.password = '',
    this.clientName = 'DroneLab',
  });

  int get myChannel => users[mySession]?.channel ?? 0;

  /// Everyone else in our channel, by name.
  List<MumbleUser> get channelUsers {
    final list = users.values.where((u) => u.session != mySession && u.channel == myChannel).toList();
    list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return list;
  }

  /// Connect and log in. Mumble servers make their own certificates, so any
  /// certificate is accepted, but [checkCertificate] is given its SHA-256
  /// and can refuse it, e.g. if it's changed since last time.
  Future<void> connect({
    bool Function(String fingerprint)? checkCertificate,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    state = MumbleState.connecting;
    error = null;
    _changes.add(null);
    try {
      final socket = await SecureSocket.connect(host, port,
          timeout: timeout, onBadCertificate: (_) => true);
      _socket = socket;
      socket.setOption(SocketOption.tcpNoDelay, true);
      final cert = socket.peerCertificate;
      fingerprint = cert == null ? null : sha256.convert(cert.der).toString();
      if (checkCertificate != null && (fingerprint == null || !checkCertificate(fingerprint!))) {
        throw MumbleException("The server's certificate has changed");
      }

      _synced = Completer<void>();
      socket.listen(_onData, onError: (Object e) => _closed('$e'), onDone: () => _closed(null),
          cancelOnError: true);

      _send(_version, (ProtoWriter()
            ..int_(1, _protocolVersion)
            ..string(2, clientName)
            ..string(3, Platform.operatingSystem)
            ..string(4, Platform.operatingSystemVersion))
          .toBytes());
      _send(_authenticate, (ProtoWriter()
            ..string(1, username)
            ..string(2, password)
            ..bool_(5, true)) // Opus
          .toBytes());
      _pingTimer = Timer.periodic(_pingInterval, (_) {
        _send(_ping, (ProtoWriter()..int_(1, DateTime.now().millisecondsSinceEpoch)).toBytes());
      });

      await _synced!.future.timeout(timeout,
          onTimeout: () => throw MumbleException("The server didn't let us in"));
      state = MumbleState.connected;
      _changes.add(null);
    } catch (e) {
      final message = e is MumbleException
          ? e.message
          : e is SocketException
              ? "Can't reach $host:$port"
              : e is HandshakeException
                  ? "That's not a Mumble server"
                  : '$e';
      _shutdown(message);
      throw MumbleException(message);
    }
  }

  void close() => _shutdown(null);

  /// Send a packet of our voice. seq counts in 10 ms frames.
  void sendVoice(int seq, Uint8List opus, {bool last = false}) {
    if (state != MumbleState.connected) return;
    _send(_udpTunnel, encodeVoice(seq: seq, opus: opus, last: last));
  }

  void sendText(String message) {
    if (state != MumbleState.connected) return;
    _send(_textMessage, (ProtoWriter()
          ..int_(3, myChannel)
          ..string(5, message))
        .toBytes());
  }

  // ----- Inside -----

  void _send(int type, Uint8List payload) {
    final socket = _socket;
    if (socket == null) return;
    final header = ByteData(6)
      ..setUint16(0, type)
      ..setUint32(2, payload.length);
    socket.add(header.buffer.asUint8List());
    socket.add(payload);
  }

  void _onData(Uint8List data) {
    _incoming.add(_pending);
    _incoming.add(data);
    var buf = _incoming.takeBytes();
    var i = 0;
    while (buf.length - i >= 6) {
      final header = ByteData.sublistView(buf, i, i + 6);
      final type = header.getUint16(0);
      final len = header.getUint32(2);
      if (buf.length - i - 6 < len) break;
      final payload = Uint8List.sublistView(buf, i + 6, i + 6 + len);
      i += 6 + len;
      try {
        _handle(type, payload);
      } on FormatException {
        // A message we couldn't read: skip it rather than drop the connection.
      }
    }
    _pending = Uint8List.fromList(Uint8List.sublistView(buf, i));
  }

  void _handle(int type, Uint8List payload) {
    switch (type) {
      case _udpTunnel:
        final v = decodeVoice(payload);
        if (v != null) _voice.add(v);
      case _serverSync:
        final m = ProtoMessage.parse(payload);
        mySession = m.int_(1);
        welcome = m.string(3) ?? '';
        _synced?.complete();
        _synced = null;
        _changes.add(null);
      case _reject:
        final m = ProtoMessage.parse(payload);
        final reason = m.string(2);
        _shutdown(reason == null || reason.isEmpty ? 'The server turned us away' : reason);
      case _channelState:
        final m = ProtoMessage.parse(payload);
        final id = m.int_(1);
        if (id != null && m.has(3)) channels[id] = m.string(3)!;
        _changes.add(null);
      case _channelRemove:
        final id = ProtoMessage.parse(payload).int_(1);
        channels.remove(id);
        _changes.add(null);
      case _userState:
        final m = ProtoMessage.parse(payload);
        final session = m.int_(1);
        if (session == null) return;
        final u = users.putIfAbsent(session, () => MumbleUser(session));
        if (m.has(3)) u.name = m.string(3)!;
        if (m.has(5)) u.channel = m.int_(5)!;
        for (final f in const [6, 7, 9, 10]) {
          if (m.has(f)) u._flags[f] = m.bool_(f)!;
        }
        _changes.add(null);
      case _userRemove:
        final session = ProtoMessage.parse(payload).int_(1);
        users.remove(session);
        _changes.add(null);
      case _textMessage:
        final m = ProtoMessage.parse(payload);
        final from = users[m.int_(1)]?.name ?? 'Server';
        _texts.add(MumbleText(from, m.string(5) ?? ''));
      case _version:
      case _ping:
        break;
    }
  }

  void _closed(String? reason) {
    if (state == MumbleState.disconnected) return;
    _shutdown(reason ?? 'The server closed the connection');
  }

  void _shutdown(String? reason) {
    _pingTimer?.cancel();
    _pingTimer = null;
    final socket = _socket;
    _socket = null;
    socket?.destroy();
    if (_synced != null && !_synced!.isCompleted) {
      _synced!.completeError(MumbleException(reason ?? 'Disconnected'));
      _synced!.future.ignore();
    }
    _synced = null;
    final wasUp = state != MumbleState.disconnected;
    state = MumbleState.disconnected;
    if (reason != null) error = reason;
    users.clear();
    channels.clear();
    mySession = null;
    if (wasUp) _changes.add(null);
  }
}
