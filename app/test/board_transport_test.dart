import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dronelab/comm/board_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('frames are split however the bytes come', () {
    final got = <List<int>>[];
    final r = FrameReader((m) => got.add(List.of(m)));
    final bytes = [
      ...frameMessage(Uint8List.fromList([1, 2, 3])),
      ...frameMessage(Uint8List(0)),
      ...frameMessage(Uint8List.fromList(List.filled(244, 7))),
    ];
    for (final b in bytes) {
      r.add([b]);
    }
    expect(got.length, 3);
    expect(got[0], [1, 2, 3]);
    expect(got[1], isEmpty);
    expect(got[2].length, 244);
    r.add(bytes);
    expect(got.length, 6);
  });

  test('a message too long is refused', () {
    final r = FrameReader((_) {});
    expect(() => r.add([245, 0]), throwsFormatException);
    expect(() => frameMessage(Uint8List(245)), throwsArgumentError);
  });

  test('virtual units are named after their socket', () {
    expect(socketUnitName('/run/user/1000/dronelab-unit.sock'), 'Virtual unit');
    expect(socketUnitName('/run/user/1000/dronelab-unit-2.sock'), 'Virtual unit 2');
  });

  test('messages go both ways over a Unix socket, and a drop is told', () async {
    final dir = await Directory.systemTemp.createTemp('dronelab-test');
    final path = '${dir.path}/dronelab-unit.sock';
    final server = await ServerSocket.bind(InternetAddress(path, type: InternetAddressType.unix), 0);
    final unitGot = <List<int>>[];
    final unitSide = Completer<Socket>();
    server.listen((s) {
      unitSide.complete(s);
      final r = FrameReader((m) => unitGot.add(List.of(m)));
      s.listen(r.add);
    });

    final t = SocketTransport();
    final appGot = <List<int>>[];
    final dropped = Completer<String?>();
    await t.open('$socketIdPrefix$path',
        onMessage: (m) => appGot.add(List.of(m)), onDropped: dropped.complete, overtaken: () => false);
    final unit = await unitSide.future;

    await t.write(Uint8List.fromList([9, 8]));
    expect(await t.writeFast(Uint8List.fromList([7])), isTrue);
    unit.add(frameMessage(Uint8List.fromList([1, 2, 3, 4])));
    await unit.flush();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(unitGot, [
      [9, 8],
      [7]
    ]);
    expect(appGot, [
      [1, 2, 3, 4]
    ]);

    unit.destroy();
    expect(await dropped.future.timeout(const Duration(seconds: 2)), isNotNull);
    await t.close();
    await server.close();
    await dir.delete(recursive: true);
  });

  test("a unit that isn't running fails to open", () async {
    final t = SocketTransport();
    await expectLater(
        t.open('$socketIdPrefix/nonexistent/dronelab-unit.sock',
            onMessage: (_) {}, onDropped: (_) {}, overtaken: () => false),
        throwsA(isA<TransportFailure>()));
  });
}
