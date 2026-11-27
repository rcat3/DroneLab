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

  test('virtual units are named by their number', () {
    expect(socketUnitName(1), 'Virtual unit');
    expect(socketUnitName(2), 'Virtual unit 2');
    expect(socketUnitNumber('unit:3'), 3);
    expect(socketUnitNumber('unit:0'), isNull);
    expect(socketUnitNumber('AA:BB'), isNull);
  });

  test('an endpoint file is read strictly', () {
    final token = 'ab' * 16;
    final ep = UnitEndpoint.parse('unit-2.ep', '40123 $token\n')!;
    expect((ep.unit, ep.port, ep.token, ep.id), (2, 40123, token, 'unit:2'));
    expect(UnitEndpoint.parse('unit-2.ep', '40123 nope'), isNull);
    expect(UnitEndpoint.parse('unit-2.ep', '0 $token'), isNull);
    expect(UnitEndpoint.parse('unit-0.ep', '4000 $token'), isNull);
    expect(UnitEndpoint.parse('other.ep', '4000 $token'), isNull);
  });

  group('over loopback', () {
    late Directory dir;
    late ServerSocket server;
    final token = '0123456789abcdef' * 2;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('dronelab-test');
      socketDirectoryOverride = dir.path;
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      await File('${dir.path}/unit-1.ep').writeAsString('${server.port} $token\n');
    });

    tearDown(() async {
      socketDirectoryOverride = null;
      await server.close();
      await dir.delete(recursive: true);
    });

    test('units that have said where they are are listed', () async {
      await File('${dir.path}/unit-3.ep').writeAsString('1234 garbage');
      await File('${dir.path}/unit-9.inuse').writeAsString('');
      final found = await SocketTransport.listening();
      expect(found.map((e) => e.id), ['unit:1']);
    });

    test('the token goes first, then messages both ways, and a drop is told', () async {
      final unitGot = <List<int>>[];
      final tokenGot = BytesBuilder();
      final unitSide = Completer<Socket>();
      server.listen((s) {
        unitSide.complete(s);
        final r = FrameReader((m) => unitGot.add(List.of(m)));
        var rest = socketTokenLength;
        s.listen((d) {
          if (rest > 0) {
            final n = d.length < rest ? d.length : rest;
            tokenGot.add(d.sublist(0, n));
            rest -= n;
            d = d.sublist(n);
          }
          if (d.isNotEmpty) r.add(d);
        });
      });

      final t = SocketTransport();
      final appGot = <List<int>>[];
      final dropped = Completer<String?>();
      await t.open('${socketIdPrefix}1',
          onMessage: (m) => appGot.add(List.of(m)), onDropped: dropped.complete, overtaken: () => false);
      final unit = await unitSide.future;

      await t.write(Uint8List.fromList([9, 8]));
      expect(await t.writeFast(Uint8List.fromList([7])), isTrue);
      unit.add(frameMessage(Uint8List.fromList([1, 2, 3, 4])));
      await unit.flush();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(String.fromCharCodes(tokenGot.toBytes()), token);
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
    });

    test('a unit that has gone fails to open', () async {
      await File('${dir.path}/unit-1.ep').delete();
      final t = SocketTransport();
      await expectLater(
          t.open('${socketIdPrefix}1', onMessage: (_) {}, onDropped: (_) {}, overtaken: () => false),
          throwsA(isA<TransportFailure>()));
    });
  });
}
