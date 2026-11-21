import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'dart:io' show Platform;

import 'comm/app_profile.dart';
import 'comm/comm_controller.dart';
import 'comm/linux_pairing.dart';
import 'comm/release_check.dart';
import 'ui/firmware_ui.dart';
import 'ui/pairing_code.dart';
import 'ui/call_ui.dart';
import 'ui/splash.dart';
import 'ui/hivemind_page.dart';
import 'ui/people.dart';
import 'ui/record_page.dart';
import 'ui/release_banner.dart';
import 'ui/remote_page.dart';
import 'ui/status_strip.dart';
import 'ui/text_page.dart';
import 'ui/theme.dart';

/// Whether a newer release of the app is out (see release_check.dart).
final releaseCheck = ReleaseCheck();

/// For opening a conversation from its notification, wherever the app is.
final navigatorKey = GlobalKey<NavigatorState>();

/// For saying what happened to a call, wherever the app is.
final messengerKey = GlobalKey<ScaffoldMessengerState>();

void main(List<String> args) {
  AppProfile.init(args);
  WidgetsFlutterBinding.ensureInitialized();
  if (defaultTargetPlatform == TargetPlatform.android) FlutterForegroundTask.initCommunicationPort();
  final comm = CommController();
  if (Platform.isLinux) {
    final pairing = LinuxPairing((name) async {
      final context = navigatorKey.currentContext;
      return context == null ? null : askPairingCode(context, name);
    });
    comm.board.pairFirst = (id) async => await pairing.pair(id) ? true : pairing.cancelled ? null : false;
    comm.board.letGo = pairing.letGo;
    comm.board.servicesReady = pairing.servicesReady;
  }
  comm.notifier.opens.listen((key) => _openConversation(comm, key));
  comm.incomingCalls.listen((call) => showIncomingCall(comm, call.personId));
  comm.invitations.listen((inv) => showInvitation(comm, inv));
  comm.callNotices.listen((text) => messengerKey.currentState?.showSnackBar(SnackBar(content: Text(text))));
  comm.notifier.callActions.listen((a) {
    final (action, personId) = a;
    if (action == 'decline') {
      comm.endCall(personId);
      return;
    }
    appTab.value = tabVoice;
    navigatorKey.currentState?.popUntil((r) => r.isFirst);
    if (action == 'answer') {
      comm.answerCall(personId);
    } else if (comm.calls[personId] != null) {
      showIncomingCall(comm, personId);
    } else {
      comm.clearMissed(personId);     // a missed call's notification: seen
    }
  });
  final started = DateTime.now();
  // Not held up by a board that's slow to connect, either
  Future.delayed(splashAtMost, () => appStarted.value = true);
  comm.init().then((_) {
    // The logo stays a moment, however quick the start
    final shown = DateTime.now().difference(started);
    Future.delayed(splashAtLeast - shown, () => appStarted.value = true);
    // Started by tapping a text's notification: to it, once there's a screen
    final key = comm.notifier.launchedWith;
    if (key != null) WidgetsBinding.instance.addPostFrameCallback((_) => _openConversation(comm, key));
    comm.notifier.askPermission();
  });
  releaseCheck.start();
  runApp(DroneLabApp(comm: comm));
}

/// A text's notification's been tapped: its conversation, on the Text tab.
void _openConversation(CommController comm, String key) {
  final nav = navigatorKey.currentState;
  if (nav == null || !comm.conversations.all.containsKey(key)) return;
  appTab.value = tabText;
  nav.popUntil((r) => r.isFirst);
  nav.push(MaterialPageRoute(builder: (_) => ConversationPage(comm: comm, conversationKey: key)));
}

class DroneLabApp extends StatelessWidget {
  final CommController comm;
  const DroneLabApp({super.key, required this.comm});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'DroneLab',
      navigatorKey: navigatorKey,
      scaffoldMessengerKey: messengerKey,
      theme: Kc.theme(),
      darkTheme: Kc.theme(),
      themeMode: ThemeMode.dark,
      home: WithForegroundTask(child: Splash(child: HomePage(comm: comm))),
    );
  }
}

/// Voice, Text, Record and Remote, each kept running while another shows,
/// under the links' status strip.
class HomePage extends StatelessWidget {
  final CommController comm;
  const HomePage({super.key, required this.comm});

  @override
  Widget build(BuildContext context) {
    return FirmwarePrompt(
      comm: comm,
      child: ListenableBuilder(
        listenable: Listenable.merge([appTab, comm, comm.conversations]),
        builder: (context, _) {
          final unread = comm.conversations.unread;
          return Scaffold(
            body: Column(
              children: [
                SafeArea(bottom: false, child: StatusStrip(comm: comm)),
                ReleaseBanner(check: releaseCheck),
                Expanded(
                  child: MediaQuery.removePadding(
                    context: context,
                    removeTop: true,
                    child: IndexedStack(
                      index: appTab.value,
                      children: [
                        HiveMindPage(comm: comm),
                        TextPage(comm: comm),
                        RecordPage(comm: comm),
                        RemotePage(comm: comm),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            bottomNavigationBar: NavigationBar(
              selectedIndex: appTab.value,
              onDestinationSelected: (i) => appTab.value = i,
              destinations: [
                const NavigationDestination(icon: Icon(Icons.mic_none), label: 'VOICE'),
                NavigationDestination(
                  icon: Badge(
                    isLabelVisible: unread > 0,
                    label: Text('$unread'),
                    backgroundColor: Theme.of(context).colorScheme.primary,
                    textColor: Theme.of(context).colorScheme.onPrimary,
                    child: const Icon(Icons.chat_bubble_outline),
                  ),
                  label: 'TEXT',
                ),
                const NavigationDestination(icon: Icon(Icons.fiber_manual_record_outlined), label: 'RECORD'),
                const NavigationDestination(icon: Icon(Icons.phone_android), label: 'REMOTE'),
              ],
            ),
          );
        },
      ),
    );
  }
}
