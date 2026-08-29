import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:torto/core/formats/image_dimensions.dart';

void main() {
  test('reads PNG dimensions and recognizes a thin ornament', () {
    final bytes = Uint8List(24)
      ..setAll(0, const [0x89, 0x50, 0x4e, 0x47])
      ..setAll(16, const [0, 0, 0, 128])
      ..setAll(20, const [0, 0, 0, 4]);

    expect(readImageDimensions(bytes), (128, 4));
    expect(isDecorativeSeparatorImage(bytes), isTrue);
  });

  test('reads GIF dimensions but rejects ordinary artwork', () {
    final bytes = Uint8List.fromList([
      0x47,
      0x49,
      0x46,
      0x38,
      0x39,
      0x61,
      0x40,
      0x01,
      0xf0,
      0x00,
    ]);

    expect(readImageDimensions(bytes), (320, 240));
    expect(isDecorativeSeparatorImage(bytes), isFalse);
  });

  test('reads JPEG dimensions from a start-of-frame segment', () {
    final bytes = Uint8List.fromList([
      0xff,
      0xd8,
      0xff,
      0xc0,
      0x00,
      0x11,
      0x08,
      0x00,
      0x06,
      0x00,
      0x60,
      0x03,
      0x01,
      0x11,
      0x00,
      0x02,
      0x11,
      0x00,
      0x03,
      0x11,
      0x00,
    ]);

    expect(readImageDimensions(bytes), (96, 6));
    expect(isDecorativeSeparatorImage(bytes), isTrue);
  });

  test('rejects unsupported and truncated image data', () {
    expect(readImageDimensions(Uint8List.fromList([1, 2, 3])), isNull);
    expect(isDecorativeSeparatorImage(Uint8List(0)), isFalse);
  });
}
