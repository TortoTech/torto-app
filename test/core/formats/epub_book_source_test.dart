import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torto/core/formats/epub_book_source.dart';
import 'package:torto/core/ir/ir.dart';

const _container = '''<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>''';

const _opf = '''<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>Test &amp; Book</dc:title>
    <dc:creator>Alice Author</dc:creator>
    <dc:creator>Bob Writer</dc:creator>
    <dc:language>en</dc:language>
    <meta name="cover" content="cover-img"/>
  </metadata>
  <manifest>
    <item id="ch1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="ch2" href="text/ch%202.xhtml" media-type="application/xhtml+xml"/>
    <item id="missing" href="text/gone.xhtml" media-type="application/xhtml+xml"/>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="cover-img" href="images/cover.png" media-type="image/png"/>
  </manifest>
  <spine toc="ncx">
    <itemref idref="ch1"/>
    <itemref idref="ch2"/>
    <itemref idref="missing"/>
    <itemref idref="unknown-idref"/>
  </spine>
</package>''';

const _ch1 = '''<?xml version="1.0"?>
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>c1</title></head>
<body><h1>Chapter 1</h1><p>First para with <b>bold</b>.</p>
<p><img src="../images/cover.png" width="64"/></p></body></html>''';

const _ch2 = '''<?xml version="1.0"?>
<html xmlns="http://www.w3.org/1999/xhtml"><body><p>Second chapter.</p></body></html>''';

const _nav = '''<?xml version="1.0"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<body><nav epub:type="toc"><ol>
  <li><a href="text/ch1.xhtml">Chapter 1</a><ol>
    <li><a href="text/ch1.xhtml#s1">Section 1.1</a></li>
  </ol></li>
  <li><a href="text/ch%202.xhtml">Chapter 2</a></li>
</ol></nav></body></html>''';

const _ncx = '''<?xml version="1.0"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/">
<navMap>
  <navPoint id="n1"><navLabel><text>NCX Chapter 1</text></navLabel><content src="text/ch1.xhtml"/></navPoint>
  <navPoint id="n2"><navLabel><text>NCX Chapter 2</text></navLabel><content src="text/ch%202.xhtml#frag"/></navPoint>
</navMap>
</ncx>''';

final _coverBytes = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4]);

Uint8List _buildEpub({
  bool includeNav = true,
  bool includeContainer = true,
  String navText = _nav,
  String chapter1Text = _ch1,
  String chapter2Text = _ch2,
  String? stylesheetText,
}) {
  final archive = Archive();
  void add(String name, String content) =>
      archive.addFile(ArchiveFile.string(name, content));
  archive.addFile(
    ArchiveFile.noCompress('mimetype', 20, utf8.encode('application/epub+zip')),
  );
  if (includeContainer) add('META-INF/container.xml', _container);
  add('OPS/content.opf', _opf);
  add('OPS/text/ch1.xhtml', chapter1Text);
  add(
    'OPS/text/ch 2.xhtml',
    chapter2Text,
  ); // decoded name; OPF references ch%202.xhtml
  if (includeNav) add('OPS/nav.xhtml', navText);
  add('OPS/toc.ncx', _ncx);
  if (stylesheetText != null) {
    add('OPS/styles/book.css', stylesheetText);
  }
  archive.addFile(
    ArchiveFile('OPS/images/cover.png', _coverBytes.length, _coverBytes),
  );
  return ZipEncoder().encodeBytes(archive);
}

void main() {
  test('opens: id, metadata, spine, cover', () async {
    final bytes = _buildEpub();
    final source = await EpubBookSource.fromBytes(bytes);
    final book = source.book;

    expect(book.id, sha256.convert(bytes).toString());
    expect(book.metadata.title, 'Test & Book');
    expect(book.metadata.authors, ['Alice Author', 'Bob Writer']);
    expect(book.metadata.language, 'en');

    // Dangling idref skipped; hrefs resolved package-root-relative + decoded.
    expect(book.spine.map((item) => item.href), [
      'OPS/text/ch1.xhtml',
      'OPS/text/ch 2.xhtml',
      'OPS/text/gone.xhtml',
    ]);
    expect(book.spine.map((item) => item.index), [0, 1, 2]);

    // <meta name="cover"> fallback (no properties="cover-image" item).
    expect(book.coverHref, 'OPS/images/cover.png');
  });

  test('uses an already-known synced publication id', () async {
    final source = await EpubBookSource.fromBytes(
      _buildEpub(),
      publicationIdHint: 'synced-book-id',
    );

    expect(source.book.id, 'synced-book-id');
  });

  test('background file opening returns a usable source', () async {
    final directory = await Directory.systemTemp.createTemp('torto-epub-open-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}${Platform.pathSeparator}book.epub');
    await file.writeAsBytes(_buildEpub());

    final source = await EpubBookSource.fromFileInBackground(
      file.path,
      publicationIdHint: 'background-book-id',
    );

    expect(source.book.id, 'background-book-id');
    expect((await source.parseSection(0)).blocks, isNotEmpty);
  });

  test(
    'background opening prepares the saved href before returning to the UI',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'torto-epub-restore-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = await File(
        '${directory.path}/book.epub',
      ).writeAsBytes(_buildEpub());
      final source = await EpubBookSource.fromFileInBackground(
        file.path,
        publicationIdHint: 'restore-book',
        initialLocator: const LocatorV1(
          publicationId: 'restore-book',
          position: 0,
          href: 'OPS/text/ch 2.xhtml',
          progression: 0,
        ),
      );
      // Mutating the input after the worker returns must not change the already
      // prepared chapter. This also verifies href wins over stale position=0.
      final input = await source.resource('OPS/text/ch 2.xhtml');
      expect(input, isNotNull);
      input!.fillRange(0, input.length, 32);
      expect((await source.parseSection(1)).blocks, isNotEmpty);
    },
  );

  test('cover-image property wins over meta cover', () async {
    final opf = _opf.replaceAll(
      '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>',
      '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>'
          '<item id="c2" href="images/cover2.png" media-type="image/png" properties="cover-image"/>',
    );
    final archive = Archive();
    archive.addFile(ArchiveFile.string('META-INF/container.xml', _container));
    archive.addFile(ArchiveFile.string('OPS/content.opf', opf));
    archive.addFile(ArchiveFile.string('OPS/text/ch1.xhtml', _ch1));
    final bytes = ZipEncoder().encodeBytes(archive);
    final source = await EpubBookSource.fromBytes(bytes);
    expect(source.book.coverHref, 'OPS/images/cover2.png');
  });

  test('reads the package rendition layout', () async {
    final opf = _opf.replaceFirst(
      '</metadata>',
      '<meta property="rendition:layout">pre-paginated</meta></metadata>',
    );
    final archive = Archive()
      ..addFile(ArchiveFile.string('META-INF/container.xml', _container))
      ..addFile(ArchiveFile.string('OPS/content.opf', opf))
      ..addFile(ArchiveFile.string('OPS/text/ch1.xhtml', _ch1));
    final source = await EpubBookSource.fromBytes(
      ZipEncoder().encodeBytes(archive),
    );

    expect(source.book.metadata.layout, RenditionLayout.prePaginated);
  });

  test('TOC prefers the nav document and resolves spine indexes', () async {
    final source = await EpubBookSource.fromBytes(_buildEpub());
    final toc = source.book.toc;
    expect(toc, hasLength(2));
    expect(toc[0].label, 'Chapter 1');
    expect(toc[0].href, 'OPS/text/ch1.xhtml');
    expect(toc[0].spineIndex, 0);
    expect(toc[0].children, hasLength(1));
    expect(toc[0].children[0].href, 'OPS/text/ch1.xhtml#s1');
    expect(toc[0].children[0].spineIndex, 0);
    expect(toc[1].label, 'Chapter 2');
    expect(toc[1].href, 'OPS/text/ch 2.xhtml');
    expect(toc[1].spineIndex, 1);
  });

  test('NCX fallback when there is no nav document', () async {
    final source = await EpubBookSource.fromBytes(
      _buildEpub(includeNav: false),
    );
    final toc = source.book.toc;
    expect(toc, hasLength(2));
    expect(toc[0].label, 'NCX Chapter 1');
    expect(toc[0].spineIndex, 0);
    expect(toc[1].href, 'OPS/text/ch 2.xhtml#frag');
    expect(toc[1].spineIndex, 1);
  });

  test('TOC note labels supply publication-level section semantics', () async {
    final notesNav = _nav.replaceFirst('Chapter 2', 'Notes');
    final source = await EpubBookSource.fromBytes(
      _buildEpub(navText: notesNav),
    );

    final section = await source.parseSection(1);
    final note = section.blocks.single as NoteBlock;
    expect(note.kind, NoteBlockKind.section);
    expect((note.blocks.single as TextBlock).plainText, 'Second chapter.');
  });

  test(
    'TOC targets promote exact paragraphs and preserve native headings',
    () async {
      const nav = '''<?xml version="1.0"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<body><nav epub:type="toc"><ol>
  <li><a href="text/ch1.xhtml#alignment"> Alignment </a><ol>
    <li><a href="text/ch1.xhtml#hierarchy">Hierarchy</a></li>
  </ol></li>
  <li><a href="text/ch1.xhtml#native">Native heading</a></li>
  <li><a href="text/ch%202.xhtml">Chapter 2</a></li>
</ol></nav></body></html>''';
      const chapter = '''<?xml version="1.0"?>
<html xmlns="http://www.w3.org/1999/xhtml"><body>
  <p id="alignment" style="text-align:center">ALIGNMENT</p>
  <p id="hierarchy">Hierarchy in practice</p>
  <h3 id="native"><em>Native heading</em></h3>
</body></html>''';
      final source = await EpubBookSource.fromBytes(
        _buildEpub(navText: nav, chapter1Text: chapter),
      );

      final blocks = (await source.parseSection(
        0,
      )).blocks.whereType<TextBlock>().toList();
      expect(blocks[0].kind, TextBlockKind.heading);
      expect(blocks[0].headingLevel, 1);
      expect(blocks[0].style.align, BlockAlign.center);
      expect(blocks[1].kind, TextBlockKind.paragraph);
      expect(blocks[2].kind, TextBlockKind.heading);
      expect(blocks[2].headingLevel, 3);
      expect((blocks[2].inlines.single as TextRun).style.italic, isTrue);
    },
  );

  test('loads external CSS alignment into authored block styles', () async {
    const chapter = '''<?xml version="1.0"?>
<html xmlns="http://www.w3.org/1999/xhtml"><head>
  <link rel="alternate stylesheet" href="../styles/book.css"/>
</head><body>
  <p class="centered">Centered paragraph</p>
  <p class="right">Right paragraph</p>
</body></html>''';
    final source = await EpubBookSource.fromBytes(
      _buildEpub(
        chapter1Text: chapter,
        stylesheetText: '''
          .centered { text-align: center; }
          .right { text-align: right; }
        ''',
      ),
    );

    final blocks = (await source.parseSection(
      0,
    )).blocks.whereType<TextBlock>().toList();
    expect(blocks[0].style.align, BlockAlign.center);
    expect(blocks[0].style.authoredAlignment, BlockAlign.center);
    expect(blocks[1].style.align, BlockAlign.end);
    expect(blocks[1].style.authoredAlignment, BlockAlign.end);
  });

  test(
    'path-only TOC labels promote matching chapter-opening paragraphs',
    () async {
      const nav = '''<?xml version="1.0"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<body><nav epub:type="toc"><ol>
  <li><a href="text/ch1.xhtml">Introduction</a></li>
  <li><a href="text/ch%202.xhtml">Chapter 2</a></li>
</ol></nav></body></html>''';
      const chapter = '''<?xml version="1.0"?>
<html xmlns="http://www.w3.org/1999/xhtml"><body>
  <p>Introduction</p><p>Opening prose.</p>
</body></html>''';
      final source = await EpubBookSource.fromBytes(
        _buildEpub(navText: nav, chapter1Text: chapter),
      );

      final heading = (await source.parseSection(0)).blocks.first as TextBlock;
      expect(heading.kind, TextBlockKind.heading);
      expect(heading.headingLevel, 1);
    },
  );

  test('parseSection parses and caches; missing section degrades', () async {
    final source = await EpubBookSource.fromBytes(_buildEpub());

    final section = await source.parseSection(0);
    expect(section.spineIndex, 0);
    expect(section.href, 'OPS/text/ch1.xhtml');
    expect(section.blocks, isNotEmpty);
    expect(section.blocks[0], isA<TextBlock>());
    expect((section.blocks[0] as TextBlock).kind, TextBlockKind.heading);
    final image = section.blocks.whereType<ImageBlock>().single;
    expect(image.href, 'OPS/images/cover.png');
    expect((image.style.width! as ImagePixels).value, 64);

    // Cached: same instance returned.
    expect(await source.parseSection(0), same(section));

    // Section with percent-encoded zip entry decodes and parses.
    final second = await source.parseSection(1);
    expect((second.blocks.single as TextBlock).plainText, 'Second chapter.');

    // Missing spine file → empty section, book still usable.
    final missing = await source.parseSection(2);
    expect(missing.blocks, isEmpty);
  });

  test(
    'resource returns bytes by root-relative href, null when absent',
    () async {
      final source = await EpubBookSource.fromBytes(_buildEpub());
      expect(await source.resource('OPS/images/cover.png'), _coverBytes);
      // Percent-encoded lookup form resolves to the same entry.
      expect(await source.resource('OPS/text/ch%202.xhtml'), isNotNull);
      expect(await source.resource('OPS/images/nope.png'), isNull);
    },
  );

  test('missing container.xml throws a FormatException', () async {
    expect(
      () => EpubBookSource.fromBytes(_buildEpub(includeContainer: false)),
      throwsA(isA<FormatException>()),
    );
  });

  test('non-zip bytes throw a FormatException', () async {
    expect(
      () => EpubBookSource.fromBytes(Uint8List.fromList(utf8.encode('nope'))),
      throwsA(isA<FormatException>()),
    );
  });
}
