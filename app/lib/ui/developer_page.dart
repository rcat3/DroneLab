import 'package:flutter/material.dart';

import '../comm/board_link.dart';
import '../comm/board_protocol.dart';
import '../comm/comm_controller.dart';
import 'widgets.dart';

/// Developer options: shown in Setup once the app's version on the About
/// page has been tapped ten times, and hidden again from here.
class DeveloperPage extends StatelessWidget {
  final CommController comm;
  const DeveloperPage({super.key, required this.comm});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: comm,
      builder: (context, _) {
        final t = comm.talkTo.kind;
        final boardUp = comm.board.state == BoardState.connected;
        final directOld = t == TalkTo.direct && boardUp && !comm.boardTakesDirectVoice;
        return Scaffold(
          appBar: AppBar(title: const Text('Developer options')),
          body: ListView(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 24 + MediaQuery.paddingOf(context).bottom),
            children: [
              const SectionHeader('Auto responders'),
              Panel(children: [
                Explained(
                  help: 'Each transmission heard on the channel you talk to is recorded and sent back as a '
                      'transmission of yours, the same way it came (server or direct), 1 second after it ends: '
                      'at most 30 seconds of it, and the recording is discarded once it\'s sent. Not in a call, '
                      'and not while you talk. A transmission that starts while one is sent back, or just after, '
                      'isn\'t answered, so two responders don\'t answer each other for ever.',
                  builder: (context, info) => PanelRow(
                    title: 'Voice responder',
                    subtitle: !comm.voiceResponder.on
                        ? 'Off'
                        : t == TalkTo.person
                            ? 'Paused: talking to one person'
                            : directOld
                                ? "Paused: the unit's firmware can't send it over direct"
                                : comm.voiceResponder.playing
                                    ? 'Sending one back'
                                    : 'Listening on ${t == TalkTo.direct ? 'the direct channel' : 'the server channel'}',
                    trailing: [
                      info,
                      Switch(value: comm.voiceResponder.on, onChanged: comm.setVoiceResponder),
                    ],
                  ),
                ),
              ]),
              const SectionHeader('Hide'),
              Panel(children: [
                PanelRow(
                  title: 'Show developer options',
                  subtitle: 'Off hides them again, and turns the responders off',
                  trailing: [
                    Switch(
                      value: comm.developerOptions,
                      onChanged: (on) {
                        comm.setDeveloperOptions(on);
                        if (!on) Navigator.of(context).pop();
                      },
                    ),
                  ],
                ),
              ]),
            ],
          ),
        );
      },
    );
  }
}
