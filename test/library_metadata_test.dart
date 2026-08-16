import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torto/app/library/library_page.dart';
import 'package:torto/app/library/library_store.dart';

const _container = '''<?xml version="1.0"?>
<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles>
</container>''';

const _opf = '''<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>Metadata Book</dc:title>
    <dc:creator>Alice</dc:creator>
    <dc:creator>Bob</dc:creator>
    <dc:language>zh-CN</dc:language>
    <dc:language>en</dc:language>
  </metadata>
  <manifest>
    <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
    <item id="cover" href="cover.png" media-type="image/png" properties="cover-image"/>
  </manifest>
  <spine><itemref idref="chapter"/></spine>
</package>''';

Uint8List _epubBytes() {
  final archive = Archive()
    ..addFile(ArchiveFile.string('META-INF/container.xml', _container))
    ..addFile(ArchiveFile.string('OPS/book.opf', _opf))
    ..addFile(
      ArchiveFile.string(
        'OPS/chapter.xhtml',
        '<html xmlns="http://www.w3.org/1999/xhtml"><body>Book</body></html>',
      ),
    );
  final cover = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
  );
  archive.addFile(ArchiveFile('OPS/cover.png', cover.length, cover));
  return ZipEncoder().encodeBytes(archive);
}

class _FakeLibraryStore extends LibraryStore {
  final List<LibraryBook> books;

  _FakeLibraryStore(this.books)
    : super(booksDir: Directory('test/__unused_library__'));

  @override
  Future<List<LibraryBook>> list() async => books;
}

void main() {
  test('LibraryStore parses and caches EPUB shelf metadata', () async {
    final directory = await Directory.systemTemp.createTemp(
      'torto-library-metadata-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}${Platform.pathSeparator}fixture.epub');
    await file.writeAsBytes(_epubBytes());

    final store = LibraryStore(booksDir: directory);
    final books = await store.list();

    expect(books, hasLength(1));
    expect(books.single.title, 'Metadata Book');
    expect(books.single.authors, ['Alice', 'Bob']);
    expect(books.single.languages, ['zh-CN', 'en']);
    expect(books.single.coverBytes, isNotEmpty);
    expect(await File('${file.path}.metadata.json').exists(), isTrue);
    expect(await File('${file.path}.cover').exists(), isTrue);

    final cached = await store.list();
    expect(cached.single.title, 'Metadata Book');
    expect(cached.single.coverBytes, books.single.coverBytes);

    await store.delete(file);
    expect(await file.exists(), isFalse);
    expect(await File('${file.path}.metadata.json').exists(), isFalse);
    expect(await File('${file.path}.cover').exists(), isFalse);
  });

  testWidgets('LibraryPage displays metadata and a fallback cover', (
    tester,
  ) async {
    final store = _FakeLibraryStore([
      LibraryBook(
        file: File('metadata.epub'),
        title: 'Metadata Book',
        authors: const ['Alice', 'Bob'],
        languages: const ['zh-CN', 'en'],
        sizeBytes: 4096,
      ),
    ]);
    await tester.pumpWidget(MaterialApp(home: LibraryPage(store: store)));
    await tester.pump();

    expect(find.text('Metadata Book'), findsOneWidget);
    expect(find.text('Alice / Bob'), findsOneWidget);
    expect(find.textContaining('zh-CN'), findsNothing);
    expect(find.textContaining('KB'), findsNothing);
    expect(find.byIcon(Icons.book_outlined), findsOneWidget);
  });
}
