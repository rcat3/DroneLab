import 'dart:typed_data';

import 'package:dronelab/comm/board_protocol.dart';
import 'package:dronelab/comm/capabilities.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('capabilities go and come back, unknown ones kept', () {
    const c = Capabilities({Capabilities.terminal: CapOpen.ask, Capabilities.lovense: CapOpen.open});
    expect(Capabilities.decode(c.encode()), c);
    final later = Capabilities.decode([3, 1, 2, 9, 1, 2, 1])!;
    expect(later[Capabilities.terminal], CapOpen.open);
    expect(later.has(9), isTrue);
    expect(Capabilities.decode([2, 1]), isNull);
    expect(Capabilities.decode([0]), Capabilities.none);
  });

  test("ours, from the board's state", () {
    String state(int toys, int term, String device) =>
        '{"devices":[{"slot":0,"state":"$device"}],"others":[{"permission":$toys},{"permission":$term}]}';
    expect(Capabilities.fromBoardState(state(2, 1, 'connected')),
        const Capabilities({Capabilities.terminal: CapOpen.ask, Capabilities.lovense: CapOpen.open}));
    expect(Capabilities.fromBoardState(state(2, 0, 'found')), Capabilities.none);
    expect(Capabilities.fromBoardState('{"comm":1}'), isNull);
  });

  test("a board's capabilities over direct comms (0x17)", () {
    final m = parseBoardMessage(Uint8List.fromList([0x17, 0x78, 0x56, 0x34, 0x12, 1, 2, 1])) as DirectCaps;
    expect(m.id, 0x12345678);
    expect(m.caps[Capabilities.lovense], CapOpen.ask);
  });
}
