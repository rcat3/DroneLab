/// Setup's Talking rows for the mic: which one talks (the unit's, the
/// phone's or a Bluetooth headset's), and for the phone's, what it does,
/// its boost, and a level meter to set the boost by. Setup puts them in
/// its panels, in an order that stays put as rows come and go.
library;

import 'package:flutter/material.dart';

import '../comm/board_link.dart';
import '../comm/comm_controller.dart';
import '../comm/phone_mic.dart';
import 'theme.dart';
import 'widgets.dart';

/// Which mic talks: the unit's (while one's connected), the phone's, or a
/// Bluetooth headset's (Android). See [shown] for when there's a choice.
class MicSourceRow extends StatelessWidget {
  final CommController comm;
  final bool unitUp;
  const MicSourceRow({super.key, required this.comm, required this.unitUp});

  /// Whether there's more than one mic to pick from.
  static bool shown(bool unitUp) => unitUp || Headset.supported;

  @override
  Widget build(BuildContext context) {
    final options = [
      if (unitUp) (MicSource.unit, 'UNIT'),
      (MicSource.phone, thisDevice.toUpperCase()),
      if (Headset.supported) (MicSource.headset, 'HEADSET'),
    ];

    // The unit's picked but not there: the phone's talks, and shows so
    final shown = !unitUp && comm.micSource == MicSource.unit ? MicSource.phone : comm.micSource;
    return Explained(
      help:
          "The unit's mic talks through your voice effect, with its own talk button and voice mode. "
          "The $thisDevice's mic leaves Bluetooth headphones on media sound, so what you hear stays clear. "
          "A headset's mic is nearer your mouth, but the headset goes into call mode while you're connected, "
          "like a phone call: what you hear comes through its narrower call sound, and so does any other "
          "app's. With the $thisDevice's or the headset's mic, the app's talk button and the headphones' "
          "button talk from it, to the server, or through the unit to its direct channel, and so does the unit's "
          "own talk button (with older firmware, that talks through the unit). The unit's voice mode is off till "
          "you pick the unit's mic again, as it would send what it heard too. Without a unit, the unit choice "
          "goes away and the $thisDevice's mic talks.",
      // The label over the choices, as Talk with: three don't leave it
      // room beside them on a phone
      builder: (context, info) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text('Mic', style: TextStyle(fontWeight: FontWeight.w600)),
                ),
                info,
              ],
            ),
            const SizedBox(height: 8),
            SegmentedButton<MicSource>(
              showSelectedIcon: false,
              segments: [for (final (v, label) in options) ButtonSegment(value: v, label: Text(label))],
              selected: {shown},
              onSelectionChanged: (sel) => comm.setMicSource(sel.first),
            ),
          ],
        ),
      ),
    );
  }
}

/// What the phone's mic does: which mic it is, and how it talks.
class PhoneMicRow extends StatelessWidget {
  final CommController comm;
  const PhoneMicRow({super.key, required this.comm});

  @override
  Widget build(BuildContext context) {
    final headset = comm.headsetMic;
    final active = comm.headsetMicName;
    final which = !headset
        ? "Talking from the $thisDevice's microphone"
        : active != null
        ? 'Talking from $active'
        : comm.phoneMicCanTalk
        ? "No Bluetooth headset to talk from: the $thisDevice's microphone talks"
        : "Talking from a Bluetooth headset, once you're connected";
    return PanelRow(
      title: which,
      subtitle: comm.board.state == BoardState.connected
          ? "Push to talk: hold the talk button, or press the headphones' play/pause button. To the server, "
                "or through the unit to its direct channel. No voice effect."
          : "Push to talk: hold the talk button, or press the headphones' play/pause button. Connect a "
                'display unit for voice mode, its voice effects and Direct.',
    );
  }
}

/// The phone mic's boost.
class MicBoostRow extends StatelessWidget {
  final CommController comm;
  const MicBoostRow({super.key, required this.comm});

  @override
  Widget build(BuildContext context) {
    return Explained(
      help:
          "A boost for a quiet microphone. Loud parts are eased down rather than clipped. Each $thisDevice "
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
    );
  }
}

/// The mic's level as others get it, while trying it (nothing's sent) or
/// while talking.
class MicMeter extends StatefulWidget {
  final CommController comm;
  const MicMeter({super.key, required this.comm});

  @override
  State<MicMeter> createState() => _MicMeterState();
}

class _MicMeterState extends State<MicMeter> {
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('Mic level', style: TextStyle(fontWeight: FontWeight.w600)),
              ),
              _trying
                  ? OutlinedButton(onPressed: _toggle, child: const Text('Stop'))
                  : FilledButton(onPressed: _toggle, child: const Text('Try it')),
            ],
          ),
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
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: Container(
                          decoration: BoxDecoration(
                            color: Kc.raised,
                            border: Border.all(color: Kc.line),
                          ),
                        ),
                      ),
                      // Where speech should reach, and where it's eased down
                      _band(_goodFrom, PhoneMic.kneeDb, Kc.visor),
                      FractionallySizedBox(
                        alignment: Alignment.centerLeft,
                        widthFactor: frac,
                        child: Container(color: color),
                      ),
                    ],
                  ),
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
        ],
      ),
    );
  }

  Widget _band(double fromDb, double toDb, Color color) => LayoutBuilder(
    builder: (context, c) {
      final w = c.maxWidth;
      final a = ((fromDb - _floor) / -_floor).clamp(0.0, 1.0) * w;
      final b = ((toDb - _floor) / -_floor).clamp(0.0, 1.0) * w;
      return Padding(
        padding: EdgeInsets.only(left: a),
        child: SizedBox(
          width: b - a,
          height: 14,
          child: ColoredBox(color: color),
        ),
      );
    },
  );
}
