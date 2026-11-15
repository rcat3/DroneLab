/// The headphones' play/pause button, through the app's media session
/// (MainActivity.kt): each press calls [onPress]. Android only, for now; on
/// an iPhone it would be MPRemoteCommandCenter.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class MediaButtons {
  static const _channel = MethodChannel('dronelab/media_buttons');
  final VoidCallback onPress;
  bool _on = false;

  MediaButtons(this.onPress) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'press') onPress();
    });
  }

  bool get supported => defaultTargetPlatform == TargetPlatform.android;

  Future<void> start() async {
    if (_on || !supported) return;
    _on = true;
    await _channel.invokeMethod('start');
  }

  Future<void> stop() async {
    if (!_on) return;
    _on = false;
    await _channel.invokeMethod('stop');
  }
}
