import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torto/core/formats/cbz_book_source.dart';
import 'package:torto/core/ir/ir.dart';

Uint8List _cbzBytes() {
  final archive = Archive()
    ..addFile(ArchiveFile.string('002.png', 'second-page'))
    ..addFile(ArchiveFile.string('001.jpg', 'first-page'))
    ..addFile(
      ArchiveFile.string(
        'ComicInfo.xml',
        '<ComicInfo><Title>测试漫画</Title><Writer>甲, 乙;丙</Writer>'
        '<LanguageISO>zh-CN</LanguageISO></ComicInfo>',
      ),
    )
    ..addFile(ArchiveFile.string('__macosx/junk.png', 'resource fork'));
  return ZipEncoder().encodeBytes(archive);
}

void main() {
  test('sorts pages by name and reads ComicInfo metadata', () async {
    final bytes = _cbzBytes();
    final source = await openCbz(bytes, 'fallback.cbz');

    expect(source.book.id, sha256.convert(bytes).toString());
    expect(source.book.metadata.title, '测试漫画');
    expect(source.book.metadata.authors, ['甲', '乙', '丙']);
    expect(source.book.metadata.languages, ['zh-CN']);

    // __macosx junk is skipped; the other two pages are name-sorted.
    expect(source.book.spine, hasLength(2));
    final first = await source.parseSection(0);
    final block = first.blocks.single as ImageBlock;
    expect(block.href, 'Images/page-00001.jpg');
    expect(await source.resource(block.href), utf8.encode('first-page'));

    final second = await source.parseSection(1);
    expect((second.blocks.single as ImageBlock).href, 'Images/page-00002.png');

    // First page doubles as the cover.
    expect(source.book.coverHref, 'Images/page-00001.jpg');
    expect(await source.resource(source.book.coverHref!), isNotEmpty);
  });

  test('falls back to the file name without ComicInfo', () async {
    final archive = Archive()
      ..addFile(ArchiveFile.string('a.bmp', 'x'));
    final source = await openCbz(
      ZipEncoder().encodeBytes(archive),
      '我的漫画.cbz',
    );
    expect(source.book.metadata.title, '我的漫画');
    expect(source.book.toc.first.label, 'a.bmp');
  });

  test('rejects archives without supported images', () {
    final archive = Archive()..addFile(ArchiveFile.string('note.txt', 'x'));
    expect(
      () => openCbz(ZipEncoder().encodeBytes(archive), 'empty.cbz'),
      throwsFormatException,
    );
  });
}
