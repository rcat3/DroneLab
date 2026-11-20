/// Invitations to a direct channel: its name, frequency, Long Range and
/// passphrase, sealed for one person with the key only the two of you have
/// (Identity.pairKey, AES-GCM), so they can join without being told the
/// passphrase, and nobody else, the server included, can read it. Sent as a
/// signed command for them alone ([OthersCommand.invite]), over the server
/// and over direct comms.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as c;

import 'board_protocol.dart';

class Invitation {
  final String fromId;      // who from (KnownPerson.id)
  final String from;        // their name
  final String name;        // the channel's
  final String passphrase;
  final int channel;        // frequency: 1, 6 or 11
  final bool longRange;
  const Invitation(this.fromId, this.from, this.name, this.passphrase, this.channel, this.longRange);
}

const _nonceLength = 12, _tagLength = 16;
final _aad = utf8.encode('dronelab-invite\n');
final _gcm = c.AesGcm.with128bits();

/// The most the name and passphrase can take together, in bytes: what fits
/// in one command, less the frequency, Long Range and the name's length.
const inviteRoom = OthersCommand.whatMax - 1 - _nonceLength - _tagLength - 3;

/// Sealed with [key], or null if it's too long to send.
Future<Uint8List?> sealInvitation(Uint8List key, String name, String passphrase, int channel, bool longRange) async {
  final n = utf8.encode(name), p = utf8.encode(passphrase);
  if (n.length + p.length > inviteRoom || n.length > 255) return null;
  final nonce = Uint8List.fromList(List.generate(_nonceLength, (_) => Random.secure().nextInt(256)));
  final box = await _gcm.encrypt([channel, longRange ? 1 : 0, n.length, ...n, ...p],
      secretKey: c.SecretKey(key), nonce: nonce, aad: _aad);
  return Uint8List.fromList([...nonce, ...box.cipherText, ...box.mac.bytes]);
}

/// Opened with [key]: the channel's name, passphrase, frequency and Long
/// Range, or null if it isn't one for us, or was changed on the way.
Future<(String, String, int, bool)?> openInvitation(Uint8List key, Uint8List sealed) async {
  if (sealed.length < _nonceLength + _tagLength + 3) return null;
  try {
    final plain = await _gcm.decrypt(
        c.SecretBox(sealed.sublist(_nonceLength, sealed.length - _tagLength),
            nonce: sealed.sublist(0, _nonceLength), mac: c.Mac(sealed.sublist(sealed.length - _tagLength))),
        secretKey: c.SecretKey(key),
        aad: _aad);
    if (plain.length < 3 || 3 + plain[2] > plain.length) return null;
    final name = utf8.decode(plain.sublist(3, 3 + plain[2]));
    final passphrase = utf8.decode(plain.sublist(3 + plain[2]));
    final channel = const [1, 6, 11].contains(plain[0]) ? plain[0] : 6;
    return (name, passphrase, channel, plain[1] != 0);
  } catch (_) {
    return null;
  }
}
