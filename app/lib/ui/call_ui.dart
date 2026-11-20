import 'package:flutter/material.dart';

import '../comm/calls.dart';
import '../comm/comm_controller.dart';
import '../main.dart';
import 'people.dart';
import 'theme.dart';
import 'widgets.dart';

/// Whose call's on screen, so the same one isn't shown twice.
String? _showing;

/// Someone's calling: who, with Answer and Decline, over whatever's on
/// screen. It goes by itself once the call's answered, turned down or given
/// up on, from here or anywhere else.
void showIncomingCall(CommController comm, String personId) {
  final context = navigatorKey.currentContext;
  if (context == null || _showing == personId) return;
  _showing = personId;
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialog) => ListenableBuilder(
      listenable: comm,
      builder: (dialog, _) {
        final call = comm.calls[personId];
        if (call == null || call.state != CallState.ringing) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (Navigator.of(dialog).canPop()) Navigator.of(dialog).pop();
          });
        }
        final name = comm.people[personId]?.name ?? '?';
        return AlertDialog(
          backgroundColor: Kc.panel,
          shape: RoundedRectangleBorder(
              side: const BorderSide(color: Kc.green), borderRadius: BorderRadius.circular(16)),
          title: Text('> INCOMING CALL', style: Kc.term(16, color: Kc.green, shadows: Kc.glow(Kc.green))),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            DroneAvatar(picture: comm.avatarOf(personId), size: 96, talking: true),
            const SizedBox(height: 16),
            Text(name, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            const Text('Calling you, alone', style: TextStyle(color: Kc.muted)),
          ]),
          actionsAlignment: MainAxisAlignment.spaceEvenly,
          actions: [
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: Kc.red, foregroundColor: Colors.white),
              onPressed: () {
                comm.endCall(personId);
                Navigator.of(dialog).pop();
              },
              icon: const Icon(Icons.call_end),
              label: const Text('Decline'),
            ),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: Kc.darkGreen, foregroundColor: Colors.white),
              onPressed: () {
                comm.answerCall(personId);
                appTab.value = tabVoice;
                Navigator.of(dialog).pop();
              },
              icon: const Icon(Icons.call),
              label: const Text('Answer'),
            ),
          ],
        );
      },
    ),
  ).whenComplete(() {
    if (_showing == personId) _showing = null;
  });
}
