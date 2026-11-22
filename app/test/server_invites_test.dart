import 'package:dronelab/comm/server_invites.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('an invitation comes back as it went, odd password and all', () {
    const i = ServerInvite('voice.example.com', 1234, 'p&s=w:o rd?#ü');
    final back = ServerInvite.parse(i.text)!;
    expect(back.host, i.host);
    expect(back.port, i.port);
    expect(back.password, i.password);
    expect(ServerInvite.preview(i.text), 'Invitation to the server voice.example.com:1234');
  });

  test('no password, default port', () {
    final back = ServerInvite.parse(const ServerInvite('10.0.0.2', 64738, '').text)!;
    expect(back.address, '10.0.0.2');
    expect(back.password, '');
  });

  test('a plain text is not one', () {
    expect(ServerInvite.parse('hello there'), isNull);
    expect(ServerInvite.preview('hello there'), 'hello there');
  });
}
