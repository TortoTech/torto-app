// Temporary repro: user reports 中国古代房内考 hangs "loading" on device.
// Times each pipeline stage so we can see where it stalls.
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torto/core/formats/epub_book_source.dart';
import 'package:torto/core/layout/layout_engine.dart';
import 'package:torto/core/layout/layout_types.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const path =
      '../torto/test-data/中国古代房内考：中国古代的性与社会 = Sexual Life in Ancient China  a Preliminary Survey of Chinese Sex and Society from Ca. 1500 B. C. Till… ([荷] 高罗佩 (Robert Hans van Gul... (z-library.sk, 1lib.sk, z-lib.sk).epub';

  const viewport = LayoutViewport(width: 360, height: 760);
  const style = ReaderStyle(
    baseFontSize: 18,
    lineHeight: 1.5,
    marginTop: 32,
    marginBottom: 32,
    marginLeft: 24,
    marginRight: 24,
  );

  test('repro: 房内考 open + paginate', () async {
    final file = File(path);
    if (!file.existsSync()) {
      print('SKIP (missing): $path');
      return;
    }
    final sw = Stopwatch()..start();
    final bytes = await file.readAsBytes();
    print('readAsBytes: ${sw.elapsedMilliseconds}ms');

    sw.reset();
    final source = await EpubBookSource.fromBytes(bytes);
    print(
      'fromBytes: ${sw.elapsedMilliseconds}ms, sections=${source.book.sectionCount}',
    );

    const engine = LayoutEngine();
    for (var i = 0; i < source.book.sectionCount && i < 50; i++) {
      sw.reset();
      final section = await source.parseSection(i);
      final parseMs = sw.elapsedMilliseconds;
      sw.reset();
      final pages = engine.paginate(section, viewport, style);
      final paginateMs = sw.elapsedMilliseconds;
      // Mirror ReaderController._preloadImages: fetch + decode every image.
      final hrefs = <String>{};
      for (final page in pages) {
        for (final item in page.items) {
          if (item is ImagePlacement) hrefs.add(item.href);
        }
      }
      sw.reset();
      var decoded = 0;
      for (final href in hrefs) {
        final imgBytes = await source.resource(href);
        if (imgBytes != null) {
          await decodeImageFromList(imgBytes);
          decoded++;
        }
      }
      print(
        'section $i: parse=${parseMs}ms paginate=${paginateMs}ms images=$decoded/${hrefs.length} in ${sw.elapsedMilliseconds}ms pages=${pages.length}',
      );
    }
    print('DONE');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
