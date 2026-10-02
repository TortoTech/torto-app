import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:torto/core/ir/ir.dart';
import 'package:torto/core/ir/text_index.dart';
import 'package:torto/core/layout/layout_engine.dart';
import 'package:torto/core/layout/layout_types.dart';
import 'package:torto/core/semantic_layout/batching.dart';
import 'package:torto/core/semantic_layout/semantic_layout.dart';
import 'package:torto/core/translation/translation_book_source.dart';
import 'package:torto/core/translation/translation_models.dart';
import 'html_ir_parser_test.dart' show parseSection;

class _Source implements BookSource {
  final Section section;
  _Source(this.section);
  @override
  Book get book => Book(
    id: 'test',
    metadata: const BookMetadata(title: 'Test'),
    spine: [SpineItem(id: section.id, index: 0, href: section.href)],
  );
  @override
  Future<Section> parseSection(int index) async => section;
  @override
  Future<Uint8List?> resource(String href) async => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('consecutive scoped tables keep their own captions and notes', () {
    final section = parseSection(
      '''<div class="table"><p>Table 1: First</p><table><tr><td>A</td></tr></table><p>Note: First note</p></div>
      <div class="table"><p>Table 2: Second</p><table><tr><td>B</td></tr></table><p>Source: Second source</p></div>''',
    );
    final tables = section.blocks.whereType<TableBlock>().toList();
    expect(tables.first.before.single.plainText, 'Table 1: First');
    expect(tables.first.after.single.plainText, 'Note: First note');
    expect(tables.last.before.single.plainText, 'Table 2: Second');
    expect(tables.last.after.single.plainText, 'Source: Second source');
  });
  test('table captions and notes retain reading order, anchors and links', () {
    final s = parseSection('''<div class="table">
      <p id="title" class="title">Learning results</p><p><a id="empty"/></p>
      <div><table id="grid"><caption>Native caption</caption><tr><td>A</td></tr></table></div>
      <p id="source">Source: <a href="notes.xhtml#author">Author</a></p>
      </div><p>Following prose.</p>''');
    final t = s.blocks.whereType<TableBlock>().single;
    expect(t.before.map((t) => t.plainText), [
      'Learning results',
      'Native caption',
    ]);
    expect(t.after.single.plainText, 'Source: Author');
    expect(t.after.single.kind, TextBlockKind.paragraph);
    expect(
      t.after.single.inlines.whereType<TextRun>().last.link,
      'OPS/text/notes.xhtml#author',
    );
    expect(sectionTextNodes(s).map((n) => n.text), [
      'Learning results',
      'Native caption',
      'A',
      'Source: Author',
      'Following prose.',
    ]);
    expect(
      s.anchors.firstWhere((a) => a.fragment == 'title').source,
      t.before.first.source!.start,
    );
    expect(
      s.anchors.firstWhere((a) => a.fragment == 'source').source,
      t.after.single.source!.start,
    );
  });
  test('caption-side inheritance and ambiguous neighboring tables', () {
    final s = parseSection(
      '''<div style="caption-side:bottom"><table><caption>Bottom</caption><tr><td>A</td></tr></table></div>
      <p>Table 2: Ambiguous</p><table><tr><td>B</td></tr></table>
      <p>Table 3 shows the result.</p>''',
    );
    final tables = s.blocks.whereType<TableBlock>().toList();
    expect(tables.first.after.single.plainText, 'Bottom');
    expect(tables.last.before, isEmpty);
    expect(s.blocks.whereType<TextBlock>().map((t) => t.plainText), [
      'Table 2: Ambiguous',
      'Table 3 shows the result.',
    ]);
  });
  test('numbered labels attach to native and image tables across wrappers', () {
    final s = parseSection(
      '''<div><p>表1 学习结果</p></div><div><table><tr><td>A</td></tr></table></div>
      <p>Other prose</p><p>Table 2: Image table</p><div><img src="table.png"/></div>''',
    );
    expect(
      s.blocks.whereType<TableBlock>().single.before.single.plainText,
      '表1 学习结果',
    );
    final figure = s.blocks.whereType<FigureBlock>().single;
    expect(figure.captionPosition, CaptionPosition.before);
    expect(figure.captions.single.plainText, 'Table 2: Image table');
  });
  test(
    'nested linked figures preserve separate images captions and source anchors',
    () {
      final s = parseSection(
        '''<p id="before">Body.</p><p id="outer"><span><a id="fig2"/></span><a href="#before"><div><div><p><img src="figure.png" width="297" height="125"/></p></div><div><p class="caption" id="caption"><b>Figure 2</b> Caption text.</p></div></div></a></p><p>After.</p>''',
      );
      expect(s.blocks, hasLength(3));
      final f = s.blocks[1] as FigureBlock;
      expect(f.images.single.href, 'OPS/text/figure.png');
      expect(f.captions.single.plainText, 'Figure 2 Caption text.');
      expect(
        f.captions.single.inlines.whereType<TextRun>().every(
          (r) => r.link == 'OPS/text/ch1.xhtml#before',
        ),
        isTrue,
      );
      expect(
        s.anchors.firstWhere((a) => a.fragment == 'outer').source,
        f.images.single.source!.start,
      );
      expect(
        s.anchors.firstWhere((a) => a.fragment == 'caption').source,
        f.captions.single.source!.start,
      );
    },
  );
  test(
    'nested media preserves surrounding prose and ordinary inline symbols',
    () {
      final s = parseSection(
        '''<p>Leading <span>words.</span><span><div><p class="caption">Diagram</p><p><img src="a.png"/></p><p><img src="b.png"/></p></div></span>Trailing words.</p>
      <p>Symbol <a href="notes.xhtml"><img src="symbol.png"/></a> in prose.</p>''',
      );
      expect((s.blocks[0] as TextBlock).plainText, 'Leading words.');
      expect((s.blocks[1] as FigureBlock).images, hasLength(2));
      expect((s.blocks[2] as TextBlock).plainText, 'Trailing words.');
      expect(
        (s.blocks[3] as TextBlock).inlines.whereType<InlineImageRun>(),
        hasLength(1),
      );
    },
  );
  test(
    'table annotations translate in replacement and bilingual modes',
    () async {
      final s = parseSection(
        '<table><caption>Title</caption><tr><td>Cell</td></tr></table>',
      );
      for (final mode in TranslationMode.values) {
        final source = TranslationBookSource(_Source(s), mode: mode)
          ..enabled = true;
        final table = s.blocks.single as TableBlock;
        final inputs = await source.untranslatedBlocksForNodes(
          0,
          table.translationSegments.map((s) => s.nodeId).toSet(),
        );
        expect(inputs, hasLength(2));
        expect(inputs.first.segmentIndex, 0);
        expect(inputs.first.text, 'Cell');
        await source.storeBatch(0, [
          for (final input in inputs)
            BlockTranslation(
              blockIndex: input.blockIndex,
              segmentIndex: input.segmentIndex,
              text: 'Translated ${input.text}',
            ),
        ]);
        final result =
            (await source.parseSection(0)).blocks.single as TableBlock;
        expect(result.before.last.plainText, 'Translated Title');
        expect(result.before.last.source, table.before.single.source);
        expect(result.before.length, mode == TranslationMode.bilingual ? 2 : 1);
        expect(
          result.rows.single.cells.single.plainText,
          contains('Translated Cell'),
        );
      }
    },
  );
  test(
    'table pagination keeps captions with first rows and notes with last rows',
    () {
      final s = parseSection(
        '<p>${'lead ' * 45}</p><div class="table"><p>Table 1: Results</p><table>${List.generate(12, (i) => '<tr><td>Row $i</td></tr>').join()}</table><p>Source: Author</p></div>',
      );
      final t = s.blocks.whereType<TableBlock>().single;
      for (final height in [180.0, 260.0, 400.0]) {
        final pages = LayoutEngine().paginate(
          s,
          LayoutViewport(width: 320, height: height),
          const ReaderStyle(
            baseFontSize: 12,
            marginTop: 10,
            marginBottom: 10,
            marginLeft: 10,
            marginRight: 10,
          ),
        );
        int pageOf(String node) => pages.indexWhere(
          (p) => p.items.any(
            (item) => switch (item) {
              TextPlacement(:final nodeId) ||
              TableCellPlacement(:final nodeId) => nodeId == node,
              _ => false,
            },
          ),
        );
        expect(
          pageOf(t.before.single.nodeId),
          pageOf(t.rows.first.cells.single.nodeId),
        );
        expect(
          pageOf(t.after.single.nodeId),
          pageOf(t.rows.last.cells.single.nodeId),
        );
        expect(
          pages
              .expand((p) => p.items)
              .whereType<TextPlacement>()
              .where((t2) => t2.nodeId == t.before.single.nodeId),
          hasLength(1),
        );
        for (final p in pages) {
          p.dispose();
        }
      }
    },
  );
  test('inherited Chinese italic becomes bold while Latin stays italic', () {
    final segments = LayoutEngine.debugResolvedSemanticSegments(
      'Scott 中文前言',
      const TextStyle(italic: true),
    );
    expect(
      segments.where((s) => s.text.contains('Scott')).single.italic,
      isTrue,
    );
    final chinese = segments.where((s) => s.text.contains('中文')).single;
    expect(chinese.bold, isTrue);
    expect(chinese.italic, isFalse);
  });
  test(
    'fixed source batches prioritize visible subsections and preserve groups',
    () {
      final s = parseSection(
        '<h2>First</h2><p>${'a' * 3000}</p><p>${'b' * 3000}</p><h2>Second</h2><p>${'c' * 6000}</p><p>Quote</p><p>— Author</p>',
      );
      final plan = semanticBatches(s);
      expect(plan.map((b) => (b.start, b.end)), [
        (0, 2),
        (2, 3),
        (3, 4),
        (4, 5),
        (5, 7),
      ]);
      final demand = demandedSemanticBatches(plan, {4});
      expect(demand.map((b) => b.start), [4, 3, 5]);
      expect(
        plan.every(
          (b) =>
              b.contextStart >= b.subsectionStart &&
              b.contextEnd <= b.subsectionEnd,
        ),
        isTrue,
      );
      expect(demandedSemanticBatches(plan, {2}).first.key, plan[1].key);
      expect(plan.first.sameSubsection(plan[1]), isTrue);
      expect(plan.first.sameSubsection(plan.last), isFalse);
    },
  );
  test('heading eligibility protects formulas footnotes and long prose', () {
    final s = parseSection(
      '<p>How reading develops</p><p>${'word ' * 40}</p><p>Formula <span class="math">x</span></p>',
    );
    expect(headingCandidate(s.blocks[0]), isFalse);
    expect(headingCandidate(s.blocks[1]), isFalse);
    expect(headingCandidate(s.blocks[2]), isFalse);
  });
}
