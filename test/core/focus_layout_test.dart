import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:torto/core/ir/ir.dart';
import 'package:torto/core/layout/layout_engine.dart';
import 'package:torto/core/layout/layout_types.dart';
import 'package:torto/core/layout/focus_layout.dart';
import 'package:torto/app/reader/focus_reading_state.dart';

final spine = SpineItemId.generated(0);
SourceRange range(String node, int length) => SourceRange(
  start: SourceAnchor(spine: spine, node: node, textOffset: 0),
  end: SourceAnchor(spine: spine, node: node, textOffset: length),
);
TextBlock paragraph(
  String node,
  String text, {
  TextBlockKind kind = TextBlockKind.paragraph,
  int depth = 0,
}) => TextBlock(
  nodeId: node,
  source: range(node, text.runes.length),
  kind: kind,
  listDepth: depth,
  inlines: [TextRun(text)],
);
const viewport = LayoutViewport(width: 320, height: 400);
const style = ReaderStyle(
  focusMode: true,
  baseFontSize: 16,
  marginTop: 20,
  marginBottom: 20,
  marginLeft: 20,
  marginRight: 20,
);
List<PageLayout> layout(List<Block> blocks, {ReaderStyle readerStyle = style}) {
  final pages = LayoutEngine().paginate(
    Section(id: spine, spineIndex: 0, href: 'chapter.xhtml', blocks: blocks),
    viewport,
    readerStyle,
    imageSizeResolver: (_) => const ui.Size(160, 100),
  );
  addTearDown(() {
    for (final page in pages) {
      page.dispose();
    }
  });
  return pages;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('split canonical nodes match the correct source offsets', () {
    final first = FocusUnitLayout(
      bounds: const ui.Rect.fromLTWH(0, 0, 100, 100),
      sources: [range('n1', 50)],
    );
    final second = FocusUnitLayout(
      bounds: const ui.Rect.fromLTWH(0, 0, 100, 100),
      sources: [
        SourceRange(
          start: SourceAnchor(spine: spine, node: 'n1', textOffset: 50),
          end: SourceAnchor(spine: spine, node: 'n1', textOffset: 100),
        ),
      ],
    );
    final atBoundary = SourceAnchor(spine: spine, node: 'n1', textOffset: 50);
    expect(first.contains(atBoundary), isFalse);
    expect(second.contains(atBoundary), isTrue);
  });

  test('fixed layouts retain ordinary pagination', () {
    final pages = LayoutEngine().paginate(
      Section(
        id: spine,
        spineIndex: 0,
        href: 'fixed',
        blocks: [paragraph('n1', 'Fixed page')],
      ),
      viewport,
      style,
      renditionLayout: RenditionLayout.prePaginated,
    );
    addTearDown(() {
      for (final page in pages) {
        page.dispose();
      }
    });
    expect(pages.single.focusUnits, isEmpty);
    expect(pages.single.scrollExtent, 0);
  });
  test('short blocks pack without splitting or moving when activated', () {
    final blocks = List.generate(
      18,
      (i) => paragraph('n$i', 'A short paragraph.'),
    );
    final pages = layout(blocks);
    expect(pages.length, greaterThan(1));
    expect(pages.first.focusUnits.length, greaterThan(1));
    expect(pages.expand((p) => p.focusUnits).length, blocks.length);
    for (final page in pages) {
      expect(page.scrollExtent, 0);
      expect(page.focusUnits.last.bounds.bottom, lessThanOrEqualTo(380.01));
    }
    final state = FocusReadingState()..attach(pages.first, 20);
    final positions = pages.first.items
        .whereType<TextPlacement>()
        .map((t) => t.y)
        .toList();
    expect(state.activate(1), isTrue);
    expect(state.anchor!.node, 'n1');
    expect(
      state
          .display(pages.first)
          .items
          .whereType<TextPlacement>()
          .map((t) => t.y),
      positions,
    );
    expect(state.activate(-1), isFalse);
    expect(state.activate(100), isFalse);
  });

  test('long paragraph owns one scrollable page between short pages', () {
    final pages = layout([
      paragraph('n0', 'Before'),
      paragraph('n1', 'Long text. ' * 250),
      paragraph('n2', 'After'),
    ]);
    expect(pages.length, 3);
    final long = pages[1];
    expect(long.focusUnits.length, 1);
    expect(long.scrollExtent, greaterThan(400));
    final text = long.items.whereType<TextPlacement>().single;
    expect(text.startLine, 0);
    expect(text.endLine, text.lineMetrics.length);
    final state = FocusReadingState()..attach(long, 20);
    state.scroll(long.scrollExtent / 2);
    final anchor = state.anchor!;
    expect(anchor.textOffset, greaterThan(0));
    expect(
      state.display(long).items.whereType<TextPlacement>().single.y,
      text.y - state.offset,
    );
    state.attach(pages.last, 20);
    state.attach(long, 20);
    expect(state.offset, long.scrollExtent / 2);
    expect(state.scroll(double.infinity), isTrue);
    expect(state.offset, long.scrollExtent);
    expect(state.activate(1), isFalse);
    state.target = anchor;
    state.attach(long, 20);
    expect(state.anchor!.textOffset, closeTo(anchor.textOffset, 60));
  });

  test(
    'headings, nested list items and translation companions stay together',
    () {
      final blocks = [
        paragraph('h', 'Heading', kind: TextBlockKind.heading),
        paragraph('a', 'Body'),
        paragraph('a@translation', 'Translation'),
        paragraph('b', 'Root list item', kind: TextBlockKind.listItem),
        paragraph(
          'c',
          'Nested list item',
          kind: TextBlockKind.listItem,
          depth: 1,
        ),
        paragraph('d', 'Another root', kind: TextBlockKind.listItem),
      ];
      final groups = FocusUnitBuilder.build(blocks);
      expect(groups.values.map((b) => b.length), [3, 2, 1]);
      final units = layout(blocks).expand((p) => p.focusUnits).toList();
      expect(units.length, 3);
      expect(units.first.anchor!.node, 'a');
      expect(units[1].contains(range('c', 1).start), isTrue);
    },
  );

  test('long quote and table remain complete with their annotations', () {
    final quote = QuoteBlock(
      body: [paragraph('q', 'Quotation. ' * 150)],
      attribution: paragraph('author', 'The author'),
    );
    final table = TableBlock(
      before: [paragraph('caption', 'Table caption')],
      rows: List.generate(
        30,
        (i) => TableRow([
          TableCell(
            nodeId: 'cell$i',
            source: range('cell$i', 4),
            inlines: const [TextRun('Cell')],
          ),
        ]),
      ),
      after: [paragraph('note', 'Table note')],
    );
    final pages = layout([quote, table, paragraph('after', 'After')]);
    expect(pages.length, 3);
    expect(pages[0].focusUnits.length, 1);
    expect(pages[0].items.whereType<QuotePlacement>().length, 1);
    expect(pages[0].items.whereType<TextPlacement>().last.nodeId, 'author');
    expect(pages[1].items.whereType<TableCellPlacement>().length, 30);
    expect(pages[1].items.whereType<TextPlacement>().last.nodeId, 'note');
    expect(pages[1].scrollExtent, greaterThan(0));
  });

  test('image caption, hard breaks and trailing heading keep content', () {
    final pages = layout([
      ImageBlock(href: 'image.png', source: range('img', 0)),
      paragraph('caption', 'Caption', kind: TextBlockKind.caption),
      const PageBreakBlock(),
      paragraph('heading', 'Trailing heading', kind: TextBlockKind.heading),
    ]);
    expect(pages.length, 2);
    expect(pages.first.focusUnits.length, 1);
    expect(
      pages.first.focusUnits.single.contains(range('img', 0).start),
      isTrue,
    );
    expect(pages.last.focusUnits.single.anchor!.node, 'heading');
  });

  test(
    'reflow finds the same canonical block and backwards entry starts at bottom',
    () {
      final blocks = [
        paragraph('short', 'Short'),
        paragraph('long', 'Reading text. ' * 200),
      ];
      final first = layout(blocks);
      final state = FocusReadingState()..backwards = true;
      state.attach(first.last, 20);
      expect(state.offset, first.last.scrollExtent);
      state.scroll(first.last.scrollExtent / 2);
      final anchor = state.anchor!;
      final second = layout(
        blocks,
        readerStyle: style.copyWith(baseFontSize: 22),
      );
      state.target = anchor;
      state.attach(second.last, 20);
      expect(state.anchor!.node, anchor.node);
      expect(state.anchor!.textOffset, closeTo(anchor.textOffset, 80));
    },
  );
}
