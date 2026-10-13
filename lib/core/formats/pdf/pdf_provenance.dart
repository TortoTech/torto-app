import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Desktop v14's TRTPRV01 envelope: a zlib-compressed bincode Packed value
/// with varint integers, UTF-8 node tuples and little-endian f64 rectangles.
Uint8List encodePdfProvenance(List<Map<String, dynamic>> slices) {
  final nodes = <(String, String)>[], indices = <(String, String), int>{};
  int node(Map anchor) {
    final key = (anchor['spine'] as String, anchor['node'] as String);
    return indices.putIfAbsent(key, () {
      nodes.add(key);
      return nodes.length - 1;
    });
  }

  for (final slice in slices) {
    node(slice['source']['start'] as Map);
    node(slice['source']['end'] as Map);
  }
  final output = BytesBuilder(copy: false);
  void integer(int value) {
    if (value < 0) throw const FormatException('Negative PDF provenance value');
    if (value < 251) {
      output.addByte(value);
      return;
    }
    final length = value <= 0xffff
        ? 2
        : value <= 0xffffffff
        ? 4
        : 8;
    output.addByte(
      length == 2
          ? 251
          : length == 4
          ? 252
          : 253,
    );
    final bytes = ByteData(length);
    if (length == 2) {
      bytes.setUint16(0, value, Endian.little);
    } else if (length == 4) {
      bytes.setUint32(0, value, Endian.little);
    } else {
      bytes.setUint64(0, value, Endian.little);
    }
    output.add(bytes.buffer.asUint8List());
  }

  void string(String value) {
    final bytes = utf8.encode(value);
    integer(bytes.length);
    output.add(bytes);
  }

  integer(nodes.length);
  for (final key in nodes) {
    string(key.$1);
    string(key.$2);
  }
  integer(slices.length);
  for (final slice in slices) {
    final start = slice['source']['start'] as Map,
        end = slice['source']['end'] as Map;
    integer(node(start));
    integer(start['text_offset'] as int);
    integer(node(end));
    integer(end['text_offset'] as int);
    integer(slice['page'] as int);
    for (final coordinate in slice['rect'] as List) {
      final value = (coordinate as num).toDouble();
      if (!value.isFinite) {
        throw const FormatException('Invalid PDF glyph rectangle');
      }
      final bytes = ByteData(8)..setFloat64(0, value, Endian.little);
      output.add(bytes.buffer.asUint8List());
    }
    integer(slice['original_glyph'] as int);
  }
  if (output.length > 32 * 1024 * 1024) {
    throw const FormatException('PDF provenance exceeds size limit');
  }
  return Uint8List.fromList([
    ...ascii.encode('TRTPRV01'),
    ...ZLibCodec(level: 1).encode(output.takeBytes()),
  ]);
}
