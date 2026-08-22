import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torto/core/formats/formats.dart';

void main() {
  test('detects every supported extension', () {
    BookFormat? detect(String name) => BookFormat.fromFileName(name);
    expect(detect('book.EPUB'), BookFormat.epub);
    expect(detect('book.mobi'), BookFormat.mobi);
    expect(detect('book.azw'), BookFormat.azw);
    expect(detect('book.azw3'), BookFormat.azw3);
    expect(detect('book.fb2'), BookFormat.fb2);
    expect(detect('book.fbz'), BookFormat.fbz);
    expect(detect('book.fb2.zip'), BookFormat.fbz);
    expect(detect('book.cbz'), BookFormat.cbz);
    expect(detect('book.CHM'), BookFormat.chm);
    expect(detect('book.pdf'), BookFormat.pdf);
    expect(detect('book.txt'), isNull);
    expect(detect('noext'), isNull);
  });

  test('openable formats match the implemented sources', () {
    for (final format in BookFormat.values) {
      expect(format.openable, isTrue, reason: '$format');
    }
  });

  test('shelf extension filter accepts all library formats', () {
    expect(hasSupportedBookExtension('a.EPUB'), isTrue);
    expect(hasSupportedBookExtension('a.fb2'), isTrue);
    expect(hasSupportedBookExtension('a.fbz'), isTrue);
    expect(hasSupportedBookExtension('a.fb2.zip'), isTrue);
    expect(hasSupportedBookExtension('a.cbz'), isTrue);
    expect(hasSupportedBookExtension('a.mobi'), isTrue);
    expect(hasSupportedBookExtension('a.azw'), isTrue);
    expect(hasSupportedBookExtension('a.azw3'), isTrue);
    expect(hasSupportedBookExtension('a.CHM'), isTrue);
    expect(hasSupportedBookExtension('a.PDF'), isTrue);
    expect(hasSupportedBookExtension('a.zip'), isFalse);
    expect(hasSupportedBookExtension('a.metadata.json'), isFalse);
  });

  test('openBook dispatches by detected format', () async {
    final cbz = ZipEncoder().encodeBytes(
      Archive()..addFile(ArchiveFile.string('001.png', 'page')),
    );
    final source = await openBook(cbz, 'comic.cbz');
    expect(source.book.spine, hasLength(1));
    expect(await source.resource('Images/page-00001.png'), utf8.encode('page'));
  });

  test('openBook rejects unknown formats and unreadable containers',
      () async {
    final bytes = Uint8List.fromList([1, 2, 3]);
    await expectLater(openBook(bytes, 'book.txt'), throwsFormatException);
    // Every supported format is detected but must be a readable container.
    await expectLater(openBook(bytes, 'book.mobi'), throwsFormatException);
    await expectLater(openBook(bytes, 'book.azw3'), throwsFormatException);
    await expectLater(openBook(bytes, 'book.chm'), throwsFormatException);
  });
}
