import 'dart:convert';

import 'package:flutter/services.dart';

/// Keeps what's typed within [max] bytes of UTF-8, as texts over direct
/// comms are limited in bytes, not letters: an emoji takes four. Typing past
/// it does nothing; something pasted is cut to what fits.
class Utf8LengthLimit extends TextInputFormatter {
  final int max;
  Utf8LengthLimit(this.max);

  static int bytes(String s) => utf8.encode(s).length;

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    if (bytes(newValue.text) <= max) return newValue;
    final old = oldValue.text, now = newValue.text;
    // What was put in: what's between the part the two start with and the
    // part they end with
    var start = 0;
    while (start < old.length && start < now.length && old.codeUnitAt(start) == now.codeUnitAt(start)) {
      start++;
    }
    var end = 0;
    while (end < old.length - start &&
        end < now.length - start &&
        old.codeUnitAt(old.length - 1 - end) == now.codeUnitAt(now.length - 1 - end)) {
      end++;
    }
    // Not in the middle of an emoji's two halves
    bool high(int u) => u >= 0xD800 && u <= 0xDBFF;
    bool low(int u) => u >= 0xDC00 && u <= 0xDFFF;
    if (start > 0 && high(now.codeUnitAt(start - 1))) start--;
    if (end > 0 && low(now.codeUnitAt(now.length - end))) end--;
    final before = now.substring(0, start), after = now.substring(now.length - end);
    final room = max - bytes(before) - bytes(after);
    if (room <= 0) return bytes(old) <= max ? oldValue : _cut(now);
    // As much of it as fits, whole characters only
    final put = now.substring(start, now.length - end).runes.toList();
    var used = 0, n = 0;
    while (n < put.length) {
      final b = bytes(String.fromCharCode(put[n]));
      if (used + b > room) break;
      used += b;
      n++;
    }
    final text = before + String.fromCharCodes(put.take(n)) + after;
    final at = text.length - after.length;
    return TextEditingValue(text: text, selection: TextSelection.collapsed(offset: at));
  }

  /// The end cut off till it fits.
  TextEditingValue _cut(String s) {
    final r = s.runes.toList();
    while (r.isNotEmpty && bytes(String.fromCharCodes(r)) > max) {
      r.removeLast();
    }
    final text = String.fromCharCodes(r);
    return TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
  }
}
