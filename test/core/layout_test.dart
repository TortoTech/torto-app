import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

import 'package:torto/core/ir/ir.dart';
import 'package:torto/core/layout/layout_engine.dart';
import 'package:torto/core/layout/layout_types.dart';

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

TextBlock _para(String text,
        {BlockStyle style = BlockStyle.normal,
        TextBlockKind kind = TextBlockKind.paragraph,
        int headingLevel = 0,
        bool listOrdered = false,
        int listOrdinal = 0,
        String nodeId = 'n1'}) =>
    TextBlock(
      kind: kind,
      headingLevel: headingLevel,
      listOrdered: listOrdered,
      listOrdinal: listOrdinal,
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

double _itemTop(PageItem item) => switch (item) {
      TextPlacement(:final y) => y,
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
          expect(item.x + item.width,
              lessThanOrEqualTo(_viewport.width - style.marginRight + _eps));
          expect(item.y, greaterThanOrEqualTo(style.marginTop - _eps));
          expect(item.y + item.sliceHeight,
              lessThanOrEqualTo(contentBottom + _eps));
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
    expect(placement.rect.width / placement.rect.height,
        closeTo(2.0, 0.01));
    expect(placement.rect.width, lessThanOrEqualTo(280 + _eps));
    expect(placement.rect.height, lessThanOrEqualTo(480 + _eps));
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
    expect(placement.rect.width / placement.rect.height,
        closeTo(100 / 2000, 0.01));
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
      _section([_para('above'), const SeparatorBlock(), _para('below', nodeId: 'n2')]),
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
        _para('Heading text line.',
            kind: TextBlockKind.heading, headingLevel: 1)
      ]),
      _viewport,
      _style(),
    );
    final body = bodyPages.single.items.single as TextPlacement;
    final heading = headingPages.single.items.single as TextPlacement;
    expect(heading.lineMetrics.first.height,
        greaterThan(body.lineMetrics.first.height));
    _disposeAll(bodyPages);
    _disposeAll(headingPages);
  });

  test('explicit run sizeScale suppresses heading default scale', () {
    final pages = engine.paginate(
      _section([
        TextBlock(
          kind: TextBlockKind.heading,
          headingLevel: 1,
          inlines: const [TextRun('Sized heading', style: TextStyle(sizeScale: 2.0))],
        )
      ]),
      _viewport,
      _style(),
    );
    final heading = pages.single.items.single as TextPlacement;
    // sizeScale 2.0 vs base font 10 → line clearly taller than a body line
    // but the default 1.6 heading scale must NOT multiply on top (would be
    // 3.2x). Compare against a plain 2.0-scaled paragraph.
    final refPages = engine.paginate(
      _section([
        TextBlock(inlines: const [
          TextRun('Sized heading', style: TextStyle(sizeScale: 2.0))
        ])
      ]),
      _viewport,
      _style(),
    );
    final ref = refPages.single.items.single as TextPlacement;
    expect(heading.lineMetrics.first.height,
        closeTo(ref.lineMetrics.first.height, 1.0));
    _disposeAll(pages);
    _disposeAll(refPages);
  });

  test('list item paginates and offsets exclude the synthetic marker', () {
    final pages = engine.paginate(
      _section([
        _para(_lorem(80), kind: TextBlockKind.listItem, listOrdinal: 3)
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

  test('preformatted and blockquote blocks paginate', () {
    final pages = engine.paginate(
      _section([
        _para('line one\nline two\nline three',
            kind: TextBlockKind.preformatted),
        _para(_lorem(10), kind: TextBlockKind.blockquote, nodeId: 'n2'),
      ]),
      _viewport,
      _style(),
    );
    final texts = pages.expand((p) => p.items).whereType<TextPlacement>();
    expect(texts, isNotEmpty);
    // Blockquote: marginStart 2em indents and narrows the column.
    final quote = texts.last;
    expect(quote.x, greaterThanOrEqualTo(10 + 2 * 10 - _eps));
    _disposeAll(pages);
  });

  test('a line taller than the page still gets placed (overflow tolerated)',
      () {
    final pages = engine.paginate(
      _section([
        TextBlock(inlines: const [
          TextRun('Huge', style: TextStyle(sizeScale: 3.0))
        ])
      ]),
      const LayoutViewport(width: 300, height: 40),
      ReaderStyle(
          baseFontSize: 30,
          marginTop: 4,
          marginBottom: 4,
          marginLeft: 4,
          marginRight: 4),
    );
    expect(pages, isNotEmpty);
    expect(pages.first.items.whereType<TextPlacement>(), isNotEmpty);
    _disposeAll(pages);
  });
}
