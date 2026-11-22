import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform, Process;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../comm/board_link.dart';
import '../comm/board_protocol.dart';
import '../comm/comm_controller.dart';
import 'people.dart';
import 'theme.dart';
import 'widgets.dart';

/// The unit's own display settings, as on the Remote's Setup tab and the
/// display's Settings: brightness, rotation, what it shows at startup; and
/// its WiFi hotspot remote, as on the display's WiFi Hotspot Remote page: on
/// or off, its name, password and QR code, a new password, and whether it
/// starts at power-up. Through the remote's API (core/app/remote.c), over
/// Bluetooth, so each shows what the others do.
class DisplayUnitPage extends StatefulWidget {
  final CommController comm;
  const DisplayUnitPage({super.key, required this.comm});

  @override
  State<DisplayUnitPage> createState() => _DisplayUnitPageState();
}

/// How often the brightness is sent while its slider's dragged.
const _dragEvery = Duration(milliseconds: 250);

/// Joining the hotspot from this device: Android's own dialogs
/// (MainActivity.kt), or NetworkManager on Linux. Not on an iPhone yet (it
/// would be NEHotspotConfiguration).
const _wifi = MethodChannel('dronelab/wifi');
bool get _canJoin => !kIsWeb && (Platform.isAndroid || Platform.isLinux);

class _DisplayUnitPageState extends State<DisplayUnitPage> {
  BoardLink get _board => widget.comm.board;

  StreamSubscription<String>? _statesSub;
  Timer? _poll;
  bool _asked = false;

  List<String>? _startupChoices;
  Map<String, dynamic>? _display; // the state's "display"
  double? _dragging;              // the brightness under a finger
  DateTime? _sentAt;

  /// GET /api/hotspot's answer; null till it comes, and for firmware from
  /// before it, which can only set Start at power-up from here.
  Map<String, dynamic>? _hotspot;
  bool _hotspotAsked = false;
  bool _hotspotBusy = false; // switching, or a new password: it takes a moment
  bool _joining = false;

  bool get _up => _board.state == BoardState.connected && _board.status != null;
  bool get _tooOld => (_board.status?.version ?? 0) < commVersionRemote;

  @override
  void initState() {
    super.initState();
    // Every state the board sends, whoever asked: this page, the Remote tab
    // or the app's own reads
    _statesSub = _board.states.listen(_onState);
    _board.addListener(_onBoard);
    _onBoard();
    // Changes made on the display itself, or on the WiFi remote
    _poll = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!_up || _tooOld) return;
      _board.request('GET', '/api/state').catchError((_) => RemoteAnswer(0, ''));
      if (_hotspot != null && !_hotspotBusy) _hotspotRequest('GET', '');
    });
  }

  @override
  void dispose() {
    _statesSub?.cancel();
    _board.removeListener(_onBoard);
    _poll?.cancel();
    super.dispose();
  }

  void _onBoard() {
    if (!_up) {
      _asked = false;
      _hotspotAsked = false;
      if (mounted) setState(() {});
      return;
    }
    if (_asked || _tooOld) return;
    _asked = true;
    _board.request('GET', '/api/info').then((a) {
      if (a.status != 200 || !mounted) return;
      final names = (jsonDecode(a.body) as Map<String, dynamic>)['startup_choices'] as List<dynamic>?;
      setState(() => _startupChoices = [for (final n in names ?? const []) n as String]);
    }).catchError((_) {});
    // A command with nothing in it answers with the state in full, where a
    // GET might be "the same as last time" (304) for someone else's copy
    _send({});
    _hotspotRequest('GET', '').whenComplete(() {
      if (mounted) setState(() => _hotspotAsked = true);
    });
  }

  void _onState(String json) {
    try {
      final d = (jsonDecode(json) as Map<String, dynamic>)['display'];
      if (d is Map<String, dynamic> && mounted) setState(() => _display = d);
    } catch (_) {}
  }

  Future<void> _send(Map<String, Object> params) async {
    final q = params.entries.map((e) => '${e.key}=${e.value}').join('&');
    try {
      await _board.request('POST', '/api/display${q.isEmpty ? '' : '?$q'}');
    } catch (_) {}
  }

  /// The hotspot: asks, or changes it (query), and keeps the answer.
  Future<void> _hotspotRequest(String method, String query) async {
    try {
      // Starting the WiFi takes a moment longer than most
      final a = await _board.request(
          method, '/api/hotspot${query.isEmpty ? '' : '?$query'}', '', const Duration(seconds: 10));
      if (a.status == 200 && mounted) setState(() => _hotspot = jsonDecode(a.body) as Map<String, dynamic>);
    } catch (_) {}
  }

  Future<void> _hotspotChange(String query) async {
    setState(() => _hotspotBusy = true);
    await _hotspotRequest('POST', query);
    if (!mounted) return;
    setState(() => _hotspotBusy = false);
    if (_hotspot?['failed'] == 1) _toast("The unit's WiFi didn't start");
  }

  Future<void> _newPassword() async {
    final h = _hotspot;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New password?'),
        content: Text(h?['on'] == 1
            ? 'Every phone that has joined is dropped, and has to join again with the new one.'
            : 'Phones that joined with the old one will have to join again with the new one.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('New password')),
        ],
      ),
    );
    if (ok == true) await _hotspotChange('new=1');
  }

  /// Join the hotspot from this phone or computer, once it's said what that
  /// does to its internet.
  Future<void> _join(String ssid, String password) async {
    final linux = Platform.isLinux;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Join $ssid?'),
        content: Text(linux
            ? "This computer's WiFi leaves the network it's on for the unit's hotspot, which has no internet: "
                "the server link drops unless it has a wired one. The remote's page is then at "
                'http://192.168.4.1. Join your own network again afterwards.'
            : "The phone's WiFi leaves the network it's on for the unit's hotspot, which has no internet. "
                'Mobile data may keep the server link going. The remote\'s page opens by itself, or is at '
                'http://192.168.4.1.\n\nAndroid asks first to save the network, then shows WiFi to connect to it.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Join')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _joining = true);
    try {
      if (linux) {
        // A fresh look first: the hotspot may have only just come on
        await Process.run('nmcli', ['device', 'wifi', 'rescan']);
        await Future<void>.delayed(const Duration(seconds: 3));
        final r = await Process.run('nmcli', ['device', 'wifi', 'connect', ssid, 'password', password]);
        final out = '${r.stdout}${r.stderr}'.trim();
        _toast(r.exitCode == 0 ? 'Joined $ssid' : "Didn't join: ${out.isEmpty ? 'nmcli failed' : out}");
      } else {
        await _wifi.invokeMethod('join', {'ssid': ssid, 'password': password});
      }
    } catch (e) {
      _toast(Platform.isLinux ? "Didn't join: NetworkManager's nmcli isn't there" : "Didn't join: $e");
    }
    if (mounted) setState(() => _joining = false);
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  void _brightness(double v, {required bool done}) {
    setState(() => _dragging = done ? null : v);
    final now = DateTime.now();
    final last = _sentAt;
    if (!done && last != null && now.difference(last) < _dragEvery) return;
    _sentAt = now;
    if (done) {
      // Shown as sent till the board's answer says so
      _display?['brightness'] = v.round();
    }
    _send({'b': v.round()});
  }

  @override
  Widget build(BuildContext context) {
    final d = _display;
    Widget body;
    if (!_up) {
      body = const Panel(children: [PanelRow(title: 'Connect to the unit to change these')]);
    } else if (_tooOld) {
      body = const Panel(children: [
        PanelRow(
            title: "The unit's firmware is too old for these",
            subtitle: "Update it, or use the display's own Settings"),
      ]);
    } else if (d == null) {
      body = const Panel(children: [PanelRow(title: 'Asking the unit...')]);
    } else {
      body = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const SectionHeader('Display'),
        _displayPanel(d),
        const SectionHeader('WiFi hotspot remote'),
        _hotspotPanel(d),
      ]);
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Display Unit')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 8, 16, 24 + MediaQuery.paddingOf(context).bottom),
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 8, bottom: 4),
            child: Text(
                "The unit's own settings, as on its display's Settings and the Remote's Setup tab. "
                'A change here shows there too.',
                style: TextStyle(color: Kc.muted, fontSize: 13)),
          ),
          // The rest of the display's controls: what it shows, the voice ring,
          // sounds, toys and the Terminal
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              style: TextButton.styleFrom(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
              onPressed: () {
                Navigator.of(context).popUntil((r) => r.isFirst);
                appTab.value = tabRemote;
              },
              icon: const Icon(Icons.phone_android, size: 18),
              label: const Text('More in the Remote tab: what it shows, sounds, toys, the Terminal'),
            ),
          ),
          body,
        ],
      ),
    );
  }

  Widget _displayPanel(Map<String, dynamic> d) {
    final choices = _startupChoices;
    final brightness = (_dragging ?? (d['brightness'] as num? ?? 50).toDouble()).clamp(1.0, 100.0);
    final rotation = d['rotation'] as int? ?? 0;
    // One it doesn't know is the first, as on the display's Settings
    final startup = d['startup'] as int? ?? 0;
    return Panel(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Row(children: [
          const Expanded(child: Text('Brightness', style: TextStyle(fontWeight: FontWeight.w600))),
          Text('${brightness.round()}%', style: Kc.term(16)),
        ]),
      ),
      Slider(
        min: 1,
        max: 100,
        value: brightness,
        onChanged: (v) => _brightness(v, done: false),
        onChangeEnd: (v) => _brightness(v, done: true),
      ),
      Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Rotation', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          SegmentedButton<int>(
            showSelectedIcon: false,
            segments: [for (var r = 0; r < 4; r++) ButtonSegment(value: r, label: Text('${r * 90}°'))],
            selected: {rotation},
            onSelectionChanged: (sel) => _send({'rot': sel.first}),
          ),
        ]),
      ),
      if (choices != null && choices.isNotEmpty)
        PanelRow(
          title: 'At startup, show',
          trailing: [
            Flexible(
              child: DropdownButton<int>(
                value: startup >= 0 && startup < choices.length ? startup : 0,
                isExpanded: true,
                underline: const SizedBox.shrink(),
                dropdownColor: Kc.raised,
                onChanged: (i) {
                  if (i != null) _send({'start': i});
                },
                items: [
                  for (var i = 0; i < choices.length; i++)
                    DropdownMenuItem(value: i, child: Text(choices[i], overflow: TextOverflow.ellipsis)),
                ],
              ),
            ),
          ],
        ),
    ]);
  }

  Widget _hotspotPanel(Map<String, dynamic> d) {
    final h = _hotspot;
    final on = h?['on'] == 1;
    final phones = h?['phones'] as int? ?? 0;
    final ssid = h?['ssid'] as String? ?? '';
    final password = h?['password'] as String? ?? '';
    final join = h?['join'] as String? ?? '';
    return Panel(children: [
      if (h != null) ...[
        Explained(
          help: 'The unit runs a WiFi network of its own, and any phone that joins it gets the remote in its '
              'browser: an iPhone, or a friend\'s phone without the app. While a phone\'s on it, it has no '
              'internet over WiFi. The app needs none of it: its Remote tab works over Bluetooth.',
          builder: (context, info) => PanelRow(
            title: 'Hotspot',
            subtitle: _hotspotBusy
                ? 'A moment...'
                : !on
                    ? 'Off'
                    : phones == 0
                        ? 'On · no phones yet'
                        : 'On · $phones phone${phones == 1 ? '' : 's'} joined',
            trailing: [
              info,
              Switch(value: on, onChanged: _hotspotBusy ? null : (v) => _hotspotChange('on=${v ? 1 : 0}')),
            ],
          ),
        ),
        if (on)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: Column(children: [
              // White round it, as cameras need a quiet zone to find it
              Container(
                color: Colors.white,
                padding: const EdgeInsets.all(12),
                child: QrImageView(data: join, size: 200, backgroundColor: Colors.white),
              ),
              const SizedBox(height: 8),
              const Text("Scan it with a phone's camera to join.",
                  textAlign: TextAlign.center, style: TextStyle(color: Kc.muted, fontSize: 13)),
            ]),
          ),
        PanelRow(
          title: 'Network',
          trailing: [SelectableText(ssid, style: Kc.term(16))],
        ),
        PanelRow(
          title: 'Password',
          trailing: [
            SelectableText(password, style: Kc.term(16)),
            IconButton(
              tooltip: 'Copy',
              icon: const Icon(Icons.copy, size: 18, color: Kc.muted),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: password));
                _toast('Password copied');
              },
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Wrap(alignment: WrapAlignment.center, spacing: 12, runSpacing: 8, children: [
            if (on && _canJoin)
              FilledButton.icon(
                onPressed: _joining ? null : () => _join(ssid, password),
                icon: const Icon(Icons.wifi),
                label: Text(Platform.isLinux ? 'Join on this computer' : 'Join on this phone'),
              ),
            OutlinedButton(
              onPressed: _hotspotBusy ? null : _newPassword,
              child: const Text('New password'),
            ),
          ]),
        ),
      ] else if (_hotspotAsked)
        const PanelRow(
            title: 'Switch it on at the display',
            subtitle: "Update the unit's firmware to switch it on, and see its password, from here"),
      Explained(
        help: 'Switches the WiFi hotspot remote on as the display starts, so phones that have joined '
            'before join again by themselves.',
        builder: (context, info) => PanelRow(
          title: 'Start at power-up',
          trailing: [
            info,
            Switch(
              value: d['remote_auto'] == 1,
              onChanged: (v) => _send({'remote': v ? 1 : 0}),
            ),
          ],
        ),
      ),
    ]);
  }
}
