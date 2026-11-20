import 'dart:io';

import 'package:dronelab/comm/identity.dart';
import 'package:flutter_test/flutter_test.dart';

class _Kept implements SeedStore {
  String? value;
  bool fails = false;
  _Kept(this.value);

  @override
  Future<String?> read() async => fails ? throw Exception('no keyring') : value;

  @override
  Future<void> write(String v) async => value = v;
}

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('seed'));
  tearDown(() async => dir.delete(recursive: true));

  File file() => File('${dir.path}/sub/identity-seed');

  test('takes over the seed kept before, then keeps to the file', () async {
    final old = _Kept('b2xk');
    final store = FileSeedStore(() async => file(), moveFrom: old);
    expect(await store.read(), 'b2xk');
    expect(await file().readAsString(), 'b2xk');
    old.value = 'changed';
    expect(await store.read(), 'b2xk');
  });

  test('none anywhere, or no keyring: null, nothing written', () async {
    expect(await FileSeedStore(() async => file(), moveFrom: _Kept(null)).read(), isNull);
    expect(await FileSeedStore(() async => file(), moveFrom: _Kept('x')..fails = true).read(), isNull);
    expect(await file().exists(), isFalse);
  });

  test('written for its owner alone, and whole', () async {
    final store = FileSeedStore(() async => file());
    await store.write('one');
    await store.write('two');
    expect(await store.read(), 'two');
    expect((await file().stat()).modeString(), 'rw-------');
    expect(await File('${file().path}.new').exists(), isFalse);
  });

  test('a seed through the file makes the same identity', () async {
    final store = FileSeedStore(() async => file());
    final a = await Identity.load(store);
    final b = await Identity.load(store);
    expect(b.publicKey, a.publicKey);
  });
}
