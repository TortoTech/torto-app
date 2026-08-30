import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

import 'package:torto/core/ir/ir.dart';
import 'package:torto/core/layout/layout_engine.dart';
import 'package:torto/core/layout/layout_types.dart';
import 'package:torto/core/linebreak/english_hyphenator.dart';

class _RecordingHyphenator implements ParagraphHyphenator {
  String? text;
  String? publicationLanguage;
  List<HyphenationSpan> spans = const [];

  @override
  Set<int> breakOpportunities({
    required String text,
    required List<HyphenationSpan> spans,
    required String? publicationLanguage,
  }) {
    this.text = text;
    this.spans = spans;
    this.publicationLanguage = publicationLanguage;
    return const {};
  }
}

const _viewport = LayoutViewport(width: 300, height: 500);
const _eps = 0.5;

ReaderStyle _style({double fontSize = 10}) => ReaderStyle(
  baseFontSize: fontSize,
  lineHeight: 1.2,
  marginTop: 10,
  marginBottom: 10,
  marginLeft: 10,
  marginRight: 10,
);

Section _section(List<Block> blocks) =>
    Section(spineIndex: 0, href: 's.xhtml', blocks: blocks);

TextBlock _para(
  String text, {
  BlockStyle style = BlockStyle.normal,
  TextBlockKind kind = TextBlockKind.paragraph,
  int headingLevel = 0,
  bool listOrdered = false,
  int listOrdinal = 0,
  int listDepth = 0,
  bool listMarkerVisible = true,
  String nodeId = 'n1',
}) => TextBlock(
  kind: kind,
  headingLevel: headingLevel,
  listOrdered: listOrdered,
  listOrdinal: listOrdinal,
  listDepth: listDepth,
  listMarkerVisible: listMarkerVisible,
  nodeId: nodeId,
  inlines: [TextRun(text)],
  style: style,
  source: SourceRange(
    start: SourceAnchor(spine: 0, node: nodeId, textOffset: 0),
    end: SourceAnchor(spine: 0, node: nodeId, textOffset: text.length),
  ),
);

String _lorem(int repetitions) =>
    'Lorem ipsum dolor sit amet, consectetur adipiscing elit. ' * repetitions;

FigureBlock _figure({
  String caption = 'A figure caption',
  CaptionPosition captionPosition = CaptionPosition.after,
}) => FigureBlock(
  images: const [ImageBlock(href: 'img/figure.png')],
  captions: [_para(caption, kind: TextBlockKind.caption, nodeId: 'caption')],
  captionPosition: captionPosition,
);

double _itemTop(PageItem item) => switch (item) {
  QuotePlacement(:final y) => y,
  TextPlacement(:final y) => y,
  ListMarkerPlacement(:final y) => y,
  TableCellPlacement(:final rect) => rect.top,
  ImagePlacement(:final rect) => rect.top,
  SeparatorPlacement(:final rect) => rect.top,
};

void _disposeAll(List<PageLayout> pages) {
  for (final page in pages) {
    page.dispose();
  }
}

void main() {
  const engine = LayoutEngine();

  test('reader style defaults to a 20 logical-pixel font size', () {
    expect(const ReaderStyle().baseFontSize, 20);
  });

  test('empty section produces zero pages', () {
    expect(engine.paginate(_section(const []), _viewport, _style()), isEmpty);
  });

  test('long text paginates into multiple pages', () {
    final pages = engine.paginate(
      _section([_para(_lorem(120))]),
      _viewport,
      _style(),
    );
    expect(pages.length, greaterThan(2));
    _disposeAll(pages);
  });

  test('y positions are monotonically non-decreasing within a page', () {
    final pages = engine.paginate(
      _section([
        _para(_lorem(60)),
        const SeparatorBlock(),
        _para(_lorem(60), nodeId: 'n2'),
      ]),
      _viewport,
      _style(),
    );
    for (final page in pages) {
      var lastY = double.negativeInfinity;
      for (final item in page.items) {
        expect(_itemTop(item), greaterThanOrEqualTo(lastY - _eps));
        lastY = _itemTop(item);
      }
    }
    _disposeAll(pages);
  });

  test('text placements stay within the content area', () {
    final style = _style();
    final pages = engine.paginate(
      _section([_para(_lorem(120))]),
      _viewport,
      style,
    );
    final contentBottom = _viewport.height - style.marginBottom;
    for (final page in pages) {
      for (final item in page.items) {
        if (item is TextPlacement) {
          expect(item.x, greaterThanOrEqualTo(style.marginLeft - _eps));
          expect(
            item.x + item.width,
            lessThanOrEqualTo(_viewport.width - style.marginRight + _eps),
          );
          expect(item.y, greaterThanOrEqualTo(style.marginTop - _eps));
          expect(
            item.y + item.sliceHeight,
            lessThanOrEqualTo(contentBottom + _eps),
          );
          expect(item.startLine, lessThan(item.endLine));
        }
      }
    }
    _disposeAll(pages);
  });

  test('PageBreakBlock forces a new page and never emits an empty page', () {
    final pages = engine.paginate(
      _section([
        _para('First page text.'),
        const PageBreakBlock(),
        const PageBreakBlock(), // consecutive breaks: still no empty page
        _para('Second page text.', nodeId: 'n2'),
      ]),
      _viewport,
      _style(),
    );
    expect(pages.length, 2);
    expect(pages[0].items, isNotEmpty);
    expect(pages[1].items, isNotEmpty);
    expect(pages[1].items.first, isA<TextPlacement>());
    _disposeAll(pages);
  });

  test('leading PageBreakBlock does not emit an empty first page', () {
    final pages = engine.paginate(
      _section([const PageBreakBlock(), _para('Only page.')]),
      _viewport,
      _style(),
    );
    expect(pages.length, 1);
    _disposeAll(pages);
  });

  test('image fits the content area and keeps its aspect ratio', () {
    final pages = engine.paginate(
      _section([const ImageBlock(href: 'img/a.png')]),
      _viewport,
      _style(),
      imageSizeResolver: (href) => const ui.Size(400, 200),
    );
    final placement = pages.single.items.single as ImagePlacement;
    expect(placement.href, 'img/a.png');
    expect(placement.rect.width / placement.rect.height, closeTo(2.0, 0.01));
    expect(placement.rect.width, lessThanOrEqualTo(280 + _eps));
    expect(placement.rect.height, lessThanOrEqualTo(480 + _eps));
    expect(placement.rect.left, closeTo(10, _eps));
    _disposeAll(pages);
  });

  test('image taller than a page scales down to fit', () {
    final pages = engine.paginate(
      _section([const ImageBlock(href: 'img/tall.png')]),
      _viewport,
      _style(),
      imageSizeResolver: (href) => const ui.Size(100, 2000),
    );
    final placement = pages.single.items.single as ImagePlacement;
    expect(placement.rect.height, lessThanOrEqualTo(480 + _eps));
    expect(
      placement.rect.width / placement.rect.height,
      closeTo(100 / 2000, 0.01),
    );
    _disposeAll(pages);
  });

  test('image without a size resolver reserves a 1em square placeholder', () {
    final style = _style();
    final pages = engine.paginate(
      _section([const ImageBlock(href: 'img/missing.png')]),
      _viewport,
      style,
    );
    final placement = pages.single.items.single as ImagePlacement;
    expect(placement.rect.width, closeTo(style.baseFontSize, _eps));
    expect(placement.rect.height, closeTo(style.baseFontSize, _eps));
    _disposeAll(pages);
  });

  test('book images preserve authored margins above the desktop minimum', () {
    final pages = engine.paginate(
      _section([
        _para('Before', nodeId: 'before'),
        const ImageBlock(
          href: 'img/spaced.png',
          style: ImageStyle(marginBefore: 30, marginAfter: 40),
        ),
        _para('After', nodeId: 'after'),
      ]),
      _viewport,
      _style().copyWith(typesettingMode: TypesettingMode.book),
      imageSizeResolver: (_) => const ui.Size(100, 50),
    );
    final items = pages.single.items;
    final before = items.whereType<TextPlacement>().first;
    final image = items.whereType<ImagePlacement>().single;
    final after = items.whereType<TextPlacement>().last;

    expect(image.rect.top - (before.y + before.sliceHeight), closeTo(30, _eps));
    expect(after.y - image.rect.bottom, closeTo(40, _eps));
    _disposeAll(pages);
  });

  test('book images use the desktop 14px minimum gap', () {
    final pages = engine.paginate(
      _section([
        _para('Before', nodeId: 'before'),
        const ImageBlock(href: 'img/default-gap.png'),
        _para('After', nodeId: 'after'),
      ]),
      _viewport,
      _style().copyWith(typesettingMode: TypesettingMode.book),
      imageSizeResolver: (_) => const ui.Size(100, 50),
    );
    final items = pages.single.items;
    final before = items.whereType<TextPlacement>().first;
    final image = items.whereType<ImagePlacement>().single;
    final after = items.whereType<TextPlacement>().last;

    expect(image.rect.top - (before.y + before.sliceHeight), closeTo(14, _eps));
    expect(after.y - image.rect.bottom, closeTo(14, _eps));
    _disposeAll(pages);
  });

  test('unified figure uses desktop caption scale, gap, and centering', () {
    final style = _style();
    final pages = engine.paginate(
      _section([_figure(caption: 'Short caption')]),
      _viewport,
      style,
      imageSizeResolver: (_) => const ui.Size(100, 80),
    );
    final image = pages.single.items.whereType<ImagePlacement>().single;
    final caption = pages.single.items.whereType<TextPlacement>().single;
    final firstBox = caption.paragraph.getBoxesForRange(0, 1).single;

    expect(
      caption.y - image.rect.bottom,
      closeTo(style.baseFontSize * 0.35, _eps),
    );
    expect(caption.lineMetrics.single.height, closeTo(10 * 0.88 * 1.4, 1));
    expect(firstBox.left, greaterThan(0));
    _disposeAll(pages);
  });

  test('unified multi-line figure caption is start-aligned', () {
    final hyphenator = _RecordingHyphenator();
    final languageEngine = LayoutEngine(hyphenator: hyphenator);
    final captionText = _lorem(8);
    final pages = languageEngine.paginate(
      _section([
        FigureBlock(
          images: const [ImageBlock(href: 'img/figure.png')],
          captions: [
            TextBlock(
              kind: TextBlockKind.caption,
              inlines: [TextRun(captionText, language: 'en-GB')],
            ),
          ],
        ),
      ]),
      _viewport,
      _style().copyWith(publicationLanguage: 'en-US'),
      imageSizeResolver: (_) => const ui.Size(100, 80),
    );
    final caption = pages
        .expand((page) => page.items)
        .whereType<TextPlacement>()
        .first;
    final firstBox = caption.paragraph.getBoxesForRange(0, 1).single;

    expect(caption.lineMetrics.length, greaterThan(1));
    expect(firstBox.left, closeTo(0, _eps));
    expect(hyphenator.text, captionText);
    expect(hyphenator.publicationLanguage, 'en-US');
    expect(hyphenator.spans.single.language, 'en-GB');
    _disposeAll(pages);
  });

  test('figure caption can precede its image', () {
    final pages = engine.paginate(
      _section([_figure(captionPosition: CaptionPosition.before)]),
      _viewport,
      _style(),
      imageSizeResolver: (_) => const ui.Size(100, 80),
    );

    expect(pages.single.items, hasLength(2));
    expect(pages.single.items.first, isA<TextPlacement>());
    expect(pages.single.items.last, isA<ImagePlacement>());
    _disposeAll(pages);
  });

  test('image and caption move together when the group fits a fresh page', () {
    const shortViewport = LayoutViewport(width: 300, height: 180);
    final pages = engine.paginate(
      _section([_para('one\ntwo\nthree\nfour\nfive'), _figure()]),
      shortViewport,
      _style(),
      imageSizeResolver: (_) => const ui.Size(100, 100),
    );

    expect(pages, hasLength(2));
    expect(pages.first.items.whereType<ImagePlacement>(), isEmpty);
    expect(pages.last.items.whereType<ImagePlacement>(), hasLength(1));
    expect(pages.last.items.whereType<TextPlacement>(), hasLength(1));
    _disposeAll(pages);
  });

  test('fixed PDF page is vertically centered in the content area', () {
    final style = _style();
    final pages = engine.paginate(
      _section([const ImageBlock(href: 'page:0', fixedPage: true)]),
      _viewport,
      style,
      imageSizeResolver: (_) => const ui.Size(100, 100),
    );
    final placement = pages.single.items.single as ImagePlacement;
    final contentCenter =
        (style.marginTop + _viewport.height - style.marginBottom) / 2;

    expect(placement.rect.center.dy, closeTo(contentCenter, _eps));
    expect(placement.rect.top, greaterThan(style.marginTop));
    expect(placement.rect.left, closeTo(0, _eps));
    expect(placement.rect.right, closeTo(_viewport.width, _eps));
    expect(placement.rect.width, closeTo(_viewport.width, _eps));
    _disposeAll(pages);
  });

  test('reflowable standalone cover is vertically centered', () {
    final style = _style();
    final pages = engine.paginate(
      _section(const [
        PageBreakBlock(),
        ImageBlock(href: 'images/cover.jpg'),
        PageBreakBlock(),
      ]),
      _viewport,
      style,
      imageSizeResolver: (_) => const ui.Size(100, 200),
      coverHref: 'images/cover.jpg',
    );
    final placement = pages.single.items.single as ImagePlacement;
    final contentCenter =
        (style.marginTop + _viewport.height - style.marginBottom) / 2;

    expect(placement.rect.center.dy, closeTo(contentCenter, _eps));
    expect(placement.rect.top, greaterThan(style.marginTop));
    _disposeAll(pages);
  });

  test('reflowable standalone non-cover image remains in normal flow', () {
    final style = _style();
    final pages = engine.paginate(
      _section(const [ImageBlock(href: 'images/illustration.jpg')]),
      _viewport,
      style,
      imageSizeResolver: (_) => const ui.Size(100, 200),
      coverHref: 'images/cover.jpg',
    );
    final placement = pages.single.items.single as ImagePlacement;

    expect(placement.rect.top, closeTo(style.marginTop, _eps));
    _disposeAll(pages);
  });

  test('pre-paginated standalone image is vertically centered', () {
    final style = _style();
    final pages = engine.paginate(
      _section(const [ImageBlock(href: 'images/fixed-page.jpg')]),
      _viewport,
      style,
      imageSizeResolver: (_) => const ui.Size(100, 200),
      renditionLayout: RenditionLayout.prePaginated,
    );
    final placement = pages.single.items.single as ImagePlacement;
    final contentCenter =
        (style.marginTop + _viewport.height - style.marginBottom) / 2;

    expect(placement.rect.center.dy, closeTo(contentCenter, _eps));
    _disposeAll(pages);
  });

  test('CJK text paginates across pages', () {
    final cjk = '天地玄黄宇宙洪荒日月盈昃辰宿列张寒来暑往秋收冬藏' * 80;
    final pages = engine.paginate(_section([_para(cjk)]), _viewport, _style());
    expect(pages.length, greaterThan(1));
    expect(pages.expand((p) => p.items).whereType<TextPlacement>(), isNotEmpty);
    _disposeAll(pages);
  });

  test('progression ends at 1.0 and firstAnchor advances across pages', () {
    final pages = engine.paginate(
      _section([_para(_lorem(150))]),
      _viewport,
      _style(),
    );
    expect(pages.length, greaterThan(2));
    expect(pages.last.progression, 1.0);
    var lastProgression = -1.0;
    var lastOffset = -1;
    for (final page in pages) {
      expect(page.progression, greaterThanOrEqualTo(lastProgression));
      lastProgression = page.progression;
      expect(page.firstAnchor, isNotNull);
      expect(page.firstAnchor!.textOffset, greaterThan(lastOffset));
      lastOffset = page.firstAnchor!.textOffset;
    }
    _disposeAll(pages);
  });

  test('separator spans the full content width at 1px height', () {
    final pages = engine.paginate(
      _section([
        _para('above'),
        const SeparatorBlock(),
        _para('below', nodeId: 'n2'),
      ]),
      _viewport,
      _style(),
    );
    final separator = pages
        .expand((p) => p.items)
        .whereType<SeparatorPlacement>()
        .single;
    expect(separator.rect.height, 1);
    expect(separator.rect.width, closeTo(280, _eps));
    expect(separator.rect.left, closeTo(10, _eps));
    _disposeAll(pages);
  });

  test('heading defaults scale the font up and make lines taller', () {
    final bodyPages = engine.paginate(
      _section([_para('Body text line.')]),
      _viewport,
      _style(),
    );
    final headingPages = engine.paginate(
      _section([
        _para(
          'Heading text line.',
          kind: TextBlockKind.heading,
          headingLevel: 1,
        ),
      ]),
      _viewport,
      _style(),
    );
    final body = bodyPages.single.items.single as TextPlacement;
    final heading = headingPages.single.items.single as TextPlacement;
    expect(
      heading.lineMetrics.first.height,
      greaterThan(body.lineMetrics.first.height),
    );
    _disposeAll(bodyPages);
    _disposeAll(headingPages);
  });

  test('book typesetting preserves authored heading margins', () {
    final pages = engine.paginate(
      _section([
        _para(
          'Heading without authored margin.',
          kind: TextBlockKind.heading,
          headingLevel: 1,
        ),
      ]),
      _viewport,
      _style().copyWith(typesettingMode: TypesettingMode.book),
    );
    final heading = pages.single.items.single as TextPlacement;

    expect(heading.y, closeTo(_style().marginTop, _eps));
    _disposeAll(pages);
  });

  test('book typesetting preserves alignment for every text block kind', () {
    final bookStyle = _style().copyWith(typesettingMode: TypesettingMode.book);
    for (final kind in TextBlockKind.values) {
      final pages = engine.paginate(
        _section([
          _para(
            'A',
            kind: kind,
            headingLevel: kind == TextBlockKind.heading ? 2 : 0,
            style: const BlockStyle(
              align: BlockAlign.end,
              authoredAlignment: BlockAlign.end,
            ),
          ),
        ]),
        _viewport,
        bookStyle,
      );
      final placement = pages.single.items.whereType<TextPlacement>().single;
      final box = placement.paragraph.getBoxesForRange(0, 1).first;
      expect(
        box.left,
        greaterThan(placement.width / 2),
        reason: '$kind should preserve authored end alignment in book mode',
      );
      _disposeAll(pages);
    }
  });

  test('book typesetting maps opaque black to the reader foreground', () {
    expect(
      LayoutEngine.debugResolvedBookTextColor(
        const TextStyle(color: 0xFF000000),
        foreground: 0xFFE8E1D5,
      ),
      0xFFE8E1D5,
    );
    expect(
      LayoutEngine.debugResolvedBookTextColor(
        const TextStyle(color: 0xFF123456),
        foreground: 0xFFE8E1D5,
      ),
      0xFF123456,
    );
  });

  test('explicit run sizeScale suppresses heading default scale', () {
    final bookStyle = _style().copyWith(typesettingMode: TypesettingMode.book);
    final pages = engine.paginate(
      _section([
        TextBlock(
          kind: TextBlockKind.heading,
          headingLevel: 1,
          inlines: const [
            TextRun('Sized heading', style: TextStyle(sizeScale: 2.0)),
          ],
        ),
      ]),
      _viewport,
      bookStyle,
    );
    final heading = pages.single.items.single as TextPlacement;
    // sizeScale 2.0 vs base font 10 → line clearly taller than a body line
    // but the default 1.6 heading scale must NOT multiply on top (would be
    // 3.2x). Compare against a plain 2.0-scaled paragraph.
    final refPages = engine.paginate(
      _section([
        TextBlock(
          inlines: const [
            TextRun('Sized heading', style: TextStyle(sizeScale: 2.0)),
          ],
        ),
      ]),
      _viewport,
      bookStyle,
    );
    final ref = refPages.single.items.single as TextPlacement;
    expect(
      heading.lineMetrics.first.height,
      closeTo(ref.lineMetrics.first.height, 1.0),
    );
    _disposeAll(pages);
    _disposeAll(refPages);
  });

  test('list item paginates and offsets exclude the synthetic marker', () {
    final pages = engine.paginate(
      _section([
        _para(_lorem(80), kind: TextBlockKind.listItem, listOrdinal: 3),
      ]),
      _viewport,
      _style(),
    );
    expect(pages.length, greaterThan(1));
    final first = pages.first.items.whereType<TextPlacement>().first;
    expect(first.textOffsetAtStart, 0);
    final second = pages[1].items.whereType<TextPlacement>().first;
    expect(second.textOffsetAtStart, greaterThan(0));
    _disposeAll(pages);
  });

  test('linked text remains hit-testable after paragraph layout', () {
    final block = TextBlock(
      nodeId: 'linked',
      inlines: const [
        TextRun('Body text '),
        TextRun(
          '1',
          link: 's.xhtml#note-1',
          style: TextStyle(
            baseline: TextBaselineShift.superscript,
            linkRole: LinkRole.footnoteReference,
          ),
        ),
      ],
      source: const SourceRange(
        start: SourceAnchor(spine: 0, node: 'linked', textOffset: 0),
        end: SourceAnchor(spine: 0, node: 'linked', textOffset: 11),
      ),
    );
    final pages = engine.paginate(_section([block]), _viewport, _style());
    addTearDown(() => _disposeAll(pages));
    final placement = pages.single.items.whereType<TextPlacement>().single;
    final link = placement.links.single;
    final box = placement.paragraph
        .getBoxesForRange(link.start, link.end)
        .single;
    final point = ui.Offset(
      placement.x + (box.left + box.right) / 2,
      placement.y - placement.sliceTop + (box.top + box.bottom) / 2,
    );

    expect(pages.single.linkAt(point), same(link));
    expect(link.role, LinkRole.footnoteReference);
    expect(link.href, 's.xhtml#note-1');
    expect(link.footnoteIcon, isTrue);
  });

  test('inline footnote is laid out as the same interactive icon', () {
    final block = TextBlock(
      nodeId: 'inline-note',
      inlines: const [
        TextRun('Body text '),
        TextRun(
          'An inline footnote.',
          style: TextStyle(inlineRole: InlineRole.footnote),
        ),
      ],
    );
    final pages = engine.paginate(_section([block]), _viewport, _style());
    addTearDown(() => _disposeAll(pages));
    final placement = pages.single.items.whereType<TextPlacement>().single;
    final link = placement.links.single;
    final box = placement.paragraph
        .getBoxesForRange(link.start, link.end)
        .firstWhere((candidate) => candidate.right > candidate.left);
    final point = ui.Offset(
      placement.x + (box.left + box.right) / 2,
      placement.y - placement.sliceTop + (box.top + box.bottom) / 2,
    );

    expect(link.footnoteIcon, isTrue);
    expect(link.inlineNote, 'An inline footnote.');
    expect(pages.single.linkAt(point), same(link));
  });

  test('blockquote keeps its authored end alignment during layout', () {
    final pages = engine.paginate(
      _section([
        _para(
          'quoted',
          kind: TextBlockKind.blockquote,
          style: const BlockStyle(
            align: BlockAlign.end,
            authoredAlignment: BlockAlign.end,
          ),
        ),
      ]),
      _viewport,
      _style(),
    );
    final placement = pages.single.items.whereType<TextPlacement>().single;
    final box = placement.paragraph.getBoxesForRange(0, 6).first;

    expect(box.left, greaterThan(placement.width / 2));
    _disposeAll(pages);
  });

  test('list markers use hanging indents and nested levels move inward', () {
    final pages = engine.paginate(
      _section([
        _para(_lorem(3), kind: TextBlockKind.listItem, listOrdinal: 1),
        _para(
          'Nested item',
          kind: TextBlockKind.listItem,
          listDepth: 1,
          nodeId: 'n2',
        ),
      ]),
      _viewport,
      _style(),
    );
    final markers = pages
        .expand((page) => page.items)
        .whereType<ListMarkerPlacement>()
        .toList();
    final text = pages
        .expand((page) => page.items)
        .whereType<TextPlacement>()
        .toList();
    expect(markers, hasLength(2));
    expect(markers[0].x, closeTo(25, _eps));
    expect(text[0].x, closeTo(markers[0].x + markers[0].width, _eps));
    expect(text.last.x, greaterThan(text.first.x));
    expect(markers[0].marker, '•');
    expect(markers[1].marker, '◦');
    _disposeAll(pages);
  });

  test(
    'marker-less nested list paragraphs keep indentation without a bullet',
    () {
      final pages = engine.paginate(
        _section([
          _para(
            'Nested continuation',
            kind: TextBlockKind.listItem,
            listDepth: 1,
            listMarkerVisible: false,
          ),
        ]),
        _viewport,
        _style(),
      );
      final items = pages.single.items;
      expect(items.whereType<ListMarkerPlacement>(), isEmpty);
      expect(items.whereType<TextPlacement>().single.x, closeTo(40, _eps));
      _disposeAll(pages);
    },
  );

  test('table grid retains headers and spans while fitting content width', () {
    final table = TableBlock(
      rows: [
        TableRow([
          TableCell(
            inlines: const [TextRun('Header')],
            header: true,
            columnSpan: 2,
          ),
        ]),
        const TableRow([
          TableCell(inlines: [TextRun('A')]),
          TableCell(inlines: [TextRun('A much longer value')]),
        ]),
      ],
    );
    final pages = engine.paginate(_section([table]), _viewport, _style());
    final cells = pages
        .expand((page) => page.items)
        .whereType<TableCellPlacement>()
        .toList();
    expect(cells, hasLength(3));
    expect(cells.first.header, isTrue);
    expect(cells.first.rect.width, lessThanOrEqualTo(280));
    expect(cells.first.rect.center.dx, closeTo(150, _eps));
    expect(cells[1].rect.right, closeTo(cells[2].rect.left, _eps));
    expect(cells[1].rect.left, closeTo(cells.first.rect.left, _eps));
    expect(cells[2].rect.right, closeTo(cells.first.rect.right, _eps));
    expect(cells.every((cell) => cell.rect.width > 0), isTrue);
    _disposeAll(pages);
  });

  test(
    'unified tables preserve authored alignment and center unspecified cells',
    () {
      final table = TableBlock(
        rows: const [
          TableRow([
            TableCell(inlines: [TextRun('Same')]),
            TableCell(
              inlines: [TextRun('Same')],
              authoredAlignment: BlockAlign.start,
            ),
          ]),
        ],
      );
      final pages = engine.paginate(_section([table]), _viewport, _style());
      final cells = pages.single.items.whereType<TableCellPlacement>().toList();
      final centered = cells[0].paragraph.getBoxesForRange(0, 1).single;
      final authoredStart = cells[1].paragraph.getBoxesForRange(0, 1).single;

      expect(centered.left, greaterThan(0));
      expect(authoredStart.left, closeTo(0, _eps));
      _disposeAll(pages);
    },
  );

  test('unified typesetting overrides authored body size and line height', () {
    final section = _section([
      TextBlock(
        inlines: const [
          TextRun('Authored body', style: TextStyle(sizeScale: 2)),
        ],
        style: const BlockStyle(lineHeight: 2),
      ),
    ]);
    final unifiedPages = engine.paginate(section, _viewport, _style());
    final bookPages = engine.paginate(
      section,
      _viewport,
      _style().copyWith(typesettingMode: TypesettingMode.book),
    );
    final unified = unifiedPages.single.items.single as TextPlacement;
    final book = bookPages.single.items.single as TextPlacement;
    expect(
      book.lineMetrics.first.height,
      greaterThan(unified.lineMetrics.first.height),
    );
    _disposeAll(unifiedPages);
    _disposeAll(bookPages);
  });

  test('unified typesetting matches desktop emphasis and link decoration', () {
    final prose = LayoutEngine.debugResolvedInlineEmphasis(
      const TextStyle(italic: true, underline: true),
    );
    final link = LayoutEngine.debugResolvedInlineEmphasis(
      TextStyle.plain,
      linked: true,
    );
    final quote = LayoutEngine.debugResolvedInlineEmphasis(
      const TextStyle(bold: true, italic: true, underline: true),
      isQuote: true,
    );
    final heading = LayoutEngine.debugResolvedInlineEmphasis(
      const TextStyle(italic: true, underline: true),
      isHeading: true,
    );

    expect(prose.italic, isTrue);
    expect(prose.underline, isFalse);
    expect(link.underline, isFalse);
    expect(quote.bold, isFalse);
    expect(quote.italic, isFalse);
    expect(quote.underline, isFalse);
    expect(heading.italic, isFalse);
    expect(heading.underline, isFalse);
  });

  test('unified typesetting justifies ordinary body paragraphs', () {
    final pages = engine.paginate(
      _section([
        _para(_lorem(4), style: const BlockStyle(align: BlockAlign.end)),
      ]),
      _viewport,
      _style(),
    );
    final placement = pages.first.items.whereType<TextPlacement>().single;
    final firstLine = placement.lineMetrics.first;

    expect(firstLine.width, closeTo(placement.width, _eps));
    _disposeAll(pages);
  });

  test('optimized layout passes run language before publication fallback', () {
    final hyphenator = _RecordingHyphenator();
    final languageEngine = LayoutEngine(hyphenator: hyphenator);
    final prose = _lorem(4);
    final pages = languageEngine.paginate(
      _section([
        TextBlock(inlines: [TextRun(prose, language: 'en-GB')]),
      ]),
      _viewport,
      _style().copyWith(publicationLanguage: 'en-US'),
    );

    expect(hyphenator.text, prose);
    expect(hyphenator.publicationLanguage, 'en-US');
    expect(hyphenator.spans, hasLength(1));
    expect(hyphenator.spans.single.language, 'en-GB');
    _disposeAll(pages);
  });

  test('optimized list body reaches hyphenator and keeps its marker', () {
    final hyphenator = _RecordingHyphenator();
    final languageEngine = LayoutEngine(hyphenator: hyphenator);
    final prose = _lorem(4);
    final pages = languageEngine.paginate(
      _section([
        TextBlock(
          kind: TextBlockKind.listItem,
          listOrdered: true,
          listOrdinal: 3,
          inlines: [TextRun(prose, language: 'en-GB')],
        ),
      ]),
      _viewport,
      _style().copyWith(publicationLanguage: 'en-US'),
    );

    expect(hyphenator.text, prose);
    expect(hyphenator.publicationLanguage, 'en-US');
    expect(hyphenator.spans, hasLength(1));
    expect(hyphenator.spans.single.language, 'en-GB');
    expect(
      pages.expand((page) => page.items).whereType<ListMarkerPlacement>(),
      isNotEmpty,
    );
    _disposeAll(pages);
  });

  test('optimized list body also covers start-aligned CJK content', () {
    final hyphenator = _RecordingHyphenator();
    final languageEngine = LayoutEngine(hyphenator: hyphenator);
    final prose = '系统思考帮助我们理解复杂世界中的结构反馈延迟以及行为之间的关系。' * 4;
    final pages = languageEngine.paginate(
      _section([
        TextBlock(
          kind: TextBlockKind.listItem,
          inlines: [TextRun(prose, language: 'zh-CN')],
        ),
      ]),
      _viewport,
      _style(),
    );

    expect(hyphenator.text, prose);
    expect(hyphenator.spans.single.language, 'zh-CN');
    expect(
      pages.expand((page) => page.items).whereType<ListMarkerPlacement>(),
      isNotEmpty,
    );
    _disposeAll(pages);
  });

  test('inline footnote does not disable optimized paragraph layout', () {
    final hyphenator = _RecordingHyphenator();
    final languageEngine = LayoutEngine(hyphenator: hyphenator);
    final pages = languageEngine.paginate(
      _section([
        TextBlock(
          inlines: [
            TextRun(_lorem(2), language: 'en-US'),
            const TextRun(
              '1',
              link: 's.xhtml#note-1',
              language: 'en-US',
              style: TextStyle(
                baseline: TextBaselineShift.superscript,
                linkRole: LinkRole.footnoteReference,
              ),
            ),
            TextRun(_lorem(2), language: 'en-US'),
          ],
        ),
      ]),
      _viewport,
      _style().copyWith(publicationLanguage: 'en-US'),
    );
    addTearDown(() => _disposeAll(pages));

    expect(hyphenator.text, isNotNull);
    expect(hyphenator.spans, hasLength(3));
    expect(hyphenator.spans[1].suppress, isTrue);
    final link = pages
        .expand((page) => page.items)
        .whereType<TextPlacement>()
        .expand((placement) => placement.links)
        .single;
    expect(link.footnoteIcon, isTrue);
    expect(link.href, 's.xhtml#note-1');
  });

  test('unified semantic block alignment matches desktop rules', () {
    TextBlock block(
      TextBlockKind kind, {
      String text = 'Semantic content',
      BlockAlign? authoredAlignment,
    }) => _para(
      text,
      kind: kind,
      style: BlockStyle(
        align: authoredAlignment ?? BlockAlign.end,
        authoredAlignment: authoredAlignment,
      ),
    );

    for (final kind in [
      TextBlockKind.heading,
      TextBlockKind.preformatted,
      TextBlockKind.footnoteDefinition,
      TextBlockKind.definitionTerm,
      TextBlockKind.definitionDescription,
    ]) {
      expect(
        LayoutEngine.debugResolvedUnifiedAlignment(block(kind)),
        BlockAlign.start,
        reason: '$kind should use neutral start alignment',
      );
    }
    expect(
      LayoutEngine.debugResolvedUnifiedAlignment(block(TextBlockKind.caption)),
      BlockAlign.center,
    );
    expect(
      LayoutEngine.debugResolvedUnifiedAlignment(
        block(TextBlockKind.quoteAttribution),
      ),
      BlockAlign.end,
    );
    expect(
      LayoutEngine.debugResolvedUnifiedAlignment(
        block(TextBlockKind.listItem, text: 'Latin list item'),
      ),
      BlockAlign.justify,
    );
    expect(
      LayoutEngine.debugResolvedUnifiedAlignment(
        block(TextBlockKind.listItem, text: '中文列表项'),
      ),
      BlockAlign.start,
    );
    expect(
      LayoutEngine.debugResolvedUnifiedAlignment(
        block(TextBlockKind.listItem, text: 'Non\u00a0breaking item'),
      ),
      BlockAlign.start,
    );
  });

  test(
    'unified prose ignores authored start and preserves special alignment',
    () {
      for (final kind in [TextBlockKind.paragraph, TextBlockKind.blockquote]) {
        for (final (authored, expected) in [
          (BlockAlign.start, BlockAlign.justify),
          (BlockAlign.center, BlockAlign.center),
          (BlockAlign.end, BlockAlign.end),
          (BlockAlign.justify, BlockAlign.justify),
        ]) {
          final block = _para(
            'Authored prose alignment',
            kind: kind,
            style: BlockStyle(align: authored, authoredAlignment: authored),
          );
          expect(
            LayoutEngine.debugResolvedUnifiedAlignment(block),
            expected,
            reason: '$kind with $authored',
          );
        }

        final parserDefault = _para(
          'Parser default alignment',
          kind: kind,
          style: const BlockStyle(align: BlockAlign.end),
        );
        expect(
          LayoutEngine.debugResolvedUnifiedAlignment(parserDefault),
          BlockAlign.justify,
        );
      }
    },
  );

  test('figure caption alignment override wins after multi-line detection', () {
    final caption = _para(
      'A caption',
      kind: TextBlockKind.caption,
      style: const BlockStyle(
        align: BlockAlign.end,
        authoredAlignment: BlockAlign.end,
      ),
    );

    expect(
      LayoutEngine.debugResolvedUnifiedAlignment(caption),
      BlockAlign.center,
    );
    expect(
      LayoutEngine.debugResolvedUnifiedAlignment(
        caption,
        override: BlockAlign.start,
      ),
      BlockAlign.start,
    );
  });

  test('unified typesetting keeps headings start-aligned', () {
    final pages = engine.paginate(
      _section([
        _para(
          'A heading',
          kind: TextBlockKind.heading,
          headingLevel: 2,
          style: const BlockStyle(align: BlockAlign.end),
        ),
      ]),
      _viewport,
      _style(),
    );
    final placement = pages.single.items.single as TextPlacement;
    final box = placement.paragraph.getBoxesForRange(0, 1).single;

    expect(box.left, closeTo(0, _eps));
    _disposeAll(pages);
  });

  test('preformatted and blockquote blocks paginate', () {
    final pages = engine.paginate(
      _section([
        _para(
          'line one\nline two\nline three',
          kind: TextBlockKind.preformatted,
        ),
        _para(_lorem(10), kind: TextBlockKind.blockquote, nodeId: 'n2'),
      ]),
      _viewport,
      _style(),
    );
    final texts = pages.expand((p) => p.items).whereType<TextPlacement>();
    expect(texts, isNotEmpty);
    // Unified layout uses the full flow width for quotes, matching desktop.
    final quote = texts.last;
    expect(quote.x, closeTo(10, _eps));
    _disposeAll(pages);
  });

  test('semantic quotes keep body before their attribution', () {
    final pages = engine.paginate(
      _section([
        QuoteBlock(
          body: [_para('quoted body', kind: TextBlockKind.blockquote)],
          attribution: _para(
            '— Author',
            kind: TextBlockKind.quoteAttribution,
            nodeId: 'n2',
          ),
        ),
      ]),
      _viewport,
      _style(),
    );
    final placements = pages
        .expand((page) => page.items)
        .whereType<TextPlacement>()
        .toList();

    expect(placements, hasLength(2));
    expect(placements.first.nodeId, 'n1');
    expect(placements.last.nodeId, 'n2');
    final attributionBox = placements.last.paragraph
        .getBoxesForRange(0, '— Author'.length)
        .first;
    expect(attributionBox.left, greaterThan(placements.last.width / 2));
    _disposeAll(pages);
  });

  test('unified semantic quotes render as one decorated card', () {
    final pages = engine.paginate(
      _section([
        QuoteBlock(
          body: [_para('Quoted body.', kind: TextBlockKind.blockquote)],
          attribution: _para(
            '— Source',
            kind: TextBlockKind.quoteAttribution,
            nodeId: 'source',
          ),
        ),
      ]),
      _viewport,
      _style(),
    );

    final quote = pages.single.items.whereType<QuotePlacement>().single;
    final text = pages.single.items.whereType<TextPlacement>().toList();
    expect(quote.height, greaterThan(24));
    expect(text, hasLength(2));
    expect(text.first.x, greaterThan(quote.x));
    expect(text.last.lineMetrics.first.left, greaterThan(0));
    _disposeAll(pages);
  });

  test('unified quote padding follows the publication writing system', () {
    final pages = engine.paginate(
      _section([
        QuoteBlock(
          body: [_para('A Latin quotation.', kind: TextBlockKind.blockquote)],
        ),
      ]),
      _viewport,
      _style().copyWith(writingSystem: WritingSystem.latin),
    );

    final quote = pages.single.items.whereType<QuotePlacement>().single;
    final text = pages.single.items.whereType<TextPlacement>().single;
    expect(text.x - quote.x, closeTo(15, _eps));
    expect(quote.x + quote.width - (text.x + text.width), closeTo(15, _eps));
    _disposeAll(pages);
  });

  test('unified quote body preserves authored first-line indentation', () {
    final pages = engine.paginate(
      _section([
        QuoteBlock(
          body: [
            _para(
              _lorem(2),
              kind: TextBlockKind.blockquote,
              style: const BlockStyle(indent: 1),
            ),
          ],
        ),
      ]),
      _viewport,
      _style(),
    );

    final text = pages.single.items.whereType<TextPlacement>().single;
    final firstTextBox = text.paragraph.getBoxesForRange(1, 2).single;
    expect(firstTextBox.left, closeTo(20, _eps));
    _disposeAll(pages);
  });

  test('unattributed unified quote has one bottom padding', () {
    final pages = engine.paginate(
      _section([
        QuoteBlock(
          body: [_para('A quotation.', kind: TextBlockKind.blockquote)],
        ),
      ]),
      _viewport,
      _style(),
    );

    final quote = pages.single.items.whereType<QuotePlacement>().single;
    final text = pages.single.items.whereType<TextPlacement>().single;
    final bottomPadding = quote.y + quote.height - (text.y + text.sliceHeight);
    expect(bottomPadding, closeTo(12, _eps));
    _disposeAll(pages);
  });

  test('note definitions stay icon-only and note sections follow mode', () {
    final definition = NoteBlock(
      kind: NoteBlockKind.definition,
      blocks: [_para('definition')],
    );
    final section = NoteBlock(
      kind: NoteBlockKind.section,
      blocks: [_para('notes section', nodeId: 'n2')],
    );
    final unified = engine.paginate(
      _section([definition, section]),
      _viewport,
      _style(),
    );
    final book = engine.paginate(
      _section([definition, section]),
      _viewport,
      _style().copyWith(typesettingMode: TypesettingMode.book),
    );

    expect(unified, isEmpty);
    expect(book, hasLength(1));
    expect(book.single.items.whereType<TextPlacement>(), hasLength(1));
    _disposeAll(book);
  });

  test(
    'book layout resolves percentage start margins against content width',
    () {
      final pages = engine.paginate(
        _section([
          _para(
            'relative margin',
            style: const BlockStyle(marginStartFraction: 0.25),
          ),
        ]),
        _viewport,
        _style().copyWith(typesettingMode: TypesettingMode.book),
      );
      final placement = pages.single.items.single as TextPlacement;

      expect(placement.x, closeTo(10 + 280 * 0.25, _eps));
      _disposeAll(pages);
    },
  );

  test(
    'a line taller than the page still gets placed (overflow tolerated)',
    () {
      final pages = engine.paginate(
        _section([
          TextBlock(
            inlines: const [TextRun('Huge', style: TextStyle(sizeScale: 3.0))],
          ),
        ]),
        const LayoutViewport(width: 300, height: 40),
        ReaderStyle(
          baseFontSize: 30,
          marginTop: 4,
          marginBottom: 4,
          marginLeft: 4,
          marginRight: 4,
        ),
      );
      expect(pages, isNotEmpty);
      expect(pages.first.items.whereType<TextPlacement>(), isNotEmpty);
      _disposeAll(pages);
    },
  );
}
