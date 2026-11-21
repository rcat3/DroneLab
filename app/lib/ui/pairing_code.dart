import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Asks for the code the board shows while it pairs (Linux: the system doesn't
/// ask, see linux_pairing.dart). Null if it's not given. Closes by itself once
/// [withdrawn] completes: the pairing's over without it.
Future<int?> askPairingCode(BuildContext context, String boardName, Future<void> withdrawn) async {
  final field = TextEditingController();
  final navigator = Navigator.of(context);
  Route<int>? route;
  var open = true;
  withdrawn.then((_) {
    final r = route;
    if (open && r != null && r.isActive) navigator.removeRoute(r);
  });
  final code = await showDialog<int>(
    context: context,
    barrierDismissible: false,
    builder: (context) {
      route ??= ModalRoute.of(context) as Route<int>?;
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
  open = false;
  return code;
}
