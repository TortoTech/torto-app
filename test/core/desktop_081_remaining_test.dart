import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:torto/core/html_ir/html_ir_parser.dart';
import 'package:torto/core/formats/direct_book_source.dart';
import 'package:torto/core/formats/reading_continuations.dart';
import 'package:torto/core/ir/ir.dart';
import 'package:torto/core/ir/inline_content.dart';
import 'package:torto/core/ir/text_index.dart';
import 'package:torto/core/layout/layout_engine.dart';
import 'package:torto/core/layout/layout_types.dart';
import 'package:torto/core/render/formula_rasterizer.dart';
import 'package:torto/core/semantic_layout/inline_semantics.dart';
import 'package:torto/core/semantic_layout/media_references.dart';
import 'html_ir_parser_test.dart' show parseSection;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('partial bilingual chapter translation keeps its label', () {
    final section = Section(
      id: const SpineItemId('s'),
      spineIndex: 0,
      href: 'ch',
      blocks: [
        TextBlock(
          nodeId: 'ordinal',
          kind: TextBlockKind.heading,
          headingLevel: 1,
          headingOrdinal: true,
          inlines: const [TextRun('Chapter One')],
        ),
        TextBlock(
          nodeId: 'ordinal@translation',
          kind: TextBlockKind.heading,
          headingLevel: 1,
          inlines: const [TextRun('第一章')],
        ),
        TextBlock(
          nodeId: 'title',
          kind: TextBlockKind.heading,
          headingLevel: 1,
          inlines: const [TextRun('Title')],
        ),
      ],
    );
    final pages = LayoutEngine().paginate(
      section,
      const LayoutViewport(width: 360, height: 640),
      const ReaderStyle(),
    );
    addTearDown(() {
      for (final page in pages) {
        page.dispose();
      }
    });
    expect(
      pages
          .expand((p) => p.items)
          .whereType<TextPlacement>()
          .map((p) => p.nodeId),
      ['ordinal', 'ordinal@translation', 'title'],
    );
  });
  test('long edited pull quotes allow one short connective change only', () {
    const prefix =
            'A substantial identical opening passage establishes the source ',
        suffix =
            ' and another long identical closing passage confirms the relation to the same unit.';
    expect(
      repeatsContinuationQuote(
        normalizeContinuationText('$prefix because this matters$suffix'),
        normalizeContinuationText('$prefix, as this matters$suffix'),
      ),
      isTrue,
    );
    expect(
      repeatsContinuationQuote(
        'Short unrelated content',
        'Short edited content',
      ),
      isFalse,
    );
  });
  test('number restarts form distinct recovered lists', () {
    final section = parseSection(
      '<div><p>1. A</p><p>2. B</p></div><div><p>1. C</p><p>2. D</p></div>',
    );
    final blocks = section.blocks.cast<TextBlock>().toList();
    expect(blocks.map((b) => b.kind), everyElement(TextBlockKind.listItem));
    expect(blocks[0].listGroupId, blocks[1].listGroupId);
    expect(blocks[2].listGroupId, blocks[3].listGroupId);
    expect(blocks[0].listGroupId, isNot(blocks[2].listGroupId));
  });
  test('literal OCR retains script symbols and avoids URL icons', () {
    final a = SourceAnchor(
      spine: const SpineItemId('s'),
      node: 'n',
      textOffset: 0,
    );
    final section = Section(
      id: a.spine,
      spineIndex: 0,
      href: 'ch',
      blocks: [
        TextBlock(
          nodeId: 'n',
          source: SourceRange(start: a, end: a),
          inlines: const [
            InlineImageRun(
              sizeScale: 1,
              image: ImageBlock(
                href: 'code',
                ocrText: ImageText(
                  '<a href="https://example.test">\tX</a>',
                  literal: true,
                ),
              ),
            ),
          ],
        ),
      ],
    );
    final pages = LayoutEngine().paginate(
      section,
      const LayoutViewport(width: 360, height: 640),
      const ReaderStyle(),
    );
    addTearDown(() {
      for (final p in pages) {
        p.dispose();
      }
    });
    final text = pages.single.items.whereType<TextPlacement>().single;
    expect(text.links.where((l) => l.websiteIcon), isEmpty);
    expect(text.displayToSource, everyElement(0));
    expect(
      text.displayToSelection!.last,
      '<a href="https://example.test">\tX</a>'.runes.length,
    );
  });
  test(
    'long OCR text has distinct progressions despite its shared zero anchor',
    () {
      final a = SourceAnchor(
        spine: const SpineItemId('s'),
        node: 'image',
        textOffset: 0,
      );
      final section = Section(
        id: a.spine,
        spineIndex: 0,
        href: 'ch',
        blocks: [
          ImageBlock(
            href: 'long',
            source: SourceRange(start: a, end: a),
            ocrText: ImageText(
              'A long image transcript wraps across many pages. ' * 80,
            ),
          ),
        ],
      );
      final pages = LayoutEngine().paginate(
        section,
        const LayoutViewport(width: 240, height: 320),
        const ReaderStyle(),
      );
      addTearDown(() {
        for (final p in pages) {
          p.dispose();
        }
      });
      expect(pages.length, greaterThan(2));
      expect(pages.map((p) => p.firstAnchor!.textOffset), everyElement(0));
      for (var i = 1; i < pages.length; i++) {
        expect(pages[i].progression, greaterThan(pages[i - 1].progression));
      }
    },
  );
  test('media citations share bibliographic ordinals and exclude prose', () {
    const text = '正文（如图 4.4），参考 (Smith, 2020)，比较（见图五、七E）。（如图4.4所示，这是说明文字。）';
    final raw = parseSection('<p>$text</p>');
    final section = composeInlineAnnotations(
      raw,
      raw,
      localCitationGroups(raw),
    );
    final runs = (section.blocks.single as TextBlock).inlines
        .whereType<TextRun>()
        .toList();
    expect(
      runs
          .where((r) => r.style.inlineCitation > 0)
          .map((r) => r.style.inlineCitation),
      [1, 2, 3],
    );
    expect((section.blocks.single as TextBlock).plainText, text);
    expect(MediaReferences.isCitation('（如图4.4所示，这是说明文字。）'), isFalse);
  });
  test(
    'circled and nested lists retain source, references and weak dashes stay prose',
    () {
      final section = parseSection(
        '<p>①第一项</p><p style="margin-left:20px">• Nested</p><p>②第二项</p>'
        '<h2>References</h2><p>1. Smith</p><p>2. Jones</p><h2>Body</h2><p>— First prose</p><p>— Second prose</p>',
      );
      final blocks = section.blocks.cast<TextBlock>().toList();
      expect(
        blocks.take(3).map((b) => b.kind),
        everyElement(TextBlockKind.listItem),
      );
      expect(blocks[1].listDepth, 1);
      expect(blocks[0].authoredListMarkerChars, 1);
      expect(blocks[4].kind, TextBlockKind.paragraph);
      expect(blocks[7].kind, TextBlockKind.paragraph);
    },
  );
  test(
    'small image bullets are recovered and omitted only in unified layout',
    () {
      final section = const HtmlIrParser().parse(
        spineIndex: 0,
        href: 'Text/ch.xhtml',
        basePath: 'Text',
        isSmallListMarkerImage: (_) => true,
        xhtml:
            '<html><body><p><img src="dot.png"/> First</p><p><img src="dot.png"/> Second</p></body></html>',
      );
      expect(
        section.blocks.cast<TextBlock>().map((b) => b.kind),
        everyElement(TextBlockKind.listItem),
      );
      final pages = LayoutEngine().paginate(
        section,
        const LayoutViewport(width: 360, height: 640),
        const ReaderStyle(),
      );
      addTearDown(() {
        for (final p in pages) {
          p.dispose();
        }
      });
      expect(
        pages.expand((p) => p.items).whereType<ListMarkerPlacement>(),
        hasLength(2),
      );
      expect(
        pages
            .expand((p) => p.items)
            .whereType<TextPlacement>()
            .expand((t) => t.inlineImages),
        isEmpty,
      );
      expect(
        (section.blocks.first as TextBlock).inlines.whereType<InlineImageRun>(),
        hasLength(1),
      );
    },
  );
  test(
    'chapter label and title share baseline and retain separate source nodes',
    () {
      final a = SourceAnchor(
        spine: const SpineItemId('s'),
        node: 'ordinal',
        textOffset: 0,
      );
      final b = SourceAnchor(
        spine: const SpineItemId('s'),
        node: 'title',
        textOffset: 0,
      );
      final section = Section(
        id: a.spine,
        spineIndex: 0,
        href: 'ch',
        blocks: [
          TextBlock(
            nodeId: 'ordinal',
            source: SourceRange(
              start: a,
              end: SourceAnchor(spine: a.spine, node: a.node, textOffset: 1),
            ),
            kind: TextBlockKind.heading,
            headingLevel: 1,
            headingOrdinal: true,
            inlines: const [TextRun('1')],
          ),
          TextBlock(
            nodeId: 'title',
            source: SourceRange(
              start: b,
              end: SourceAnchor(spine: b.spine, node: b.node, textOffset: 5),
            ),
            kind: TextBlockKind.heading,
            headingLevel: 1,
            inlines: const [TextRun('Title')],
          ),
        ],
      );
      final pages = LayoutEngine().paginate(
        section,
        const LayoutViewport(width: 360, height: 640),
        const ReaderStyle(),
      );
      addTearDown(() {
        for (final p in pages) {
          p.dispose();
        }
      });
      final text = pages.single.items.whereType<TextPlacement>().toList();
      expect(text, hasLength(2));
      expect(
        text[0].y + text[0].lineMetrics.first.baseline,
        closeTo(text[1].y + text[1].lineMetrics.first.baseline, .01),
      );
      expect(text[0].source!.start.node, 'ordinal');
      expect(text[1].source!.start.node, 'title');
    },
  );
  test(
    'OCR body glyphs have display offsets and zero original-source length',
    () {
      final a = SourceAnchor(
        spine: const SpineItemId('s'),
        node: 'n',
        textOffset: 0,
      );
      final block = TextBlock(
        nodeId: 'n',
        source: SourceRange(
          start: a,
          end: SourceAnchor(spine: a.spine, node: a.node, textOffset: 2),
        ),
        inlines: const [
          TextRun('A'),
          InlineImageRun(
            sizeScale: 1,
            image: ImageBlock(href: 'image', ocrText: ImageText('文字😀')),
          ),
          TextRun('B'),
        ],
      );
      final section = Section(
        id: a.spine,
        spineIndex: 0,
        href: 'ch',
        blocks: [block],
      );
      final node = sectionTextNodes(section, includeImageText: true).single;
      expect(node.text, 'A文字😀B');
      expect(block.plainText, 'AB');
      expect(node.sourceOffsets, [0, 1, 1, 1, 1, 2]);
      final pages = LayoutEngine().paginate(
        section,
        const LayoutViewport(width: 360, height: 640),
        const ReaderStyle(),
      );
      addTearDown(() {
        for (final p in pages) {
          p.dispose();
        }
      });
      final text = pages.single.items.whereType<TextPlacement>().single;
      expect(text.inlineImages, isEmpty);
      expect(text.displayToSource.last, 2);
      expect(text.displayToSelection!.last, 5);
      expect(imageTextProjection(block.inlines).$1, node.text);
    },
  );
  test(
    'standalone image text reflows with its original zero-length anchor',
    () {
      final a = SourceAnchor(
        spine: const SpineItemId('s'),
        node: 'img',
        textOffset: 0,
      );
      final section = Section(
        id: a.spine,
        spineIndex: 0,
        href: 'ch',
        blocks: [
          ImageBlock(
            href: 'image',
            source: SourceRange(start: a, end: a),
            ocrText: const ImageText('Copied text from an image.'),
          ),
        ],
      );
      final pages = LayoutEngine().paginate(
        section,
        const LayoutViewport(width: 360, height: 640),
        const ReaderStyle(),
      );
      addTearDown(() {
        for (final p in pages) {
          p.dispose();
        }
      });
      final text = pages.single.items.whereType<TextPlacement>().single;
      expect(text.displayToSource, everyElement(0));
      expect(text.displayToSelection!.last, 26);
      expect(
        sectionTextNodes(section, includeImageText: true).single.displayId,
        text.nodeId,
      );
    },
  );
  test('formula geometry is ready before any pixel raster exists', () async {
    final rasterizer = FormulaRasterizer();
    addTearDown(rasterizer.dispose);
    const value = MathInline('x^2');
    final section = Section(
      id: const SpineItemId('s'),
      spineIndex: 0,
      href: 'ch',
      blocks: [
        TextBlock(inlines: const [value]),
      ],
    );
    await rasterizer.prepare(section, 0xff000000, deferPixels: true);
    final metrics = rasterizer.lookup(value, 0xff000000)!;
    expect(metrics.width, greaterThan(0));
    expect(rasterizer.image(metrics.href), isNull);
    final raster = await rasterizer.renderHref(metrics.href);
    expect(raster?.width, metrics.width);
    expect(rasterizer.image(metrics.href), isNotNull);
  });
  test(
    'container widths compose and ARIA captions attach without absorbing prose',
    () {
      final section = parseSection(
        '<div style="width:50%;max-width:240px"><div style="width:50%">'
        '<p><img src="fig.png" aria-describedby="legend" style="width:100%"/></p></div></div>'
        '<p>Ordinary intervening prose.</p><p id="legend">Opaque caption.</p>',
      );
      final figure = section.blocks.whereType<FigureBlock>().single;
      expect(figure.captions.single.plainText, 'Opaque caption.');
      expect(figure.images.single.style.containerFraction, .25);
      expect(figure.images.single.style.containerPixels, 120);
      expect(
        section.blocks.whereType<TextBlock>().single.plainText,
        'Ordinary intervening prose.',
      );
      final pages = LayoutEngine().paginate(
        section,
        const LayoutViewport(width: 400, height: 640),
        const ReaderStyle(),
        imageSizeResolver: (_) => const ui.Size(1000, 500),
      );
      addTearDown(() {
        for (final p in pages) {
          p.dispose();
        }
      });
      expect(
        pages
            .expand((p) => p.items)
            .whereType<ImagePlacement>()
            .single
            .rect
            .width,
        lessThanOrEqualTo(100),
      );
    },
  );
  test(
    'breadcrumb links disappear but a prose paragraph containing links remains',
    () {
      final section = parseSection(
        '<div class="breadcrumbs"><a href="a">Home</a> &gt; <a href="b">Chapter</a></div>'
        '<p>Read <a href="a">this source</a> for context.</p>',
      );
      expect(section.blocks, hasLength(1));
      expect(
        (section.blocks.single as TextBlock).plainText,
        'Read this source for context.',
      );
    },
  );
  test(
    'unlisted repeated pull quotes join the preceding TOC unit with aliases',
    () async {
      final source = DirectBookSource.open(
        const SourceBook(
          id: 'book',
          metadata: BookMetadata(),
          sections: [
            SourceSection(
              title: 'Chapter',
              content: HtmlSectionContent(
                '<h1 id="start">Chapter</h1><p>A repeated quote is part of this chapter.</p>',
              ),
            ),
            SourceSection(
              title: 'Spread',
              content: HtmlSectionContent(
                '<div role="doc-pullquote"><p id="quote">A repeated quote is part of this chapter.</p></div>',
              ),
            ),
            SourceSection(
              title: 'Next',
              content: HtmlSectionContent('<h1>Next chapter</h1>'),
            ),
          ],
          tableOfContents: [
            SourceTocEntry(
              label: 'Chapter',
              href: 'Text/section-1.xhtml#start',
            ),
            SourceTocEntry(label: 'Next', href: 'Text/section-3.xhtml'),
          ],
        ),
      );
      final joined = await ReadingContinuationSource.open(source);
      expect(joined.book.sectionCount, 2);
      final section = await joined.parseSection(0);
      expect(section.blocks.whereType<QuoteBlock>(), hasLength(1));
      expect(joined.book.indexOfSpine(source.book.spine[1].id), 0);
      expect(
        joined.book.hrefTargets['Text/section-2.xhtml#quote'],
        'Text/section-1.xhtml#continuation-1-quote',
      );
      expect(
        section.anchors.any((a) => a.fragment == 'continuation-1-quote'),
        isTrue,
      );
    },
  );
}
