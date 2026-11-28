import 'dart:convert';

import 'package:dronelab/comm/board_protocol.dart' show OthersCommand;
import 'package:dronelab/comm/hivesight_guide.dart';
import 'package:dronelab/comm/hivesight_invite.dart';
import 'package:dronelab/comm/hivesight_join.dart';
import 'package:dronelab/comm/identity.dart';
import 'package:dronelab/comm/known_people.dart';
import 'package:dronelab/comm/rules.dart';
import 'package:flutter_test/flutter_test.dart';

Future<HiveSightInvite> _invite(Identity me, List<String> hosts, {Duration lasts = const Duration(hours: 12)}) =>
    HiveSightInvite.make(me, hosts: hosts, port: 8443, token: 'abcdefghijklmnopqrstuvwx', expires: DateTime.now().add(lasts));

void main() {
  late Identity guide;
  setUp(() async => guide = await Identity.fromSeed(List.filled(32, 7)));

  group('the text and the code fit', () {
    test('an invitation text is well under direct comms limit with up to 3 addresses', () async {
      for (final hosts in [
        ['192.168.1.20'],
        ['192.168.1.20', '10.0.0.5'],
        ['192.168.100.200', '10.255.255.254', '172.16.254.254'],
      ]) {
        final i = await _invite(guide, hosts);
        final bytes = utf8.encode(i.text).length;
        expect(bytes, lessThan(OthersCommand.longTextBytes - 150), reason: '${hosts.length} addresses: $bytes bytes');
        // and the code's link is about 320 characters, a size that scans easily
        expect(i.link.length, lessThan(400));
      }
    });
  });

  group('reading a scanned code', () {
    test('a good one', () async {
      final i = await _invite(guide, ['192.168.1.20']);
      final r = await readCode(i.link);
      expect(r.result, CodeResult.ok);
      expect(r.invite!.guideId, guide.id);
    });

    test('one altered', () async {
      final i = await _invite(guide, ['192.168.1.20']);
      final r = await readCode(i.link.replaceFirst('h=192.168.1.20', 'h=192.168.1.21'));
      expect(r.result, CodeResult.altered);
      expect(r.problem, contains('altered'));
    });

    test('one that has expired', () async {
      final i = await HiveSightInvite.make(
        guide,
        hosts: ['192.168.1.20'],
        port: 8443,
        token: 'abcdefghijklmnopqrstuvwx',
        expires: DateTime.now().subtract(const Duration(minutes: 5)),
      );
      final r = await readCode(i.link);
      expect(r.result, CodeResult.expired);
      expect(r.problem, startsWith('That session ended at'));
    });

    test("something that isn't a HiveSight link", () async {
      for (final t in ['https://example.com/', 'hello', 'dronelab://join?x=1', '']) {
        final r = await readCode(t);
        expect(r.result, CodeResult.notHiveSight, reason: t);
        expect(r.problem, "That isn't a HiveSight code");
      }
    });

    test('a HiveSight link that is missing its parts', () async {
      expect((await readCode('dronelab://hivesight?g=abc')).result, CodeResult.damaged);
    });
  });

  group('deciding to join', () {
    late HiveSightInvite i;
    late KnownPeople people;
    late HiveRules rules;
    setUp(() async {
      i = await _invite(guide, ['192.168.1.20']);
      people = KnownPeople((_) {});
      rules = HiveRules();
    });

    Future<JoinDecision> code() => decideJoin(i, rules: rules, people: people, fromCode: true);

    test('a code from a Guide we know names them, and asks if not allowed yet', () async {
      people.byKey(guide.publicKey, 'Mistress');
      final d = await code();
      expect(d.refusal, isNull);
      expect(d.from, 'Mistress');
      expect(d.fromCode, isTrue);
      expect(d.ask, isTrue);
    });

    test('a code from a Guide we know and have allowed goes straight on', () async {
      people.byKey(guide.publicKey, 'Mistress');
      rules.note(_hex(guide.publicKey), 'Mistress').allowed.add(RuleClass.hiveSight);
      final d = await code();
      expect(d.ask, isFalse);
    });

    test('a code from a Guide we do not know says so, with the key id', () async {
      final d = await code();
      expect(d.refusal, isNull);
      expect(d.from, "a Guide you don't know yet (⬡ ${guide.id.substring(0, 8)})");
      expect(d.savedName, '⬡ ${guide.id.substring(0, 8)}');
      expect(d.ask, isTrue);
    });

    test('Nobody refuses, and Anyone does not ask', () async {
      rules.rule(RuleClass.hiveSight).policy = Policy.off;
      expect((await code()).refusal, contains('Nobody'));
      rules.rule(RuleClass.hiveSight).policy = Policy.anyone;
      final d = await code();
      expect(d.refusal, isNull);
      expect(d.ask, isFalse);
    });

    test('an altered or expired code is refused', () async {
      final altered = HiveSightInvite.parse(i.link.replaceFirst('p=8443', 'p=8444'))!;
      expect((await decideJoin(altered, rules: rules, people: people, fromCode: true)).refusal, contains('altered'));
      final old = await HiveSightInvite.make(guide,
          hosts: ['10.0.0.2'], port: 8443, token: 'abcdefghijklmnopqrstuvwx', expires: DateTime.now().subtract(const Duration(seconds: 5)));
      expect((await decideJoin(old, rules: rules, people: people, fromCode: true)).refusal, startsWith('This session ended'));
    });

    test('a text only from the Guide who signed it', () async {
      final mine = KnownPerson.keyId(guide.publicKey);
      final ok = await decideJoin(i, rules: rules, people: people, who: mine, from: 'Mistress');
      expect(ok.refusal, isNull);
      expect(ok.from, 'Mistress');
      final other = await Identity.fromSeed(List.filled(32, 9));
      final no = await decideJoin(i, rules: rules, people: people, who: KnownPerson.keyId(other.publicKey), from: 'Someone');
      expect(no.refusal, "This invitation isn't from the person who sent it");
      final byName = await decideJoin(i, rules: rules, people: people, who: 'n:Mistress', from: 'Mistress');
      expect(byName.refusal, isNotNull);
    });
  });

  group("this computer's addresses", () {
    test("keep the sender's rules: no loopback, link-local or Docker, sorted, each once", () {
      expect(
        HiveSightGuide.lanAddresses(['127.0.0.1', '192.168.1.5', '172.17.0.1', '10.0.0.2', '169.254.3.3', '192.168.1.5', 'bogus', '100.64.0.9']),
        ['10.0.0.2', '100.64.0.9', '192.168.1.5'],
      );
      expect(HiveSightGuide.lanAddresses(const []), isEmpty);
    });
  });
}

String _hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
