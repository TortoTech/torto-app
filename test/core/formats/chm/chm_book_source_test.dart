import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:torto/core/formats/chm/chm_book_source.dart';
import 'package:torto/core/html_ir/tolerant_xml.dart';
import 'package:torto/core/ir/ir.dart';
import 'package:xml/xml.dart';

void main() {
  test('parses nested HTML help contents (.hhc)', () {
    final entries = parseHhc('''
      <html><body><ul>
        <li><object type="text/sitemap"><param name="Name" value="Chapter 1">
            <param name="Local" value="book/ch1.html"></object>
          <ul><li><object type="text/sitemap"><param name="Name" value="Part A">
              <param name="Local" value="book/ch1.html#a"></object></ul>
        <li><object type="text/sitemap"><param name="Name" value="Chapter 2">
            <param name="Local" value="book/ch2.html"></object>
      </ul></body></html>''');

    expect(entries, hasLength(2));
    expect(entries[0].label, 'Chapter 1');
    expect(entries[0].children.single.label, 'Part A');
    expect(entries[1].target, 'book/ch2.html');
  });

  test('repairs legacy HTML into reading-IR-compatible XHTML', () {
    final xhtml = htmlToXhtml(
      '<HTML><HEAD><META charset=windows-1252><title>Legacy</title></HEAD>'
      '<BODY><p>One&nbsp;two<br><img src="images/a.jpg"></BODY></HTML>',
    );
    // Must be well-formed XML for the strict IR parser.
    final document = tryParseXmlTolerant(xhtml);
    expect(document, isNotNull);
    final paragraph = document!.descendants
        .whereType<XmlElement>()
        .firstWhere((element) => element.name.local == 'p');
    expect(paragraph.innerText, contains('\u00A0'));
    expect(
      document.descendants.whereType<XmlElement>().any(
            (element) => element.name.local == 'img',
          ),
      isTrue,
    );
  });

  test('converts body-level layout tables to divs and drops spacers', () {
    final xhtml = htmlToXhtml(
      '<html><body><table><tr><td width="100%">Cell text</td></tr></table>'
      '<p><img src="a.gif" alt="previous page" width="1" height="1"></p></body></html>',
    );
    expect(xhtml.toLowerCase(), isNot(contains('<table')));
    expect(xhtml.toLowerCase(), isNot(contains('previous')));
    expect(xhtml, contains('Cell text'));
  });

  test('detects html metadata: title, author, cover', () {
    final metadata = inspectHtml('''
      <html><head><title>Sample Manual</title>
      <meta name="author" content="Alice"></head>
      <body><h1>Intro</h1><img src="img/COVER.png" alt="cover"></body></html>
    ''');
    expect(metadata.title, 'Sample Manual');
    expect(metadata.authors, contains('Alice'));
    expect(metadata.coverTarget, 'img/COVER.png');
  });

  test('rejects non-CHM bytes', () {
    expect(
      () => openChm(Uint8List.fromList(List.filled(128, 0)), 'x.chm'),
      throwsFormatException,
    );
  });

  // Mirrors torto's (locally-ignored) desktop fixture test.
  test('opens the real Information Dashboard Design fixture', () async {
    final directory = Directory('../torto/test-data');
    if (!directory.existsSync()) return;
    final chmFile = directory.listSync().firstWhere(
          (entity) => entity.path.toLowerCase().endsWith('.chm'),
          orElse: () => throw StateError('no fixture'),
        );
    final source = await openChm(
      chmFile is File ? chmFile.readAsBytesSync() : Uint8List(0),
      'fixture.chm',
    );

    expect(source.book.metadata.title, 'Information Dashboard Design');
    expect(
      source.book.metadata.authors.any((a) => a.contains('Stephen Few')),
      isTrue,
    );
    expect(source.book.spine.length, greaterThan(50));
    expect(source.book.toc.length, greaterThan(5));
    expect(source.book.coverHref, isNotNull);

    var imageCount = 0;
    for (var index = 0; index < source.book.spine.length; index++) {
      final section = await source.parseSection(index);
      expect(section.blocks, isNotEmpty, reason: 'empty CHM section $index');
      for (final block in section.blocks) {
        if (block is ImageBlock) {
          expect(
            await source.resource(block.href),
            isNotNull,
            reason: 'missing CHM image ${block.href}',
          );
          imageCount++;
        }
      }
    }
    expect(imageCount, greaterThan(10));
  });
}
