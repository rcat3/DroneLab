import 'package:flutter/material.dart';

import '../comm/board_link.dart';
import '../comm/board_protocol.dart';
import '../comm/comm_controller.dart';
import '../comm/text_responder.dart';
import 'theme.dart';
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
                Explained(
                  help: 'Each text received is echoed back to the conversation it came in, on every channel, '
                      'the ways a text there goes, a second after it comes. A text sent to you privately that '
                      'starts with / is a command instead, answered privately; /help lists them. A text typed on '
                      'this phone in the last minute isn\'t echoed, nor the same text twice within 5 seconds, so '
                      'two responders don\'t echo each other for ever. Over adb too: see text_responder.dart.',
                  builder: (context, info) => PanelRow(
                    title: 'Text responder',
                    subtitle: !comm.textResponder.on
                        ? 'Off'
                        : comm.textResponder.echo
                            ? 'Echoing texts, taking commands'
                            : 'Taking commands, not echoing',
                    trailing: [
                      info,
                      Switch(value: comm.textResponder.on, onChanged: comm.setTextResponder),
                    ],
                  ),
                ),
                if (comm.textResponder.on)
                  PanelRow(
                    title: 'Echo texts',
                    subtitle: 'Off leaves only the commands',
                    trailing: [Switch(value: comm.textResponder.echo, onChanged: comm.setTextEcho)],
                  ),
              ]),
              if (comm.textResponder.on) ...[
                const SectionHeader('Commands'),
                Panel(children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: SelectableText(TextResponder.help, style: Kc.term(14)),
                  ),
                ]),
              ],
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
