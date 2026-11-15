/// A small Mumble client: it logs in, keeps track of who's in our channel,
/// and sends and receives Opus voice. Voice goes over UDP, encrypted with the
/// key the server gives (crypt_state.dart), while UDP gets through: a UDP
/// ping every few seconds checks. Otherwise it goes inside the TLS
/// connection (Mumble's "UDP tunnel"), which always works, but a lost
/// packet there holds up everything after it. Plain Dart, so it can be
/// tested on a computer.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'crypt_state.dart';
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
const _cryptSetup = 15;

const _voiceTypePing = 1;
const _udpPingInterval = Duration(seconds: 5);
const _udpTimeout = Duration(seconds: 12);      // no answer for this long: back to TCP
const _resyncAfter = Duration(seconds: 5);      // no good packet for this long: ask for a new nonce

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
  final bool useUdp;

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
    this.useUdp = true,
  });

  // ----- UDP -----

  final CryptState _crypt = CryptState();
  RawDatagramSocket? _udp;
  InternetAddress? _udpAddress;
  Timer? _udpPingTimer;
  DateTime? _lastUdpGood;
  DateTime _lastResync = DateTime.fromMillisecondsSinceEpoch(0);
  int udpPacketsIn = 0;
  int tcpVoiceIn = 0;

  /// True while voice is going over UDP.
  bool get udpActive {
    final last = _lastUdpGood;
    return _udp != null && last != null && DateTime.now().difference(last) < _udpTimeout;
  }

  Future<void> _startUdp() async {
    if (!useUdp || _udp != null || !_crypt.ready) return;
    try {
      final address = (await InternetAddress.lookup(host)).first;
      final socket = await RawDatagramSocket.bind(
          address.type == InternetAddressType.IPv6 ? InternetAddress.anyIPv6 : InternetAddress.anyIPv4, 0);
      if (state == MumbleState.disconnected) {
        socket.close();
        return;
      }
      _udp = socket;
      _udpAddress = address;
      socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        Datagram? d;
        while ((d = socket.receive()) != null) {
          _onUdp(d!.data);
        }
      });
      _sendUdpPing();
      _udpPingTimer = Timer.periodic(_udpPingInterval, (_) => _sendUdpPing());
    } catch (_) {
      // No UDP: the voice stays in the TCP connection
    }
  }

  void _sendUdpPing() {
    final b = BytesBuilder()..addByte(_voiceTypePing << 5);
    writeMumbleVarint(b, DateTime.now().millisecondsSinceEpoch);
    _sendUdp(b.toBytes());
    // A connection that's gone quiet goes back to TCP, which tells the
    // server to send that way too
    final wasActive = _wasUdpActive;
    _wasUdpActive = udpActive;
    if (wasActive != _wasUdpActive) _changes.add(null);
  }

  bool _wasUdpActive = false;

  void _sendUdp(Uint8List plain) {
    final socket = _udp, address = _udpAddress;
    if (socket == null || address == null || !_crypt.ready) return;
    socket.send(_crypt.encrypt(plain), address, port);
  }

  void _onUdp(Uint8List data) {
    final plain = _crypt.decrypt(data);
    if (plain == null) {
      // Out of step with the server's count: ask it for its nonce again
      final now = DateTime.now();
      final last = _lastUdpGood;
      if ((last == null || now.difference(last) > _resyncAfter) && now.difference(_lastResync) > _resyncAfter) {
        _lastResync = now;
        _send(_cryptSetup, Uint8List(0));
      }
      return;
    }
    final first = !udpActive;
    _lastUdpGood = DateTime.now();
    if (first) {
      _wasUdpActive = true;
      _changes.add(null);
    }
    if (plain.isEmpty) return;
    if (plain[0] >> 5 == voiceTypeOpus) {
      try {
        final v = decodeVoice(plain);
        if (v != null) {
          udpPacketsIn++;
          _voice.add(v);
        }
      } on FormatException {
        // a broken packet
      }
    }
  }

  void _onCryptSetup(Uint8List payload) {
    final m = ProtoMessage.parse(payload);
    final key = m.bytes(1), client = m.bytes(2), server = m.bytes(3);
    if (key != null && key.length == 16 && client != null && client.length == 16 && server != null && server.length == 16) {
      _crypt.setKey(key, client, server);
      _startUdp();
    } else if (server != null && server.length == 16) {
      _crypt.setDecryptIv(server);       // the server's starting its count again
    } else if (_crypt.ready) {
      // The server asks for our count
      _send(_cryptSetup, (ProtoWriter()..bytes(2, _crypt.encryptIv)).toBytes());
    }
  }

  void _stopUdp() {
    _udpPingTimer?.cancel();
    _udpPingTimer = null;
    _udp?.close();
    _udp = null;
    _lastUdpGood = null;
    _wasUdpActive = false;
  }

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
    final packet = encodeVoice(seq: seq, opus: opus, last: last);
    if (udpActive) {
      _sendUdp(packet);
    } else {
      _send(_udpTunnel, packet);
    }
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
        if (v != null) {
          tcpVoiceIn++;
          _voice.add(v);
        }
      case _cryptSetup:
        _onCryptSetup(payload);
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
    _stopUdp();
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
