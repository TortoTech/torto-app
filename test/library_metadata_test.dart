import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:torto/app/library/library_page.dart';
import 'package:torto/app/library/library_store.dart';
import 'package:torto/app/progress_store.dart';

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

Uint8List _singlePagePdf() {
  List<int> ascii(String value) => Uint8List.fromList(value.codeUnits);
  final objects = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] '
        '/Contents 4 0 R >>',
    '<< /Length 0 >>\nstream\n\nendstream',
  ];
  final output = BytesBuilder(copy: false)..add(ascii('%PDF-1.4\n'));
  final offsets = <int>[];
  for (var index = 0; index < objects.length; index++) {
    offsets.add(output.length);
    output.add(ascii('${index + 1} 0 obj\n${objects[index]}\nendobj\n'));
  }
  final xref = output.length;
  output
    ..add(ascii('xref\n0 ${objects.length + 1}\n'))
    ..add(ascii('0000000000 65535 f \n'));
  for (final offset in offsets) {
    output.add(ascii('${offset.toString().padLeft(10, '0')} 00000 n \n'));
  }
  output.add(
    ascii(
      'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\n'
      'startxref\n$xref\n%%EOF\n',
    ),
  );
  return output.takeBytes();
}

class _FakeLibraryStore extends LibraryStore {
  final List<LibraryBook> books;

  _FakeLibraryStore(this.books)
    : super(booksDir: Directory('test/__unused_library__'));

  @override
  Future<List<LibraryBook>> list() async => books;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  test('LibraryStore lists every supported format', () async {
    final directory = await Directory.systemTemp.createTemp(
      'torto-library-formats-',
    );
    addTearDown(() => directory.delete(recursive: true));

    final fb2 = '''
<?xml version="1.0" encoding="UTF-8"?>
<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0">
  <description><title-info><book-title>FB2 书架书</book-title><lang>ru</lang></title-info></description>
  <body><section><title><p>章</p></title><p>正文</p></section></body>
</FictionBook>''';
    await File(
      '${directory.path}${Platform.pathSeparator}shelf.fb2',
    ).writeAsString(fb2);

    final cbz = ZipEncoder().encodeBytes(
      Archive()..addFile(ArchiveFile.string('001.png', 'page')),
    );
    await File(
      '${directory.path}${Platform.pathSeparator}shelf.cbz',
    ).writeAsBytes(cbz);
    // Neither a shelf format nor a book: ignored by the listing.
    await File(
      '${directory.path}${Platform.pathSeparator}note.txt',
    ).writeAsString('x');
    await File(
      '${directory.path}${Platform.pathSeparator}shelf.fb2.cover',
    ).writeAsBytes([1]);

    final books = await LibraryStore(booksDir: directory).list();
    expect(
      books.map((book) => book.title),
      unorderedEquals(['FB2 书架书', 'shelf']),
    );
  });

  test('remote books use a content-addressed storage name', () async {
    final directory = await Directory.systemTemp.createTemp(
      'torto-remote-library-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final bytes = _epubBytes();
    final contentId = sha256.convert(bytes).toString();
    final downloaded = File(
      '${directory.path}${Platform.pathSeparator}$contentId.part',
    );
    await downloaded.writeAsBytes(bytes);
    final remoteName =
        '${List.filled(20, 'A very long remote title ').join()}.epub';
    final remoteCover = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    );

    final installed = await LibraryStore(booksDir: directory).installDownloaded(
      downloaded,
      contentId,
      remoteName,
      remoteTitle: 'Remote Manifest Title',
      remoteAuthors: const ['Remote Author'],
      remoteCoverBytes: remoteCover,
      remoteAddedAt: 42,
    );

    expect(
      installed.path,
      '${directory.path}${Platform.pathSeparator}$contentId.epub',
    );
    expect(await installed.exists(), isTrue);
    final book = (await LibraryStore(booksDir: directory).list()).single;
    expect(book.title, 'Remote Manifest Title');
    expect(book.authors, ['Remote Author']);
    expect(book.coverBytes, remoteCover);
    expect(book.addedAt, 42);
  });

  test('cached PDFs get a generated first-page cover', () async {
    final directory = await Directory.systemTemp.createTemp('torto-pdf-cover-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}${Platform.pathSeparator}book.pdf');
    await file.writeAsBytes(_singlePagePdf());
    final stat = await file.stat();
    await File('${file.path}.metadata.json').writeAsString(
      jsonEncode({
        'version': 2,
        'sizeBytes': stat.size,
        'modifiedMillis': stat.modified.millisecondsSinceEpoch,
        'id': List.filled(64, 'a').join(),
        'addedAt': 1,
        'title': 'PDF Book',
        'authors': <String>[],
        'languages': <String>[],
        'hasCover': false,
      }),
    );
    final book = (await LibraryStore(booksDir: directory).list()).single;

    expect(book.coverBytes, isNotNull);
    expect(book.coverBytes!.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
    expect(await File('${file.path}.cover').readAsBytes(), book.coverBytes);
  });

  testWidgets('LibraryPage displays metadata and a fallback cover', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final progressStore = ProgressStore(await SharedPreferences.getInstance());
    final store = _FakeLibraryStore([
      LibraryBook(
        file: File('metadata.epub'),
        title: 'Metadata Book',
        authors: const ['Alice', 'Bob'],
        languages: const ['zh-CN', 'en'],
        sizeBytes: 4096,
      ),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: LibraryPage(store: store, progressStore: progressStore),
      ),
    );
    await tester.pump();

    final title = tester.widget<Text>(find.text('Metadata Book'));
    expect(title.maxLines, 1);
    expect(title.overflow, TextOverflow.ellipsis);
    expect(find.text('Alice / Bob'), findsNothing);
    expect(find.textContaining('zh-CN'), findsNothing);
    expect(find.textContaining('KB'), findsNothing);
    expect(find.byIcon(Icons.book_outlined), findsOneWidget);
  });

  testWidgets('LibraryPage scrolls through the complete library', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final progressStore = ProgressStore(await SharedPreferences.getInstance());
    final books = List.generate(
      16,
      (index) => LibraryBook(
        id: 'book-${index.toString().padLeft(2, '0')}',
        file: File('book-$index.epub'),
        title: 'Book ${index.toString().padLeft(2, '0')}',
        sizeBytes: 1,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: LibraryPage(
          store: _FakeLibraryStore(books),
          progressStore: progressStore,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Book 00'), findsOneWidget);
    expect(find.text('Book 15'), findsNothing);
    final grid = tester.widget<GridView>(find.byType(GridView));
    final delegate =
        grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
    expect(delegate.crossAxisCount, 3);
    await tester.scrollUntilVisible(
      find.text('Book 15'),
      700,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Book 15'), findsOneWidget);
  });

  test('shelf sorting uses the latest read or import time', () {
    final books = [
      LibraryBook(
        id: 'a',
        file: File('a.epub'),
        title: 'A',
        sizeBytes: 1,
        addedAt: 100,
      ),
      LibraryBook(
        id: 'b',
        file: File('b.epub'),
        title: 'B',
        sizeBytes: 1,
        addedAt: 300,
      ),
      LibraryBook(
        id: 'c',
        file: File('c.epub'),
        title: 'C',
        sizeBytes: 1,
        addedAt: 200,
      ),
    ];

    sortShelfBooks(books, {'a': 400, 'b': 250});

    expect(books.map((book) => book.id), ['a', 'b', 'c']);
  });
}
