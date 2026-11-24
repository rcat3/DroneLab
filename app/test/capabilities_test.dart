import 'dart:typed_data';

import 'package:dronelab/comm/board_protocol.dart';
import 'package:dronelab/comm/capabilities.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('capabilities go and come back, unknown ones kept', () {
    const c = Capabilities({Capabilities.terminal: CapOpen.ask, Capabilities.vibe: CapOpen.open}, {Capabilities.vibe: 0x05});
    expect(Capabilities.decode(c.encode()), c);
    expect(Capabilities.decode(c.encode())!.vibeChannels, 0x05);
    final later = Capabilities.decode([2, 1, 2, 0, 9, 1, 7])!;
    expect(later[Capabilities.terminal], CapOpen.open);
    expect(later.has(9), isTrue);
    expect(Capabilities.decode([2, 1, 2, 0]), isNull);
    expect(Capabilities.decode([0]), Capabilities.none);
  });

  test("ours, from the board's state", () {
    String state(int toys, int term, String device) =>
        '{"mapped":3,"devices":[{"slot":0,"state":"$device"}],"others":[{"permission":$toys},{"permission":$term}]}';
    expect(Capabilities.fromBoardState(state(2, 1, 'connected')),
        const Capabilities({Capabilities.terminal: CapOpen.ask, Capabilities.vibe: CapOpen.open}, {Capabilities.vibe: 3}));
    expect(Capabilities.fromBoardState(state(2, 0, 'found')), Capabilities.none);
    expect(Capabilities.fromBoardState('{"comm":1}'), isNull);
  });

  test("a board's capabilities over direct comms (0x17)", () {
    final m = parseBoardMessage(Uint8List.fromList([0x17, 0x78, 0x56, 0x34, 0x12, 1, 2, 1, 3])) as DirectCaps;
    expect(m.id, 0x12345678);
    expect(m.caps[Capabilities.vibe], CapOpen.ask);
    expect(m.caps.vibeChannels, 3);
  });
}
