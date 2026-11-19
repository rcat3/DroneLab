import 'dart:io';
import 'dart:typed_data';

import 'package:dronelab/comm/identity.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final seed = Uint8List.fromList(List.generate(32, (i) => i * 7 + 1));

  test('the same seed makes the same identity and certificate', () async {
    final a = await Identity.fromSeed(seed);
    final b = await Identity.fromSeed(seed);
    expect(a.publicKey, b.publicKey);
    expect(a.certificatePem, b.certificatePem);
    expect(a.certificateHash, b.certificateHash);
    expect(a.certificateHash.length, 40);
    expect(a.id.length, 16);
  });

  test('the certificate and key are usable for TLS', () async {
    final me = await Identity.fromSeed(seed);
    final context = SecurityContext(withTrustedRoots: false)
      ..useCertificateChainBytes(me.certificatePem)
      ..usePrivateKeyBytes(me.privateKeyPem)
      ..setTrustedCertificatesBytes(me.certificatePem); // so its signature's checked
    // A server that asks for it, as Mumble's do
    final server = await SecureServerSocket.bind(InternetAddress.loopbackIPv4, 0, context, requestClientCertificate: true);
    String? seen;
    server.listen((s) {
      seen = s.peerCertificate?.der == null ? null : 'got';
      s.destroy();
    });
    final client = await SecureSocket.connect(InternetAddress.loopbackIPv4, server.port,
        context: context, onBadCertificate: (_) => true);
    await Future.delayed(const Duration(milliseconds: 200));
    client.destroy();
    await server.close();
    expect(seen, 'got');
  });

  test('the export code brings the seed back, and catches mistakes', () async {
    final me = await Identity.fromSeed(seed);
    final code = me.exportCode;
    expect(Identity.seedFromCode(code), seed);
    expect(Identity.seedFromCode(code.toLowerCase().replaceAll('-', ' ')), seed);
    final wrong = (code[0] == 'A' ? 'B' : 'A') + code.substring(1);
    expect(() => Identity.seedFromCode(wrong), throwsFormatException);
  });

  test('announcements are checked', () async {
    final me = await Identity.fromSeed(seed);
    final fp = 'ab' * 32;
    final data = await IdentityAnnouncement.make(me, fp);
    final a = await IdentityAnnouncement.read(data);
    expect(a, isNotNull);
    expect(a!.publicKey, me.publicKey);
    expect(a.certificateHash, me.certificateHash);
    expect(a.serverFingerprint, fp);
    data[40] ^= 1;
    expect(await IdentityAnnouncement.read(data), isNull);
  });
}
