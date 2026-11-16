// Two clients on a real Mumble server: one talks, the other hears it.
//   MUMBLE_HOST=192.168.15.200 MUMBLE_PASSWORD=... flutter test test/mumble_test.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:dronelab/comm/mumble_client.dart';
import 'package:dronelab/comm/voice_packet.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final host = Platform.environment['MUMBLE_HOST'];
  final password = Platform.environment['MUMBLE_PASSWORD'] ?? '';

  test('voice goes from one client to another, inside TCP', () async {
    final a = MumbleClient(host: host!, username: 'test-talker', password: password, useUdp: false);
    final b = MumbleClient(host: host, username: 'test-listener', password: password, useUdp: false);
    String? fp;
    await a.connect(checkCertificate: (f) {
      fp = f;
      return true;
    });
    await b.connect(checkCertificate: (f) => f == fp);
    expect(a.state, MumbleState.connected);
    await Future.delayed(const Duration(milliseconds: 300));
    expect(b.channelUsers.map((u) => u.name), contains('test-talker'));

    final heard = <IncomingVoice>[];
    final sub = b.voice.listen(heard.add);
    for (var i = 0; i < 25; i++) {
      a.sendVoice(i * 2, Uint8List.fromList([0xF8, 0xFF, 0xFE, i]), last: i == 24);
      await Future.delayed(const Duration(milliseconds: 20));
    }
    await Future.delayed(const Duration(milliseconds: 500));
    await sub.cancel();
    final talker = a.mySession;
    a.close();
    b.close();

    expect(heard.length, 25);
    expect(heard.first.session, talker);
    expect(heard.map((v) => v.seq), [for (var i = 0; i < 25; i++) i * 2]);
    expect(heard.last.last, isTrue);
  }, skip: host == null ? 'set MUMBLE_HOST to run it' : false, timeout: const Timeout(Duration(seconds: 30)));

  test('voice goes over UDP once it gets through', () async {
    final a = MumbleClient(host: host!, username: 'test-udp-talker', password: password);
    final b = MumbleClient(host: host, username: 'test-udp-listener', password: password);
    await a.connect();
    await b.connect();
    for (var i = 0; i < 50 && !(a.udpActive && b.udpActive); i++) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    expect(a.udpActive, isTrue, reason: "the talker's UDP pings weren't answered");
    expect(b.udpActive, isTrue, reason: "the listener's UDP pings weren't answered");

    final heard = <IncomingVoice>[];
    final sub = b.voice.listen(heard.add);
    for (var i = 0; i < 25; i++) {
      a.sendVoice(i * 2, Uint8List.fromList([0xF8, 0xFF, 0xFE, i]), last: i == 24);
      await Future.delayed(const Duration(milliseconds: 20));
    }
    await Future.delayed(const Duration(milliseconds: 500));
    await sub.cancel();
    a.close();
    b.close();

    expect(heard.length, 25);
    expect(b.udpPacketsIn, 25, reason: 'all of it over UDP');
    expect(b.tcpVoiceIn, 0, reason: 'none of it inside TCP');
    expect(heard.last.last, isTrue);
  }, skip: host == null ? 'set MUMBLE_HOST to run it' : false, timeout: const Timeout(Duration(seconds: 30)));

  test('plugin data goes from one client to another, unseen', () async {
    final a = MumbleClient(host: host!, username: 'test-plugin-sender', password: password);
    final b = MumbleClient(host: host, username: 'test-plugin-receiver', password: password);
    await a.connect();
    await b.connect();
    for (var i = 0; i < 20 && !a.users.containsKey(b.mySession); i++) {
      await Future.delayed(const Duration(milliseconds: 100));
    }

    final got = <MumblePluginData>[];
    final texts = <MumbleText>[];
    final subs = [b.pluginData.listen(got.add), b.texts.listen(texts.add)];
    a.sendPluginData([b.mySession!], 'dronelab-test', Uint8List.fromList([1, 2, 3]));
    await Future.delayed(const Duration(milliseconds: 500));
    expect(got.length, 1);
    expect(got.first.sender, a.mySession);
    expect(got.first.id, 'dronelab-test');
    expect(got.first.data, [1, 2, 3]);

    // How many of a quick run get through: the server's limit
    got.clear();
    for (var i = 0; i < 10; i++) {
      a.sendPluginData([b.mySession!], 'dronelab-test', Uint8List.fromList([i]));
    }
    await Future.delayed(const Duration(milliseconds: 1500));
    // ignore: avoid_print
    print('plugin data: ${got.length} of 10 sent at once got through');
    for (final s in subs) {
      await s.cancel();
    }
    a.close();
    b.close();
    expect(texts, isEmpty, reason: 'nothing shows in the chat');
  }, skip: host == null ? 'set MUMBLE_HOST to run it' : false, timeout: const Timeout(Duration(seconds: 30)));

  test('a wrong password is turned away', () async {
    final c = MumbleClient(host: host!, username: 'test-wrong', password: 'not-the-password');
    await expectLater(c.connect(), throwsA(isA<MumbleException>()));
  }, skip: host == null ? 'set MUMBLE_HOST to run it' : false);
}
