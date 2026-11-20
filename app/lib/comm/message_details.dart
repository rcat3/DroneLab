/// How a text came, or went, for its Details: which ways, on which channel,
/// how big, and over direct comms, each packet on the air and every copy of
/// it heard, how strong and how many times passed on. For testing direct
/// comms' range and relaying.
library;

/// One copy of a packet heard over direct comms (HeardCopy).
class RadioCopy {
  final int broadcast;      // the sending board's counter for it: a relayed copy shares it
  final int rssi;           // dBm, from the last board it came from
  final int hops;           // times passed on
  final int bytes;          // on the air
  final int atMs;           // when it came
  const RadioCopy(this.broadcast, this.rssi, this.hops, this.bytes, this.atMs);

  Map<String, dynamic> toJson() => {'b': broadcast, 'r': rssi, 'h': hops, 'n': bytes, 't': atMs};
  static RadioCopy fromJson(Map<String, dynamic> j) => RadioCopy((j['b'] as num).toInt(), (j['r'] as num).toInt(),
      (j['h'] as num).toInt(), (j['n'] as num).toInt(), (j['t'] as num).toInt());
}

/// One packet on the air over direct comms: a text, or one of a long one's
/// parts, which its board sends [sends] times.
class RadioPacket {
  final int part;           // from 0
  final int? counter;       // its command's, null for a part that never came
  final int bytes;          // on the air: as sent, or as the first copy heard was
  final List<RadioCopy> copies;   // heard, as they came; more may come after it's shown
  RadioPacket(this.part, this.counter, this.bytes, [List<RadioCopy>? copies]) : copies = copies ?? [];

  /// The board's sends heard: copies but for those relayed twice.
  int get sendsHeard => {for (final c in copies) c.broadcast}.length;

  Map<String, dynamic> toJson() => {
        'p': part,
        if (counter != null) 'c': counter,
        'n': bytes,
        if (copies.isNotEmpty) 'x': [for (final c in copies) c.toJson()],
      };
  static RadioPacket fromJson(Map<String, dynamic> j) => RadioPacket(
      (j['p'] as num).toInt(),
      (j['c'] as num?)?.toInt(),
      (j['n'] as num?)?.toInt() ?? 0,
      [for (final c in j['x'] as List<dynamic>? ?? const []) RadioCopy.fromJson(c as Map<String, dynamic>)]);
}

/// The direct channel a text went on, as it was then.
class DirectChannelInfo {
  final String name;
  final String id;          // 8 hex digits
  final bool keyed;         // a passphrase; false for the open channel
  final int frequency;      // 1, 6 or 11
  final bool longRange;
  final String boardName;   // ours on it
  const DirectChannelInfo(this.name, this.id, this.keyed, this.frequency, this.longRange, this.boardName);

  Map<String, dynamic> toJson() => {'n': name, 'i': id, 'k': keyed, 'f': frequency, 'l': longRange, 'b': boardName};
  static DirectChannelInfo fromJson(Map<String, dynamic> j) => DirectChannelInfo(
      j['n'] as String? ?? '', j['i'] as String? ?? '', j['k'] == true, (j['f'] as num?)?.toInt() ?? 0,
      j['l'] == true, j['b'] as String? ?? '');
}

/// One way a text came (or went): over the server, or direct.
class MessageRoute {
  static const server = 'server', direct = 'direct';
  final String via;
  final int atMs;           // when it came, or went
  final String channel;     // where: the channel's name, or '' to one person
  final int bytes;          // what the way carried: a server text's HTML, the direct commands' text
  // The server's
  final String? host;
  // Direct's
  final DirectChannelInfo? radio;
  final int sends;          // each packet's sent this many times (COMMAND_SENDS)
  final List<RadioPacket> packets;

  MessageRoute(this.via, this.atMs,
      {this.channel = '', this.bytes = 0, this.host, this.radio, this.sends = 0, List<RadioPacket>? packets})
      : packets = packets ?? [];

  /// When the last copy came, of those heard.
  int? get lastCopyMs {
    int? last;
    for (final p in packets) {
      for (final c in p.copies) {
        if (last == null || c.atMs > last) last = c.atMs;
      }
    }
    return last;
  }

  /// When the first copy came, of those heard.
  int? get firstCopyMs {
    int? first;
    for (final p in packets) {
      for (final c in p.copies) {
        if (first == null || c.atMs < first) first = c.atMs;
      }
    }
    return first;
  }

  Map<String, dynamic> toJson() => {
        'v': via,
        't': atMs,
        if (channel.isNotEmpty) 'c': channel,
        if (bytes != 0) 'n': bytes,
        if (host != null) 'h': host,
        if (radio != null) 'r': radio!.toJson(),
        if (sends != 0) 's': sends,
        if (packets.isNotEmpty) 'p': [for (final p in packets) p.toJson()],
      };
  static MessageRoute fromJson(Map<String, dynamic> j) => MessageRoute(j['v'] as String? ?? '', (j['t'] as num).toInt(),
      channel: j['c'] as String? ?? '',
      bytes: (j['n'] as num?)?.toInt() ?? 0,
      host: j['h'] as String?,
      radio: j['r'] == null ? null : DirectChannelInfo.fromJson(j['r'] as Map<String, dynamic>),
      sends: (j['s'] as num?)?.toInt() ?? 0,
      packets: [for (final p in j['p'] as List<dynamic>? ?? const []) RadioPacket.fromJson(p as Map<String, dynamic>)]);
}

/// A text's details: who it was for, and each way it came or went, the
/// first first.
class MessageDetails {
  final int scope;          // OthersCommand.scope*: who it was for
  final List<MessageRoute> routes;
  MessageDetails(this.scope, [List<MessageRoute>? routes]) : routes = routes ?? [];

  Map<String, dynamic> toJson() => {'s': scope, 'r': [for (final r in routes) r.toJson()]};
  static MessageDetails fromJson(Map<String, dynamic> j) => MessageDetails((j['s'] as num?)?.toInt() ?? 0,
      [for (final r in j['r'] as List<dynamic>? ?? const []) MessageRoute.fromJson(r as Map<String, dynamic>)]);
}

/// A direct broadcast's length on the air for a command, as direct.c sends
/// it: its header, the type and who it's for, the command (body and
/// signature), then the tag.
int directFrameBytes(int commandBytes, {int targets = 0}) => 15 + 2 + 4 * targets + commandBytes + 8;
