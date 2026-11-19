/// Who we are to others: one secret seed, kept in the phone's secure
/// storage, that everything else is made from, so the seed alone brings it
/// all back (see [Identity.exportCode]):
///   - an Ed25519 key pair, our identity: its public key is who we are, and
///     it signs what we send (the identity announcement on the server, and
///     commands for others' boards);
///   - a P-256 certificate for the Mumble server, the same every time (fixed
///     dates and serial, and an RFC 6979 signature), so the server, and
///     everyone on it, sees the same certificate hash each time we connect.
/// Plain Dart but for [Identity.load], so it can be tested on a computer.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:cryptography/cryptography.dart' as c;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/export.dart' as pc;

class Identity {
  static const seedLength = 32;
  static const keyLength = 32;
  static const signatureLength = 64;
  static const _storeKey = 'identitySeed';

  final Uint8List seed;
  final Uint8List publicKey;
  final c.SimpleKeyPair _keyPair;

  /// The Mumble certificate and its private key, PEM, for SecureSocket.
  final Uint8List certificatePem;
  final Uint8List privateKeyPem;

  /// SHA-1 of the certificate, hex, as Mumble shows it to everyone.
  final String certificateHash;

  Identity._(this.seed, this.publicKey, this._keyPair, this.certificatePem, this.privateKeyPem, this.certificateHash);

  static final _ed25519 = c.Ed25519();

  /// Ours: made from the seed in secure storage, or a new one the first time.
  static Future<Identity> load([FlutterSecureStorage storage = const FlutterSecureStorage()]) async {
    final stored = await storage.read(key: _storeKey);
    if (stored != null) {
      try {
        final seed = base64.decode(stored);
        if (seed.length == seedLength) return await fromSeed(seed);
      } on FormatException {
        // not one of ours: a new one
      }
    }
    final seed = Uint8List.fromList(List.generate(seedLength, (_) => Random.secure().nextInt(256)));
    await storage.write(key: _storeKey, value: base64.encode(seed));
    return fromSeed(seed);
  }

  /// Take on the identity in an exported code, in place of ours.
  static Future<Identity> import(String code, [FlutterSecureStorage storage = const FlutterSecureStorage()]) async {
    final seed = seedFromCode(code);
    await storage.write(key: _storeKey, value: base64.encode(seed));
    return fromSeed(seed);
  }

  static Future<Identity> fromSeed(List<int> seed) async {
    final s = Uint8List.fromList(seed);
    final pair = await _ed25519.newKeyPairFromSeed(s);
    final pub = Uint8List.fromList((await pair.extractPublicKey()).bytes);
    final (cert, key) = _certificate(s);
    return Identity._(s, pub, pair, _pem('CERTIFICATE', cert), _pem('PRIVATE KEY', key),
        hash.sha1.convert(cert).toString());
  }

  /// A short id for a public key: its first 8 bytes, hex, as the boards
  /// show it and the muted list gives it (others.h), for showing, and for
  /// keying things.
  static String idOf(List<int> publicKey) => _hex(publicKey.sublist(0, 8));

  String get id => idOf(publicKey);

  Future<Uint8List> sign(List<int> message) async =>
      Uint8List.fromList((await _ed25519.sign(message, keyPair: _keyPair)).bytes);

  static Future<bool> verify(List<int> publicKey, List<int> message, List<int> signature) {
    if (publicKey.length != keyLength || signature.length != signatureLength) return Future.value(false);
    return _ed25519.verify(message,
        signature: c.Signature(signature, publicKey: c.SimplePublicKey(publicKey, type: c.KeyPairType.ed25519)));
  }

  // ----- Keys shared with one other -----

  static final _x25519 = c.X25519();
  static final _p = (BigInt.one << 255) - BigInt.from(19);

  /// An Ed25519 public key as the X25519 one of the same secret: u = (1 +
  /// y) / (1 - y), RFC 7748's map between the two curves. Null if it isn't
  /// one.
  static Uint8List? montgomeryOf(List<int> edKey) {
    if (edKey.length != keyLength) return null;
    var y = BigInt.zero;
    for (var i = keyLength - 1; i >= 0; i--) {
      y = (y << 8) | BigInt.from(i == keyLength - 1 ? edKey[i] & 0x7F : edKey[i]);  // the top bit's x's sign
    }
    final den = (BigInt.one - y) % _p;
    if (y >= _p || den == BigInt.zero) return null;
    var u = ((BigInt.one + y) * den.modPow(_p - BigInt.two, _p)) % _p;
    final out = Uint8List(keyLength);
    for (var i = 0; i < keyLength; i++) {
      out[i] = (u & BigInt.from(0xFF)).toInt();
      u >>= 8;
    }
    return out;
  }

  /// Our secret as an X25519 one: the scalar Ed25519 makes from the seed.
  Future<c.SimpleKeyPair> _xKeyPair() =>
      _x25519.newKeyPairFromSeed(hash.sha512.convert(seed).bytes.sublist(0, 32));

  /// A key only we and the one with this public key have, the same made on
  /// either side, with nothing swapped first: X25519 between our identity
  /// keys, then SHA-256 of "dronelab-pair\n", that, and the two public keys,
  /// the lower first, cut to 16 bytes. For talking to them alone over
  /// direct comms (direct.h). Null for our own key, or one that isn't a key.
  Future<Uint8List?> pairKey(List<int> theirKey) async {
    final their = montgomeryOf(theirKey);
    if (their == null || _compare(theirKey, publicKey) == 0) return null;
    final shared = await (await _x25519.sharedSecretKey(
            keyPair: await _xKeyPair(), remotePublicKey: c.SimplePublicKey(their, type: c.KeyPairType.x25519)))
        .extractBytes();
    if (shared.every((b) => b == 0)) return null;     // a key of small order: nothing secret in it
    final (lo, hi) = _compare(publicKey, theirKey) < 0 ? (publicKey, theirKey) : (theirKey, publicKey);
    final digest = hash.sha256.convert([...utf8.encode('dronelab-pair\n'), ...shared, ...lo, ...hi]);
    return Uint8List.fromList(digest.bytes.sublist(0, 16));
  }

  /// Our X25519 public key, for checking [montgomeryOf] gives the same.
  Future<Uint8List> xPublicKey() async =>
      Uint8List.fromList((await (await _xKeyPair()).extractPublicKey()).bytes);

  static int _compare(List<int> a, List<int> b) {
    for (var i = 0; i < a.length && i < b.length; i++) {
      if (a[i] != b[i]) return a[i] - b[i];
    }
    return a.length - b.length;
  }

  // ----- The code to back it up with -----

  static const _base32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

  /// The seed and two bytes of its SHA-256, base32, in groups of four: all
  /// it takes to be us, so it's to be kept secret.
  String get exportCode {
    final bytes = [...seed, ...hash.sha256.convert(seed).bytes.sublist(0, 2)];
    var bits = 0, value = 0;
    final out = StringBuffer();
    for (final b in bytes) {
      value = (value << 8) | b;
      bits += 8;
      while (bits >= 5) {
        bits -= 5;
        out.write(_base32[(value >> bits) & 31]);
      }
      value &= (1 << bits) - 1;
    }
    if (bits > 0) out.write(_base32[(value << (5 - bits)) & 31]);
    final s = out.toString();
    return [for (var i = 0; i < s.length; i += 4) s.substring(i, min(i + 4, s.length))].join('-');
  }

  /// The seed in a code from [exportCode]; FormatException if it isn't one.
  static Uint8List seedFromCode(String code) {
    final clean = code.toUpperCase().replaceAll(RegExp(r'[^A-Z2-7]'), '');
    final out = <int>[];
    var bits = 0, value = 0;
    for (final ch in clean.split('')) {
      value = (value << 5) | _base32.indexOf(ch);
      bits += 5;
      if (bits >= 8) {
        bits -= 8;
        out.add((value >> bits) & 0xFF);
        value &= (1 << bits) - 1;
      }
    }
    if (out.length != seedLength + 2) throw const FormatException("That's not the whole code");
    final seed = Uint8List.fromList(out.sublist(0, seedLength));
    final check = hash.sha256.convert(seed).bytes;
    if (check[0] != out[seedLength] || check[1] != out[seedLength + 1]) {
      throw const FormatException("That code isn't right: check it for a mistake");
    }
    return seed;
  }

  // ----- The Mumble certificate -----

  static final _p256 = pc.ECDomainParameters('secp256r1');
  static const _oidEcdsaSha256 = [1, 2, 840, 10045, 4, 3, 2];
  static const _oidEcPublicKey = [1, 2, 840, 10045, 2, 1];
  static const _oidP256 = [1, 2, 840, 10045, 3, 1, 7];
  static const _oidCommonName = [2, 5, 4, 3];

  /// The certificate (DER) and its private key (PKCS #8 DER), from the seed.
  static (Uint8List, Uint8List) _certificate(Uint8List seed) {
    // The P-256 key: from the seed, so it's the same each time
    BigInt d = BigInt.zero;
    for (var i = 0; d == BigInt.zero || d >= _p256.n; i++) {
      final mac = hash.Hmac(hash.sha256, seed).convert(utf8.encode('dronelab-mumble-cert-$i')).bytes;
      d = _int(mac);
    }
    final q = (_p256.G * d)!.getEncoded(false);
    final dBytes = _bytes(d, 32);

    final algorithm = _seq([_oid(_oidEcdsaSha256)]);
    final name = _seq([
      _set([
        _seq([_oid(_oidCommonName), _tlv(0x0C, utf8.encode('DroneLab'))])
      ])
    ]);
    final spki = _seq([
      _seq([_oid(_oidEcPublicKey), _oid(_oidP256)]),
      _bitString(q),
    ]);
    final serial = [0x01, ...hash.sha256.convert(q).bytes.sublist(0, 15)];
    final tbs = _seq([
      _tlv(0xA0, _integer([2])), // v3
      _integer(serial),
      algorithm,
      name,
      _seq([_tlv(0x17, ascii.encode('260101000000Z')), _tlv(0x18, ascii.encode('99991231235959Z'))]),
      name,
      spki,
    ]);
    // RFC 6979: given a MAC, pointycastle makes k from the key and message
    final signer = pc.ECDSASigner(pc.SHA256Digest(), pc.HMac(pc.SHA256Digest(), 64))
      ..init(true, pc.PrivateKeyParameter<pc.ECPrivateKey>(pc.ECPrivateKey(d, _p256)));
    final sig = signer.generateSignature(tbs) as pc.ECSignature;
    final cert = _seq([tbs, algorithm, _bitString(_seq([_integer(_bytes(sig.r)), _integer(_bytes(sig.s))]))]);

    final sec1 = _seq([
      _integer([1]),
      _tlv(0x04, dBytes),
      _tlv(0xA1, _bitString(q)),
    ]);
    final pkcs8 = _seq([
      _integer([0]),
      _seq([_oid(_oidEcPublicKey), _oid(_oidP256)]),
      _tlv(0x04, sec1),
    ]);
    return (cert, pkcs8);
  }

  // ----- DER -----

  static Uint8List _tlv(int tag, List<int> body) {
    final len = body.length;
    final head = <int>[tag];
    if (len < 0x80) {
      head.add(len);
    } else {
      final l = <int>[];
      for (var n = len; n > 0; n >>= 8) {
        l.insert(0, n & 0xFF);
      }
      head
        ..add(0x80 | l.length)
        ..addAll(l);
    }
    return Uint8List.fromList([...head, ...body]);
  }

  static Uint8List _seq(List<List<int>> items) => _tlv(0x30, [for (final i in items) ...i]);
  static Uint8List _set(List<List<int>> items) => _tlv(0x31, [for (final i in items) ...i]);
  static Uint8List _bitString(List<int> bytes) => _tlv(0x03, [0, ...bytes]);

  /// An INTEGER from big-endian bytes, as the positive number they are.
  static Uint8List _integer(List<int> bytes) {
    var b = bytes.skipWhile((x) => x == 0).toList();
    if (b.isEmpty || b[0] & 0x80 != 0) b = [0, ...b];
    return _tlv(0x02, b);
  }

  static Uint8List _oid(List<int> parts) {
    final out = <int>[parts[0] * 40 + parts[1]];
    for (final p in parts.skip(2)) {
      final chunk = <int>[p & 0x7F];
      for (var n = p >> 7; n > 0; n >>= 7) {
        chunk.insert(0, 0x80 | (n & 0x7F));
      }
      out.addAll(chunk);
    }
    return _tlv(0x06, out);
  }

  static BigInt _int(List<int> bytes) => bytes.fold(BigInt.zero, (n, b) => (n << 8) | BigInt.from(b));

  static Uint8List _bytes(BigInt n, [int? length]) {
    final out = <int>[];
    for (var v = n; v > BigInt.zero; v >>= 8) {
      out.insert(0, (v & BigInt.from(0xFF)).toInt());
    }
    while (length != null && out.length < length) {
      out.insert(0, 0);
    }
    return Uint8List.fromList(out);
  }

  static Uint8List _pem(String label, List<int> der) {
    final b64 = base64.encode(der);
    final lines = [for (var i = 0; i < b64.length; i += 64) b64.substring(i, min(i + 64, b64.length))];
    return Uint8List.fromList(utf8.encode('-----BEGIN $label-----\n${lines.join('\n')}\n-----END $label-----\n'));
  }

  static String _hex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// What a signed identity announcement says (see [IdentityAnnouncement]).
class IdentityAnnouncement {
  /// What it's called in Mumble's plugin data.
  static const dataId = 'dronelab-identity';
  static const _version = 1;
  static const _context = 'dronelab-identity\n';
  static const length = 1 + Identity.keyLength + 20 + 32 + Identity.signatureLength;

  final Uint8List publicKey;
  final String certificateHash;     // hex, as Mumble's
  final String serverFingerprint;   // hex, SHA-256 of the server's certificate

  IdentityAnnouncement(this.publicKey, this.certificateHash, this.serverFingerprint);

  /// Ours, for others on this server: our key, our certificate's hash and
  /// the server's, signed, so it can't be taken to another server or used
  /// by someone with another certificate.
  ///   version (1), public key (32), certificate SHA-1 (20), server
  ///   certificate SHA-256 (32), Ed25519 signature (64) of what's before it,
  ///   after "dronelab-identity\n"
  static Future<Uint8List> make(Identity me, String serverFingerprint) async {
    final body = [_version, ...me.publicKey, ..._unhex(me.certificateHash), ..._unhex(serverFingerprint)];
    final sig = await me.sign([...utf8.encode(_context), ...body]);
    return Uint8List.fromList([...body, ...sig]);
  }

  /// One heard, if its signature's good; null if it isn't one.
  static Future<IdentityAnnouncement?> read(List<int> data) async {
    if (data.length != length || data[0] != _version) return null;
    final body = data.sublist(0, length - Identity.signatureLength);
    final key = data.sublist(1, 1 + Identity.keyLength);
    if (!await Identity.verify(key, [...utf8.encode(_context), ...body], data.sublist(body.length))) return null;
    return IdentityAnnouncement(Uint8List.fromList(key), Identity._hex(data.sublist(33, 53)), Identity._hex(data.sublist(53, 85)));
  }

  static List<int> _unhex(String hex) =>
      [for (var i = 0; i + 1 < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)];
}
