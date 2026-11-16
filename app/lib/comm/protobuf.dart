/// Just enough protocol buffers for Mumble's control messages: writing
/// varints, strings and bytes, and reading any message into its fields.
library;

import 'dart:convert';
import 'dart:typed_data';

class ProtoWriter {
  final BytesBuilder _out = BytesBuilder();

  void _varint(int v) {
    // Unsigned, up to 64 bits.
    while (true) {
      final b = v & 0x7F;
      v = v >>> 7;
      if (v == 0) {
        _out.addByte(b);
        return;
      }
      _out.addByte(b | 0x80);
    }
  }

  void int_(int field, int value) {
    _varint(field << 3);
    _varint(value);
  }

  void bool_(int field, bool value) => int_(field, value ? 1 : 0);

  void bytes(int field, List<int> value) {
    _varint((field << 3) | 2);
    _varint(value.length);
    _out.add(value);
  }

  void string(int field, String value) => bytes(field, utf8.encode(value));

  /// A repeated varint field, packed.
  void packed(int field, List<int> values) {
    final inner = ProtoWriter();
    for (final v in values) {
      inner._varint(v);
    }
    bytes(field, inner.toBytes());
  }

  Uint8List toBytes() => _out.toBytes();
}

/// A message's fields by number. Repeated fields keep every value, in order.
/// Varints are ints, length-delimited fields are bytes, and fixed 32 and 64
/// bit fields are ints of their raw bits.
class ProtoMessage {
  final Map<int, List<Object>> fields = {};

  ProtoMessage.parse(Uint8List data) {
    var i = 0;
    int varint() {
      var v = 0, shift = 0;
      while (true) {
        if (i >= data.length) throw const FormatException('protobuf: truncated varint');
        final b = data[i++];
        v |= (b & 0x7F) << shift;
        shift += 7;
        if (b & 0x80 == 0) return v;
      }
    }

    while (i < data.length) {
      final key = varint();
      final number = key >> 3;
      Object value;
      switch (key & 7) {
        case 0:
          value = varint();
        case 1:
          if (i + 8 > data.length) throw const FormatException('protobuf: truncated');
          value = ByteData.sublistView(data, i, i + 8).getUint64(0, Endian.little);
          i += 8;
        case 2:
          final len = varint();
          if (i + len > data.length) throw const FormatException('protobuf: truncated');
          value = Uint8List.sublistView(data, i, i + len);
          i += len;
        case 5:
          if (i + 4 > data.length) throw const FormatException('protobuf: truncated');
          value = ByteData.sublistView(data, i, i + 4).getUint32(0, Endian.little);
          i += 4;
        default:
          throw FormatException('protobuf: wire type ${key & 7}');
      }
      fields.putIfAbsent(number, () => []).add(value);
    }
  }

  bool has(int field) => fields.containsKey(field);

  int? int_(int field) {
    final v = fields[field]?.last;
    return v is int ? v : null;
  }

  bool? bool_(int field) {
    final v = int_(field);
    return v == null ? null : v != 0;
  }

  Uint8List? bytes(int field) {
    final v = fields[field]?.last;
    return v is Uint8List ? v : null;
  }

  String? string(int field) {
    final v = bytes(field);
    return v == null ? null : utf8.decode(v, allowMalformed: true);
  }

  List<int> ints(int field) => [for (final v in fields[field] ?? const []) if (v is int) v];
}
