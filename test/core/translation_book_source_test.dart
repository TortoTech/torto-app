import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:torto/core/ir/ir.dart';
import 'package:torto/core/ir/text_index.dart';
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
    spine: [
      SpineItem(id: SpineItemId.generated(0), index: 0, href: 'chapter.xhtml'),
    ],
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
    start: SourceAnchor(
      spine: SpineItemId.generated(0),
      node: node,
      textOffset: 0,
    ),
    end: SourceAnchor(
      spine: SpineItemId.generated(0),
      node: node,
      textOffset: value.length,
    ),
  ),
);

void main() {
  test(
    'bilingual paragraphs share original anchors but retain distinct display identities',
    () async {
      final paragraph = _text('Original paragraph.', 'n0');
      final original = _Source(
        Section(
          id: const SpineItemId.generated(0),
          spineIndex: 0,
          href: 'chapter.xhtml',
          blocks: [paragraph],
        ),
      );
      final source = TranslationBookSource(
        original,
        mode: TranslationMode.bilingual,
      );
      await source.storeBatch(0, [
        const BlockTranslation(blockIndex: 0, text: '长度不同的译文段落。'),
      ]);
      source.enabled = true;
      final nodes = sectionTextNodes(await source.parseSection(0)).toList();
      expect(nodes, hasLength(2));
      expect(nodes.map((n) => n.displayId).toSet(), hasLength(2));
      expect(nodes.last.source.start, paragraph.source!.start);
      final selected = SourceRange(
        start: nodes.last.source.start,
        end: SourceAnchor(
          spine: nodes.last.source.start.spine,
          node: 'n0',
          textOffset: 999,
        ),
      );
      final (ranges, quote) = await resolveOriginalParagraphSelection(
        original,
        [selected, selected],
      );
      expect(ranges, hasLength(1));
      expect(ranges.single.toJson(), paragraph.source!.toJson());
      expect(quote, 'Original paragraph.');
    },
  );
  test('protected inline styles and formulas round-trip through markup', () {
    const link = 'chapter.xhtml#note';
    const original = <Inline>[
      TextRun('Important', style: TextStyle(bold: true)),
      TextRun(' emphasis', style: TextStyle(italic: true, emphasis: true)),
      TextRun(' term', style: TextStyle(italic: true, alternateVoice: true)),
      TextRun(' work', style: TextStyle(italic: true, citation: true)),
      TextRun(' visual', style: TextStyle(italic: true)),
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
    expect(encoded, contains('<em> emphasis</em>'));
    expect(encoded, contains('<i> term</i>'));
    expect(encoded, contains('<cite> work</cite>'));
    expect(encoded, contains('<torto-italic> visual</torto-italic>'));
    expect(encoded, contains('<torto-math-0/>'));

    final decoded = TranslationMarkupCodec.decode(
      '<strong>重要</strong><em>强调</em><i>术语</i><cite>作品</cite>'
      '<torto-italic>视觉</torto-italic>'
      '<noteref><sup>1</sup></noteref><torto-math-0/>',
      original,
      language: 'zh-CN',
    );
    expect((decoded[0] as TextRun).style.bold, isTrue);
    expect((decoded[1] as TextRun).style.emphasis, isTrue);
    expect((decoded[2] as TextRun).style.alternateVoice, isTrue);
    expect((decoded[3] as TextRun).style.citation, isTrue);
    expect((decoded[4] as TextRun).style.italic, isTrue);
    expect((decoded[4] as TextRun).style.emphasis, isFalse);
    expect((decoded[5] as TextRun).link, link);
    expect(decoded[6], isA<MathInline>());
  });

  test(
    'translation restores inline images near their relative text position',
    () {
      const image = InlineImageRun(
        image: ImageBlock(href: 'images/chapter-icon.png'),
        sizeScale: 1,
        presentation: true,
      );
      const original = <Inline>[TextRun('Chapter '), image, TextRun('title')];

      expect(TranslationMarkupCodec.encode(original), 'Chapter title');
      final translated = TranslationMarkupCodec.decode(
        '章节标题',
        original,
        language: 'zh-CN',
      );

      final imageIndex = translated.indexWhere(
        (inline) => inline is InlineImageRun,
      );
      expect(imageIndex, greaterThan(0));
      expect(imageIndex, lessThan(translated.length - 1));
      expect(translated[imageIndex], same(image));
      expect(
        translated.whereType<TextRun>().map((run) => run.text).join(),
        '章节标题',
      );
    },
  );

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
        id: SpineItemId.generated(0),
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
      _Source(
        Section(
          id: SpineItemId.generated(0),
          spineIndex: 0,
          href: 'chapter.xhtml',
          blocks: [list],
        ),
      ),
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

  test('note definitions translate nested semantic text blocks', () async {
    final note = NoteBlock(
      kind: NoteBlockKind.definition,
      blocks: [
        _text('Original note', 'note'),
        QuoteBlock(body: [_text('Quoted note', 'note-quote')]),
      ],
    );
    final source = TranslationBookSource(
      _Source(
        Section(
          id: SpineItemId.generated(0),
          spineIndex: 0,
          href: 'chapter.xhtml',
          blocks: [note],
        ),
      ),
    );

    final inputs = await source.untranslatedBlocksForNodes(0, {
      'note',
      'note-quote',
    });
    expect(inputs.map((input) => input.segmentIndex), [0, 1]);
    await source.storeBatch(0, const [
      BlockTranslation(blockIndex: 0, segmentIndex: 0, text: '脚注译文'),
      BlockTranslation(blockIndex: 0, segmentIndex: 1, text: '引用译文'),
    ]);
    source.enabled = true;

    final translated =
        (await source.parseSection(0)).blocks.single as NoteBlock;
    expect((translated.blocks[0] as TextBlock).plainText, '脚注译文');
    expect(
      ((translated.blocks[1] as QuoteBlock).body.single).plainText,
      '引用译文',
    );
  });
}
