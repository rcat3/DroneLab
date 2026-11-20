import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Asks for the code the board shows while it pairs (Linux: the system doesn't
/// ask, see linux_pairing.dart). Null if it's not given.
Future<int?> askPairingCode(BuildContext context, String boardName) {
  final field = TextEditingController();
  return showDialog<int>(
    context: context,
    barrierDismissible: false,
    builder: (context) {
      void done() {
        final code = int.tryParse(field.text);
        if (code != null) Navigator.of(context).pop(code);
      }

      return AlertDialog(
        title: Text('Pair with $boardName'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Type the code the board shows.'),
          const SizedBox(height: 12),
          TextField(
            controller: field,
            autofocus: true,
            keyboardType: TextInputType.number,
            maxLength: 6,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            style: const TextStyle(fontSize: 24, letterSpacing: 6),
            onSubmitted: (_) => done(),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          FilledButton(onPressed: done, child: const Text('Pair')),
        ],
      );
    },
  );
}
