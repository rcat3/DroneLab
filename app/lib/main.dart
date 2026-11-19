import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'comm/comm_controller.dart';
import 'comm/release_check.dart';
import 'ui/firmware_ui.dart';
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

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.initCommunicationPort();
  final comm = CommController();
  comm.init();
  releaseCheck.start();
  runApp(DroneLabApp(comm: comm));
}

class DroneLabApp extends StatelessWidget {
  final CommController comm;
  const DroneLabApp({super.key, required this.comm});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DroneLab',
      theme: Kc.theme(),
      darkTheme: Kc.theme(),
      themeMode: ThemeMode.dark,
      home: WithForegroundTask(child: HomePage(comm: comm)),
    );
  }
}

/// HiveMind, the Terminal, controlling others, recording and the remote, each
/// kept running while another shows, under the links' status strip.
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
