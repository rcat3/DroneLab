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
  static const callsChannel = 'calls';
  static const missedChannel = 'missed_calls';
  static const waitingChannel = 'call_waiting';
  static const permissionsChannel = 'permission_requests';

  /// A permission request's notification, tapped: [opens] gives this.
  static const permissionsPayload = 'permissions';
  static const _permissionsId = 2;
  static const _batteryId = 1;
  static const _native = MethodChannel('dronelab/notifications');

  final _plugin = FlutterLocalNotificationsPlugin();
  SharedPreferences? _prefs;
  bool _ready = false;

  /// Texts from others, and the unit's battery running low.
  bool texts = true;
  bool battery = true;
  bool calls = false;     // off at first: calls ring in the headphones, worn nearly all the time
  bool missed = true;
  bool permissionRequests = false;    // off at first: the attention tone's in the headphones

  /// A call's notification, tapped or answered from it: what (null for the
  /// notification itself, 'answer' or 'decline') and who's calling.
  final _callActions = StreamController<(String?, String)>.broadcast();
  Stream<(String?, String)> get callActions => _callActions.stream;

  /// A conversation's key, as its notification is tapped.
  final _opens = StreamController<String>.broadcast();
  Stream<String> get opens => _opens.stream;

  /// The conversation whose notification started the app, if one did.
  String? launchedWith;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    texts = _prefs!.getBool('notifyTexts') ?? true;
    battery = _prefs!.getBool('notifyBattery') ?? true;
    calls = _prefs!.getBool('notifyCalls') ?? false;
    missed = _prefs!.getBool('notifyMissed') ?? true;
    permissionRequests = _prefs!.getBool('notifyPermissions') ?? false;
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
            android: AndroidInitializationSettings('ic_notify'),
            linux: LinuxInitializationSettings(defaultActionName: 'Open')),
        onDidReceiveNotificationResponse: (r) {
          final key = r.payload;
          if (key != null && key.startsWith(_callPrefix)) {
            _callActions.add((r.actionId, key.substring(_callPrefix.length)));
          } else if (key != null && key.isNotEmpty) {
            _opens.add(key);
          }
        },
      );
      try {
        final launch = await _plugin.getNotificationAppLaunchDetails();
        if (launch?.didNotificationLaunchApp ?? false) {
          final key = launch!.notificationResponse?.payload;
          if (key != null && key.isNotEmpty) launchedWith = key;
        }
      } on UnimplementedError {
        // Linux: a notification can't start the app
      }
      final android = _android;
      await android?.createNotificationChannel(const AndroidNotificationChannel(textsChannel, 'Text messages',
          description: 'Texts from others in the hive', importance: Importance.high));
      await android?.createNotificationChannel(const AndroidNotificationChannel(batteryChannel, 'Unit battery low',
          description: "Your unit's battery is running low", importance: Importance.defaultImportance));
      // Calls ring with the phone's ringtone, until they're answered or
      // given up on; the sound's changed in Android's settings for it
      await android?.createNotificationChannel(const AndroidNotificationChannel(callsChannel, 'Calls',
          description: 'Someone in the hive calling you',
          importance: Importance.max,
          sound: UriAndroidNotificationSound('content://settings/system/ringtone'),
          audioAttributesUsage: AudioAttributesUsage.notificationRingtone));
      // Someone else calling during a call: shown, but silent, as the
      // call-waiting beeps are in the headphones
      await android?.createNotificationChannel(const AndroidNotificationChannel(waitingChannel, 'Call waiting',
          description: 'Someone calling while you are in a call',
          importance: Importance.high,
          playSound: false,
          enableVibration: false));
      await android?.createNotificationChannel(const AndroidNotificationChannel(missedChannel, 'Missed calls',
          description: "Calls you didn't answer", importance: Importance.high));
      await android?.createNotificationChannel(const AndroidNotificationChannel(permissionsChannel,
          'Permission requests',
          description: 'Someone asking to control something of yours', importance: Importance.high));
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

  Future<void> setPermissionRequests(bool on) async {
    permissionRequests = on;
    await _prefs?.setBool('notifyPermissions', on);
    if (!on) await clearPermissionRequests();
  }

  /// Someone's asking to control something of ours: tapped, the
  /// Permissions screen.
  Future<void> showPermissionRequest(String name, String what) async {
    if (!_ready || !permissionRequests) return;
    try {
      await _plugin.show(
        id: _permissionsId,
        title: 'Permission request',
        body: what.isEmpty ? '$name asks to control your unit' : '$name asks to control your unit: $what',
        payload: permissionsPayload,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(permissionsChannel, 'Permission requests',
              channelDescription: 'Someone asking to control something of yours',
              importance: Importance.high,
              priority: Priority.high,
              category: AndroidNotificationCategory.social),
        ),
      );
    } catch (_) {}
  }

  Future<void> clearPermissionRequests() => _cancel(_permissionsId);

  static const _callPrefix = 'call:';
  static int _callId(String personId) => 3000 + (personId.hashCode & 0xFFFFFF);
  static int _missedId(String personId) => 0x2000000 + (personId.hashCode & 0xFFFFFF);

  Future<void> setCalls(bool on) async {
    calls = on;
    await _prefs?.setBool('notifyCalls', on);
  }

  Future<void> setMissed(bool on) async {
    missed = on;
    await _prefs?.setBool('notifyMissed', on);
  }

  /// Someone's calling: rings until it's answered, turned down, or they
  /// give up (insistent), with Answer and Decline.
  /// [inCallWith] names who we're talking to in a call already: then it's
  /// call waiting, shown without the ringtone.
  Future<void> showCall(String personId, String name, Uint8List? avatar, {String? inCallWith}) async {
    if (!_ready || !calls) return;
    final waiting = inCallWith != null;
    try {
      await _plugin.show(
        id: _callId(personId),
        title: name,
        body: waiting ? "Calling you · you're in a call with $inCallWith" : 'Calling you',
        payload: '$_callPrefix$personId',
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(waiting ? waitingChannel : callsChannel, waiting ? 'Call waiting' : 'Calls',
              channelDescription: waiting ? 'Someone calling while you are in a call' : 'Someone in the hive calling you',
              importance: waiting ? Importance.high : Importance.max,
              priority: waiting ? Priority.high : Priority.max,
              category: AndroidNotificationCategory.call,
              ongoing: true,
              autoCancel: false,
              audioAttributesUsage: AudioAttributesUsage.notificationRingtone,
              // FLAG_INSISTENT: rings till it's seen to
              additionalFlags: waiting ? null : Int32List.fromList([4]),
              largeIcon: avatar == null ? null : ByteArrayAndroidBitmap(avatar),
              actions: const [
                AndroidNotificationAction('decline', 'Decline', showsUserInterface: true),
                AndroidNotificationAction('answer', 'Answer', showsUserInterface: true),
              ]),
        ),
      );
    } catch (_) {}
  }

  Future<void> clearCall(String personId) => _cancel(_callId(personId));

  /// A call that wasn't answered.
  Future<void> showMissed(String personId, String name, int count, Uint8List? avatar) async {
    if (!_ready || !missed) return;
    try {
      await _plugin.show(
        id: _missedId(personId),
        title: count == 1 ? 'Missed call' : '$count missed calls',
        body: name,
        payload: '$_callPrefix$personId',
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(missedChannel, 'Missed calls',
              channelDescription: "Calls you didn't answer",
              importance: Importance.high,
              category: AndroidNotificationCategory.missedCall,
              largeIcon: avatar == null ? null : ByteArrayAndroidBitmap(avatar)),
        ),
      );
    } catch (_) {}
  }

  Future<void> clearMissed(String personId) => _cancel(_missedId(personId));

  Future<void> _cancel(int id) async {
    try {
      await _plugin.cancel(id: id);
    } catch (_) {}
  }
}
