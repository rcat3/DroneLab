/// Pairing a board on Windows. Android pairs by itself when the app first
/// uses what's encrypted, and Linux has its own agent (linux_pairing.dart);
/// Windows doesn't pair on use: the first encrypted read just fails. So the
/// app asks for it, through universal_ble: Windows 11 shows its own pairing
/// dialog, and Windows 10 a small window to type the code the board shows
/// (the board has to be allowing it: Settings, Paired Phones, Pair a phone).
library;

import 'package:flutter/foundation.dart';
import 'package:universal_ble/universal_ble.dart';

class WindowsPairing {
  /// Whether [id] is paired now, pairing it if it isn't: false if it didn't.
  Future<bool> pair(String id) async {
    try {
      await UniversalBle.pair(id, timeout: const Duration(seconds: 90));
      return true;
    } catch (e) {
      debugPrint('pairing: $e');
      return false;
    }
  }
}
