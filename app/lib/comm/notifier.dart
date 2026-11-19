import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// DroneLab's notifications, each kind on an Android channel of its own, so
/// its sound, pop-up and status bar can be set in Android's settings
/// ([openChannelSettings]); and each kind on or off here. Texts open their
/// conversation when tapped ([opens]).
class Notifier {
  static const textsChannel = 'texts';
  static const batteryChannel = 'battery';
  static const _batteryId = 1;
  static const _native = MethodChannel('dronelab/notifications');

  final _plugin = FlutterLocalNotificationsPlugin();
  SharedPreferences? _prefs;
  bool _ready = false;

  /// Texts from others, and the unit's battery running low.
  bool texts = true;
  bool battery = true;

  /// A conversation's key, as its notification is tapped.
  final _opens = StreamController<String>.broadcast();
  Stream<String> get opens => _opens.stream;

  /// The conversation whose notification started the app, if one did.
  String? launchedWith;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    texts = _prefs!.getBool('notifyTexts') ?? true;
    battery = _prefs!.getBool('notifyBattery') ?? true;
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(android: AndroidInitializationSettings('ic_notify')),
        onDidReceiveNotificationResponse: (r) {
          final key = r.payload;
          if (key != null && key.isNotEmpty) _opens.add(key);
        },
      );
      final launch = await _plugin.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp ?? false) {
        final key = launch!.notificationResponse?.payload;
        if (key != null && key.isNotEmpty) launchedWith = key;
      }
      final android = _android;
      await android?.createNotificationChannel(const AndroidNotificationChannel(textsChannel, 'Text messages',
          description: 'Texts from others in the hive', importance: Importance.high));
      await android?.createNotificationChannel(const AndroidNotificationChannel(batteryChannel, 'Unit battery low',
          description: "Your unit's battery is running low", importance: Importance.defaultImportance));
      _ready = true;
    } catch (e) {
      debugPrint('Notifications unavailable: $e');   // none, then
    }
  }

  AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

  /// Android 13 on asks the wearer first.
  Future<void> askPermission() async {
    try {
      await _android?.requestNotificationsPermission();
    } catch (_) {}
  }

  Future<void> setTexts(bool on) async {
    texts = on;
    await _prefs?.setBool('notifyTexts', on);
  }

  Future<void> setBattery(bool on) async {
    battery = on;
    await _prefs?.setBool('notifyBattery', on);
    if (!on) await _cancel(_batteryId);
  }

  /// Android's own settings for a channel: sound, pop-up, status bar.
  Future<void> openChannelSettings(String channel) async {
    try {
      await _native.invokeMethod('channelSettings', {'id': channel});
    } catch (_) {}
  }

  static int _idOf(String key) => 1000 + (key.hashCode & 0x3FFFFFF);

  /// A conversation's new texts, the latest few, as a chat: [lines] are who
  /// from, what, when, and their avatar (a PNG or JPEG) if it's known,
  /// oldest first.
  Future<void> showTexts(String key, String title, List<(String, String, DateTime, Uint8List?)> lines,
      {required bool group}) async {
    if (!_ready || !texts || lines.isEmpty) return;
    const me = Person(name: 'You');
    Person who(String from, Uint8List? avatar) =>
        Person(name: from, key: from, icon: avatar == null ? null : ByteArrayAndroidIcon(avatar));
    final style = MessagingStyleInformation(
      me,
      conversationTitle: group ? title : null,
      groupConversation: group,
      messages: [for (final (from, text, time, avatar) in lines) Message(text, time, who(from, avatar))],
    );
    final latest = lines.last.$4;
    try {
      await _plugin.show(
        id: _idOf(key),
        title: title,
        body: lines.last.$2,
        payload: key,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(textsChannel, 'Text messages',
              channelDescription: 'Texts from others in the hive',
              importance: Importance.high,
              priority: Priority.high,
              category: AndroidNotificationCategory.message,
              largeIcon: latest == null ? null : ByteArrayAndroidBitmap(latest),
              styleInformation: style),
        ),
      );
    } catch (_) {}
  }

  /// A conversation's been read: its notification goes.
  Future<void> clearTexts(String key) => _cancel(_idOf(key));

  Future<void> showBattery(int percent) async {
    if (!_ready || !battery) return;
    try {
      await _plugin.show(
        id: _batteryId,
        title: 'Unit battery low',
        body: "Your unit's battery is at $percent%. Charge it soon.",
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(batteryChannel, 'Unit battery low',
              channelDescription: "Your unit's battery is running low", category: AndroidNotificationCategory.status),
        ),
      );
    } catch (_) {}
  }

  Future<void> clearBattery() => _cancel(_batteryId);

  Future<void> _cancel(int id) async {
    try {
      await _plugin.cancel(id: id);
    } catch (_) {}
  }
}
