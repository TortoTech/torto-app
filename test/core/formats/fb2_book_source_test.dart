import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torto/core/formats/fb2_book_source.dart';
import 'package:torto/core/ir/ir.dart';

const _coverPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
    '+A8AAQUBAScY42YAAAAASUVORK5CYII=';

const _fb2 = '''<?xml version="1.0" encoding="UTF-8"?>
<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" xmlns:l="http://www.w3.org/1999/xlink">
  <description><title-info>
    <book-title>FB2 测试书</book-title>
    <author><first-name>三</first-name><last-name>张</last-name></author>
    <author><nickname>阿笔</nickname></author>
    <lang>zh-CN</lang>
    <coverpage><image l:href="#cover"/></coverpage>
  </title-info></description>
  <body>
    <section id="one"><title><p>第一章</p></title><p>正文内容</p><image l:href="#cover"/></section>
    <section id="two"><title><p>第二章</p></title><subtitle>副题</subtitle><p>第二段 <emphasis>强调</emphasis> 文本。</p><empty-line/><v>诗行</v></section>
  </body>
  <body name="notes"><section><title><p>注释</p></title><p>注 1</p></section></body>
  <binary id="cover" content-type="image/png">$_coverPngBase64</binary>
</FictionBook>''';

Uint8List _fb2Bytes() => Uint8List.fromList(utf8.encode(_fb2));

Uint8List _fbzBytes() => ZipEncoder().encodeBytes(
      Archive()
        ..addFile(ArchiveFile.string('book.fb2', _fb2))
        ..addFile(ArchiveFile.string('readme.txt', 'not a book')),
    );

void main() {
  test('converts metadata, cover, and sections', () async {
    final source = await openFb2(_fb2Bytes(), 'fixture.fb2');

    expect(source.book.id, sha256.convert(_fb2Bytes()).toString());
    expect(source.book.metadata.title, 'FB2 测试书');
    expect(source.book.metadata.authors, ['三 张', '阿笔']);
    expect(source.book.metadata.languages, ['zh-CN']);
    expect(source.book.coverHref, isNotNull);
    expect(await source.resource(source.book.coverHref!), isNotEmpty);

    // Two linear chapter sections, then the non-linear notes body.
    expect(source.book.spine, hasLength(3));
    expect(source.book.toc, hasLength(2));
    expect(source.book.toc.first.label, '第一章');

    final chapter = await source.parseSection(0);
    expect(
      chapter.blocks.whereType<TextBlock>(),
      isNotEmpty,
      reason: 'chapter text must survive the FB2→HTML→IR pipeline',
    );
    final image = chapter.blocks.whereType<ImageBlock>().single;
    expect(image.href, startsWith('Images/image-'));

    final second = await source.parseSection(1);
    // <title> becomes the first heading and <subtitle> the second.
    final headings = second.blocks
        .whereType<TextBlock>()
        .where((block) => block.kind == TextBlockKind.heading)
        .map((block) => block.plainText)
        .toList();
    expect(headings, containsAllInOrder(['第二章', '副题']));
  });

  test('opens zipped FBZ archives and plain .fb2.zip names', () async {
    for (final name in const ['fixture.fbz', 'fixture.fb2.zip']) {
      final source = await openFb2(_fbzBytes(), name);
      expect(source.book.metadata.title, 'FB2 测试书', reason: name);
      expect(source.book.spine, hasLength(3), reason: name);
    }
  });

  test('falls back to the file name title and section numbering', () async {
    const bare = '''
<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0">
  <body><p>裸正文</p></body>
</FictionBook>''';
    final source = await openFb2(
      Uint8List.fromList(utf8.encode(bare)),
      '无名之书.fb2',
    );
    expect(source.book.metadata.title, '无名之书');
    expect(source.book.spine, hasLength(1));
    expect(source.book.toc.first.label, '第 1 节');
  });

  test('rejects non-FictionBook and unreadable documents', () async {
    expect(
      () => openFb2(
        Uint8List.fromList(utf8.encode('<html><body>no</body></html>')),
        'x.fb2',
      ),
      throwsFormatException,
    );
    expect(
      () => openFb2(ZipEncoder().encodeBytes(Archive()), 'x.fbz'),
      throwsFormatException,
    );
    final empty = Uint8List.fromList(
      utf8.encode('<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"/>'),
    );
    expect(() => openFb2(empty, 'x.fb2'), throwsFormatException);
  });
}
