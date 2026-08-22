import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:torto/core/formats/epub_book_source.dart';
import 'package:torto/core/ir/ir.dart';

/// Integration smoke tests against real books from the torto repo's
/// test-data directory. Each test skips gracefully when the file is absent.
void main() {
  const books = <String, int?>{
    'Structured Writing Rhetoric and Process.epub': null,
    '数学觉醒学会更清晰地思考.epub': 1000, // assert total blocks > 1000
    'On Web Typography (Jason Santa Maria [Santa Maria, Jason]) (z-library.sk, 1lib.sk, z-lib.sk).epub':
        null,
  };

  for (final entry in books.entries) {
    test('opens and parses: ${entry.key}', () async {
      final file = File('../torto/test-data/${entry.key}');
      if (!file.existsSync()) {
        // ignore: avoid_print
        print('SKIP: ${file.path} not found');
        return;
      }
      final bytes = await file.readAsBytes();
      final source = await EpubBookSource.fromBytes(bytes);
      final book = source.book;

      expect(book.metadata.title, isNotEmpty);
      expect(book.spine, isNotEmpty);
      expect(book.toc, isNotEmpty);

      var failures = 0;
      var totalBlocks = 0;
      final imageHrefs = <String>[];
      for (var i = 0; i < book.spine.length; i++) {
        final section = await source.parseSection(i);
        if (section.blocks.isEmpty) failures++;
        totalBlocks += section.blocks.length;
        for (final block in section.blocks) {
          if (block is ImageBlock && imageHrefs.length < 8) {
            imageHrefs.add(block.href);
          }
        }
      }
      final failureRate = failures / book.spine.length;
      // ignore: avoid_print
      print(
          '${entry.key}: sections=${book.spine.length} failures=$failures '
          '(${100 * failureRate}% ) blocks=$totalBlocks toc=${book.toc.length} '
          'title="${book.metadata.title}"');
      expect(failureRate, lessThan(0.10));
      final minBlocks = entry.value;
      if (minBlocks != null) {
        expect(totalBlocks, greaterThan(minBlocks));
      }

      // Image resources must be fetchable by their resolved hrefs.
      var checked = 0;
      for (final href in imageHrefs) {
        expect(href, isNotEmpty);
        final resource = await source.resource(href);
        expect(resource, isNotNull, reason: 'missing resource: $href');
        checked++;
      }
      // Most real books have images; do not require any, but report.
      // ignore: avoid_print
      print('${entry.key}: checked $checked image resources');
    }, timeout: const Timeout(Duration(minutes: 5)));
  }
}
