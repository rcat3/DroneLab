import 'dart:convert';
import 'dart:typed_data';

/// What someone lets others control: their capabilities, as their unit says
/// (others_capabilities in core/app/others.h). A list, so more can come
/// later: how many, then for each its id and how it's open. One they haven't
/// got, or let nobody control, is left out; one this app doesn't know is
/// kept, and not shown.
///
/// Said over direct comms in the unit's hello (0x17 from the board), and
/// over the server by the app, in Mumble's plugin data ([dataId]), worked
/// out from the board's own /api/state.
class Capabilities {
  /// The ids, as OTHERS_CAP_*.
  static const terminal = 1, lovense = 2;

  /// The plugin data's id over the server.
  static const dataId = 'dronelab-caps';

  /// Each one's how it's open: [CapOpen.ask] or [CapOpen.open].
  final Map<int, CapOpen> open;
  const Capabilities(this.open);

  static const none = Capabilities({});

  /// How someone lets others control [id]; null for not at all.
  CapOpen? operator [](int id) => open[id];
  bool has(int id) => open.containsKey(id);

  /// As it's sent: how many, then each one's id and how.
  Uint8List encode() => Uint8List.fromList([
        open.length,
        for (final e in open.entries) ...[e.key, e.value.code],
      ]);

  /// From what was sent; null if it doesn't make sense.
  static Capabilities? decode(List<int> data) {
    if (data.isEmpty || data.length < 1 + 2 * data[0]) return null;
    final open = <int, CapOpen>{};
    for (var i = 0; i < data[0]; i++) {
      final how = CapOpen.of(data[2 + 2 * i]);
      if (how != null) open[data[1 + 2 * i]] = how;
    }
    return Capabilities(open);
  }

  /// Ours, from the board's /api/state: the Terminal and the Lovense
  /// devices as their permissions have them (Off left out), and the Lovense
  /// devices only with one connected, as the board itself works it out.
  /// Null if it isn't the state.
  static Capabilities? fromBoardState(String json) {
    try {
      final j = jsonDecode(json);
      if (j is! Map<String, dynamic>) return null;
      final others = j['others'];
      if (others is! List || others.length < 2) return null;
      CapOpen? how(Object? kind) => switch ((kind as Map<String, dynamic>)['permission']) {
            2 => CapOpen.open,
            1 => CapOpen.ask,
            _ => null,
          };
      final devices = j['devices'] as List<dynamic>? ?? const [];
      final toys = devices.any((d) => const ['connected', 'connecting', 'lost'].contains((d as Map)['state']));
      final term = how(others[1]), toy = toys ? how(others[0]) : null;
      return Capabilities({terminal: ?term, lovense: ?toy});
    } catch (_) {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is Capabilities &&
      other.open.length == open.length &&
      open.entries.every((e) => other.open[e.key] == e.value);

  @override
  int get hashCode => Object.hashAllUnordered(open.entries.map((e) => Object.hash(e.key, e.value)));
}

/// How a capability's open to others.
enum CapOpen {
  ask(1),     // to those the wearer allows
  open(2);    // to anyone

  final int code;
  const CapOpen(this.code);

  static CapOpen? of(int code) => switch (code) { 1 => ask, 2 => open, _ => null };
}
