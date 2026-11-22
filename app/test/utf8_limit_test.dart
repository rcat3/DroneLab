import 'dart:convert';

import 'package:dronelab/comm/board_protocol.dart';
import 'package:dronelab/ui/utf8_limit.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

TextEditingValue v(String s) => TextEditingValue(text: s, selection: TextSelection.collapsed(offset: s.length));

void main() {
  final f = Utf8LengthLimit(10);

  test('typing within the limit is left alone', () {
    expect(f.formatEditUpdate(v('abc'), v('abcd')).text, 'abcd');
  });

  test('typing past it does nothing', () {
    expect(f.formatEditUpdate(v('abcdefghij'), v('abcdefghijk')).text, 'abcdefghij');
  });

  test('an emoji that would go past it is not half put in', () {
    expect(f.formatEditUpdate(v('abcdefgh'), v('abcdefgh😀')).text, 'abcdefgh');
  });

  test('a paste is cut to what fits, in whole characters', () {
    final out = f.formatEditUpdate(v('ab'), v('ab😀😀😀'));
    expect(out.text, 'ab😀😀');
    expect(utf8.encode(out.text).length, lessThanOrEqualTo(10));
  });

  test('a paste in the middle keeps what comes after', () {
    final old = const TextEditingValue(text: 'abXY', selection: TextSelection.collapsed(offset: 2));
    final now = const TextEditingValue(text: 'ab123456789XY', selection: TextSelection.collapsed(offset: 11));
    final out = f.formatEditUpdate(old, now);
    expect(out.text, 'ab123456XY');
    expect(out.selection.baseOffset, 8);
  });

  test('the most that can be typed always goes in six parts', () {
    final most = '😀' * (OthersCommand.longTextBytes ~/ 4) + 'é' * ((OthersCommand.longTextBytes % 4) ~/ 2);
    final parts = OthersCommand.sendText(most);
    expect(parts.length, lessThanOrEqualTo(OthersCommand.partsMax));
    final joined = parts.map((p) => utf8.decode(p.what.sublist(5))).join();
    expect(joined, most);
  });
}
