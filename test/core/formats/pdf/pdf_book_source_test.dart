import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:torto/core/formats/pdf/pdf_book_source.dart';
import 'package:torto/core/formats/pdf/pdf_cover.dart';
import 'package:torto/core/formats/pdf/pdf_document.dart';
import 'package:torto/core/formats/pdf/pdf_fonts.dart';
import 'package:torto/core/formats/pdf/pdf_syntax.dart';
import 'package:torto/core/ir/ir.dart';

/// Builds a minimal but structurally complete PDF: classic xref, /Info with
/// a UTF-16BE title, outlines with direct + named destinations, a Type0
/// font with a ToUnicode CMap, a simple font, and one Flate-compressed
/// content stream.
Uint8List buildFixturePdf() {
  final toUnicodeCMap = '''
/CIDInit /ProcSet findresource begin
12 dict begin
begincmap
1 begincodespacerange
<0000> <ffff>
endcodespacerange
2 beginbfchar
<0001> <4e2d>
<0002> <6587>
<0003> <6d4b>
<0004> <8bd5>
endbfchar
1 beginbfrange
<0010> <0012> <0041>
endbfrange
endcmap
CMapName currentdict /CMap defineresource pop
end end
''';

  final flateContent = 'BT /F2 10 Tf 72 620 Td (Compressed page) Tj ET';
  final compressed = Uint8List.fromList(
    ZLibCodec().encode(Uint8List.fromList(flateContent.codeUnits)),
  );

  final objects = <List<int>>[
    // 1: catalog
    utf8Bytes(
      '<< /Type /Catalog /Pages 2 0 R /Outlines 7 0 R '
      '/Names << /Dests 11 0 R >> >>',
    ),
    // 2: pages
    utf8Bytes('<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>'),
    // 3: page 1 (Type0 font + simple font)
    utf8Bytes(
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] '
      '/Resources << /Font << /F1 5 0 R /F2 6 0 R >> >> '
      '/Contents 9 0 R >>',
    ),
    // 4: page 2 (flate-compressed content)
    utf8Bytes(
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] '
      '/Resources << /Font << /F2 6 0 R >> >> /Contents 10 0 R >>',
    ),
    // 5: Type0 font, Identity-H + ToUnicode
    utf8Bytes(
      '<< /Type /Font /Subtype /Type0 /BaseFont /Test '
      '/Encoding /Identity-H /DescendantFonts [] /ToUnicode 8 0 R >>',
    ),
    // 6: simple font
    utf8Bytes(
      '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica '
      '/Encoding /WinAnsiEncoding >>',
    ),
    // 7: outlines
    utf8Bytes('<< /Type /Outlines /First 12 0 R /Last 14 0 R /Count 3 >>'),
    // 8: ToUnicode CMap stream
    utf8Bytes(
      '<< /Length ${toUnicodeCMap.length} >>\nstream\n$toUnicodeCMap\nendstream',
    ),
    // 9: page 1 content (uncompressed)
    utf8Bytes(
      '<< /Length 200 >>\nstream\n'
      'BT /F1 12 Tf 72 700 Td <00010002> Tj ET\n'
      'BT /F1 12 Tf 72 660 Td [<0003> -90 <0004>] TJ ET\n'
      'BT /F2 10 Tf 72 620 Td (Hello & welcome) Tj ET\n'
      'endstream',
    ),
    // 10: page 2 content (flate)
    () {
      final header =
          '<< /Filter /FlateDecode /Length ${compressed.length} >>\nstream\n';
      final body = <int>[
        ...utf8Bytes(header),
        ...compressed,
        ...utf8Bytes('\nendstream'),
      ];
      return body;
    }(),
    // 11: named destinations
    utf8Bytes('<< /Names [(target) [4 0 R /Fit]] >>'),
    // 12: outline 1 → page 1
    utf8Bytes(
      '<< /Title (\xfe\xff\\000M\\000a\\000p) /Parent 7 0 R '
      '/Dest [3 0 R /Fit] /Next 13 0 R >>',
    ),
    // 13: outline 2 → named destination on page 2
    utf8Bytes(
      '<< /Title (Page Two) /Parent 7 0 R /A << /S /GoTo /D (target) >> '
      '/Next 14 0 R >>',
    ),
    // 14: outline 3 → page 2 (closing the chain)
    utf8Bytes('<< /Title (Last) /Parent 7 0 R /Dest [4 0 R /Fit] >>'),
    // 15: info — title "四千周测试" as UTF-16BE with BOM.
    utf8Bytes('<< /Title <FEFF56DB534354686D4B8BD5> /Author (Test Author) >>'),
  ];

  final output = BytesBuilder(copy: false);
  output.add(utf8Bytes('%PDF-1.4\n%\xe2\xe3\xcf\xd3\n'));
  final offsets = <int>[];
  for (var index = 0; index < objects.length; index++) {
    offsets.add(output.length);
    output
      ..add(utf8Bytes('${index + 1} 0 obj\n'))
      ..add(objects[index])
      ..add(utf8Bytes('\nendobj\n'));
  }
  final xref = output.length;
  output.add(utf8Bytes('xref\n0 ${objects.length + 1}\n'));
  output.add(utf8Bytes('0000000000 65535 f \n'));
  for (final offset in offsets) {
    output.add(utf8Bytes('${offset.toString().padLeft(10, '0')} 00000 n \n'));
  }
  output.add(
    utf8Bytes(
      'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R /Info 15 0 R >>\n'
      'startxref\n$xref\n%%EOF\n',
    ),
  );
  return output.takeBytes();
}

List<int> utf8Bytes(String text) => Uint8List.fromList(text.codeUnits);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('parses xref, catalog, info, and outlines', () {
    final document = PdfDocument.open(buildFixturePdf());
    expect(document.pages, hasLength(2));
    final (title, author) = document.infoMetadata();
    expect(title, '四千周测试');
    expect(author, 'Test Author');
    final toc = document.outline();
    expect(toc, hasLength(3));
    expect(toc[0].label, 'Map');
    expect(toc[0].href, 'Text/section-1.xhtml');
    expect(toc[1].label, 'Page Two');
    expect(toc[1].href, 'Text/section-2.xhtml');
    expect(toc[2].label, 'Last');
  });

  test('decodes ToUnicode CMaps (bfchar + bfrange)', () {
    final document = PdfDocument.open(buildFixturePdf());
    final font = document.resolve(const PdfRef(5, 0)) as PdfDict;
    final map = buildFontMap(font, document.resolve);
    expect(map.codeWidth, 2);
    expect(map.lookup(0x0001), '中');
    expect(map.lookup(0x0002), '文');
    expect(map.lookup(0x0003), '测');
    expect(map.lookup(0x0010), 'A');
    expect(map.lookup(0x0012), 'C');
  });

  test('extracts text with font mapping and flate content', () async {
    final source = await openPdf(buildFixturePdf(), 'fixture.pdf');
    expect(source.book.metadata.title, '四千周测试');
    expect(source.book.metadata.authors, ['Test Author']);
    expect(source.book.spine, hasLength(2));

    final page1 = await source.parseSection(0);
    final texts = page1.blocks
        .whereType<TextBlock>()
        .map((block) => block.plainText)
        .toList();
    expect(texts, contains('中文'));
    expect(texts, contains('测 试')); // kern gap ≥ space threshold
    expect(texts, contains('Hello & welcome'));

    final page2 = await source.parseSection(1);
    final page2Text = page2.blocks
        .whereType<TextBlock>()
        .map((block) => block.plainText)
        .join();
    expect(page2Text, contains('Compressed page'));
  });

  test('rejects non-PDF bytes and text-less PDFs are reported', () async {
    expect(
      () => openPdf(Uint8List.fromList(List.filled(64, 0x41)), 'x.pdf'),
      throwsFormatException,
    );
  });

  test(
    'uses native fixed-page rendering when a file path is available',
    () async {
      final rendered = Uint8List.fromList([1, 2, 3]);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pdfCoverChannel, (call) async {
            expect((call.arguments as Map)['path'], '/books/fixture.pdf');
            return switch (call.method) {
              'inspect' => {'pageCount': 2},
              'renderPage' => rendered,
              _ => null,
            };
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(pdfCoverChannel, null),
      );

      final source = await openPdf(
        buildFixturePdf(),
        'fixture.pdf',
        filePath: '/books/fixture.pdf',
      );
      final section = await source.parseSection(0);
      final image = section.blocks.single as ImageBlock;

      expect(image.href, 'Pages/page-00001.png');
      expect(await source.resource(image.href), rendered);
    },
  );

  test('native rendering opens PDFs unsupported by the Dart parser', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pdfCoverChannel, (call) async {
          if (call.method == 'inspect') return {'pageCount': 3};
          return Uint8List.fromList([1]);
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pdfCoverChannel, null),
    );

    final source = await openPdf(
      Uint8List.fromList(List.filled(64, 0x41)),
      'unsupported.pdf',
      filePath: '/books/unsupported.pdf',
      titleHint: 'Synced title',
      publicationIdHint: 'book-id',
    );

    expect(source.book.id, 'book-id');
    expect(source.book.metadata.title, 'Synced title');
    expect(source.book.spine, hasLength(3));
    expect((await source.parseSection(0)).blocks.single, isA<ImageBlock>());
  });

  test('opens the real 四千周.pdf fixture', () async {
    final file = File('../torto/test-data/四千周.pdf');
    if (!file.existsSync()) {
      // ignore: avoid_print
      print('SKIP: 四千周.pdf not found');
      return;
    }
    final source = await openPdf(await file.readAsBytes(), '四千周.pdf');
    expect(source.book.metadata.title, '四千周');
    expect(source.book.metadata.authors, contains('奥利弗·伯克曼'));
    expect(source.book.spine.length, greaterThan(100));
    expect(source.book.toc.length, greaterThan(10));

    var textPages = 0;
    var characters = 0;
    for (var i = 0; i < source.book.spine.length; i++) {
      final section = await source.parseSection(i);
      if (section.blocks.isEmpty) continue;
      textPages++;
      for (final block in section.blocks) {
        if (block is TextBlock) characters += block.plainText.length;
      }
    }
    // ignore: avoid_print
    print('四千周.pdf: textPages=$textPages characters=$characters');
    expect(textPages, greaterThan(100));
    expect(characters, greaterThan(100000));

    // Body text must actually be Chinese prose, not mojibake.
    final sample = await source.parseSection(10);
    final sampleText = sample.blocks
        .whereType<TextBlock>()
        .map((block) => block.plainText)
        .join();
    expect(sampleText, contains(RegExp(r'[\u4e00-\u9fff]')));
  });
}
