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
}
