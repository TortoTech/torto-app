import 'package:flutter_test/flutter_test.dart';
import 'package:torto/core/formats/pdf/ocr_markup.dart';
import 'package:torto/core/html_ir/note_references.dart';
import 'package:torto/core/ir/ir.dart';
import 'package:torto/core/ir/inline_content.dart';
import 'package:torto/core/layout/sentence_structure.dart';
import 'package:torto/core/translation/translation_markup.dart';

void main() {
  test(
    'small cross-file note markers require a whole notes section and preserve anchors',
    () {
      const anchor = SourceAnchor(
        spine: SpineItemId('chapter'),
        node: 'n',
        textOffset: 0,
      );
      const source = SourceRange(start: anchor, end: anchor);
      const runs = [
        TextRun('1', style: TextStyle(sizeScale: .8), link: 'notes.xhtml#n1'),
        TextRun('2', link: 'notes.xhtml#n2'),
        TextRun(
          'Related chapter',
          style: TextStyle(sizeScale: .8),
          link: 'chapter.xhtml#n',
        ),
      ];
      final section = Section(
        id: const SpineItemId('chapter'),
        spineIndex: 0,
        href: 'chapter.xhtml',
        blocks: [
          TextBlock(
            kind: TextBlockKind.paragraph,
            inlines: runs,
            source: source,
          ),
        ],
      );
      Book book(String href) => Book(
        id: 'book',
        metadata: const BookMetadata(),
        spine: const [],
        toc: [TocEntry(label: 'Notes', href: href)],
      );
      final marked =
          markNoteReferences(section, book('notes.xhtml')).blocks.single
              as TextBlock;
      expect(
        (marked.inlines[0] as TextRun).style.linkRole,
        LinkRole.footnoteReference,
      );
      expect((marked.inlines[1] as TextRun).style.linkRole, LinkRole.normal);
      expect((marked.inlines[2] as TextRun).style.linkRole, LinkRole.normal);
      expect(marked.source, same(source));
      expect(marked.plainText, (section.blocks.single as TextBlock).plainText);
      expect(
        markNoteReferences(section, book('notes.xhtml#n1')),
        same(section),
      );
    },
  );

  test('translated inline images move by identity rather than text length', () {
    const first = InlineImageRun(
      image: ImageBlock(href: 'a.png'),
      sizeScale: 1,
    );
    const second = InlineImageRun(
      image: ImageBlock(href: 'b.png'),
      sizeScale: 1,
    );
    const original = [
      TextRun('A'),
      first,
      TextRun(' long source sentence '),
      second,
    ];
    expect(
      TranslationMarkupCodec.encode(original),
      'A<t-img-0/> long source sentence <t-img-1/>',
    );
    final result = TranslationMarkupCodec.decode(
      '<t-img-1/>Translated<t-img-0/>',
      original,
      language: 'en',
      requireSizeMarkup: true,
    );
    expect(result.first, same(second));
    expect(result.last, same(first));
    for (final malformed in [
      'Missing',
      '<t-img-0/>',
      '<t-img-0/><t-img-0/>',
      '<t-img-0/><t-img-1/><t-img-2/>',
      '<t-img-0 /><t-img-1/>',
    ]) {
      expect(
        () => TranslationMarkupCodec.decode(
          malformed,
          original,
          language: 'en',
          requireSizeMarkup: true,
        ),
        throwsFormatException,
      );
    }
    expect(
      TranslationMarkupCodec.decode(
        'Legacy',
        original,
        language: 'en',
      ).whereType<InlineImageRun>(),
      hasLength(2),
    );
  });

  test('single sentence colon continuations retain complete source text', () {
    for (final value in [
      '是这个道理：没道理。',
      '此时此刻，你的脑正在完成一件惊人的壮举：阅读。',
      'Consider this simple question: What is your birth date?',
      'Note: This explanation is intentionally longer than six words and forty characters.',
      '他说：“快走！”',
      'Note: "Dr. Smith arrived."',
    ]) {
      expect(SentenceStructure.boundaries(value), isEmpty, reason: value);
      expect(
        SentenceStructure.apply([
          TextRun(value),
        ]).whereType<TextRun>().map((r) => r.text).join(),
        value,
      );
    }
    expect(SentenceStructure.boundaries('说明：先理解，再表达。'), contains(3));
    expect(SentenceStructure.boundaries('他说：“第一句。第二句。”'), contains(3));
    final authored = SentenceStructure.apply(const [
      TextRun('说明：'),
      BreakInline(),
      TextRun('下一步。'),
    ]);
    expect(
      authored.whereType<BreakInline>().where((b) => !b.synthetic),
      hasLength(1),
    );
  });

  test('OCR literal tags survive while real wrappers and code stay intact', () {
    expect(
      escapeUnpairedOcrTags('The <div> and <table> elements.'),
      'The &lt;div&gt; and &lt;table&gt; elements.',
    );
    for (final value in [
      'A <div>paired\ncontent</div> wrapper.',
      '<table><tr><td>Cell</td></tr></table>',
      'Use `<div>` in code.\n```html\n<table>\n```',
    ]) {
      expect(escapeUnpairedOcrTags(value), value);
    }
  });

  test('unified captions emphasize only their label', () {
    final result = emphasizeCaptionLabel(const [
      TextRun(
        'Figure 2. Bold italic caption',
        style: TextStyle(
          bold: true,
          italic: true,
          emphasis: true,
          alternateVoice: true,
        ),
      ),
    ]).cast<TextRun>();
    expect(result.first.style.bold, isTrue);
    expect(result.last.style.bold, isFalse);
    expect(result.every((r) => !r.style.italic && !r.style.emphasis), isTrue);
    expect(result.map((r) => r.text).join(), 'Figure 2. Bold italic caption');
  });
}
