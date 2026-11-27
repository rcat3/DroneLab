import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../comm/comm_controller.dart';

const _channel = MethodChannel('dronelab/hivesight');

/// HiveSight's entry point: experimental, so only with developer options
/// on, and only where the phone can run it (Android 11 or newer).
/// Opens the Vessel's full-screen view, after a one-time notice.
class HiveSightButton extends StatefulWidget {
  final CommController comm;

  /// Runs just before the view opens (closes the sheet this sits in).
  final VoidCallback? before;
  const HiveSightButton({super.key, required this.comm, this.before});

  @override
  State<HiveSightButton> createState() => _HiveSightButtonState();
}

class _HiveSightButtonState extends State<HiveSightButton> {
  late final Future<bool> _supported = _check();

  Future<bool> _check() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('supported') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<void> _open() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('HiveSight'),
        content: const Text(
          'Experimental. Your Guide controls what you see and hear, and the picture can '
          'flash. Do not use it if flashing lights can affect you. Back leaves the view.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Open as Vessel')),
        ],
      ),
    );
    if (ok != true) return;
    widget.before?.call();
    try {
      await _channel.invokeMethod<void>('open');
    } on PlatformException {
      // not supported here; the button is hidden then
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.comm,
      builder: (context, _) {
        if (!widget.comm.developerOptions) return const SizedBox.shrink();
        return FutureBuilder<bool>(
          future: _supported,
          builder: (context, snap) {
            if (snap.data != true) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(top: 8),
              child: OutlinedButton(onPressed: _open, child: const Text('HiveSight')),
            );
          },
        );
      },
    );
  }
}
