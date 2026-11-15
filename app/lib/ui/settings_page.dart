import 'package:flutter/material.dart';

import '../comm/board_link.dart';
import '../comm/board_protocol.dart';
import '../comm/comm_controller.dart';
import 'groups_page.dart';
import 'server_page.dart';

/// What's set once and left: the server, the board's comm settings, direct
/// comms, and who's muted.
class CommSettingsPage extends StatelessWidget {
  final CommController comm;
  const CommSettingsPage({super.key, required this.comm});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: comm,
      builder: (context, _) {
        final connected = comm.board.state == BoardState.connected;
        final settings = connected ? comm.boardSettings : null;
        final direct = settings?.direct;
        final title = Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary);
        final line = Divider(height: 1, indent: 16, endIndent: 16, color: Theme.of(context).colorScheme.outlineVariant);
        Widget header(String text) => Padding(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
              child: Text(text, style: title),
            );

        return Scaffold(
          appBar: AppBar(title: const Text('Comm Settings')),
          body: ListView(
            children: [
              header('Server'),
              ListTile(
                leading: const Icon(Icons.dns),
                title: Text(comm.server.host.isEmpty ? 'Set up the server' : comm.server.host),
                subtitle: const Text('Address, your name, password, avatar and buffer'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () =>
                    Navigator.of(context).push(MaterialPageRoute(builder: (_) => ServerPage(comm: comm))),
              ),
              header('Board'),
              if (settings == null)
                const ListTile(title: Text('Connect to the board to change these'))
              else ...[
                ListTile(
                  title: const Text('Talking'),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: SegmentedButton<BoardMode>(
                      segments: const [
                        ButtonSegment(value: BoardMode.pushToTalk, label: Text('Push to talk'), icon: Icon(Icons.touch_app)),
                        ButtonSegment(value: BoardMode.voice, label: Text('Voice'), icon: Icon(Icons.graphic_eq)),
                      ],
                      selected: {comm.board.status?.mode ?? BoardMode.pushToTalk},
                      onSelectionChanged: (sel) => comm.board.setMode(sel.first),
                    ),
                  ),
                ),
                if (direct != null) ...[
                  line,
                  ListTile(
                    title: const Text('Talk on'),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: SegmentedButton<int>(
                        segments: const [
                          ButtonSegment(value: CommController.talkServer, label: Text('Server'), icon: Icon(Icons.cloud)),
                          ButtonSegment(
                              value: CommController.talkDirect,
                              label: Text('Direct'),
                              icon: Icon(Icons.settings_input_antenna)),
                        ],
                        selected: {settings.talkOn},
                        onSelectionChanged: (sel) => comm.setTalkOn(sel.first),
                      ),
                    ),
                  ),
                ],
                if (settings.voices.isNotEmpty) ...[
                  line,
                  ListTile(
                    title: const Text('Comm voice'),
                    subtitle: const Text("The voice effect the others hear, whatever the board's speaker plays"),
                    trailing: DropdownButton<int>(
                      value: settings.voice,
                      onChanged: (v) => comm.setBoardSettings(voice: v),
                      items: [
                        const DropdownMenuItem(value: -1, child: Text('Same as speaker')),
                        for (var i = 0; i < settings.voices.length; i++)
                          DropdownMenuItem(value: i, child: Text(settings.voices[i])),
                      ],
                    ),
                  ),
                ],
                line,
                SwitchListTile(
                  title: const Text('Speaker off while talking'),
                  subtitle: const Text("So those nearby don't hear what goes to the group"),
                  value: settings.muteSpeaker,
                  onChanged: (on) => comm.setBoardSettings(muteSpeaker: on),
                ),
                line,
                ListTile(
                  title: const Text("Show the board's Comm screen while"),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: SegmentedButton<int>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(value: 0, label: Text('Never')),
                        ButtonSegment(value: 1, label: Text('Talking')),
                        ButtonSegment(value: 2, label: Text('Hearing')),
                        ButtonSegment(value: 3, label: Text('Both')),
                      ],
                      selected: {settings.show},
                      onSelectionChanged: (sel) => comm.setBoardSettings(show: sel.first),
                    ),
                  ),
                ),
              ],
              if (direct != null) ...[
                header('Direct comms'),
                SwitchListTile(
                  secondary: const Icon(Icons.settings_input_antenna),
                  title: const Text('Direct comms'),
                  subtitle: const Text("Board to board over the radio, for where there's no signal. "
                      'Works with or without the server'),
                  value: direct.on,
                  onChanged: comm.setDirect,
                ),
                line,
                ListTile(
                  leading: Icon(direct.keyed ? Icons.lock : Icons.lock_open),
                  title: Text(direct.keyed ? direct.group : 'Open group'),
                  subtitle: Text('Group. Others see you as ${direct.name}'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () =>
                      Navigator.of(context).push(MaterialPageRoute(builder: (_) => GroupsPage(comm: comm))),
                ),
              ],
              if (comm.muted.isNotEmpty) ...[
                header('Muted by you'),
                for (final (i, name) in (comm.muted.toList()..sort()).indexed) ...[
                  if (i > 0) line,
                  ListTile(
                    leading: const Icon(Icons.volume_off),
                    title: Text(name),
                    trailing: TextButton(onPressed: () => comm.setMuted(name, false), child: const Text('Unmute')),
                  ),
                ],
              ],
              const SizedBox(height: 24),
            ],
          ),
        );
      },
    );
  }
}
