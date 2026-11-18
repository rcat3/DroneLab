import 'package:flutter/material.dart';

import '../comm/comm_controller.dart';
import 'people.dart';
import 'status_strip.dart';
import 'theme.dart';
import 'widgets.dart';

/// Someone in the hive: who they are, how they're linked, what they run, and
/// muting them; and shortcuts to message or control them.
Future<void> showPerson(BuildContext context, CommController comm, String key) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheet) => ListenableBuilder(
        listenable: comm,
        builder: (sheet, _) {
          final found = hivePeople(comm).where((p) => p.key == key);
          if (found.isEmpty) {
            return const SafeArea(
              child: Padding(padding: EdgeInsets.all(24), child: Text("They've gone", textAlign: TextAlign.center)),
            );
          }
          final p = found.first;
          final talking = p.talking && !p.mutedByMe;
          final b = p.board;
          final m = comm.mumble;
          final direct = comm.boardSettings?.direct;
          final link = p.onServer
              ? 'Server · ${m == null ? '' : m.channelPath(m.myChannel)}'
              : 'Direct · ${direct == null ? '' : directChannelName(direct)}';
          final ago = b == null ? null : (DateTime.now().millisecondsSinceEpoch - b.seenMs) ~/ 1000;
          Widget kv(String k, Widget v) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 32),
                  child: Row(children: [
                    Expanded(child: Text(k, style: const TextStyle(color: Kc.muted, fontSize: 14))),
                    v,
                  ]),
                ),
              );
          Widget value(String s) => Flexible(child: Text(s, textAlign: TextAlign.end));
          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [
                    DroneAvatar(picture: p.user?.texture, talking: talking, size: 76),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(p.name, style: Kc.term(24)),
                          const SizedBox(height: 4),
                          Text(
                            p.mutedByMe
                                ? 'Muted by you'
                                : talking
                                    ? 'TALKING'
                                    : p.user?.muted ?? false
                                        ? 'Muted'
                                        : 'Listening',
                            style: talking ? Kc.term(14, color: Kc.green) : const TextStyle(color: Kc.muted),
                          ),
                        ],
                      ),
                    ),
                  ]),
                  const SizedBox(height: 14),
                  Panel(color: Kc.bg, children: [
                    kv('Link', value(link)),
                    if (b != null)
                      kv('Signal', Row(mainAxisSize: MainAxisSize.min, children: [
                        SignalBars(b.rssi),
                        const SizedBox(width: 8),
                        Text('${b.rssi} dBm', style: Kc.term(16)),
                      ])),
                    if (ago != null) kv('Last heard', value(ago < 3 ? 'Now' : '$ago s ago')),
                    if (b != null) kv('Firmware', value(b.firmware.isEmpty ? 'Not known' : b.firmware)),
                    if (b != null) kv('App', value(b.app.isEmpty ? 'None linked' : b.app)),
                    kv('Mute for me', Switch(value: p.mutedByMe, onChanged: (on) => comm.setMuted(p.name, on))),
                  ]),
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: comm.canSendCommands
                            ? () {
                                recipients.only(p.key);
                                Navigator.pop(sheet);
                                appTab.value = tabTerminal;
                              }
                            : null,
                        icon: const Icon(Icons.terminal, size: 18),
                        label: const Text('Message'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: comm.canSendCommands
                            ? () {
                                recipients.only(p.key);
                                Navigator.pop(sheet);
                                appTab.value = tabControl;
                              }
                            : null,
                        icon: const Icon(Icons.tune, size: 18),
                        label: const Text('Control'),
                      ),
                    ),
                  ]),
                ],
              ),
            ),
          );
        },
      ),
    );
