/// Keeps the app running with the screen off, while the comm channel is on:
/// an Android foreground service, with its notification. The work itself
/// stays in the app; the service only keeps Android from stopping it.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:universal_ble/universal_ble.dart';

bool _initialised = false;

void _init() {
  if (_initialised) return;
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'comm',
      channelName: 'HiveMind',
      channelDescription: 'Shown while the comm channel is on',
      onlyAlertOnce: true,
    ),
    iosNotificationOptions: const IOSNotificationOptions(showNotification: false, playSound: false),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.nothing(),
      autoRunOnBoot: false,
      allowWakeLock: true,
      allowWifiLock: true,
    ),
  );
  _initialised = true;
}

@pragma('vm:entry-point')
void _startCallback() {
  FlutterForegroundTask.setTaskHandler(_IdleHandler());
}

class _IdleHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}
  @override
  void onRepeatEvent(DateTime timestamp) {}
  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

/// [microphone]: talking from the phone's mic with the screen off, which
/// Android (14) only lets a service do that says so as it starts, and only
/// once the mic's allowed. A service already running without it is
/// restarted with it.
bool _withMicrophone = false;

Future<void> startBackground({bool microphone = false}) async {
  if (defaultTargetPlatform != TargetPlatform.android) return;
  _init();
  if (await FlutterForegroundTask.isRunningService) {
    if (!microphone || _withMicrophone) return;
    await FlutterForegroundTask.stopService();
  }
  _withMicrophone = microphone;
  final permission = await FlutterForegroundTask.checkNotificationPermission();
  if (permission != NotificationPermission.granted) {
    await FlutterForegroundTask.requestNotificationPermission();
  }
  // A connected device service needs the Bluetooth permission first
  // (Android 14), which it won't have if only the server's been used yet.
  final bluetooth = await UniversalBle.hasPermissions();
  await FlutterForegroundTask.startService(
    serviceTypes: [
      if (bluetooth) ForegroundServiceTypes.connectedDevice,
      ForegroundServiceTypes.mediaPlayback,
      if (microphone) ForegroundServiceTypes.microphone,
    ],
    serviceId: 1,
    notificationTitle: 'HiveMind is on',
    notificationText: 'Tap to open DroneLab',
    callback: _startCallback,
  );
}

Future<void> stopBackground() async {
  if (defaultTargetPlatform != TargetPlatform.android) return;
  if (await FlutterForegroundTask.isRunningService) {
    await FlutterForegroundTask.stopService();
  }
  _withMicrophone = false;
}
