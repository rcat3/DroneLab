import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'comm/comm_controller.dart';
import 'ui/comm_page.dart';
import 'ui/remote_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.initCommunicationPort();
  final comm = CommController();
  comm.init();
  runApp(DroneLabApp(comm: comm));
}

class DroneLabApp extends StatelessWidget {
  final CommController comm;
  const DroneLabApp({super.key, required this.comm});

  @override
  Widget build(BuildContext context) {
    // Dark, with pink controls, like the board
    final scheme = ColorScheme.fromSeed(seedColor: Colors.pink, brightness: Brightness.dark);
    return MaterialApp(
      title: 'DroneLab',
      theme: ThemeData(colorScheme: scheme, useMaterial3: true),
      home: WithForegroundTask(child: HomePage(comm: comm)),
    );
  }
}

/// The comm channel and the remote, each kept running while the other shows.
class HomePage extends StatefulWidget {
  final CommController comm;
  const HomePage({super.key, required this.comm});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: [CommPage(comm: widget.comm), RemotePage(comm: widget.comm)],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.headset_mic), label: 'Comm'),
          NavigationDestination(icon: Icon(Icons.tune), label: 'Remote'),
        ],
      ),
    );
  }
}
