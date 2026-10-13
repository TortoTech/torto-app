import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:torto/core/formats/pdf/pdf_book_source.dart';
import 'package:torto/core/formats/pdf/pdf_ocr_book_source.dart';
import 'package:torto/core/ir/ir.dart';
import 'package:torto/core/ir/text_index.dart';
import 'package:torto/core/layout/layout_engine.dart';
import 'package:torto/core/layout/layout_types.dart';
import 'package:torto/core/linebreak/english_hyphenator.dart';

import 'pdf_book_source_test.dart' show buildFixturePdf;

class OriginalSource implements BookSource, DisposableBookSource {
  bool disposed = false;
  @override
  final Book book = Book(
    id: 'book',
    metadata: const BookMetadata(title: 'Book'),
    spine: [
      for (var i = 0; i < 4; i++)
        SpineItem(
          id: SpineItemId('pdf-page-${i + 1}'),
          index: i,
          href: 'Text/page-${i + 1}.xhtml',
        ),
    ],
  );
  @override
  Future<Section> parseSection(int index) async => Section(
    id: book.spine[index].id,
    spineIndex: index,
    href: book.spine[index].href,
    blocks: [ImageBlock(href: 'Pages/page-${index + 1}.png', fixedPage: true)],
  );
  @override
  Future<Uint8List?> resource(String href) async =>
      Uint8List.fromList([1, 2, 3]);
  @override
  void dispose() {
    disposed = true;
  }
}

Map<String, dynamic> document(
  List<String> pages, {
  List<Object> roles = const [],
  List<Object> resources = const [],
}) => {
  'version': 1,
  'book_id': 'book',
  'view_mode': 'reflow',
  'pages': [
    for (final page in pages) {'markdown': page},
  ],
  'resources': resources,
  'page_roles': roles,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader(
      'Literata',
    )..addFont(rootBundle.load('assets/fonts/Literata-opsz-wght.ttf'))).load();
  });
  late Directory temporary;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('torto-ocr-');
  });
  tearDown(() => temporary.delete(recursive: true));

  test(
    'untagged OCR English reaches automatic hyphenation without altering source text',
    () async {
      const prose =
          'The internationalization of the organization is an important consideration for the development of communication.';
      final source = PdfOcrBookSource(
        OriginalSource(),
        document([prose, '# Next', '# Another', '# End']),
        temporary,
        mode: PdfOcrViewMode.reflow,
      );
      addTearDown(source.dispose);
      final section = await source.parseSection(0);
      final paragraph = section.blocks.whereType<TextBlock>().first;
      expect(paragraph.plainText, prose);
      expect(
        paragraph.inlines.whereType<TextRun>().map((r) => r.language),
        everyElement('en'),
      );
      final hyphenator = EnglishHyphenator.forTesting({
        EnglishHyphenationLocale.enUs: (word) => switch (word.toLowerCase()) {
          'internationalization' => [5, 8, 12, 14],
          'organization' => [2, 5, 7],
          'consideration' => [3, 6, 8],
          'development' => [2, 5, 7],
          'communication' => [3, 5, 7, 9],
          _ => [],
        },
      });
      var insertedHyphen = false;
      for (final width in [150.0, 180.0, 220.0]) {
        final pages = LayoutEngine(hyphenator: hyphenator).paginate(
          section,
          LayoutViewport(width: width, height: 1400),
          const ReaderStyle(baseFontSize: 20, marginLeft: 12, marginRight: 12),
        );
        for (final placement
            in pages.expand((p) => p.items).whereType<TextPlacement>()) {
          final selection = placement.paragraph.getBoxesForRange(0, 2000);
          expect(selection, isNotEmpty);
          // Discretionary hyphens add display characters while source ranges
          // continue to refer to the untouched OCR paragraph.
          if (placement.nodeId != paragraph.nodeId) continue;
          final map = placement.displayToSource;
          for (var i = 0; i + 1 < map.length; i++) {
            final boundary = map[i];
            if (boundary == map[i + 1] &&
                boundary > 0 &&
                boundary < prose.length &&
                RegExp(
                  r'[A-Za-z]{2}',
                ).hasMatch(prose.substring(boundary - 1, boundary + 1)) &&
                placement.paragraph
                    .getBoxesForRange(i, i + 1)
                    .any((box) => box.right > box.left)) {
              insertedHyphen = true;
            }
          }
        }
        for (final page in pages) {
          page.dispose();
        }
      }
      expect(insertedHyphen, isTrue);
      expect(paragraph.plainText, prose);
    },
  );

  test(
    'OCR language inference preserves explicit languages and avoids CJK and foreign prose',
    () async {
      final source = PdfOcrBookSource(
        OriginalSource(),
        document([
          '<p lang="en-GB">The organization of the international programme is important.</p>\n\n<p lang="fr">The organization of the programme is important.</p>',
          '这是中文正文，其中包括 internationalization 等术语，但其主要内容仍然是中文。',
          'La communication internationale facilite le développement des organisations et des communautés.',
          '> The organization is important for the development of communication.\n\n[^1]: The organization is important for the development of communication.',
        ]),
        temporary,
        mode: PdfOcrViewMode.reflow,
      );
      addTearDown(source.dispose);
      final section = await source.parseSection(0);
      final texts = section.blocks.whereType<TextBlock>().toList();
      expect(
        texts[0].inlines.whereType<TextRun>().map((r) => r.language),
        everyElement('en-GB'),
      );
      expect(
        texts[1].inlines.whereType<TextRun>().map((r) => r.language),
        everyElement('fr'),
      );
      expect(
        texts[2].inlines.whereType<TextRun>().map((r) => r.language),
        everyElement(isNull),
      );
      expect(
        texts[3].inlines.whereType<TextRun>().map((r) => r.language),
        everyElement(isNull),
      );
      final quote = section.blocks.whereType<QuoteBlock>().single;
      expect(
        quote.body.first.inlines.whereType<TextRun>().map((r) => r.language),
        everyElement('en'),
      );
    },
  );

  test(
    'desktop OCR becomes continuous IR with tables, math, images and page anchors',
    () async {
      final original = OriginalSource();
      final source = PdfOcrBookSource(
        original,
        document(
          [
            '# Chapter One\n\nA **bold** sentence with \$x^2\$.\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\n![Figure](../Ocr/figure.png)',
            'A new paragraph ends here.',
            '# Chapter Two\n\nSecond chapter.',
            'Last paragraph.',
          ],
          resources: [
            {
              'href': 'Ocr/figure.png',
              'file_name': 'figure.png',
              'media_type': 'image/png',
            },
          ],
        ),
        temporary,
        mode: PdfOcrViewMode.reflow,
        toc: [
          const TocEntry(
            label: 'Chapter One',
            href: 'Text/page-1.xhtml',
            spineIndex: 0,
          ),
          const TocEntry(
            label: 'Chapter Two',
            href: 'Text/page-3.xhtml',
            spineIndex: 2,
          ),
        ],
      );
      addTearDown(source.dispose);
      expect(source.book.spine.map((s) => s.id.value), [
        'pdf-ocr-reflow-1',
        'pdf-ocr-reflow-2',
      ]);
      expect(source.book.toc.last.href, 'Text/ocr-reflow-2.xhtml#ocr-toc-1');
      final section = await source.parseSection(0);
      expect(section.blocks.whereType<TableBlock>(), hasLength(1));
      final texts = section.blocks.whereType<TextBlock>().toList();
      expect(
        texts.expand((b) => b.inlines).whereType<MathInline>().single.latex,
        'x^2',
      );
      expect(
        texts
            .expand((b) => b.inlines)
            .whereType<TextRun>()
            .any((r) => r.text == 'bold' && r.style.bold),
        isTrue,
      );
      final images = [
        ...section.blocks.whereType<ImageBlock>(),
        ...section.blocks.whereType<FigureBlock>().expand((b) => b.images),
      ];
      expect(images.single.href, 'Ocr/figure.png');
      expect(
        section.anchors.map((a) => a.fragment),
        containsAll(['pdf-page-1', 'pdf-page-2']),
      );
      final secondPage = sectionTextNodes(
        section,
      ).firstWhere((n) => n.text.startsWith('A new paragraph'));
      expect(source.physicalPage(0, secondPage.source.start, section), 1);
      source.mode = PdfOcrViewMode.original;
      expect((await source.parseSection(1)).blocks.single, isA<ImageBlock>());
      expect(source.book.sectionCount, 4);
    },
  );

  test(
    'cross-page prose joins safely and restores hyphenation without showing original page duplicates',
    () async {
      final source = PdfOcrBookSource(
        OriginalSource(),
        document([
          'An inter-',
          'national example continues',
          'with another line.\n\n# Heading',
          'A separate paragraph.',
        ]),
        temporary,
        mode: PdfOcrViewMode.reflow,
      );
      addTearDown(source.dispose);
      final section = await source.parseSection(0);
      expect(
        sectionTextNodes(section).map((n) => n.text),
        contains('An international example continues'),
      );
      expect(section.blocks.whereType<ImageBlock>(), isEmpty);
      expect(
        sectionTextNodes(section).map((n) => n.text),
        contains('A separate paragraph.'),
      );
    },
  );

  test(
    'OCR display formulas, links and footnotes remain semantic content',
    () async {
      final source = PdfOcrBookSource(
        OriginalSource(),
        document([
          '# Title\n\nA citation[^1] and [site](https://example.org).\n\n\$\$\nx^2 + y^2\n\$\$\n\n[^1]: Note text with **emphasis**.',
          '# Next\n\nAnother note[^1].\n\n[^1]: A different note.',
          '# Another',
          '# End',
        ]),
        temporary,
        mode: PdfOcrViewMode.reflow,
      );
      addTearDown(source.dispose);
      final section = await source.parseSection(0);
      final inlines = section.blocks.whereType<TextBlock>().expand(
        (b) => b.inlines,
      );
      expect(inlines.whereType<MathInline>().single.display, isTrue);
      expect(
        inlines.whereType<TextRun>().any(
          (run) => run.link == 'https://example.org',
        ),
        isTrue,
      );
      expect(
        inlines.whereType<TextRun>().any(
          (run) => run.style.linkRole == LinkRole.footnoteReference,
        ),
        isTrue,
      );
      expect(section.blocks.whereType<NoteBlock>(), hasLength(2));
      expect(
        inlines
            .whereType<TextRun>()
            .where((run) => run.style.linkRole == LinkRole.footnoteReference)
            .map((run) => run.link)
            .toSet(),
        hasLength(2),
      );
    },
  );

  test(
    'cover roles and missing OCR retain original images and do not merge prose',
    () async {
      final source = PdfOcrBookSource(
        OriginalSource(),
        document(
          [
            'Cover text',
            'A paragraph without terminal',
            '',
            'Following paragraph.',
          ],
          roles: [
            {'physical_page': 1, 'role': 'cover'},
            {'physical_page': 4, 'role': 'back-cover'},
          ],
        ),
        temporary,
        mode: PdfOcrViewMode.reflow,
      );
      addTearDown(source.dispose);
      final section = await source.parseSection(0);
      final images = [
        ...section.blocks.whereType<ImageBlock>(),
        ...section.blocks.whereType<FigureBlock>().expand((b) => b.images),
      ];
      expect(
        images.map((b) => b.href),
        containsAll(['Pages/page-1.png', 'Pages/page-3.png']),
      );
      final backCover = images.singleWhere(
        (image) => image.href == 'Pages/page-4.png',
      );
      expect(source.physicalPage(0, backCover.source!.start, section), 3);
      expect(
        sectionTextNodes(section).map((n) => n.text).join(' '),
        isNot(contains('Cover text')),
      );
    },
  );

  test(
    'loads desktop archive resources, preserves local mode and rejects path traversal',
    () async {
      final original =
          await openPdf(
                buildFixturePdf(),
                'fixture.pdf',
                publicationIdHint: 'book',
              )
              as PdfBookSource;
      final value = document(
        ['# One', '# Two'],
        resources: [
          {
            'href': 'Ocr/f.png',
            'file_name': 'f.png',
            'media_type': 'image/png',
          },
        ],
      );
      final archive = Archive()
        ..add(ArchiveFile('document.json', 0, utf8.encode(jsonEncode(value))))
        ..add(ArchiveFile('resources/f.png', 3, [1, 2, 3]));
      await File(
        '${temporary.path}/ocr.zip',
      ).writeAsBytes(ZipEncoder().encode(archive));
      final source = (await loadPdfOcrBookSource(original, temporary))!;
      expect(source.mode, PdfOcrViewMode.reflow);
      expect(await source.resource('Ocr/f.png'), [1, 2, 3]);
      source.mode = PdfOcrViewMode.original;
      await source.saveMode();
      final reloaded = (await loadPdfOcrBookSource(original, temporary))!;
      expect(reloaded.mode, PdfOcrViewMode.original);
      archive.add(ArchiveFile('../escaped.txt', 1, [1]));
      await File(
        '${temporary.path}/ocr.zip',
      ).writeAsBytes(ZipEncoder().encode(archive));
      await expectLater(
        loadPdfOcrBookSource(original, temporary),
        throwsFormatException,
      );
      reloaded.dispose();
    },
  );
}
