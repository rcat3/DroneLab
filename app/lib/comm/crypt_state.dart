/// Mumble's encryption for voice over UDP: OCB2-AES128, as in Mumble's
/// src/crypto/CryptStateOCB2.cpp (BSD-style licence, The Mumble Developers),
/// ported to Dart a byte at a time, with its guard against the 2019 attack on
/// OCB2 (https://eprint.iacr.org/2019/311, section 9).
///
/// Each packet is [IV byte][3 bytes of the tag][encrypted data]. The IVs count
/// up a packet at a time; decrypt() works out packets that arrive late or
/// after some were lost, and turns away repeats.
library;

import 'dart:typed_data';

import 'package:pointycastle/export.dart';

const _block = 16;

class CryptState {
  final AESEngine _enc = AESEngine();
  final AESEngine _dec = AESEngine();
  final Uint8List encryptIv = Uint8List(_block);
  final Uint8List decryptIv = Uint8List(_block);
  final Uint8List _history = Uint8List(256);
  bool ready = false;

  int good = 0, late = 0, lost = 0;

  /// Set from the server's CryptSetup: the key, our nonce (encrypting) and
  /// the server's (decrypting).
  void setKey(Uint8List key, Uint8List clientNonce, Uint8List serverNonce) {
    _enc.init(true, KeyParameter(key));
    _dec.init(false, KeyParameter(key));
    encryptIv.setAll(0, clientNonce);
    decryptIv.setAll(0, serverNonce);
    _history.fillRange(0, 256, 0);
    ready = true;
  }

  /// The server's nonce alone: it's starting its count again.
  void setDecryptIv(Uint8List serverNonce) => decryptIv.setAll(0, serverNonce);

  Uint8List _aes(Uint8List block) {
    final out = Uint8List(_block);
    _enc.processBlock(block, 0, out, 0);
    return out;
  }

  Uint8List _aesDecrypt(Uint8List block) {
    final out = Uint8List(_block);
    _dec.processBlock(block, 0, out, 0);
    return out;
  }

  // Multiply by 2 in GF(2^128), as a big-endian number (Mumble's S2)
  static void _times2(Uint8List b) {
    final carry = b[0] >> 7;
    for (var i = 0; i < _block - 1; i++) {
      b[i] = ((b[i] << 1) | (b[i + 1] >> 7)) & 0xFF;
    }
    b[_block - 1] = ((b[_block - 1] << 1) & 0xFF) ^ (carry * 0x87);
  }

  // Multiply by 3 (Mumble's S3): b ^= 2b
  static void _times3(Uint8List b) {
    final twice = Uint8List.fromList(b);
    _times2(twice);
    for (var i = 0; i < _block; i++) {
      b[i] ^= twice[i];
    }
  }

  static void _xor(Uint8List dst, Uint8List a, Uint8List b) {
    for (var i = 0; i < _block; i++) {
      dst[i] = a[i] ^ b[i];
    }
  }

  /// OCB2 encrypt [plain] under [nonce], into a ciphertext as long as it,
  /// and the 16-byte tag. Returns false only with [modifyOnAttack] off, for
  /// a packet that the attack could use.
  (Uint8List, Uint8List, bool) ocbEncrypt(Uint8List plain, Uint8List nonce, {bool modifyOnAttack = true}) {
    final out = Uint8List(plain.length);
    final checksum = Uint8List(_block);
    final delta = _aes(Uint8List.fromList(nonce));
    final tmp = Uint8List(_block);
    var success = true;
    var len = plain.length;
    var at = 0;
    while (len > _block) {
      // The second to last block, if it's all zeros but for its last byte,
      // could be used for the attack: flip a bit of it (and of the checksum)
      var flip = false;
      if (len - _block <= _block) {
        var sum = 0;
        for (var i = 0; i < _block - 1; i++) {
          sum |= plain[at + i];
        }
        if (sum == 0) {
          if (modifyOnAttack) {
            flip = true;
          } else {
            success = false;
          }
        }
      }
      _times2(delta);
      for (var i = 0; i < _block; i++) {
        tmp[i] = delta[i] ^ plain[at + i];
      }
      if (flip) tmp[0] ^= 1;
      final e = _aes(tmp);
      for (var i = 0; i < _block; i++) {
        out[at + i] = delta[i] ^ e[i];
        checksum[i] ^= plain[at + i];
      }
      if (flip) checksum[0] ^= 1;
      len -= _block;
      at += _block;
    }
    _times2(delta);
    tmp.fillRange(0, _block, 0);
    tmp[_block - 1] = (len * 8) & 0xFF; // len * 8, big-endian, in the last bytes (len is 16 at most)
    _xor(tmp, tmp, delta);
    final pad = _aes(tmp);
    for (var i = 0; i < _block; i++) {
      tmp[i] = i < len ? plain[at + i] : pad[i];
    }
    _xor(checksum, checksum, tmp);
    for (var i = 0; i < len; i++) {
      out[at + i] = pad[i] ^ tmp[i];
    }
    _times3(delta);
    _xor(tmp, delta, checksum);
    return (out, _aes(tmp), success);
  }

  /// OCB2 decrypt. Returns the plaintext, the tag to check, and false if the
  /// packet looks like the attack.
  (Uint8List, Uint8List, bool) ocbDecrypt(Uint8List encrypted, Uint8List nonce) {
    final out = Uint8List(encrypted.length);
    final checksum = Uint8List(_block);
    final delta = _aes(Uint8List.fromList(nonce));
    final tmp = Uint8List(_block);
    var success = true;
    var len = encrypted.length;
    var at = 0;
    while (len > _block) {
      _times2(delta);
      for (var i = 0; i < _block; i++) {
        tmp[i] = delta[i] ^ encrypted[at + i];
      }
      final d = _aesDecrypt(tmp);
      for (var i = 0; i < _block; i++) {
        out[at + i] = delta[i] ^ d[i];
        checksum[i] ^= out[at + i];
      }
      len -= _block;
      at += _block;
    }
    _times2(delta);
    tmp.fillRange(0, _block, 0);
    tmp[_block - 1] = (len * 8) & 0xFF;
    _xor(tmp, tmp, delta);
    final pad = _aes(tmp);
    tmp.fillRange(0, _block, 0);
    for (var i = 0; i < len; i++) {
      tmp[i] = encrypted[at + i];
    }
    _xor(tmp, tmp, pad);
    _xor(checksum, checksum, tmp);
    for (var i = 0; i < len; i++) {
      out[at + i] = tmp[i];
    }
    // The attack would need the last block to decrypt to delta (but for its
    // last byte, which only the length changes)
    var same = true;
    for (var i = 0; i < _block - 1; i++) {
      if (tmp[i] != delta[i]) {
        same = false;
        break;
      }
    }
    if (same) success = false;
    _times3(delta);
    _xor(tmp, delta, checksum);
    return (out, _aes(tmp), success);
  }

  /// A packet to send.
  Uint8List encrypt(Uint8List plain) {
    for (var i = 0; i < _block; i++) {
      encryptIv[i] = (encryptIv[i] + 1) & 0xFF;
      if (encryptIv[i] != 0) break;
    }
    final (cipher, tag, _) = ocbEncrypt(plain, encryptIv);
    final out = Uint8List(4 + cipher.length);
    out[0] = encryptIv[0];
    out[1] = tag[0];
    out[2] = tag[1];
    out[3] = tag[2];
    out.setAll(4, cipher);
    return out;
  }

  /// A packet received, or null if it doesn't check out or is a repeat.
  Uint8List? decrypt(Uint8List packet) {
    if (packet.length < 4) return null;
    final save = Uint8List.fromList(decryptIv);
    final ivByte = packet[0];
    var restore = false;
    var lateNow = 0, lostNow = 0;

    if (((decryptIv[0] + 1) & 0xFF) == ivByte) {
      // In order
      if (ivByte > decryptIv[0]) {
        decryptIv[0] = ivByte;
      } else if (ivByte < decryptIv[0]) {
        decryptIv[0] = ivByte;
        for (var i = 1; i < _block; i++) {
          decryptIv[i] = (decryptIv[i] + 1) & 0xFF;
          if (decryptIv[i] != 0) break;
        }
      } else {
        return null;
      }
    } else {
      // Out of order, or a repeat
      var diff = ivByte - decryptIv[0];
      if (diff > 128) {
        diff -= 256;
      } else if (diff < -128) {
        diff += 256;
      }
      if (ivByte < decryptIv[0] && diff > -30 && diff < 0) {
        // Late, no wraparound
        lateNow = 1;
        lostNow = -1;
        decryptIv[0] = ivByte;
        restore = true;
      } else if (ivByte > decryptIv[0] && diff > -30 && diff < 0) {
        // Late, from before a wraparound
        lateNow = 1;
        lostNow = -1;
        decryptIv[0] = ivByte;
        for (var i = 1; i < _block; i++) {
          final was = decryptIv[i];
          decryptIv[i] = (was - 1) & 0xFF;
          if (was != 0) break;
        }
        restore = true;
      } else if (ivByte > decryptIv[0] && diff > 0) {
        // Some lost
        lostNow = ivByte - decryptIv[0] - 1;
        decryptIv[0] = ivByte;
      } else if (ivByte < decryptIv[0] && diff > 0) {
        // Some lost, and wrapped around
        lostNow = 256 - decryptIv[0] + ivByte - 1;
        decryptIv[0] = ivByte;
        for (var i = 1; i < _block; i++) {
          decryptIv[i] = (decryptIv[i] + 1) & 0xFF;
          if (decryptIv[i] != 0) break;
        }
      } else {
        return null;
      }
      if (_history[decryptIv[0]] == decryptIv[1]) {
        decryptIv.setAll(0, save);
        return null;
      }
    }

    final (plain, tag, ok) = ocbDecrypt(Uint8List.sublistView(packet, 4), decryptIv);
    if (!ok || tag[0] != packet[1] || tag[1] != packet[2] || tag[2] != packet[3]) {
      decryptIv.setAll(0, save);
      return null;
    }
    _history[decryptIv[0]] = decryptIv[1];
    if (restore) decryptIv.setAll(0, save);
    good++;
    late = (late + lateNow).clamp(0, 1 << 30);
    lost = (lost + lostNow).clamp(0, 1 << 30);
    return plain;
  }
}
