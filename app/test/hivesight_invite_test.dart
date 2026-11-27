import 'package:dronelab/comm/hivesight_invite.dart';
import 'package:dronelab/comm/identity.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a HiveSight invitation goes through a text and checks out, and not once changed', () async {
    final me = await Identity.fromSeed(List.filled(32, 7));
    final i = await HiveSightInvite.make(
      me,
      hosts: ['192.168.1.20', '10.0.0.5'],
      port: 8443,
      token: 'abcdefghijklmnopqrstuv',
      expires: DateTime.now().add(const Duration(hours: 12)),
    );
    final back = HiveSightInvite.parse('words first\n${i.text}')!;
    expect(back.hosts, i.hosts);
    expect(back.fingerprint, me.hiveSightCertificate.fingerprint);
    expect(await back.verify(), isTrue);
    expect(back.guideId, me.id);
    final changed = HiveSightInvite.parse(i.text.replaceFirst('p=8443', 'p=8444'))!;
    expect(await changed.verify(), isFalse);
    expect(HiveSightInvite.parse('just a text'), isNull);
  });
}
