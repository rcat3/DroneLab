import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'comm/comm_controller.dart';
import 'ui/comm_page.dart';

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
      home: WithForegroundTask(child: CommPage(comm: comm)),
    );
  }
}
