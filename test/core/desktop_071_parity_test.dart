import 'dart:ui' as ui;
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:torto/app/reader/focus_reading_state.dart';
import 'package:torto/core/ir/ir.dart';
import 'package:torto/core/ir/inline_content.dart';
import 'package:torto/core/translation/translation_book_source.dart';
import 'package:torto/core/translation/translation_models.dart';
import 'package:torto/core/layout/layout_engine.dart';
import 'package:torto/core/layout/layout_types.dart';
import 'package:torto/core/layout/sentence_structure.dart';
import 'package:torto/core/semantic_layout/inline_semantics.dart';
import 'package:torto/core/semantic_layout/semantic_layout.dart';
import 'html_ir_parser_test.dart' show parseSection;

class MutableSource implements BookSource {
  Section section;
  MutableSource(this.section);
  @override
  Book get book => Book(
    id: 'book',
    metadata: const BookMetadata(),
    spine: [SpineItem(id: section.id, index: 0, href: section.href)],
  );
  @override
  Future<Section> parseSection(int index) async => section;
  @override
  Future<Uint8List?> resource(String href) async => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'TOC anchors define pages, heading preludes fold, bad targets retain content',
    () {
      final section = parseSection(
        '<h1 id="chapter">Chapter</h1><h2 id="one">One</h2><p>${'Body. ' * 300}</p><h2 id="two">Two</h2><p>Second.</p>',
      );
      const style = ReaderStyle(focusMode: true);
      final pages = LayoutEngine().paginate(
        section,
        const LayoutViewport(width: 340, height: 600),
        style,
        readingToc: [
          for (final fragment in ['chapter', 'one', 'two', 'one', 'missing'])
            TocEntry(label: fragment, href: '${section.href}#$fragment'),
        ],
      );
      addTearDown(() {
        for (final page in pages) {
          page.dispose();
        }
      });
      expect(pages, hasLength(2));
      expect(pages.first.scrollExtent, greaterThan(0));
      expect(pages.last.focusUnits, hasLength(1));
      final heading = pages.first.items.whereType<TextPlacement>().first;
      expect(
        pages.first.focusUnits.first.hitTest(
          ui.Offset(heading.x + 5, heading.y + 5),
        ),
        false,
      );
      final state = FocusReadingState()..attach(pages.first, style.marginTop);
      final before = state.progression;
      state.scroll(pages.first.scrollExtent / 2);
      expect(state.progression, greaterThan(before));
      final anchor = state.anchor;
      state.attach(pages.last, style.marginTop);
      state.attach(pages.first, style.marginTop);
      expect(state.anchor, anchor);
    },
  );
  test('tall lists retain root descendants and separate authored ownership', () {
    final section = parseSection(
      '<p>Introduction.</p><ul><li>${'Long root. ' * 120}<ul><li>Nested</li></ul></li><li>Last</li></ul><ul><li>Independent</li></ul>',
    );
    final pages = LayoutEngine().paginate(
      section,
      const LayoutViewport(width: 320, height: 400),
      const ReaderStyle(focusMode: true),
    );
    addTearDown(() {
      for (final page in pages) {
        page.dispose();
      }
    });
    expect(pages, hasLength(1));
    expect(pages.single.focusUnits, hasLength(4));
    final nested = section.blocks.whereType<TextBlock>().firstWhere(
      (b) => b.plainText == 'Nested',
    );
    expect(pages.single.focusUnits[1].contains(nested.source!.start), true);
  });
  test(
    'figures retain ordinary caption paragraphs and endnotes retain boundaries',
    () {
      final figure = parseSection(
        '<figure><img src="a.png"/><p>Figure 1. A caption.</p><p>Source: Author.</p></figure>',
      );
      expect((figure.blocks.single as FigureBlock).captions, hasLength(2));
      final notes = parseSection(
        '<p>Text<a role="doc-noteref" href="#n1">1</a><a role="doc-noteref" href="#n2">2</a></p><ol><li id="n1" role="doc-endnote"><p>First note.</p><p>Continuation.</p></li><li id="n2" role="doc-endnote">Second note.</li></ol>',
      );
      expect(notes.blocks.whereType<NoteBlock>(), hasLength(2));
      expect(notes.anchors.map((a) => a.fragment), containsAll(['n1', 'n2']));
    },
  );
  test(
    'local citations support multiple works and years without confusing notation',
    () {
      final section = parseSection(
        '<p>Studies (Smith, 2020, 2021; Jones &amp; Brown, 2019). See [2-4]. Array [2, 4]. Updated (January 1, 2020).</p>',
      );
      final groups = localCitationGroups(section);
      expect(groups, hasLength(2));
      final composed = composeSemanticLayout(section, section, groups);
      expect(
        composed.blocks
            .whereType<TextBlock>()
            .single
            .inlines
            .whereType<TextRun>()
            .where((run) => run.style.inlineCitation > 0),
        hasLength(2),
      );
      expect(localCitationGroups(composed), isEmpty);
      expect(
        headingCandidate(
          parseSection('<p>Ordinary short prose</p>').blocks.single,
        ),
        false,
      );
      expect(
        headingCandidate(
          parseSection('<p>Chapter IV: The book</p>').blocks.single,
        ),
        true,
      );
      expect(
        headingCandidate(parseSection('<p>2.1 Methods</p>').blocks.single),
        true,
      );
    },
  );
  test(
    'colons split prose but preserve URLs, times and paired punctuation',
    () {
      expect(SentenceStructure.boundaries('Note: Next step.'), hasLength(1));
      expect(
        SentenceStructure.boundaries(
          '时间12:30，比例1：2，网址https://example.com:8080/a，继续。',
        ),
        isEmpty,
      );
      expect(SentenceStructure.boundaries('“说明：保持完整”以及（备注：不拆开）。'), isEmpty);
    },
  );
  test(
    'separate table labels and titles share a baseline while retaining source nodes',
    () {
      final section = parseSection(
        '<p id="number">Table 1</p><p id="title">A descriptive title that can wrap naturally across the available width</p><table><tr><td>Cell</td></tr></table>',
      );
      final table = section.blocks.single as TableBlock;
      expect(table.before, hasLength(2));
      final pages = LayoutEngine().paginate(
        section,
        const LayoutViewport(width: 360, height: 700),
        const ReaderStyle(),
      );
      addTearDown(() {
        for (final page in pages) {
          page.dispose();
        }
      });
      final placements = pages.first.items.whereType<TextPlacement>().toList();
      expect(placements, hasLength(2));
      expect(
        placements[0].y + placements[0].lineMetrics.first.baseline,
        closeTo(
          placements[1].y + placements[1].lineMetrics.first.baseline,
          .01,
        ),
      );
      expect(
        placements[0].source!.start.node,
        isNot(placements[1].source!.start.node),
      );
      expect(placements[1].lineMetrics.length, greaterThan(1));
      expect(placements[1].syntheticPrefixLength, greaterThan(0));
    },
  );
  test(
    'caption labels are bold without changing source text or body styling',
    () {
      const inlines = [TextRun('Figure '), TextRun('3.2. A caption')];
      final output = emphasizeCaptionLabel(inlines);
      expect(
        output.whereType<TextRun>().map((run) => run.text).join(),
        'Figure 3.2. A caption',
      );
      expect(output.whereType<TextRun>().first.style.bold, true);
      expect(output.whereType<TextRun>().last.style.bold, false);
    },
  );
  test(
    'new formula recognition invalidates incompatible cached translations and permits retry',
    () async {
      final section = parseSection('<p>Original text.</p>', spineIndex: 0);
      final source = MutableSource(section);
      final translated = TranslationBookSource(source)..enabled = true;
      await translated.storeBatch(0, const [
        BlockTranslation(blockIndex: 0, text: '译文。'),
      ]);
      final original = section.blocks.single as TextBlock;
      source.section = Section(
        id: section.id,
        spineIndex: 0,
        href: section.href,
        blocks: [
          withInlines(original, [
            ...original.inlines,
            const MathInline('x', original: [TextRun('x')]),
          ]),
        ],
      );
      final fallback = await translated.parseSection(0);
      expect(
        (fallback.blocks.single as TextBlock).inlines.whereType<MathInline>(),
        hasLength(1),
      );
      expect(
        await translated.untranslatedBlocksForNodes(0, {original.nodeId}),
        hasLength(1),
      );
    },
  );
}
