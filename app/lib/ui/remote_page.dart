import 'package:flutter/material.dart';

import '../comm/board_link.dart';
import '../comm/board_protocol.dart';
import '../comm/comm_controller.dart';
import '../comm/remote_model.dart';
import 'people.dart';
import 'remote_screen_tab.dart';
import 'remote_sound_tab.dart';
import 'remote_terminal_tab.dart';
import 'remote_toys_tab.dart';
import 'setup_page.dart';
import 'theme.dart';

/// The remote: the unit's own controls, in the app, over Bluetooth, as the
/// unit's WiFi hotspot remote has them in a web page. Screen, Sound, Toys and
/// Terminal; the unit's settings are in Setup, under Display Unit.
///
/// It needs the unit's firmware to have the app's remote ([commVersionRemoteApp]).
class RemotePage extends StatefulWidget {
  final CommController comm;
  const RemotePage({super.key, required this.comm});

  @override
  State<RemotePage> createState() => _RemotePageState();
}

class _RemotePageState extends State<RemotePage> with SingleTickerProviderStateMixin {
  late final RemoteModel _model;
  late final TabController _tabs;

  BoardLink get _board => widget.comm.board;

  @override
  void initState() {
    super.initState();
    _model = RemoteModel(_board, saver: widget.comm.unitStorage);
    _tabs = TabController(length: 4, vsync: this)..addListener(_where);
    appTab.addListener(_where);
    _board.addListener(_onBoard);
    _where();
  }

  @override
  void dispose() {
    appTab.removeListener(_where);
    _board.removeListener(_onBoard);
    _tabs.dispose();
    _model.dispose();
    super.dispose();
  }

  void _onBoard() => setState(() {});

  /// The remote only asks the unit for things while it's on screen, and the
  /// snapshot only while Screen is.
  void _where() {
    final on = appTab.value == tabRemote;
    _model.active = on;
    final screen = on && _tabs.index == 0;
    if (screen && !_model.screenShown) _model.refreshScreen();
    _model.screenShown = screen;
  }

  @override
  Widget build(BuildContext context) {
    final connected = _board.state == BoardState.connected && _board.status != null;
    final tooOld = connected && _board.status!.version < commVersionRemoteApp;
    return Scaffold(
      appBar: AppBar(
        title: const Row(children: [
          Icon(Icons.phone_android, color: Kc.green, size: 22),
          SizedBox(width: 10),
          Text('DroneLab Remote'),
        ]),
        actions: [
          IconButton(
            tooltip: 'Setup',
            icon: const Icon(Icons.settings),
            onPressed: () =>
                Navigator.of(context).push(MaterialPageRoute(builder: (_) => SetupPage(comm: widget.comm))),
          ),
        ],
        bottom: connected && !tooOld
            ? TabBar(
                controller: _tabs,
                tabs: const [Tab(text: 'Screen'), Tab(text: 'Sound'), Tab(text: 'Toys'), Tab(text: 'Terminal')],
              )
            : null,
      ),
      body: !connected
          ? const _Note(
              'Connect to the unit first: tap the status strip at the top.\n\n'
              "The remote runs the unit over Bluetooth, so the phone keeps its internet.")
          : tooOld
              ? const _Note("The unit's firmware is too old for the remote in the app. Update the unit, "
                  "or use its WiFi remote (Settings, Phone Remote).")
              : ListenableBuilder(
                  listenable: _model,
                  builder: (context, _) => !_model.hasState
                      ? const Center(child: CircularProgressIndicator())
                      : TabBarView(
                          controller: _tabs,
                          // Sliders and the arrows take horizontal drags: tabs change by tapping them
                          physics: const NeverScrollableScrollPhysics(),
                          children: [
                            RemoteScreenTab(model: _model),
                            RemoteSoundTab(model: _model),
                            RemoteToysTab(model: _model, comm: widget.comm),
                            RemoteTerminalTab(model: _model),
                          ],
                        ),
                ),
    );
  }
}

class _Note extends StatelessWidget {
  final String text;
  const _Note(this.text);

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(padding: const EdgeInsets.all(32), child: Text(text, textAlign: TextAlign.center)),
      );
}
