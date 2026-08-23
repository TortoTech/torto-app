// Benchmarks the same work needed before an EPUB's first page can be shown.
//
// Real fixtures are discovered from torto/test-data so newly added books are
// covered without maintaining a filename list. Missing fixtures are skipped.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:torto/core/formats/epub_book_source.dart';
import 'package:torto/core/ir/ir.dart';
import 'package:torto/core/layout/layout_engine.dart';
import 'package:torto/core/layout/layout_types.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('benchmark EPUB first-page startup', () async {
    final directory = Directory('../torto/test-data');
    if (!directory.existsSync()) return;
    final files =
        directory
            .listSync()
            .whereType<File>()
            .where((file) => file.path.toLowerCase().endsWith('.epub'))
            .toList()
          ..sort((a, b) => a.lengthSync().compareTo(b.lengthSync()));

    const viewport = LayoutViewport(width: 360, height: 760);
    const style = ReaderStyle(
      baseFontSize: 18,
      lineHeight: 1.5,
      marginTop: 32,
      marginBottom: 32,
      marginLeft: 24,
      marginRight: 24,
    );
    const engine = LayoutEngine();

    for (final file in files) {
      var timer = Stopwatch()..start();
      final source = await EpubBookSource.fromFileInBackground(
        file.path,
        publicationIdHint: 'benchmark-${file.path}',
      );
      final openMs = timer.elapsedMilliseconds;

      timer = Stopwatch()..start();
      Section? section;
      var sectionIndex = 0;
      for (; sectionIndex < source.book.sectionCount; sectionIndex++) {
        final candidate = await source.parseSection(sectionIndex);
        if (candidate.blocks.isNotEmpty) {
          section = candidate;
          break;
        }
      }
      final parseMs = timer.elapsedMilliseconds;
      if (section == null) continue;

      timer = Stopwatch()..start();
      final images = <String, ui.Image>{};
      for (final block in section.blocks.whereType<ImageBlock>()) {
        final data = await source.resource(block.href);
        if (data == null) continue;
        try {
          images[block.href] = await _decodeReaderImage(data);
        } catch (_) {
          // Unsupported image resources are ignored by the app too.
        }
      }
      final imageMs = timer.elapsedMilliseconds;

      timer = Stopwatch()..start();
      final pages = engine.paginate(
        section,
        viewport,
        style,
        imageSizeResolver: (href) {
          final image = images[href];
          return image == null
              ? null
              : ui.Size(image.width.toDouble(), image.height.toDouble());
        },
      );
      final layoutMs = timer.elapsedMilliseconds;

      // ignore: avoid_print
      print(
        'OPEN ${file.uri.pathSegments.last} '
        'size=${(file.lengthSync() / 1024 / 1024).toStringAsFixed(2)}MB '
        'spine=$sectionIndex backgroundOpen=${openMs}ms '
        'parse=${parseMs}ms images=${imageMs}ms layout=${layoutMs}ms '
        'firstPage=${openMs + parseMs + imageMs + layoutMs}ms',
      );

      for (final page in pages) {
        page.dispose();
      }
      for (final image in images.values) {
        image.dispose();
      }
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}

Future<ui.Image> _decodeReaderImage(Uint8List bytes) async {
  const maxDimension = 2048;
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  try {
    final codec = await ui.instantiateImageCodecWithSize(
      buffer,
      getTargetSize: (width, height) {
        final longest = math.max(width, height);
        if (longest <= maxDimension) return const ui.TargetImageSize();
        final scale = maxDimension / longest;
        return ui.TargetImageSize(
          width: math.max(1, (width * scale).round()),
          height: math.max(1, (height * scale).round()),
        );
      },
    );
    try {
      return (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
  } finally {
    buffer.dispose();
  }
}
