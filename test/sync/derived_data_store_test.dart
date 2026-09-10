import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:torto/app/sync/derived_data_store.dart';
import 'package:torto/core/ir/ir.dart';

void main() {
  late Directory temporary;
  late Directory books;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('torto-derived-test-');
    books = Directory('${temporary.path}${Platform.pathSeparator}books');
    await books.create();
  });

  tearDown(() => temporary.delete(recursive: true));

  test(
    'applies generated metadata and turns flat PDF entries into a tree',
    () async {
      const bookId = 'book-id';
      final derived = Directory(
        '${temporary.path}${Platform.pathSeparator}derived-sync-v1'
        '${Platform.pathSeparator}$bookId',
      );
      await derived.create(recursive: true);
      await File(
        '${derived.path}${Platform.pathSeparator}metadata.json',
      ).writeAsString(
        jsonEncode({
          'version': 1,
          'book_id': bookId,
          'metadata': {
            'version': 1,
            'book_id': bookId,
            'metadata': {
              'title': 'Generated title',
              'authors': ['Alice'],
              'provider_name': 'provider',
              'model': 'model',
            },
          },
          'toc': {
            'version': 1,
            'book_id': bookId,
            'verified_pages': true,
            'page_mapping_revision': 2,
            'entries': [
              {'depth': 0, 'title': 'Chapter', 'physical_page': 1},
              {'depth': 1, 'title': 'Section', 'physical_page': 2},
            ],
          },
        }),
      );
      final store = DerivedDataStore.fromBooksDirectory(books);
      final book = Book(
        id: bookId,
        metadata: const BookMetadata(),
        spine: const [
          SpineItem(id: SpineItemId.generated(0), index: 0, href: 'page:0'),
          SpineItem(id: SpineItemId.generated(1), index: 1, href: 'page:1'),
        ],
      );

      final metadata = await store.metadata(bookId);
      final toc = await store.generatedToc(bookId, book);

      expect(metadata?.title, 'Generated title');
      expect(metadata?.authors, ['Alice']);
      expect(toc.single.label, 'Chapter');
      expect(toc.single.children.single.label, 'Section');
      expect(toc.single.children.single.spineIndex, 1);
    },
  );
}
