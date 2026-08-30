import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:torto/core/ir/ir.dart';
import 'package:torto/core/translation/translation_book_source.dart';
import 'package:torto/core/translation/translation_markup.dart';
import 'package:torto/core/translation/translation_models.dart';

class _Source implements BookSource {
  final Section section;

  _Source(this.section);

  @override
  final Book book = const Book(
    id: 'book',
    metadata: BookMetadata(title: 'Book'),
    spine: [SpineItem(index: 0, href: 'chapter.xhtml')],
  );

  @override
  Future<Section> parseSection(int index) async => section;

  @override
  Future<Uint8List?> resource(String href) async => null;
}

TextBlock _text(
  String value,
  String node, {
  TextBlockKind kind = TextBlockKind.paragraph,
  List<Inline>? inlines,
}) => TextBlock(
  kind: kind,
  nodeId: node,
  inlines: inlines ?? [TextRun(value)],
  source: SourceRange(
    start: SourceAnchor(spine: 0, node: node, textOffset: 0),
    end: SourceAnchor(spine: 0, node: node, textOffset: value.length),
  ),
);

void main() {
  test('protected inline styles and formulas round-trip through markup', () {
    const link = 'chapter.xhtml#note';
    const original = <Inline>[
      TextRun('Important', style: TextStyle(bold: true)),
      TextRun(
        '1',
        style: TextStyle(
          baseline: TextBaselineShift.superscript,
          linkRole: LinkRole.footnoteReference,
        ),
        link: link,
      ),
      MathInline('x^2'),
    ];
    final encoded = TranslationMarkupCodec.encode(original);
    expect(encoded, contains('<strong>Important</strong>'));
    expect(encoded, contains('<torto-math-0/>'));

    final decoded = TranslationMarkupCodec.decode(
      '<strong>重要</strong><noteref><sup>1</sup></noteref><torto-math-0/>',
      original,
      language: 'zh-CN',
    );
    expect((decoded[0] as TextRun).style.bold, isTrue);
    expect((decoded[1] as TextRun).link, link);
    expect(decoded[2], isA<MathInline>());
  });

  test(
    'translation source overlays visible semantic blocks and toggles off',
    () async {
      final paragraph = _text('Hello', 'p');
      final quote = QuoteBlock(body: [_text('Quoted', 'q')]);
      final table = TableBlock(
        rows: [
          TableRow([
            TableCell(inlines: const [TextRun('Cell')], nodeId: 'cell'),
          ]),
        ],
      );
      final figure = FigureBlock(
        images: const [ImageBlock(href: 'image.png')],
        captions: [_text('Caption', 'caption', kind: TextBlockKind.caption)],
      );
      final section = Section(
        spineIndex: 0,
        href: 'chapter.xhtml',
        blocks: [paragraph, quote, table, figure],
      );
      final source = TranslationBookSource(_Source(section));
      final inputs = await source.untranslatedBlocksForNodes(0, {
        'p',
        'q',
        'cell',
        'caption',
      });
      expect(inputs, hasLength(4));
      await source.storeBatch(0, [
        const BlockTranslation(blockIndex: 0, text: '你好'),
        const BlockTranslation(blockIndex: 1, segmentIndex: 0, text: '引用'),
        const BlockTranslation(blockIndex: 2, segmentIndex: 0, text: '单元格'),
        const BlockTranslation(blockIndex: 3, segmentIndex: 0, text: '图注'),
      ]);

      source.enabled = true;
      final translated = await source.parseSection(0);
      expect((translated.blocks[0] as TextBlock).plainText, '你好');
      expect((translated.blocks[1] as QuoteBlock).body.single.plainText, '引用');
      expect(
        (translated.blocks[2] as TableBlock).rows.single.cells.single.plainText,
        '单元格',
      );
      expect(
        (translated.blocks[3] as FigureBlock).captions.single.plainText,
        '图注',
      );

      source.enabled = false;
      expect((await source.parseSection(0)).blocks.first, same(paragraph));
    },
  );

  test('bilingual list translation keeps one marker-bearing item', () async {
    final list = TextBlock(
      kind: TextBlockKind.listItem,
      listOrdered: true,
      listOrdinal: 2,
      listDepth: 1,
      nodeId: 'li',
      inlines: const [TextRun('Second item')],
    );
    final source = TranslationBookSource(
      _Source(Section(spineIndex: 0, href: 'chapter.xhtml', blocks: [list])),
      mode: TranslationMode.bilingual,
    );
    await source.storeBatch(0, [
      const BlockTranslation(blockIndex: 0, text: '第二项'),
    ]);
    source.enabled = true;
    final blocks = (await source.parseSection(0)).blocks.cast<TextBlock>();
    expect(blocks, hasLength(2));
    expect(blocks.first.listMarkerVisible, isTrue);
    expect(blocks.last.listMarkerVisible, isFalse);
    expect(blocks.last.listOrdinal, 2);
  });
}
