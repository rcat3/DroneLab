/// Setup's Talking panel without a unit: which mic (the phone's or a
/// Bluetooth headset's), its boost, and a level meter to set the boost by.
library;

import 'package:flutter/material.dart';

import '../comm/comm_controller.dart';
import '../comm/mumble_client.dart';
import '../comm/phone_mic.dart';
import 'theme.dart';
import 'widgets.dart';

class PhoneMicPanel extends StatelessWidget {
  final CommController comm;
  final Widget tones;
  const PhoneMicPanel({super.key, required this.comm, required this.tones});

  @override
  Widget build(BuildContext context) {
    final headset = comm.headsetMic && Headset.supported;
    final active = comm.headsetMicName;
    final serverUp = comm.mumble?.state == MumbleState.connected;
    final which = !headset
        ? "Talking from the $thisDevice's microphone"
        : active != null
            ? 'Talking from $active'
            : serverUp
                ? "No Bluetooth headset to talk from: the $thisDevice's microphone talks"
                : "Talking from a Bluetooth headset, once the server's connected";
    return Panel(children: [
      PanelRow(
        title: which,
        subtitle: 'Push to talk: hold the talk button, or press the headphones\' play/pause '
            'button. Connect a display unit for voice mode, its voice effects and Direct.',
      ),
      if (Headset.supported)
        Explained(
          help: "The phone's mic leaves Bluetooth headphones on media sound, so what you hear stays clear. "
              "A headset's mic is nearer your mouth, but the headset goes into call mode while the server's "
              'connected, like a phone call: what you hear comes through its narrower call sound, and so '
              "does any other app's.",
          builder: (context, info) => Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
            child: Row(children: [
              const Expanded(child: Text('Mic', style: TextStyle(fontWeight: FontWeight.w600))),
              info,
              const SizedBox(width: 8),
              SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: false, label: Text('PHONE')),
                  ButtonSegment(value: true, label: Text('HEADSET')),
                ],
                selected: {comm.headsetMic},
                onSelectionChanged: (sel) => comm.setHeadsetMic(sel.first),
              ),
            ]),
          ),
        ),
      Explained(
        help: "A boost for a quiet microphone. Loud parts are eased down rather than clipped. Each $thisDevice "
            'keeps its own: set it by the meter below.',
        builder: (context, info) => PanelRow(
          title: 'Mic boost',
          trailing: [
            info,
            DropdownButton<int>(
              value: comm.phoneMicGainDb,
              underline: const SizedBox.shrink(),
              dropdownColor: Kc.raised,
              onChanged: (v) => comm.setPhoneMicGain(v ?? 0),
              items: [
                for (var db = 0; db <= PhoneMic.maxGainDb; db += 3)
                  DropdownMenuItem(value: db, child: Text(db == 0 ? 'None' : '+$db dB')),
              ],
            ),
          ],
        ),
      ),
      _MicMeter(comm: comm),
      tones,
    ]);
  }
}

/// The mic's level as others get it, while trying it (nothing's sent) or
/// while talking.
class _MicMeter extends StatefulWidget {
  final CommController comm;
  const _MicMeter({required this.comm});

  @override
  State<_MicMeter> createState() => _MicMeterState();
}

class _MicMeterState extends State<_MicMeter> {
  bool _trying = false;

  Future<void> _toggle() async {
    if (_trying) {
      setState(() => _trying = false);
      await widget.comm.stopMicMeter();
    } else {
      setState(() => _trying = true);
      final ok = await widget.comm.startMicMeter();
      if (!ok && mounted) setState(() => _trying = false);
    }
  }

  @override
  void dispose() {
    if (_trying) widget.comm.stopMicMeter();
    super.dispose();
  }

  // The bar runs from -48 dB to full scale
  static const _floor = -48.0;
  // Speech peaks wanted here
  static const _goodFrom = -18.0;

  @override
  Widget build(BuildContext context) {
    final comm = widget.comm;
    final live = _trying || comm.sendingNow;
    final err = comm.phoneMicError;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 8, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const Expanded(child: Text('Mic level', style: TextStyle(fontWeight: FontWeight.w600))),
          _trying
              ? OutlinedButton(onPressed: _toggle, child: const Text('Stop'))
              : FilledButton(onPressed: _toggle, child: const Text('Try it')),
        ]),
        const SizedBox(height: 8),
        ValueListenableBuilder<double>(
          valueListenable: comm.micLevel,
          builder: (context, db, _) {
            final v = live ? db : -60.0;
            final frac = ((v - _floor) / -_floor).clamp(0.0, 1.0);
            final color = v >= PhoneMic.kneeDb
                ? Kc.warn
                : v >= _goodFrom
                    ? Kc.green
                    : Kc.darkGreen;
            return Semantics(
              label: live ? 'Mic level ${v.round()} dB' : 'Mic level, not listening',
              child: SizedBox(
                height: 14,
                child: Stack(children: [
                  Positioned.fill(child: Container(decoration: BoxDecoration(color: Kc.raised, border: Border.all(color: Kc.line)))),
                  // Where speech should reach, and where it's eased down
                  _band(_goodFrom, PhoneMic.kneeDb, Kc.visor),
                  FractionallySizedBox(alignment: Alignment.centerLeft, widthFactor: frac, child: Container(color: color)),
                ]),
              ),
            );
          },
        ),
        const SizedBox(height: 6),
        Text(
          err ??
              (live
                  ? 'Talk as you would. Peaks in the green band sound right to others; mostly in the dark part, '
                      'add boost; yellow is being eased down, so take some off. Nothing is sent while trying.'
                  : "Try it to see your level as others get it, after the $thisDevice's own processing and the boost."),
          style: TextStyle(color: err != null ? Kc.softRed : Kc.muted, fontSize: 13),
        ),
      ]),
    );
  }

  Widget _band(double fromDb, double toDb, Color color) => LayoutBuilder(
        builder: (context, c) {
          final w = c.maxWidth;
          final a = ((fromDb - _floor) / -_floor).clamp(0.0, 1.0) * w;
          final b = ((toDb - _floor) / -_floor).clamp(0.0, 1.0) * w;
          return Padding(
            padding: EdgeInsets.only(left: a),
            child: SizedBox(width: b - a, height: 14, child: ColoredBox(color: color)),
          );
        },
      );
}
