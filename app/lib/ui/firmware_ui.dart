import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../comm/board_link.dart';
import '../comm/board_protocol.dart';
import '../comm/comm_controller.dart';
import '../comm/firmware_update.dart';
import 'theme.dart';
import 'widgets.dart';

/// The web installer, for firmware too old for the app to update.
const webInstallerUrl = 'https://rcat3.github.io/DroneLab/';

/// A small warning, when boards nearby run another version of direct comms
/// and can't be heard (the board's status, commVersion 7). Tap for why.
class OtherFirmwareIcon extends StatelessWidget {
  final CommController comm;
  const OtherFirmwareIcon({super.key, required this.comm});

  @override
  Widget build(BuildContext context) {
    final other = comm.board.state == BoardState.connected && (comm.board.status?.otherFirmware ?? false);
    if (!other) return const SizedBox.shrink();
    return IconButton(
      icon: const Icon(Icons.warning_amber_rounded, color: Kc.warn),
      tooltip: 'Incompatible firmware nearby',
      onPressed: () => showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          icon: const Icon(Icons.warning_amber_rounded, color: Kc.warn),
          title: const Text('Incompatible firmware'),
          content: const Text('Incompatible firmware detected nearby. Make sure all users are running the latest release.'),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
        ),
      ),
    );
  }
}

/// Asks once whenever a board turns up whose firmware is behind the app's:
/// to update it from the app, or with the web installer if it's too old.
class FirmwarePrompt extends StatefulWidget {
  final CommController comm;
  final Widget child;
  const FirmwarePrompt({super.key, required this.comm, required this.child});

  @override
  State<FirmwarePrompt> createState() => _FirmwarePromptState();
}

class _FirmwarePromptState extends State<FirmwarePrompt> {
  final Set<String> _asked = {};   // boards asked about, and why, this time the app's run

  @override
  void initState() {
    super.initState();
    widget.comm.addListener(_check);
  }

  @override
  void dispose() {
    widget.comm.removeListener(_check);
    super.dispose();
  }

  void _check() {
    final comm = widget.comm;
    final standing = comm.firmwareStanding;
    if (standing != FirmwareStanding.canUpdate && standing != FirmwareStanding.needsInstaller) return;
    if (comm.firmwareUpdate.busy) return;
    // Once it's said which firmware it is, if it can (commVersion 2), and
    // once a board each time the app runs, unless it's changed: from too old
    // for the app, say, to firmware the app can update
    final b = comm.board;
    if (b.firmware == null && (b.status?.version ?? 0) >= commVersionRemote) return;
    if (!_asked.add('${b.deviceId} $standing')) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      standing == FirmwareStanding.canUpdate ? offerFirmwareUpdate(context, comm) : showWebInstaller(context, comm);
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Ask, then update the board from the app.
Future<void> offerFirmwareUpdate(BuildContext context, CommController comm) async {
  final b = comm.bundledFirmware;
  if (b == null) return;
  final go = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text("Update the unit's firmware?"),
      content: Text('The unit has ${comm.board.firmware}, and this app comes with ${b.version}. '
          'Keeping them in step keeps every feature working, and units only hear each other over '
          'direct mode with the same version.\n\n'
          'It takes about 3 minutes. Keep the phone next to the unit, with the unit charged to '
          '20% or more. Direct mode pauses meanwhile. The unit restarts at the end, and the app '
          'reconnects to it.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Later')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Update')),
      ],
    ),
  );
  if (go != true || !context.mounted) return;
  comm.firmwareUpdate.reset();
  comm.updateFirmware();
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _UpdateProgress(comm: comm, version: b.version),
  );
}

class _UpdateProgress extends StatelessWidget {
  final CommController comm;
  final String version;
  const _UpdateProgress({required this.comm, required this.version});

  @override
  Widget build(BuildContext context) {
    final u = comm.firmwareUpdate;
    return ListenableBuilder(
      listenable: u,
      builder: (context, _) => PopScope(
        canPop: !u.busy,
        child: AlertDialog(
          title: Text(switch (u.state) {
            UpdateState.done => 'Updated',
            UpdateState.failed => "The update didn't work",
            _ => 'Updating the unit',
          }),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (u.busy) ...[
              LinearProgressIndicator(
                value: u.state == UpdateState.sending ? u.progress : null,
                color: Kc.pink,
                backgroundColor: Kc.line,
              ),
              const SizedBox(height: 12),
              Text(switch (u.state) {
                UpdateState.finishing => 'Checking the firmware...',
                UpdateState.installing => 'Installing it on the unit, about a minute. It restarts when it\'s '
                    'done, and the app reconnects to it.',
                _ => 'Sending $version: ${(u.progress * 100).floor()}%. Keep the phone next to the unit.',
              }),
            ],
            if (u.state == UpdateState.done)
              Text('The unit has restarted with $version, and the app has reconnected to it.'),
            if (u.state == UpdateState.failed)
              Text('${u.problem}. The unit carries on with the firmware it had.'),
          ]),
          actions: [
            if (u.state == UpdateState.failed)
              TextButton(
                onPressed: () {
                  u.reset();
                  comm.updateFirmware();
                },
                child: const Text('Try again'),
              ),
            if (!u.busy) TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
          ],
        ),
      ),
    );
  }
}

/// For firmware too old for the app to update: the web installer, once.
Future<void> showWebInstaller(BuildContext context, CommController comm) => showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Update the unit's firmware"),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text("The unit's firmware${comm.board.firmware == null ? '' : ' (${comm.board.firmware})'} is older "
              "than this app, and too old for the app to update. Some features won't work until it's "
              'updated.\n\n'
              'Install the latest release once with the web installer, from a computer with Chrome or Edge '
              "and a USB cable. Your settings are kept. After that, the app keeps the unit up to date."),
          const SizedBox(height: 12),
          const SelectableText(webInstallerUrl, style: TextStyle(color: Kc.green)),
        ]),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(const ClipboardData(text: webInstallerUrl));
              Navigator.pop(context);
            },
            child: const Text('Copy the address'),
          ),
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK')),
        ],
      ),
    );

/// Setup's section on the board's firmware.
class FirmwarePanel extends StatelessWidget {
  final CommController comm;
  const FirmwarePanel({super.key, required this.comm});

  @override
  Widget build(BuildContext context) {
    final b = comm.board;
    final fw = b.firmware ?? 'not known yet';
    final carried = comm.bundledFirmware?.version;
    final (String subtitle, Widget? action) = switch (comm.firmwareStanding) {
      FirmwareStanding.current => ('Up to date${carried == null ? '' : ' with this app'}', null),
      FirmwareStanding.canUpdate => (
          'This app comes with $carried',
          FilledButton(onPressed: () => offerFirmwareUpdate(context, comm), child: const Text('Update')),
        ),
      FirmwareStanding.needsInstaller => (
          'Too old for the app to update',
          OutlinedButton(onPressed: () => showWebInstaller(context, comm), child: const Text('How')),
        ),
      FirmwareStanding.newer => ('Newer than this app${carried == null ? '' : ' ($carried)'}: update the app', null),
      FirmwareStanding.unknown => (carried == null ? '' : 'This app comes with $carried', null),
    };
    return Panel(children: [
      PanelRow(
        leading: Icon(
          comm.firmwareStanding == FirmwareStanding.current ? Icons.check_circle_outline : Icons.memory,
          color: comm.firmwareStanding == FirmwareStanding.canUpdate ||
                  comm.firmwareStanding == FirmwareStanding.needsInstaller
              ? Kc.warn
              : Kc.muted,
        ),
        title: 'Firmware $fw',
        subtitle: subtitle.isEmpty ? null : subtitle,
        trailing: [?action],
      ),
    ]);
  }
}
