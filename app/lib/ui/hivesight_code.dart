import 'dart:math';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../comm/hivesight_guide.dart';
import '../comm/hivesight_invite.dart';
import 'theme.dart';

/// The session's invitation as a QR code, for a Vessel's phone to scan: on
/// site, with no server and no units, anyone who sees it can join until the
/// session ends. Starts the sender and a session first if they aren't on.
/// Returns why not, or null once the code has been shown and closed.
Future<String?> showHiveSightCode(BuildContext context, HiveSightGuide g) async {
  final why = await g.startSessionAnyway();
  if (why != null) return why;
  if (!context.mounted) return null;
  await showDialog<void>(context: context, builder: (_) => _CodeDialog(g));
  return null;
}

class _CodeDialog extends StatefulWidget {
  final HiveSightGuide g;
  const _CodeDialog(this.g);

  @override
  State<_CodeDialog> createState() => _CodeDialogState();
}

class _CodeDialogState extends State<_CodeDialog> {
  HiveSightInvite? _invite;
  String _for = '';

  @override
  void initState() {
    super.initState();
    widget.g.addListener(_changed);
    _changed();
  }

  @override
  void dispose() {
    widget.g.removeListener(_changed);
    super.dispose();
  }

  // The code follows the session and this computer's addresses as they change
  Future<void> _changed() async {
    final g = widget.g;
    final key = '${g.session?.token}\n${g.addrs.join(',')}';
    if (key == _for) return;
    _for = key;
    final i = await g.currentInvite();
    if (!mounted || key != _for) return;
    setState(() => _invite = i);
  }

  @override
  Widget build(BuildContext context) {
    final i = _invite;
    final side = min(MediaQuery.sizeOf(context).shortestSide - 120, 420.0);
    return AlertDialog(
      title: const Text('HiveSight code'),
      content: SizedBox(
        width: max(side, 240) + 24,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (i == null)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('The session has ended.', textAlign: TextAlign.center),
              )
            else ...[
              // White round it, as cameras need a quiet zone to find it
              Container(
                color: Colors.white,
                padding: const EdgeInsets.all(12),
                child: QrImageView(
                  data: i.link,
                  size: max(side, 240),
                  backgroundColor: Colors.white,
                  errorCorrectionLevel: QrErrorCorrectLevel.M,
                ),
              ),
              const SizedBox(height: 10),
              Text('Until ${HiveSightInvite.clock(i.expires)}', style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              const Text(
                "Scan this with DroneLab's HiveSight on the Vessel's phone.",
                textAlign: TextAlign.center,
                style: TextStyle(color: Kc.muted, fontSize: 13),
              ),
              const SizedBox(height: 4),
              const Text(
                'Anyone who sees it can join until you end the session.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Kc.muted, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
      actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done'))],
    );
  }
}
