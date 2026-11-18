import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../comm/release_check.dart';
import 'theme.dart';

/// Under the status strip, while a newer release of the app is out: to
/// download it from the releases page, or to put off until the app next
/// starts.
class ReleaseBanner extends StatelessWidget {
  final ReleaseCheck check;
  const ReleaseBanner({super.key, required this.check});

  static const _releases = 'https://github.com/rcat3/DroneLab/releases/latest';

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: check,
      builder: (context, _) {
        final v = check.version;
        if (v == null) return const SizedBox.shrink();
        return Material(
          color: Kc.panel,
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Kc.line))),
            child: Row(children: [
              const Icon(Icons.system_update, color: Kc.green, size: 20),
              const SizedBox(width: 10),
              Expanded(child: Text('DroneLab $v is available', style: const TextStyle(fontSize: 14))),
              TextButton(
                onPressed: () => launchUrl(Uri.parse(check.page ?? _releases), mode: LaunchMode.externalApplication),
                child: const Text('Download'),
              ),
              IconButton(
                tooltip: 'Not now',
                icon: const Icon(Icons.close, size: 18, color: Kc.muted),
                onPressed: check.dismiss,
              ),
            ]),
          ),
        );
      },
    );
  }
}
