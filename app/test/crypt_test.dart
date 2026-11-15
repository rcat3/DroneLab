// Mumble's OCB2-AES128, checked against Mumble's own tests
// (src/tests/TestCrypt/TestCrypt.cpp).
import 'dart:typed_data';

import 'package:dronelab/comm/crypt_state.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List bytes(List<int> b) => Uint8List.fromList(b);
final key = bytes(List.generate(16, (i) => i));

void main() {
  test('test vectors (draft-krovetz-ocb-00)', () {
    final cs = CryptState()..setKey(key, key, key);
    final (_, blank, ok) = cs.ocbEncrypt(Uint8List(0), key);
    expect(ok, isTrue);
    expect(blank, [0xBF, 0x31, 0x08, 0x13, 0x07, 0x73, 0xAD, 0x5E, 0xC7, 0x0E, 0xC6, 0x9E, 0x78, 0x75, 0xA7, 0xB0]);

    final (crypt, tag, ok2) = cs.ocbEncrypt(bytes(List.generate(40, (i) => i)), key);
    expect(ok2, isTrue);
    expect(tag, [0x9D, 0xB0, 0xCD, 0xF8, 0x80, 0xF7, 0x3E, 0x3E, 0x10, 0xD4, 0xEB, 0x32, 0x17, 0x76, 0x66, 0x88]);
    expect(crypt, [
      0xF7, 0x5D, 0x6B, 0xC8, 0xB4, 0xDC, 0x8D, 0x66, 0xB8, 0x36, 0xA2, 0xB0, 0x8B, 0x32, 0xA6, 0x36, //
      0x9F, 0x1C, 0xD3, 0xC5, 0x22, 0x8D, 0x79, 0xFD, 0x6C, 0x26, 0x7F, 0x5F, 0x6A, 0xA7, 0xB2, 0x31, //
      0xC7, 0xDF, 0xB9, 0xD5, 0x99, 0x51, 0xAE, 0x9C,
    ]);
  });

  test('the XEX* attack is caught, and avoided', () {
    final nonce = bytes([0xff, 0xee, 0xdd, 0xcc, 0xbb, 0xaa, 0x99, 0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11, 0x00]);
    final cs = CryptState()..setKey(key, nonce, nonce);
    final src = Uint8List(32);
    src[15] = 128;
    src.fillRange(16, 32, 42);

    final (encrypted, encTag, encOk) = cs.ocbEncrypt(src, nonce, modifyOnAttack: false);
    expect(encOk, isFalse);
    final forged = Uint8List.fromList(encrypted);
    forged[15] ^= 128;
    final forgedTag = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      forgedTag[i] = src[16 + i] ^ forged[16 + i];
    }
    final (_, decTag, decOk) = cs.ocbDecrypt(Uint8List.sublistView(forged, 0, 16), nonce);
    expect(decTag, forgedTag);
    expect(decOk, isFalse);
    expect(encTag, isNotNull);

    final (enc2, tag2, ok2) = cs.ocbEncrypt(src, nonce);
    final (dec2, decTag2, decOk2) = cs.ocbDecrypt(enc2, nonce);
    expect(ok2 && decOk2, isTrue);
    expect(decTag2, tag2);
    expect(src[0], 0);
    expect(dec2[0], 1);
  });

  test('round trips of every length', () {
    final nonce = bytes(List.generate(16, (i) => 0xff - i));
    final cs = CryptState()..setKey(key, nonce, nonce);
    for (var len = 0; len < 128; len++) {
      final src = bytes(List.generate(len, (i) => (i * 7 + len) & 0xFF));
      final (enc, tag, _) = cs.ocbEncrypt(src, nonce);
      final (dec, tag2, ok) = cs.ocbDecrypt(enc, nonce);
      expect(ok, isTrue, reason: 'length $len');
      expect(dec, src, reason: 'length $len');
      expect(tag2, tag, reason: 'length $len');
    }
  });

  test('packets: in order, late, lost, repeated and tampered with', () {
    final a = CryptState()..setKey(key, bytes(List.filled(16, 1)), bytes(List.filled(16, 2)));
    final b = CryptState()..setKey(key, bytes(List.filled(16, 2)), bytes(List.filled(16, 1)));
    final packets = [for (var i = 0; i < 300; i++) a.encrypt(bytes([i & 0xFF, i >> 8, 9, 9]))];
    // In order, across the IV byte wrapping round
    for (var i = 0; i < 260; i++) {
      expect(b.decrypt(packets[i]), [i & 0xFF, i >> 8, 9, 9], reason: 'packet $i');
    }
    expect(b.decrypt(packets[259]), isNull, reason: 'a repeat');
    // Two lost, then one of them turns up late
    expect(b.decrypt(packets[262]), isNotNull);
    expect(b.decrypt(packets[261]), isNotNull);
    expect(b.decrypt(packets[263]), isNotNull);
    final bad = Uint8List.fromList(packets[264]);
    bad[6] ^= 1;
    expect(b.decrypt(bad), isNull, reason: 'tampered with');
    expect(b.decrypt(packets[264]), isNotNull);
  });
}
