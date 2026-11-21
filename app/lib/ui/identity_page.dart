import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../comm/comm_controller.dart';
import 'theme.dart';
import 'widgets.dart';

/// Who you are to the hive: your name, your avatar, and the key that makes
/// you you, with its backup.
class IdentityPage extends StatefulWidget {
  final CommController comm;
  const IdentityPage({super.key, required this.comm});

  @override
  State<IdentityPage> createState() => _IdentityPageState();
}

class _IdentityPageState extends State<IdentityPage> {
  late final _name = TextEditingController(text: widget.comm.server.username);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _saveName() => widget.comm.setName(_name.text);

  static const _hexagon = '⬡';
  static const _max = CommController.nameMaxBytes;

  static int _bytes(String s) => utf8.encode(s).length;

  /// The hexagon where the cursor is, or at the end, if there's room.
  void _addHexagon() {
    final v = _name.value;
    final at = v.selection.isValid ? v.selection : TextSelection.collapsed(offset: v.text.length);
    final text = v.text.replaceRange(at.start, at.end, _hexagon);
    if (_bytes(text) > _max) return;
    _name.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: at.start + _hexagon.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    final comm = widget.comm;
    return PopScope(
      // The name's taken on the way out, as well as on the keyboard's Done
      onPopInvokedWithResult: (didPop, _) => _saveName(),
      child: Scaffold(
        appBar: AppBar(title: const Text('Identity')),
        body: ListenableBuilder(
          listenable: comm,
          builder: (context, _) => ListView(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 24 + MediaQuery.paddingOf(context).bottom),
            children: [
              const SectionHeader('Your name'),
              if (comm.refusedName != null)
                Panel(
                  border: Kc.softRed,
                  children: [
                    PanelRow(
                      leading: const Icon(Icons.error_outline, color: Kc.softRed),
                      title: '${comm.server.host} won\'t take "${comm.refusedName}"',
                      subtitle: comm.refusedNameHelp,
                    ),
                  ],
                ),
              if (comm.refusedName != null) const SizedBox(height: 8),
              Panel(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    // Rebuilt as it's typed in, for the count
                    child: ValueListenableBuilder(
                      valueListenable: _name,
                      builder: (context, value, _) => _nameField(context, _bytes(value.text)),
                    ),
                  ),
                ],
              ),
              const SectionHeader('Your avatar'),
              _AvatarPanel(comm: comm),
              const SectionHeader('Your identity key'),
              _KeyPanel(comm: comm),
            ],
          ),
        ),
      ),
    );
  }

  /// The name, kept to what the unit can send over direct comms: bytes, not
  /// letters, as a letter's one byte and the hexagon three.
  Widget _nameField(BuildContext context, int used) => TextField(
    controller: _name,
    autocorrect: false,
    // Nothing past the limit; a name from before that's over
    // it can still be cut down
    inputFormatters: [
      TextInputFormatter.withFunction(
        (old, now) => _bytes(now.text) <= _max || _bytes(now.text) < _bytes(old.text) ? now : old,
      ),
    ],
    textCapitalization: TextCapitalization.words,
    textInputAction: TextInputAction.done,
    onSubmitted: (_) => _saveName(),
    onTapOutside: (_) => FocusScope.of(context).unfocus(),
    decoration: InputDecoration(
      labelText: 'Name',
      hintText: 'What the others see',
      // The HexDrones' hexagon, which keyboards haven't got
      suffixIcon: IconButton(
        tooltip: 'Add a hexagon',
        icon: const Text(_hexagon, style: TextStyle(fontSize: 22)),
        onPressed: used + _bytes(_hexagon) <= _max ? _addHexagon : null,
      ),
      helperText: "The name or designation by which you're known to others.",
      helperMaxLines: 2,
      counterText: '$used of $_max bytes${used >= _max ? ': full' : ''}',
      counterStyle: used > _max ? const TextStyle(color: Kc.softRed) : null,
    ),
  );
}

/// Your avatar, for the server and direct comms alike.
class _AvatarPanel extends StatefulWidget {
  final CommController comm;
  const _AvatarPanel({required this.comm});

  @override
  State<_AvatarPanel> createState() => _AvatarPanelState();
}

class _AvatarPanelState extends State<_AvatarPanel> {
  bool _picking = false;

  Future<void> _pick() async {
    setState(() => _picking = true);
    try {
      final file = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (file == null) return;
      final ok = await widget.comm.setAvatar(await file.readAsBytes());
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("That doesn't look like a picture")));
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final avatar = widget.comm.avatar;
    return Panel(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              DroneAvatar(picture: avatar, size: 96),
              const Spacer(),
              if (avatar != null)
                IconButton(
                  tooltip: 'Remove your avatar',
                  icon: const Icon(Icons.delete_outline, color: Kc.muted),
                  onPressed: () => widget.comm.setAvatar(null),
                ),
              const SizedBox(width: 4),
              avatar == null
                  ? FilledButton(onPressed: _picking ? null : _pick, child: const Text('Choose'))
                  : OutlinedButton(onPressed: _picking ? null : _pick, child: const Text('Change')),
            ],
          ),
        ),
      ],
    );
  }
}

/// Who others know us as: the key the app made, which signs what we send.
/// Backing it up is its code; the same code on another phone, or after
/// reinstalling, makes that phone us.
class _KeyPanel extends StatelessWidget {
  final CommController comm;
  const _KeyPanel({required this.comm});

  @override
  Widget build(BuildContext context) {
    final me = comm.identity;
    return Panel(
      children: [
        PanelRow(
          leading: const Icon(Icons.fingerprint, color: Kc.muted),
          title: me == null ? 'None' : 'Identity ${me.id.substring(0, 8)}',
          subtitle: me == null
              ? "The phone's secure storage couldn't be used"
              : 'Cryptographic key that establishes your identity.',
          trailing: [
            if (me != null)
              OutlinedButton(onPressed: () => _showCode(context, me.exportCode), child: const Text('Back up')),
          ],
        ),
        PanelRow(
          title: 'Restore an identity',
          subtitle: 'Become the identity in a backed-up code',
          trailing: [OutlinedButton(onPressed: () => _restore(context), child: const Text('Restore'))],
        ),
      ],
    );
  }

  void _showCode(BuildContext context, String code) => showDialog<void>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: const Text('Your identity code'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(code, style: Kc.term(16)),
          const SizedBox(height: 12),
          const Text(
            'Anyone with this code can pass as you. Keep it somewhere safe, and nowhere else.',
            style: TextStyle(color: Kc.muted, fontSize: 13),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: code));
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied')));
          },
          child: const Text('Copy'),
        ),
        TextButton(onPressed: () => Navigator.pop(dialog), child: const Text('Done')),
      ],
    ),
  );

  Future<void> _restore(BuildContext context) async {
    final field = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Restore an identity'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: field,
              autofocus: true,
              minLines: 2,
              maxLines: 3,
              decoration: const InputDecoration(hintText: 'XXXX-XXXX-...'),
            ),
            const SizedBox(height: 12),
            const Text(
              "This phone's identity is replaced: back it up first if you'll want it again.",
              style: TextStyle(color: Kc.muted, fontSize: 13),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(dialog, field.text), child: const Text('Restore')),
        ],
      ),
    );
    if (code == null || code.trim().isEmpty) return;
    final error = await comm.importIdentity(code);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error ?? 'Identity restored')));
    }
  }
}
