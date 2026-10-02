import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:torto/core/ir/ir.dart';
import 'package:torto/core/ir/inline_content.dart';
import 'package:torto/core/layout/footnote_numbering.dart';
import 'package:torto/core/layout/layout_engine.dart';
import 'package:torto/core/layout/layout_types.dart';
import 'package:torto/app/reader/reader_controller.dart';

TextRun note(String text, {String? link}) => TextRun(
  text,
  link: link,
  style: TextStyle(
    inlineRole: link == null ? InlineRole.footnote : InlineRole.normal,
    linkRole: link == null ? LinkRole.normal : LinkRole.footnoteReference,
  ),
);
Section section(List<Block> blocks) => Section(
  id: const SpineItemId.generated(0),
  spineIndex: 0,
  href: 'a.xhtml',
  blocks: blocks,
);
TextBlock text(String id) => TextBlock(
  nodeId: id,
  inlines: [const TextRun('Body text'), note('Original note')],
);
List<int> numbers(Section s) => [
  for (final b in s.blocks)
    for (final p in blockTexts(b))
      for (final r in p.inlines.whereType<TextRun>())
        if (r.style.footnoteNumber > 0) r.style.footnoteNumber,
];

class NotesController extends ReaderController {
  final List<PageLayout> pages;
  NotesController(this.pages) {
    opened = true;
  }
  @override
  List<PageLayout> get currentPages => pages;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'styled fragments coalesce; repeat occurrences and citations stay distinct',
    () {
      final block = TextBlock(
        nodeId: 'p',
        inlines: [
          const TextRun('Body'),
          note('[', link: 'a#n'),
          note('40', link: 'a#n'),
          note(']', link: 'a#n'),
          const TextRun(' '),
          note('[40]', link: 'a#n'),
          note('[40]', link: 'a#n'),
          const TextRun('(Smith, 2000)', style: TextStyle(inlineCitation: 1)),
        ],
      );
      final original = section([block, text('second')]);
      final numbered = numberFootnotes(original);
      expect(numbers(numbered), [1, 1, 1, 2, 3, 1]);
      expect(numbers(original), isEmpty);
      final runs = coalesceNumberedFootnotes(
        (numbered.blocks.first as TextBlock).inlines,
      ).whereType<TextRun>().where((r) => r.style.footnoteNumber > 0).toList();
      expect(runs.map((r) => r.text), ['[40]', '[40]', '[40]']);
      expect((numbered.blocks.first as TextBlock).plainText, block.plainText);
    },
  );
  test('quotes tables and complete lists share desktop numbering scopes', () {
    final quote = QuoteBlock(body: [text('q1'), text('q2')]);
    final table = TableBlock(
      before: [text('before')],
      after: [text('after')],
      rows: [
        TableRow([TableCell(inlines: text('cell').inlines)]),
      ],
    );
    final original = section([
      quote,
      table,
      text('intro'),
      TextBlock(
        kind: TextBlockKind.listItem,
        listGroupId: 'list',
        inlines: text('l1').inlines,
      ),
      TextBlock(
        kind: TextBlockKind.listItem,
        listGroupId: 'list',
        inlines: text('l2').inlines,
      ),
      text('after-list'),
    ]);
    expect(numbers(numberFootnotes(original)), [1, 2, 1, 2, 3, 1, 2, 3, 1]);
  });
  test(
    'popup numbering survives page slices and gathers the complete paragraph',
    () async {
      SharedPreferences.setMockInitialValues({});
      final block = TextBlock(
        nodeId: 'p',
        inlines: [
          for (var i = 0; i < 12; i++) ...[
            TextRun('Repeated body text. ' * 4),
            note('note $i'),
          ],
        ],
      );
      final pages = LayoutEngine().paginate(
        section([block]),
        const LayoutViewport(width: 360, height: 230),
        const ReaderStyle(),
      );
      expect(pages.length, greaterThan(1));
      final controller = NotesController(pages);
      final selected = pages.first.items
          .whereType<TextPlacement>()
          .first
          .links
          .first;
      final entries = await controller.referenceNotes(selected);
      expect(entries.map((n) => n.displayMarker), [
        for (var i = 1; i <= 12; i++) '$i',
      ]);
      expect(entries.map((n) => n.text), [
        for (var i = 0; i < 12; i++) 'note $i',
      ]);
      controller.dispose();
      for (final page in pages) {
        page.dispose();
      }
    },
  );
  test('book typography does not acquire display numbering', () {
    final pages = LayoutEngine().paginate(
      section([text('p')]),
      const LayoutViewport(width: 360, height: 700),
      const ReaderStyle(typesettingMode: TypesettingMode.book),
    );
    expect(
      pages.first.items
          .whereType<TextPlacement>()
          .first
          .links
          .single
          .footnoteNumber,
      0,
    );
    for (final page in pages) {
      page.dispose();
    }
  });
  test(
    'bilingual list companions reuse numbers without advancing the list',
    () {
      TextBlock item(String id) => TextBlock(
        nodeId: id,
        kind: TextBlockKind.listItem,
        listGroupId: 'list',
        inlines: [const TextRun('Body'), note('Note')],
      );
      final numbered = numberFootnotes(
        section([
          text('intro'),
          text('intro@translation'),
          item('a'),
          item('a@translation'),
          item('b'),
        ]),
      );
      expect(numbers(numbered), [1, 1, 2, 2, 3]);
    },
  );
}
