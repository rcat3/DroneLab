import 'dart:typed_data';

import 'package:dronelab/comm/known_people.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final key = Uint8List.fromList(List.filled(32, 7));

  test('someone known by their certificate becomes known by their key, keeping their mute', () {
    final renamed = <(String, String)>[];
    final people = KnownPeople((_) {})..onRenamed = (a, b) => renamed.add((a, b));
    final p = people.onServer('aa' * 20, 'Alice');
    people.setMuted(p.id, true);
    final k = people.bind(key, 'aa' * 20, 'Alice');
    expect(k.id, KnownPerson.keyId(key));
    expect(k.muted, isTrue);
    expect(renamed, [(p.id, k.id)]);
    // Their certificate finds them by their key from now on
    expect(people.onServer('aa' * 20, 'Alice').id, k.id);
    expect(people[p.id], isNull);
  });

  test('a name on someone new is a clash, but not on the same person renamed', () async {
    final people = KnownPeople((_) {});
    final alice = people.onServer('aa' * 20, 'Alice');
    await Future.delayed(const Duration(milliseconds: 5));
    final other = people.onServer('bb' * 20, 'alice');
    expect(people.clashes(other)?.id, alice.id);
    expect(people.clashes(alice), isNull);
    // Known only by name: nothing to go on
    expect(people.clashes(people.named('Alice')), isNull);
  });

  test('kept and read back', () {
    String? saved;
    final a = KnownPeople((j) => saved = j);
    final p = a.bind(key, 'cc' * 20, 'Bob');
    a.setMuted(p.id, true);
    return Future.delayed(const Duration(milliseconds: 1100), () {
      final b = KnownPeople((_) {})..load(saved);
      expect(b[p.id]?.muted, isTrue);
      expect(b[p.id]?.key, key);
      expect(b.onServer('cc' * 20, 'Bob').id, p.id);
    });
  });

  test('a new identity can take the place of the old one', () async {
    final renamed = <(String, String)>[];
    final people = KnownPeople((_) {})..onRenamed = (a, b) => renamed.add((a, b));
    final old = people.bind(key, 'aa' * 20, 'Alice');
    people.setMuted(old.id, true);
    await Future.delayed(const Duration(milliseconds: 5));
    final now = people.bind(Uint8List.fromList(List.filled(32, 9)), 'bb' * 20, 'Alice');
    expect(people.clashes(now)?.id, old.id);
    people.replace(old.id, now.id);
    expect(people[old.id], isNull);
    expect(people.clashes(people[now.id]!), isNull);
    expect(people[now.id]!.muted, isTrue);
    expect(renamed.last, (old.id, now.id));
    // The old one, if it turns up again, is someone new now
    await Future.delayed(const Duration(milliseconds: 5));
    final back = people.bind(key, 'aa' * 20, 'Alice');
    expect(people.clashes(back)?.id, now.id);
  });

  test('someone known longer who takes a newer name is the one marked, until they change back', () async {
    final people = KnownPeople((_) {});
    final alice = people.bind(key, 'aa' * 20, 'Alice');
    await Future.delayed(const Duration(milliseconds: 5));
    final bob = people.bind(Uint8List.fromList(List.filled(32, 9)), 'bb' * 20, 'Bob');
    await Future.delayed(const Duration(milliseconds: 5));
    people.bind(key, 'aa' * 20, 'bob');       // Alice takes Bob's name
    expect(people.clashes(people[alice.id]!)?.id, bob.id);
    expect(people.clashes(people[bob.id]!), isNull);
    people.bind(key, 'aa' * 20, 'Alice');     // and goes back
    expect(people.clashes(people[alice.id]!), isNull);
    expect(people.clashes(people[bob.id]!), isNull);
  });
}
