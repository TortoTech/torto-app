// Benchmark: parse + paginate real books from torto/test-data.
//
// Reports per-book timing (open, per-section parse, full-book pagination at a
// phone-like viewport). Runs in the flutter_test VM with the test font, so
// absolute numbers are a proxy — on-device numbers will differ. The goal is
// to catch pathological slowness and give a rough performance envelope.
//
// Books are referenced by relative path and skipped gracefully when absent.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:torto/core/formats/epub_book_source.dart';
import 'package:torto/core/layout/layout_engine.dart';
import 'package:torto/core/layout/layout_types.dart';

void main() {
  const books = [
    'Structured Writing Rhetoric and Process.epub',
    '数学觉醒学会更清晰地思考.epub',
    'How We Read Now _ Strategic Choices for Print, Screen, and -- Naomi S_ Baron; Professor of Linguistics Emerita Naomi S -- 2015 -- OUP Premium -- isbn13 9780190084097 -- 945d1049c302f6f7ab96634638a6f5cf -- Anna’s Arch.epub',
    '中国古代房内考：中国古代的性与社会.epub',
  ];

  // Phone-like logical viewport (e.g. 360x800 class device).
  const viewport = LayoutViewport(width: 360, height: 760);
  const style = ReaderStyle(
    baseFontSize: 18,
    lineHeight: 1.5,
    marginTop: 32,
    marginBottom: 32,
    marginLeft: 24,
    marginRight: 24,
  );

  for (final name in books) {
    test('benchmark: $name', () async {
      final file = File('../torto/test-data/$name');
      if (!file.existsSync()) {
        // ignore: avoid_print
        print('SKIP (missing): $name');
        return;
      }
      final sw = Stopwatch()..start();
      final bytes = await file.readAsBytes();
      final source = await EpubBookSource.fromBytes(bytes);
      final openMs = sw.elapsedMilliseconds;

      var parseMs = 0;
      var paginateMs = 0;
      var totalPages = 0;
      var totalBlocks = 0;
      var slowestSectionMs = 0;
      var slowestSection = -1;

      final engine = LayoutEngine();
      for (var i = 0; i < source.book.sectionCount; i++) {
        var t = Stopwatch()..start();
        final section = await source.parseSection(i);
        parseMs += t.elapsedMilliseconds;

        t = Stopwatch()..start();
        final pages = engine.paginate(section, viewport, style);
        final elapsed = t.elapsedMilliseconds;
        paginateMs += elapsed;
        if (elapsed > slowestSectionMs) {
          slowestSectionMs = elapsed;
          slowestSection = i;
        }
        totalPages += pages.length;
        totalBlocks += section.blocks.length;
        for (final page in pages) {
          page.dispose();
        }
      }

      // ignore: avoid_print
      print(
        'BENCH $name\n'
        '  size=${(bytes.length / 1024 / 1024).toStringAsFixed(1)}MB '
        'sections=${source.book.sectionCount} blocks=$totalBlocks pages=$totalPages\n'
        '  open=${openMs}ms parse=${parseMs}ms paginate=${paginateMs}ms '
        'total=${sw.elapsedMilliseconds}ms\n'
        '  paginate/section avg=${source.book.sectionCount == 0 ? 0 : paginateMs ~/ source.book.sectionCount}ms '
        'slowest=#$slowestSection ${slowestSectionMs}ms',
      );
    }, timeout: const Timeout(Duration(minutes: 10)));
  }
}
