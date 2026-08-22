import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:torto/core/formats/mobi/mobi_book_source.dart';
import 'package:torto/core/formats/mobi/mobi_kf8.dart';
import 'package:torto/core/ir/ir.dart';

void main() {
  test('decompresses PalmDOC literals, back-references, and spaces', () {
    final compressed = Uint8List.fromList([
      3, 0x61, 0x62, 0x63, // literal run "abc"
      0x80, 0x18, // back-reference distance 4 length 3 → "abc"
      0xc1, // 0xc0|0x01 → " A"
    ]);
    expect(utf8.decode(decompressPalmDocForTest(compressed)), 'abcabc A');
  });

  test('detects navigation documents vs authored contents pages', () {
    expect(
      isNavigationDocumentForTest(
        '<html><body><nav epub:type="toc"><ol><li>One</li></ol></nav></body></html>',
      ),
      isTrue,
    );
    expect(
      isNavigationDocumentForTest(
        '<html><body><h2>Table of Contents</h2><ul><li>One</li></ul></body></html>',
      ),
      isFalse,
    );
  });

  test('normalizes MOBI HTML and embedded images', () {
    const body = '<a id="chapter-start"></a>'
        '<h1 aid="kindle-heading">Title</h1>'
        '<p>Hello &amp; world</p>'
        '<img recindex="00001">';
    final normalized = normalizeChapter(body, {1: 'Images/image-1.jpg'});
    expect(normalized, contains('<h1 id="kindle-heading">Title</h1>'));
    expect(normalized, contains('<a id="chapter-start"></a>'));
    expect(normalized, contains('Hello &amp; world'));
    expect(normalized, contains('src="../Images/image-1.jpg"'));
  });

  test('opens a MOBI6 fixture with metadata, sections, and cover', () async {
    final bytes = _mobi6Fixture();
    final source = await openMobi(bytes, 'fixture.mobi');

    expect(source.book.metadata.title, 'Native MOBI');
    expect(source.book.metadata.authors, ['Test Author']);
    expect(source.book.metadata.languages, ['en']);
    expect(source.book.coverHref, 'Images/kindle-1.png');
    expect(source.book.spine, hasLength(2));
    final first = await source.parseSection(0);
    expect(first.blocks, hasLength(greaterThanOrEqualTo(2)));
    expect(
      first.blocks.whereType<TextBlock>().map((b) => b.plainText),
      contains('Hello & world.'),
    );
    final second = await source.parseSection(1);
    expect(second.blocks, isNotEmpty);
    expect(await source.resource('Images/kindle-1.png'), isNotNull);
  });

  test('rejects non-MOBI bytes', () async {
    expect(
      () => openMobi(Uint8List.fromList(List.filled(128, 0)), 'x.mobi'),
      throwsFormatException,
    );
  });

  // Real books from ../torto/test-data (skipped when absent).
  for (final name in const ['1.mobi', '1.azw3', 'Lifestyle Gurus.azw3']) {
    test('opens and parses real book: $name', () async {
      final file = File('../torto/test-data/$name');
      if (!file.existsSync()) {
        // ignore: avoid_print
        print('SKIP: ${file.path} not found');
        return;
      }
      final source = await openMobi(
        await file.readAsBytes(),
        name,
      );
      final book = source.book;
      // ignore: avoid_print
      print(
        '$name: title="${book.metadata.title}" sections=${book.spine.length} '
        'toc=${book.toc.length} cover=${book.coverHref} '
        'resources=${await _resourceCount(source)}',
      );
      expect(book.metadata.title, isNotEmpty);
      expect(book.spine, isNotEmpty);

      var failures = 0;
      var totalBlocks = 0;
      final imageHrefs = <String>{};
      for (var i = 0; i < book.spine.length; i++) {
        final section = await source.parseSection(i);
        if (section.blocks.isEmpty) failures++;
        totalBlocks += section.blocks.length;
        for (final block in section.blocks) {
          if (block is ImageBlock) imageHrefs.add(block.href);
        }
      }
      // ignore: avoid_print
      print(
        '$name: blocks=$totalBlocks failures=$failures images=${imageHrefs.length}',
      );
      expect(failures / book.spine.length, lessThan(0.10));
      expect(totalBlocks, greaterThan(20));

      var checked = 0;
      for (final href in imageHrefs.take(8)) {
        final resource = await source.resource(href);
        expect(resource, isNotNull, reason: 'missing image $href');
        checked++;
      }
      // ignore: avoid_print
      print('$name: verified $checked image resources');
    });
  }
}

Future<int> _resourceCount(BookSource source) async {
  var count = 0;
  for (var i = 0; i < source.book.spine.length; i++) {
    final section = await source.parseSection(i);
    for (final block in section.blocks) {
      if (block is ImageBlock && await source.resource(block.href) != null) {
        count++;
      }
    }
  }
  return count;
}

// ------------------------------------------------------------ mobi6 fixture

Uint8List _mobi6Fixture() {
  final title = utf8.encode('Native MOBI');
  final text = utf8.encode(
    '<html><body><h1>One</h1><p>Hello &amp; world.</p>'
    '<img recindex=00001></body></html><mbp:pagebreak/>'
    '<html><body><h1>Two</h1><p>Second.</p></body></html>',
  );
  final exth = _exth([
    (100, utf8.encode('Test Author')),
    (524, utf8.encode('en')),
    (201, Uint8List.fromList([0, 0, 0, 0])),
  ]);
  const mobiHeaderLength = 232;
  final exthOffset = 16 + mobiHeaderLength;
  final titleOffset = exthOffset + exth.length;
  final recordZero = ByteData(titleOffset + title.length);
  void putU16(int offset, int value) => recordZero.setUint16(offset, value);
  void putU32(int offset, int value) => recordZero.setUint32(offset, value);
  putU16(0, 1); // compression: none
  putU32(4, text.length);
  putU16(8, 1); // one text record
  putU16(10, 4096); // record size
  recordZero.setUint32(16, 0x4d4f4249); // 'MOBI'
  putU32(20, mobiHeaderLength);
  putU32(24, 2); // mobi type: book
  putU32(28, 65001); // UTF-8
  putU32(32, 42);
  putU32(36, 6); // file version 6
  putU32(84, titleOffset);
  putU32(88, title.length);
  recordZero.setUint8(95, 9); // locale: English
  putU32(108, 2); // first resource record
  putU32(112, 0xffffffff); // no HUFF
  putU32(128, 0x40); // EXTH present
  putU32(244, 0xffffffff); // no NCX
  recordZero.buffer
      .asUint8List()
      .setRange(exthOffset, exthOffset + exth.length, exth);
  recordZero.buffer.asUint8List().setRange(
        titleOffset,
        titleOffset + title.length,
        title,
      );

  final cover = Uint8List.fromList([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
  ]);
  final records = [
    recordZero.buffer.asUint8List(),
    Uint8List.fromList(text),
    cover,
  ];
  final headerLength = 78 + records.length * 8;
  final output = BytesBuilder();
  final header = Uint8List(headerLength);
  header.setRange(0, title.length, title); // PDB name
  header.setRange(60, 68, utf8.encode('BOOKMOBI'));
  ByteData.view(header.buffer).setUint16(76, records.length);
  var offset = headerLength;
  for (var index = 0; index < records.length; index++) {
    ByteData.view(header.buffer).setUint32(78 + index * 8, offset);
    offset += records[index].length;
  }
  output.add(header);
  for (final record in records) {
    output.add(record);
  }
  return output.takeBytes();
}

Uint8List _exth(List<(int, List<int>)> entries) {
  final length = 12 +
      entries.fold<int>(0, (sum, entry) => sum + 8 + entry.$2.length);
  final padded = (length + 3) & ~3;
  final output = Uint8List(padded);
  final view = ByteData.view(output.buffer);
  output.setRange(0, 4, utf8.encode('EXTH'));
  view.setUint32(4, padded);
  view.setUint32(8, entries.length);
  var position = 12;
  for (final (kind, data) in entries) {
    view.setUint32(position, kind);
    view.setUint32(position + 4, 8 + data.length);
    output.setRange(position + 8, position + 8 + data.length, data);
    position += 8 + data.length;
  }
  return output;
}
