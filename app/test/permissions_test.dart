import 'package:dronelab/comm/board_link.dart';
import 'package:dronelab/comm/capabilities.dart';
import 'package:dronelab/comm/permissions.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final key = List<int>.generate(32, (i) => i);
  final id = key.take(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  String state({int toys = 1, int term = 1, int ignore = 0, bool allowed = false}) =>
      '{"devices":[],"others":[{"permission":$toys,"ignore":$ignore,"senders":[]},'
      '{"permission":$term,"ignore":0,"senders":[{"name":"Ann","id":"$id","allowed":${allowed ? 1 : 0},"clash":0}]}]}';

  Permissions make() => Permissions(BoardLink());

  test('a refused command on Ask is a request, once, gathering what it asks for', () {
    final p = make()..boardState(state());
    var told = 0;
    p.onNew = (_) => told++;
    p.refused(Capabilities.display, key, 'Ann', 'k:1', everyone: false, channel: false, what: 'hi');
    p.refused(Capabilities.display, key, 'Ann', 'k:1', everyone: false, channel: false, what: 'hi again');
    p.refused(Capabilities.vibe, key, 'Ann', 'k:1', everyone: false, channel: false, what: 'vibrate 3');
    expect(p.requests.length, 1);
    expect(p.requests.first.caps, {Capabilities.display, Capabilities.vibe});
    expect(told, 2);
  });

  test('no request for Off, Anyone, what is ignored, or someone allowed', () {
    final p = make()..boardState(state(toys: 0, ignore: ignoreEveryone));
    p.refused(Capabilities.vibe, key, 'Ann', 'k:1', everyone: false, channel: false, what: '');
    expect(p.requests, isEmpty);
    p.boardState(state(toys: 1, ignore: ignoreEveryone));
    p.refused(Capabilities.vibe, key, 'Ann', 'k:1', everyone: true, channel: false, what: '');
    expect(p.requests, isEmpty);
    p.boardState(state(allowed: true));
    p.refused(Capabilities.display, key, 'Ann', 'k:1', everyone: false, channel: false, what: '');
    expect(p.requests, isEmpty);
  });

  test('declined, it does not ask again for that; allowed on the unit, the request goes', () {
    final p = make()..boardState(state());
    p.refused(Capabilities.display, key, 'Ann', 'k:1', everyone: false, channel: false, what: '');
    p.decline(p.requests.first);
    p.refused(Capabilities.display, key, 'Ann', 'k:1', everyone: false, channel: false, what: '');
    expect(p.requests, isEmpty);
    expect(p.declined.length, 1);
    p.refused(Capabilities.vibe, key, 'Ann', 'k:1', everyone: false, channel: false, what: '');
    expect(p.requests.length, 1);
    p.boardState(state(toys: 2));
    expect(p.requests, isEmpty);
  });

  test('the log says how each command came and what came of it', () {
    final p = make()..boardState(state(toys: 0));
    p.heard(Capabilities.display, key, 'Ann', 'k:1',
        done: false, muted: false, direct: true, scope: 2, what: 'put “hi” on your display');
    p.heard(Capabilities.vibe, key, 'Ann', 'k:1',
        done: false, muted: false, direct: false, scope: 1, what: 'set your toys on V1 to 4');
    p.heard(Capabilities.vibe, key, 'Ann', 'k:1', done: true, muted: false, direct: false, scope: 0, what: 'x');
    expect(p.commandLog.map((e) => (e.via, e.scope, e.outcome)), [
      ('Cloud', 'To everyone', 'Done'),
      ('Cloud', 'To the channel', 'Not done: Vibe is off'),
      ('Direct', 'To you only', 'Not done: they asked for permission'),
    ]);
    p.decline(p.requests.first);
    expect(p.commandLog.first.outcome, "You declined Ann's request for Terminal");
  });
}
