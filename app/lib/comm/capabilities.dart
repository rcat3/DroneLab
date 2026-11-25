import 'dart:convert';
import 'dart:typed_data';

/// What someone lets others control: their capabilities, as their unit says
/// (others_capabilities in core/app/others.h). A list, so more can come
/// later: how many, then for each its id, how it's open, and a byte more
/// (for Vibe toys, the channels their toys follow; otherwise 0). One they
/// haven't got, or let nobody control, is left out; one this app doesn't
/// know is kept, and not shown.
///
/// Said over direct comms in the unit's hello (0x17 from the board), and
/// over the server by the app, in Mumble's plugin data ([dataId]), worked
/// out from the board's own /api/state.
class Capabilities {
  /// The ids, as OTHERS_CAP_*: the display (words and pictures), Vibe
  /// toys, and sounds from the unit's speaker. 3 and 4 are kept for E-stim
  /// and Machines.
  static const display = 1, vibe = 2, sounds = 6;

  /// The plugin data's id over the server.
  static const dataId = 'dronelab-caps';

  /// Bytes in each entry: id, how, data.
  static const entry = 3;

  /// Each one's how it's open: [CapOpen.ask] or [CapOpen.open].
  final Map<int, CapOpen> open;

  /// Each one's byte more, where it isn't 0.
  final Map<int, int> data;
  const Capabilities(this.open, [this.data = const {}]);

  static const none = Capabilities({});

  /// How someone lets others control [id]; null for not at all.
  CapOpen? operator [](int id) => open[id];
  bool has(int id) => open.containsKey(id);

  /// The Vibe channels their toys follow, a bit for each, V1 the lowest; 0
  /// if they haven't said.
  int get vibeChannels => data[vibe] ?? 0;

  /// As it's sent: how many, then each one's id, how, and data.
  Uint8List encode() => Uint8List.fromList([
        open.length,
        for (final e in open.entries) ...[e.key, e.value.code, (data[e.key] ?? 0) & 0xFF],
      ]);

  /// From what was sent; null if it doesn't make sense.
  static Capabilities? decode(List<int> data) {
    if (data.isEmpty || data.length < 1 + entry * data[0]) return null;
    final open = <int, CapOpen>{}, more = <int, int>{};
    for (var i = 0; i < data[0]; i++) {
      final at = 1 + entry * i;
      final how = CapOpen.of(data[at + 1]);
      if (how == null) continue;
      open[data[at]] = how;
      if (data[at + 2] != 0) more[data[at]] = data[at + 2];
    }
    return Capabilities(open, more);
  }

  /// Ours, from the board's /api/state: each kind as the board offers it
  /// ("offered": Off left out, Vibe toys only with one connected, sounds
  /// only with a speaker), and Vibe toys with the channels they follow
  /// ("mapped"). Null if it isn't the state.
  static Capabilities? fromBoardState(String json) {
    try {
      final j = jsonDecode(json);
      if (j is! Map<String, dynamic>) return null;
      final others = j['others'];
      if (others is! List || others.length < 3) return null;
      CapOpen? offered(int at) => CapOpen.of(((others[at] as Map<String, dynamic>)['offered'] as num?)?.toInt() ?? 0);
      final toy = offered(0);
      final mapped = (j['mapped'] as num?)?.toInt() ?? 0;
      return Capabilities({display: ?offered(1), vibe: ?toy, sounds: ?offered(2)},
          {if (toy != null && mapped != 0) vibe: mapped});
    } catch (_) {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is Capabilities &&
      other.open.length == open.length &&
      open.entries.every((e) => other.open[e.key] == e.value) &&
      other.data.length == data.length &&
      data.entries.every((e) => other.data[e.key] == e.value);

  @override
  int get hashCode => Object.hash(Object.hashAllUnordered(open.entries.map((e) => Object.hash(e.key, e.value))),
      Object.hashAllUnordered(data.entries.map((e) => Object.hash(e.key, e.value))));
}

/// How a capability's open to others.
enum CapOpen {
  ask(1),     // to those the wearer allows
  open(2);    // to anyone

  final int code;
  const CapOpen(this.code);

  static CapOpen? of(int code) => switch (code) { 1 => ask, 2 => open, _ => null };
}
