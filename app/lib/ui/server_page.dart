import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../comm/comm_controller.dart';

/// The Mumble server to join, and how much to buffer what comes back.
class ServerPage extends StatefulWidget {
  final CommController comm;
  const ServerPage({super.key, required this.comm});

  @override
  State<ServerPage> createState() => _ServerPageState();
}

class _ServerPageState extends State<ServerPage> {
  late final _host = TextEditingController(text: widget.comm.server.host);
  late final _port = TextEditingController(text: '${widget.comm.server.port}');
  late final _user = TextEditingController(text: widget.comm.server.username);
  late final _password = TextEditingController(text: widget.comm.server.password);
  late double _buffer = widget.comm.bufferMs.toDouble();
  bool _showPassword = false;
  bool _picking = false;

  Future<void> _pickAvatar() async {
    setState(() => _picking = true);
    try {
      final file = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (file == null) return;
      final ok = await widget.comm.setAvatar(await file.readAsBytes());
      if (mounted) setState(() {});
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("That doesn't look like a picture")));
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  @override
  void dispose() {
    for (final c in [_host, _port, _user, _password]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final s = ServerSettings(
      host: _host.text.trim(),
      port: int.tryParse(_port.text.trim()) ?? 64738,
      username: _user.text.trim(),
      password: _password.text,
    );
    final changed = s.host != widget.comm.server.host ||
        s.port != widget.comm.server.port ||
        s.username != widget.comm.server.username ||
        s.password != widget.comm.server.password;
    await widget.comm.saveServer(s, _buffer.round());
    if (changed && widget.comm.serverWanted) {
      await widget.comm.disconnectServer();
      await widget.comm.connectServer();
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Server'),
        actions: [TextButton(onPressed: _save, child: const Text('Save'))],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('The Mumble server everyone joins. Anyone can join it from the Mumble app too.'),
          const SizedBox(height: 16),
          TextField(
            controller: _host,
            decoration: const InputDecoration(labelText: 'Address', hintText: 'e.g. 192.168.1.10'),
            keyboardType: TextInputType.url,
            autocorrect: false,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _port,
            decoration: const InputDecoration(labelText: 'Port'),
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _user,
            decoration: const InputDecoration(labelText: 'Your name', hintText: 'What the others see'),
            autocorrect: false,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _password,
            obscureText: !_showPassword,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: 'Server password',
              suffixIcon: IconButton(
                tooltip: _showPassword ? 'Hide' : 'Show',
                icon: Icon(_showPassword ? Icons.visibility_off : Icons.visibility),
                onPressed: () => setState(() => _showPassword = !_showPassword),
              ),
            ),
          ),
          const SizedBox(height: 24),
          Text('Your avatar', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Row(
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(border: Border.all(color: Theme.of(context).colorScheme.outline)),
                child: widget.comm.avatar == null
                    ? const Icon(Icons.person, size: 40)
                    : Image.memory(widget.comm.avatar!, fit: BoxFit.cover, gaplessPlayback: true),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Wrap(
                  spacing: 8,
                  children: [
                    FilledButton.tonal(
                        onPressed: _picking ? null : _pickAvatar, child: const Text('Choose a picture')),
                    if (widget.comm.avatar != null)
                      TextButton(
                          onPressed: () async {
                            await widget.comm.setAvatar(null);
                            setState(() {});
                          },
                          child: const Text('Remove')),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text('Shown on the others\' displays while you talk, cut square from the middle. '
              'Mumble on a computer shows it too.'),
          const SizedBox(height: 24),
          Text('Buffer: ${_buffer.round()} ms', style: Theme.of(context).textTheme.titleSmall),
          Slider(
            value: _buffer,
            min: 20,
            max: 300,
            divisions: 28,
            label: '${_buffer.round()} ms',
            onChanged: (v) => setState(() => _buffer = v),
          ),
          const Text('How long the others\' voices wait before playing, to ride out an uneven connection. '
              'Less is quicker; more is smoother on mobile data.'),
        ],
      ),
    );
  }
}
