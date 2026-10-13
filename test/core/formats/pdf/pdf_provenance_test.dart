import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:torto/core/formats/pdf/pdf_provenance.dart';

void main() {
  test('packed provenance matches the desktop bincode field order', () {
    final anchor = {'spine': 's', 'node': 'n', 'text_offset': 0};
    final bytes = encodePdfProvenance([
      {
        'source': {
          'start': anchor,
          'end': {...anchor, 'text_offset': 1},
        },
        'page': 0,
        'rect': [1, 2, 3, 4],
        'original_glyph': 0,
      },
    ]);
    expect(ascii.decode(bytes.sublist(0, 8)), 'TRTPRV01');
    final expected = BytesBuilder()..add([1, 1, 115, 1, 110, 1, 0, 0, 0, 1, 0]);
    for (final value in [1, 2, 3, 4]) {
      expected.add(
        (ByteData(
          8,
        )..setFloat64(0, value.toDouble(), Endian.little)).buffer.asUint8List(),
      );
    }
    expected.addByte(0);
    expect(ZLibCodec().decode(bytes.sublist(8)), expected.toBytes());
  });
  test(
    'empty sidecars retain the versioned envelope and two empty vectors',
    () {
      final bytes = encodePdfProvenance([]);
      expect(ZLibCodec().decode(bytes.sublist(8)), [0, 0]);
    },
  );
}
