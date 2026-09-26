import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:torto/core/ir/ir.dart';
import 'package:torto/core/layout/sentence_structure.dart';
import 'package:torto/core/layout/layout_engine.dart';
import 'package:torto/core/layout/layout_types.dart';
import 'package:torto/core/linebreak/english_hyphenator.dart';
import 'package:torto/core/render/formula_rasterizer.dart';

List<String> split(String text, {bool semicolons = true}) {
  final cuts = SentenceStructure.boundaries(text, splitSemicolons: semicolons);
  var start = 0;
  return [
    for (final end in [...cuts, text.length])
      (() {
        final value = text.substring(start, end);
        start = end;
        return value;
      })(),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'inline formulae preserve optimized sentence layout and tappable source ranges',
    () async {
      final renderer = FormulaRasterizer();
      addTearDown(renderer.dispose);
      const formula = MathInline(
        r'2\pi fT=2\pi',
        original: [TextRun('2πfT=2π')],
        originalImage: 'formula.png',
      );
      await renderer.render(formula, 0xff000000);
      const before =
          'The time it takes to go one revolution is called the period T, and the motion we say is periodic with period T. T is a solution to the equation ';
      const after = '. The period is simply the inverse of the frequency.';
      final block = TextBlock(
        nodeId: 'period',
        inlines: const [TextRun(before), formula, TextRun(after)],
      );
      final section = Section(
        id: const SpineItemId.generated(0),
        spineIndex: 0,
        href: 'a',
        blocks: [block],
      );
      for (final split in [false, true]) {
        final pages = LayoutEngine(formulaResolver: renderer.lookup).paginate(
          section,
          const LayoutViewport(width: 340, height: 1200),
          ReaderStyle(
            focusMode: true,
            sentenceSplit: split,
            foreground: 0xff000000,
            baseFontSize: 12,
          ),
        );
        final placement = pages.single.items.whereType<TextPlacement>().single;
        expect(
          placement.lineMetrics
              .take(placement.lineMetrics.length - 1)
              .every((m) => m.hardBreak),
          isTrue,
          reason:
              'optimized layout must emit explicit line endings even around math',
        );
        expect(placement.inlineImages, hasLength(1));
        final link = placement.links.single;
        expect(link.latex, formula.latex);
        expect(link.originalImage, 'formula.png');
        expect(placement.displayToSource[link.start], before.runes.length);
        expect(
          placement.displayToSource[link.end],
          before.runes.length + formula.sourceText.runes.length,
        );
        expect(placement.displayToSource.last, block.plainText.runes.length);
        final box = placement.paragraph
            .getBoxesForRange(link.start, link.end)
            .single;
        expect(
          box.right - box.left,
          closeTo(placement.inlineImages.single.width, 0.1),
        );
        for (final page in pages) {
          page.dispose();
        }
      }
    },
  );
  test(
    'sentence splitting retains optimized hyphens, indents and source offsets',
    () {
      const sentence = 'Read internationalization documentation carefully. ';
      const prose = '$sentence$sentence';
      final block = TextBlock(nodeId: 'p', inlines: const [TextRun(prose)]);
      final section = Section(
        id: const SpineItemId.generated(0),
        spineIndex: 0,
        href: 'a',
        blocks: [block],
      );
      final hyphenator = EnglishHyphenator.forTesting({
        EnglishHyphenationLocale.enUs: (word) => switch (word) {
          'internationalization' => [2, 5, 7, 11, 13, 16],
          'documentation' => [3, 5, 8, 10],
          'carefully' => [4, 7],
          _ => [],
        },
      });
      var selectedHyphens = 0;
      for (final width in [180.0, 220.0, 260.0, 300.0]) {
        final pages = LayoutEngine(hyphenator: hyphenator).paginate(
          section,
          LayoutViewport(width: width, height: 1200),
          const ReaderStyle(
            focusMode: true,
            sentenceSplit: true,
            typesettingMode: TypesettingMode.unified,
            publicationLanguage: 'en-US',
            baseFontSize: 10,
            marginLeft: 10,
            marginRight: 10,
          ),
        );
        final placement = pages.single.items.whereType<TextPlacement>().single;
        final mapping = placement.displayToSource;
        expect(mapping.last, prose.length);
        expect(mapping, orderedEquals([...mapping]..sort()));
        final secondStart = mapping.lastIndexOf(sentence.length);
        final firstStart = mapping.lastIndexOf(0);
        final firstBox = placement.paragraph
            .getBoxesForRange(firstStart, firstStart + 1)
            .first;
        final secondBox = placement.paragraph
            .getBoxesForRange(secondStart, secondStart + 1)
            .first;
        expect(secondBox.left, closeTo(firstBox.left, 0.1));
        expect(secondBox.top, greaterThan(firstBox.top));
        // Discretionary hyphens add visible glyphs with zero source length
        // inside an original word (unlike sentence breaks or indents).
        for (var i = 1; i + 1 < mapping.length; i++) {
          final offset = mapping[i];
          if (offset <= 0 ||
              offset >= prose.length ||
              mapping[i + 1] != offset) {
            continue;
          }
          if (!RegExp(
            r'[a-z]{2}',
          ).hasMatch(prose.substring(offset - 1, offset + 1))) {
            continue;
          }
          final boxes = placement.paragraph.getBoxesForRange(i, i + 1);
          if (boxes.any((box) => box.right > box.left)) selectedHyphens++;
        }
        expect(pages.single.focusUnits.length, 1);
        for (final page in pages) {
          page.dispose();
        }
      }
      expect(selectedHyphens, greaterThan(0));
    },
  );
  test('desktop sentence and punctuation examples', () {
    final cases = <String, List<String>>{
      '第一句。第二句！第三句？': ['第一句。', '第二句！', '第三句？'],
      'Read first; write later.': ['Read first;', 'write later.'],
      '他说：“先理解；再表达。”': ['他说：“先理解；再表达。”'],
      '“先理解”；“再表达”。': ['“先理解”；', '“再表达”。'],
      'He said "Read first. Think; then write."; Continue.': [
        'He said "Read first. Think; then write.";',
        'Continue.',
      ],
      "Don't rush; think first.": ["Don't rush;", 'think first.'],
      "James' notes; read them.": ["James' notes;", 'read them.'],
      '参见文献（甲，2020；乙，2021）；继续。': ['参见文献（甲，2020；乙，2021）；', '继续。'],
      '先做；“未闭合；继续；尾部': ['先做；', '“未闭合；继续；尾部'],
      'A;;B;': ['A;;', 'B;'],
      '前句结束。（补充说明。）后句开始。': ['前句结束。（补充说明。）', '后句开始。'],
      '前句结束。（新方法）可以提高效率。': ['前句结束。', '（新方法）可以提高效率。'],
      '他说：“她喊‘快走！’”，随后大家离开。然后休息。': ['他说：“她喊‘快走！’”，随后大家离开。', '然后休息。'],
      '他说：“她念‘第一句。第二句。’”（出处）后面的解释另起一句。': [
        '他说：“她念‘第一句。第二句。’”（出处）',
        '后面的解释另起一句。',
      ],
      '这是前一句。C. O. D.对justify的解释是：': ['这是前一句。', 'C. O. D.对justify的解释是：'],
      'Dr. Smith paid 3.14 dollars. Next sentence.': [
        'Dr. Smith paid 3.14 dollars.',
        'Next sentence.',
      ],
      '第一句。new methods是新方法。': ['第一句。', 'new methods是新方法。'],
      '😀第一句。𠀀第二句。': ['😀第一句。', '𠀀第二句。'],
    };
    for (final entry in cases.entries) {
      final actual = split(entry.key);
      expect(
        actual.map((s) => s.trim()).toList(),
        entry.value,
        reason: entry.key,
      );
      expect(actual.join(), entry.key);
    }
    expect(split('甲；乙。丙；丁。', semicolons: false), ['甲；乙。', '丙；丁。']);
    expect(SentenceStructure.boundaries('First.\nSecond.'), isEmpty);
  });

  test('formatting, links, formulae and footnotes keep their source text', () {
    const formula = MathInline('x=1.5; y=2');
    const note = TextRun(
      '注释。另一句。',
      style: TextStyle(inlineRole: InlineRole.footnote),
    );
    final input = <Inline>[
      const TextRun(
        '第一句。',
        style: TextStyle(bold: true),
        link: 'chapter.xhtml',
      ),
      note,
      const TextRun('公式'),
      formula,
      const TextRun('有效。最后一句。'),
    ];
    final output = SentenceStructure.apply(input);
    expect(output.whereType<MathInline>().single, same(formula));
    expect(
      output
          .whereType<TextRun>()
          .where((r) => r.style.inlineRole == InlineRole.footnote)
          .single
          .text,
      note.text,
    );
    expect(output.whereType<TextRun>().first.style.bold, isTrue);
    expect(output.whereType<TextRun>().first.link, 'chapter.xhtml');
    expect(output.indexWhere((i) => i is BreakInline), 2);
    expect(
      TextBlock(inlines: output).plainText,
      TextBlock(inlines: input).plainText,
    );
    expect(output.whereType<BreakInline>().every((b) => b.synthetic), isTrue);
  });

  test(
    'sentence subparagraphs are focus-only and retain a single activation unit',
    () {
      final spine = SpineItemId.generated(0);
      final block = TextBlock(
        nodeId: 'n1',
        inlines: const [
          TextRun('First sentence. Second sentence. Third sentence.'),
        ],
        source: SourceRange(
          start: SourceAnchor(spine: spine, node: 'n1', textOffset: 0),
          end: SourceAnchor(spine: spine, node: 'n1', textOffset: 48),
        ),
      );
      final section = Section(
        id: spine,
        spineIndex: 0,
        href: 'a',
        blocks: [block],
      );
      const viewport = LayoutViewport(width: 1200, height: 600);
      List<PageLayout> layout(ReaderStyle style) {
        final pages = LayoutEngine().paginate(section, viewport, style);
        addTearDown(() {
          for (final page in pages) {
            page.dispose();
          }
        });
        return pages;
      }

      final ordinary = layout(const ReaderStyle(sentenceSplit: true));
      final off = layout(const ReaderStyle(focusMode: true));
      final on = layout(
        const ReaderStyle(focusMode: true, sentenceSplit: true),
      );
      expect(
        ordinary.single.items
            .whereType<TextPlacement>()
            .single
            .lineMetrics
            .length,
        1,
      );
      expect(
        off.single.items.whereType<TextPlacement>().single.lineMetrics.length,
        1,
      );
      final text = on.single.items.whereType<TextPlacement>().single;
      expect(text.lineMetrics.length, 3);
      expect(on.single.focusUnits.length, 1);
      expect(text.displayToSource.last, block.plainText.runes.length);
      expect(block.inlines, hasLength(1));
      final second = text.displayToSource.lastIndexOf(
        'First sentence. '.length,
      );
      final position = text.paragraph
          .getBoxesForRange(second, second + 1)
          .first;
      expect(position.left, closeTo(text.lineMetrics.first.left, 45));
      expect(text.source, same(block.source));
    },
  );

  test('headings, code, tables and quote attribution stay unchanged', () {
    final spine = SpineItemId.generated(0);
    TextBlock text(String id, TextBlockKind kind) =>
        TextBlock(nodeId: id, kind: kind, inlines: const [TextRun('甲；乙。丙；丁。')]);
    final section = Section(
      id: spine,
      spineIndex: 0,
      href: 'a',
      blocks: [
        text('heading', TextBlockKind.heading),
        text('code', TextBlockKind.preformatted),
        QuoteBlock(
          body: [text('quote', TextBlockKind.paragraph)],
          attribution: text('author', TextBlockKind.paragraph),
        ),
        TableBlock(
          rows: const [
            TableRow([
              TableCell(inlines: [TextRun('甲。乙。')]),
            ]),
          ],
          before: [text('tableCaption', TextBlockKind.caption)],
        ),
        text('list', TextBlockKind.listItem),
        text('caption', TextBlockKind.caption),
      ],
    );
    final pages = LayoutEngine().paginate(
      section,
      const LayoutViewport(width: 1200, height: 1600),
      const ReaderStyle(focusMode: true, sentenceSplit: true),
      imageSizeResolver: (_) => const ui.Size(10, 10),
    );
    addTearDown(() {
      for (final page in pages) {
        page.dispose();
      }
    });
    final lines = {
      for (final text
          in pages.expand((p) => p.items).whereType<TextPlacement>())
        text.nodeId: text.lineMetrics.length,
    };
    expect(lines['heading'], 1);
    expect(lines['code'], 1);
    expect(lines['quote'], 2);
    expect(lines['author'], 1);
    expect(lines['tableCaption'], 1);
    expect(lines['list'], 4);
    expect(lines['caption'], 4);
  });
}
