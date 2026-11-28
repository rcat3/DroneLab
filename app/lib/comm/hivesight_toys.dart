/// The Guide's toys in a HiveSight session: one Vessel at a time, by the
/// channels (V1 to V6) their unit's toys are mapped to, the same Vibe
/// commands HiveMind Control sends (others.h 0x41 set, 0x45 pattern parts,
/// 0x40 stop). They go Guide, sender, the Vessel's phone, their unit, and
/// are only done as that Vessel's permissions say; what they let us do
/// comes back as [VesselToysInfo]. The unit stops every toy by itself if
/// the Vessel's phone stops keeping up its lease (hivesight_vessel_toys.dart).
library;

import 'dart:async';
import 'dart:convert';

import 'board_protocol.dart';
import 'hivesight_guide.dart';
import 'patterns.dart';

/// What a Vessel's phone says about their toys.
class VesselToysInfo {
  final bool unit; // their unit's connected and new enough
  final int mapped; // the channels their toys are on, a bit each
  final bool allowed; // they let us
  final String why; // if not: off, not allowed, ignored
  const VesselToysInfo(this.unit, this.mapped, this.allowed, this.why);

  static VesselToysInfo? of(Object? j) => j is Map<String, dynamic>
      ? VesselToysInfo(
          j['unit'] == true,
          ((j['mapped'] as num?)?.toInt() ?? 0) & OthersCommand.allChannels,
          j['allowed'] == true,
          j['why'] as String? ?? '',
        )
      : null;

  bool get ready => unit && allowed && mapped != 0;
}

/// A pattern playing: a built-in one by its name, or a custom one.
class ToyPattern {
  final String? builtIn;
  final VibePattern? custom;
  const ToyPattern.builtIn(String this.builtIn) : custom = null;
  const ToyPattern.custom(VibePattern this.custom) : builtIn = null;

  String get name => builtIn ?? custom!.name;
  bool same(ToyPattern? o) => o != null && o.builtIn == builtIn && o.custom?.hashHex == custom?.hashHex;
}

class GuideToys {
  GuideToys(this.g);
  final HiveSightGuide g;

  /// How often a held slider's level is sent, and how long after a stop it's sent again.
  static const _dragEvery = Duration(milliseconds: 300);
  static const _stopAgainAfter = Duration(milliseconds: 1500);

  /// The Vessel being driven (the sender's id for them).
  String? target;
  final List<int> levels = List.filled(OthersCommand.vibeChannels, 0);

  /// The channels the pattern plays on; the others are held at their level.
  int active = OthersCommand.allChannels;
  ToyPattern? playing;
  int speed = 100;

  final Map<int, Timer> _drag = {};
  final Set<int> _dragLater = {};
  Timer? _partsAgain;

  GuideVessel? get vessel {
    for (final v in g.vessels) {
      if (v.id == target) return v;
    }
    return null;
  }

  VesselToysInfo? get info => vessel?.toys;
  int get mapped => info?.mapped ?? 0;
  bool get ready => info?.ready ?? false;

  /// Drive [id], having stopped whoever was.
  void pick(String? id) {
    if (id == target) return;
    stop();
    target = id;
  }

  void _tx(GuideVessel v, OthersCommand c) => g.sendToys(v, c.what);

  void _sendParts(GuideVessel v, VibePattern p) {
    final def = p.encode();
    for (final part in OthersCommand.patternParts(def, VibePattern.hashOf(def))) {
      _tx(v, part);
    }
  }

  /// Set [channels] (those mapped): each as its level, on the pattern if
  /// it's one of those it plays on, steady otherwise.
  void _send(int channels) {
    final v = vessel;
    if (v == null || !ready) return;
    final mask = channels & mapped;
    if (mask == 0) return;
    final p = playing;
    final patterned = p == null ? 0 : mask & active;
    if (patterned != 0) {
      if (p!.custom != null) _sendParts(v, p.custom!);
      _tx(v, OthersCommand.setVibe(patterned, levels, speed: speed, builtIn: p.builtIn, hash: p.custom?.hash));
    }
    if (mask & ~patterned != 0) _tx(v, OthersCommand.setVibe(mask & ~patterned, levels));
    _keepParts();
  }

  /// A custom pattern's parts again now and then, for a unit that's lost them.
  void _keepParts() {
    _partsAgain?.cancel();
    final p = playing?.custom;
    if (p == null) {
      _partsAgain = null;
      return;
    }
    _partsAgain = Timer.periodic(const Duration(seconds: 30), (_) {
      final v = vessel;
      if (v != null && playing?.custom != null) _sendParts(v, playing!.custom!);
    });
  }

  /// A slider moved: sent now, then at most every [_dragEvery] with the last
  /// value sent last.
  void setLevel(int channel, int level) {
    levels[channel] = level.clamp(0, OthersCommand.levelTop);
    if (_drag.containsKey(channel)) {
      _dragLater.add(channel);
      return;
    }
    _send(1 << channel);
    _drag[channel] = Timer(_dragEvery, () {
      _drag.remove(channel);
      if (_dragLater.remove(channel)) setLevel(channel, levels[channel]);
    });
  }

  /// Play [p] on the channels it's on (or nothing, to hold them steady).
  void play(ToyPattern? p) {
    playing = p;
    if (p != null) _startDriving(active & mapped);
    _send(mapped);
  }

  void setSpeed(int percent) {
    speed = percent.clamp(25, 300);
    if (playing != null) _send(active & mapped);
  }

  void toggleActive(int channel) {
    active ^= 1 << channel;
    if (playing != null) {
      if (active & (1 << channel) != 0) _startDriving(1 << channel);
      _send(1 << channel);
    }
  }

  /// Channels starting a pattern while off go three quarters of the way up,
  /// for it to drive up to.
  void _startDriving(int mask) {
    for (var c = 0; c < OthersCommand.vibeChannels; c++) {
      if (mask & (1 << c) != 0 && levels[c] == 0) levels[c] = (OthersCommand.levelTop * 3 / 4).round();
    }
  }

  /// Stop every Vessel's toys, not only the one being driven: the top bar's STOP TOYS.
  void stopAll() {
    stop();
    for (final v in g.vessels) {
      if (v.id == target) continue;
      g.sendToys(v, OthersCommand.stopAll().what);
      Timer(_stopAgainAfter, () => g.sendToys(v, OthersCommand.stopAll().what));
    }
  }

  /// Stop everything on the Vessel's toys, always, whatever's shown.
  void stop() {
    for (final t in _drag.values) {
      t.cancel();
    }
    _drag.clear();
    _dragLater.clear();
    _partsAgain?.cancel();
    _partsAgain = null;
    levels.fillRange(0, levels.length, 0);
    playing = null;
    final v = vessel;
    if (v == null) return;
    _tx(v, OthersCommand.stopAll());
    Timer(_stopAgainAfter, () => g.sendToys(v, OthersCommand.stopAll().what));
  }
}

/// The base64 of a command's bytes, as the sender relays it.
String toysWire(List<int> what) => base64Encode(what);
