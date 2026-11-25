import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../comm/app_profile.dart';
import '../comm/board_link.dart';
import '../comm/comm_controller.dart';
import 'status_strip.dart';
import 'theme.dart';
import 'widgets.dart';

/// The project's home, behind the logo.
const projectUrl = 'https://github.com/rcat3/DroneLab';

/// The latest release's page: the app, firmware and 3D printed parts.
const downloadUrl = '$projectUrl/releases/latest';

/// The app, the phone it's on, and the unit it's linked to: versions, the
/// link's signal, MAC addresses, housing, uptime and battery. The unit's
/// side comes from GET /api/about, read again every few seconds while the
/// page shows.
class AboutPage extends StatefulWidget {
  final CommController comm;
  const AboutPage({super.key, required this.comm});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  static const _device = MethodChannel('dronelab/device');

  PackageInfo? _app;
  String? _os;
  String? _phone;
  Map<String, dynamic>? _unit;    // GET /api/about; null until it's answered, or on older firmware
  int? _rssi;
  Timer? _timer;
  bool _reading = false;

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((p) => mounted ? setState(() => _app = p) : null);
    _readPhone();
    _read();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _read());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _readPhone() async {
    String os, phone = '';
    if (Platform.isLinux) {
      (os, phone) = await _linuxInfo();
      if (mounted) {
        setState(() {
          _os = os;
          _phone = phone;
        });
      }
      return;
    }
    try {
      final m = await _device.invokeMapMethod<String, dynamic>('info');
      os = 'Android ${m?['release'] ?? ''} (API ${m?['sdk'] ?? '?'})';
      final make = (m?['manufacturer'] as String? ?? '').trim();
      final model = (m?['model'] as String? ?? '').trim();
      phone = [if (make.isNotEmpty) _capitalised(make), model].join(' ');
    } catch (_) {
      os = '${Platform.isIOS ? 'iOS' : Platform.operatingSystem} ${Platform.operatingSystemVersion}';
    }
    if (mounted) {
      setState(() {
        _os = os;
        _phone = phone;
      });
    }
  }

  /// The distribution (os-release), and the computer's model: a Raspberry
  /// Pi's device tree says, a PC's firmware (DMI) usually does.
  static Future<(String, String)> _linuxInfo() async {
    Future<String> read(String path) async {
      try {
        return (await File(path).readAsString()).replaceAll('\x00', '').trim();
      } catch (_) {
        return '';
      }
    }

    final release = await read('/etc/os-release');
    final name = RegExp(r'^PRETTY_NAME="?([^"\n]*)"?', multiLine: true).firstMatch(release)?.group(1);
    var model = await read('/proc/device-tree/model');
    if (model.isEmpty) {
      model = [await read('/sys/devices/virtual/dmi/id/sys_vendor'), await read('/sys/devices/virtual/dmi/id/product_name')]
          .where((s) => s.isNotEmpty)
          .join(' ');
    }
    return (name ?? 'Linux', model);
  }

  Future<void> _read() async {
    final b = widget.comm.board;
    if (_reading || b.state != BoardState.connected || b.status == null) {
      if (_unit != null || _rssi != null) {
        setState(() {
          _unit = null;
          _rssi = null;
        });
      }
      return;
    }
    _reading = true;
    try {
      final rssi = await b.readRssi();
      Map<String, dynamic>? unit;
      try {
        final a = await b.request('GET', '/api/about');
        if (a.status == 200) unit = jsonDecode(a.body) as Map<String, dynamic>;
      } catch (_) {}
      if (mounted) {
        setState(() {
          _unit = unit ?? _unit;
          _rssi = rssi;
        });
      }
    } finally {
      _reading = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.comm,
      builder: (context, _) {
        final comm = widget.comm;
        final b = comm.board;
        final up = b.state == BoardState.connected && b.status != null;
        final u = up ? _unit : null;
        final st = b.status;
        final battery = u?['battery'] as Map<String, dynamic>?;
        final percent = (battery?['percent'] as num?)?.toInt() ?? (up ? st?.battery : null);
        final charging = battery != null ? battery['charging'] == 1 : (st?.charging ?? false);
        final volts = (battery?['volts'] as num?)?.toDouble();
        final housing = (u?['housing'] as String?) ?? comm.boardSettings?.housing;
        final uptime = (u?['uptime'] as num?)?.toInt();
        return Scaffold(
          appBar: AppBar(title: const Text('About')),
          body: ListView(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 24 + MediaQuery.paddingOf(context).bottom),
            children: [
              _Logo(onTap: _openSite),
              const SectionHeader('App'),
              Panel(children: [
                _Fact('Version', _app?.version ?? '...', onTap: _versionTapped),
                _Fact('OS', _os ?? '...'),
                if ((_phone ?? '').isNotEmpty) _Fact('Device', _phone!),
                if (AppProfile.name != null) _Fact('Profile', AppProfile.name!),
                PanelRow(
                  leading: const Icon(Icons.qr_code_2, color: Kc.pink),
                  title: 'Share the app',
                  subtitle: 'A QR code for the download page',
                  trailing: const [Icon(Icons.chevron_right, color: Kc.muted)],
                  onTap: _shareApp,
                ),
              ]),
              const SectionHeader('Display unit'),
              Panel(children: [
                PanelRow(
                  leading: _LinkDot(up),
                  title: b.name ?? comm.lastBoardName ?? 'No unit paired',
                  subtitle: boardStatusText(comm),
                  trailing: [if (up && _rssi != null) _Signal(_rssi!)],
                ),
                if (up) ...[
                  _Fact('Firmware', (u?['firmware'] as String?) ?? b.firmware ?? '...'),
                  if (u?['built'] != null) _Fact('Built', u!['built'] as String),
                  if ((u?['board'] ?? b.model) != null) _Fact('Board', _boardName((u?['board'] ?? b.model) as String)),
                  if (u?['bt_mac'] != null) _Fact('Bluetooth MAC', u!['bt_mac'] as String),
                  if (u?['wifi_mac'] != null) _Fact('WiFi MAC', u!['wifi_mac'] as String),
                  if (housing != null) _Fact('Enclosure', housing == 'low-profile' ? 'Low-profile' : 'Speaker'),
                  if (uptime != null) _Fact('Uptime', _uptimeText(uptime)),
                ],
              ]),
              if (up && percent != null) ...[
                const SectionHeader('Battery'),
                Panel(children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                    child: _BatteryGauge(percent, charging),
                  ),
                  if (volts != null) _Fact('Voltage', '${volts.toStringAsFixed(2)} V'),
                  _Fact('Charge', charging ? 'Charging' : 'Not charging',
                      color: charging ? Kc.green : null),
                ]),
              ],
              if (up && u == null && b.firmware != null)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text("Update the unit's firmware to see its build, MAC addresses, uptime and voltage.",
                      style: TextStyle(color: Kc.muted, fontSize: 13)),
                ),
            ],
          ),
        );
      },
    );
  }

  /// Ten taps on the version, as Android's build number, show the
  /// developer options in Setup; the last few count down.
  int _taps = 0;
  static const _tapsToReveal = 10;

  void _versionTapped() {
    final comm = widget.comm;
    final messenger = ScaffoldMessenger.of(context);
    void say(String text) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 1)));
    }
    if (comm.developerOptions) {
      say('Developer options are already on, in Setup');
      return;
    }
    _taps++;
    final left = _tapsToReveal - _taps;
    if (left <= 0) {
      _taps = 0;
      comm.setDeveloperOptions(true);
      say('Developer options are on, in Setup');
    } else if (left <= 4) {
      say('$left tap${left == 1 ? '' : 's'} from developer options');
    }
  }

  /// The download page as a QR code, for someone else's phone to scan.
  void _shareApp() => showDialog<void>(
        context: context,
        builder: (dialog) => AlertDialog(
          insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          backgroundColor: Kc.panel,
          shape: RoundedRectangleBorder(
              side: const BorderSide(color: Kc.pink), borderRadius: BorderRadius.circular(16)),
          title: Text('> GET DRONELAB', style: Kc.term(16, color: Kc.pink, shadows: Kc.glow(Kc.pink))),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              color: Colors.white,
              padding: const EdgeInsets.all(12),
              child: QrImageView(data: downloadUrl, size: 220, backgroundColor: Colors.white),
            ),
            const SizedBox(height: 12),
            SelectableText(downloadUrl.replaceFirst('https://', ''),
                textAlign: TextAlign.center, style: Kc.term(13, color: Kc.pink)),
            const SizedBox(height: 8),
            const Text("Scan it with a phone's camera for the latest release: the app, firmware and 3D printed parts.",
                textAlign: TextAlign.center, style: TextStyle(color: Kc.muted, fontSize: 13)),
          ]),
          actions: [
            TextButton.icon(
              icon: const Icon(Icons.copy, size: 18),
              label: const Text('Copy link'),
              onPressed: () {
                Clipboard.setData(const ClipboardData(text: downloadUrl));
                Navigator.of(dialog).pop();
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('Link copied'), duration: Duration(seconds: 1)));
              },
            ),
            TextButton(onPressed: () => Navigator.of(dialog).pop(), child: const Text('Close')),
          ],
        ),
      );

  void _openSite() => launchUrl(Uri.parse(projectUrl), mode: LaunchMode.externalApplication);

  static String _capitalised(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  /// The board's component name, as "waveshare_esp32s3_touch_amoled_1_75",
  /// shortened to what's on its box.
  static String _boardName(String board) => switch (board) {
        'waveshare_esp32s3_touch_amoled_1_75' => 'Waveshare ESP32-S3 Touch AMOLED 1.75"',
        'virtual_unit' => 'Virtual unit, on a computer',
        _ => board,
      };

  static String _uptimeText(int seconds) {
    final m = seconds ~/ 60, h = m ~/ 60, d = h ~/ 24;
    if (d > 0) return '${d}d ${h % 24}h ${(m % 60).toString().padLeft(2, '0')}m';
    if (h > 0) return '${h}h ${(m % 60).toString().padLeft(2, '0')}m';
    return '${m}m ${(seconds % 60).toString().padLeft(2, '0')}s';
  }
}

/// The logo, as the board shows at startup, and a link to the project.
class _Logo extends StatelessWidget {
  final VoidCallback onTap;
  const _Logo({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Semantics(
        link: true,
        label: 'DroneLab. Opens the project on GitHub',
        excludeSemantics: true,
        child: Material(
          color: Colors.black,
          shape: RoundedRectangleBorder(
              side: const BorderSide(color: Kc.line), borderRadius: BorderRadius.circular(12)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Column(children: [
              Image.asset('assets/dronelab_logo.png', fit: BoxFit.fitWidth, width: double.infinity),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Flexible(
                    child: Text(projectUrl.replaceFirst('https://', ''),
                        overflow: TextOverflow.ellipsis, style: Kc.term(14, color: Kc.pink)),
                  ),
                  const SizedBox(width: 6),
                  const Icon(Icons.open_in_new, size: 16, color: Kc.pink),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// A name on the left and its value on the right, in the Terminal's letters.
class _Fact extends StatelessWidget {
  final String name;
  final String value;
  final Color? color;
  final VoidCallback? onTap;    // in place of selecting its value
  const _Fact(this.name, this.value, {this.color, this.onTap});

  @override
  Widget build(BuildContext context) {
    final style = Kc.term(15, color: color ?? Kc.text);
    final row = Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(children: [
        Text(name, style: const TextStyle(color: Kc.muted)),
        const SizedBox(width: 16),
        Expanded(
          child: onTap == null
              ? SelectableText(value, textAlign: TextAlign.end, style: style)
              : Text(value, textAlign: TextAlign.end, style: style),
        ),
      ]),
    );
    return onTap == null ? row : InkWell(onTap: onTap, child: row);
  }
}

class _LinkDot extends StatelessWidget {
  final bool on;
  const _LinkDot(this.on);

  @override
  Widget build(BuildContext context) => Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: on ? Kc.green : Kc.off,
          boxShadow: on ? [BoxShadow(color: Kc.green.withValues(alpha: 0.8), blurRadius: 8)] : null,
        ),
      );
}

/// The link's signal: four bars and the dBm.
class _Signal extends StatelessWidget {
  final int rssi;
  const _Signal(this.rssi);

  int get bars => rssi >= -60 ? 4 : rssi >= -70 ? 3 : rssi >= -80 ? 2 : rssi >= -90 ? 1 : 0;

  @override
  Widget build(BuildContext context) {
    final color = bars <= 1 ? Kc.warn : Kc.green;
    return Semantics(
      label: 'Signal $bars of 4, $rssi dBm',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
          for (var i = 0; i < 4; i++)
            Container(
              width: 4,
              height: 6.0 + 4 * i,
              margin: const EdgeInsets.only(right: 2),
              color: i < bars ? color : Kc.off,
            ),
          const SizedBox(width: 6),
          Text('$rssi dBm', style: Kc.term(14, color: color)),
        ]),
      ),
    );
  }
}

/// The battery's charge as a wide bar, the percent beside it.
class _BatteryGauge extends StatelessWidget {
  final int percent;
  final bool charging;
  const _BatteryGauge(this.percent, this.charging);

  @override
  Widget build(BuildContext context) {
    final color = percent <= 15 ? Kc.softRed : Kc.green;
    return Row(children: [
      Expanded(
        child: Container(
          height: 22,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
              border: Border.all(color: color, width: 1.5), borderRadius: const BorderRadius.all(Radius.circular(4))),
          alignment: Alignment.centerLeft,
          child: FractionallySizedBox(
            widthFactor: percent.clamp(0, 100) / 100,
            child: Container(
              decoration: BoxDecoration(
                  color: color, boxShadow: [BoxShadow(color: color.withValues(alpha: 0.5), blurRadius: 8)]),
            ),
          ),
        ),
      ),
      Container(width: 3, height: 9, color: color),
      const SizedBox(width: 12),
      if (charging) const Icon(Icons.bolt, size: 20, color: Kc.green),
      Text('$percent%', style: Kc.term(20, color: color, shadows: Kc.glow(color))),
    ]);
  }
}
