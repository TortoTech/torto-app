import 'package:flutter_test/flutter_test.dart';
import 'package:torto/core/html_ir/html_ir_parser.dart';
import 'package:torto/core/ir/ir.dart';

Section parseSection(
  String body, {
  int spineIndex = 2,
  String href = 'OPS/text/ch1.xhtml',
  String basePath = 'OPS/text',
  String head = '',
  bool noteSection = false,
  bool Function(String href)? isDecorativeSeparatorImage,
}) {
  final xhtml = '''<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><head>$head</head><body>$body</body></html>''';
  return const HtmlIrParser().parse(
    spineIndex: spineIndex,
    href: href,
    xhtml: xhtml,
    basePath: basePath,
    hints: SectionParseHints(noteSection: noteSection),
    isDecorativeSeparatorImage: isDecorativeSeparatorImage,
  );
}

TextBlock textBlock(Section section, int index) {
  final block = section.blocks[index];
  expect(block, isA<TextBlock>());
  return block as TextBlock;
}

QuoteBlock quoteBlock(Section section, int index) {
  final block = section.blocks[index];
  expect(block, isA<QuoteBlock>());
  return block as QuoteBlock;
}

void main() {
  group('blocks', () {
    test('headings with levels and semantic style', () {
      final section = parseSection('<h1>One</h1><h3>Three</h3>');
      expect(section.blocks, hasLength(2));
      final h1 = textBlock(section, 0);
      expect(h1.kind, TextBlockKind.heading);
      expect(h1.headingLevel, 1);
      expect(h1.plainText, 'One');
      expect((h1.inlines.single as TextRun).style.bold, isTrue);
      expect(
        (h1.inlines.single as TextRun).style.sizeScale,
        closeTo(1.5, 1e-9),
      );
      final h3 = textBlock(section, 1);
      expect(h3.headingLevel, 3);
      expect(
        (h3.inlines.single as TextRun).style.sizeScale,
        closeTo(1.15, 1e-9),
      );
    });

    test('paragraph', () {
      final section = parseSection('<p>Hello world</p>');
      final block = textBlock(section, 0);
      expect(block.kind, TextBlockKind.paragraph);
      expect(block.plainText, 'Hello world');
    });

    test('retains nearest lang and xml:lang on individual text runs', () {
      final section = parseSection(
        '<div lang="en-US"><p>American '
        '<span xml:lang="en-GB">British</span> again</p>'
        '<p lang="fr">Français</p></div>',
      );
      final first = textBlock(section, 0).inlines.whereType<TextRun>().toList();
      final second = textBlock(section, 1).inlines.single as TextRun;

      expect(first.map((run) => run.text), ['American ', 'British', ' again']);
      expect(first.map((run) => run.language), ['en-US', 'en-GB', 'en-US']);
      expect(second.language, 'fr');
    });

    test('blockquote retains quoted paragraphs as a semantic unit', () {
      final section = parseSection('<blockquote><p>quoted</p></blockquote>');
      final quote = quoteBlock(section, 0);
      expect(quote.body, hasLength(1));
      expect(quote.body.single.kind, TextBlockKind.blockquote);
      expect(quote.body.single.plainText, 'quoted');
    });

    test('blockquote keeps alignment authored on its nested paragraph', () {
      final section = parseSection(
        '<blockquote><p style="text-align: right">quoted</p></blockquote>',
      );
      final block = quoteBlock(section, 0).body.single;

      expect(block.kind, TextBlockKind.blockquote);
      expect(block.style.align, BlockAlign.end);
      expect(block.style.authoredAlignment, BlockAlign.end);
    });

    test('preserves alignment from a sole block inline wrapper', () {
      final section = parseSection(
        '<p><span><span class="signature">Visual memo no. 100</span></span></p>'
        '<p>Following prose</p>',
        head: '''<style>
          .signature { display: block; text-align: right; }
        </style>''',
      );

      final signature = textBlock(section, 0);
      final prose = textBlock(section, 1);
      expect(signature.style.align, BlockAlign.end);
      expect(signature.style.authoredAlignment, BlockAlign.end);
      expect(prose.style.align, BlockAlign.start);
      expect(prose.style.authoredAlignment, isNull);
    });

    test('pre preserves whitespace and newlines', () {
      final section = parseSection('<pre>line1\n  line2</pre>');
      final block = textBlock(section, 0);
      expect(block.kind, TextBlockKind.preformatted);
      expect(block.plainText, 'line1\n  line2');
    });

    test('blockquote extracts an authored attribution', () {
      final section = parseSection(
        '<blockquote><p>quoted</p><footer>— Author</footer></blockquote>',
      );
      final quote = quoteBlock(section, 0);

      expect(quote.body.single.plainText, 'quoted');
      expect(quote.attribution?.kind, TextBlockKind.quoteAttribution);
      expect(quote.attribution?.plainText, '— Author');
    });

    test('blockquote retains stanza spacing between sibling paragraphs', () {
      final section = parseSection(
        '<blockquote><p>first</p><br/><p>second</p></blockquote>',
      );
      final quote = quoteBlock(section, 0);

      expect(quote.body, hasLength(2));
      expect(quote.body.first.style.hardBreakAfter, isTrue);
      expect(quote.body.last.style.hardBreakAfter, isFalse);
    });

    test('definition lists retain term and description semantics', () {
      final section = parseSection('<dl><dt>Term</dt><dd>Meaning</dd></dl>');

      expect(textBlock(section, 0).kind, TextBlockKind.definitionTerm);
      expect(textBlock(section, 0).plainText, 'Term');
      expect(textBlock(section, 1).kind, TextBlockKind.definitionDescription);
      expect(textBlock(section, 1).plainText, 'Meaning');
    });

    test('adjacent inferred captions stay separate semantic siblings', () {
      final section = parseSection(
        '<p><img src="chart.png"/></p><p class="caption">Figure 1. Data</p>',
      );
      expect(section.blocks, hasLength(2));
      final image = section.blocks.first as ImageBlock;
      final caption = section.blocks.last as TextBlock;

      expect(image.href, 'OPS/text/chart.png');
      expect(caption.kind, TextBlockKind.caption);
      expect(caption.plainText, 'Figure 1. Data');
    });

    test('infers adjacent captions inside a block-only container', () {
      final section = parseSection(
        '<section><p><img src="chart.png"/></p>'
        '<p class="figcaption">图 2 系统结构</p></section>',
      );

      expect(section.blocks, hasLength(2));
      expect(section.blocks.first, isA<ImageBlock>());
      expect((section.blocks.last as TextBlock).kind, TextBlockKind.caption);
    });

    test('publication note-section hints wrap the section semantically', () {
      final section = parseSection(
        '<h2>Notes</h2><p>One note.</p>',
        noteSection: true,
      );

      expect(section.blocks, hasLength(2));
      expect(section.blocks.every((block) => block is NoteBlock), isTrue);
      expect(
        section.blocks
            .cast<NoteBlock>()
            .expand((note) => note.blocks)
            .whereType<TextBlock>()
            .map((block) => block.plainText),
        ['Notes', 'One note.'],
      );
    });

    test('recognizes a structural quote and right-aligned attribution', () {
      final section = parseSection(
        '<div class="quote-card"><p class="quote-body">Quoted prose.</p>'
        '<p class="quote-tail">— Author</p></div>',
        head: '''<style>
          .quote-card { padding: 5px; background-color: #eee; }
          .quote-body { margin: 1em 2em; font-style: italic; }
          .quote-tail { margin: 0 2em 2em 0; text-align: right; }
        </style>''',
      );

      final quote = section.blocks.single as QuoteBlock;
      expect(quote.body.single.plainText, 'Quoted prose.');
      expect(quote.attribution?.plainText, '— Author');
      expect(quote.attribution?.kind, TextBlockKind.quoteAttribution);
    });

    test('groups sibling verse lines, stanza break, and attribution', () {
      final section = parseSection(
        '<p class="verse-line">Line one</p>'
        '<p class="verse-line">Line two</p>'
        '<p class="verse-line">Line three</p><br/>'
        '<p class="verse-line">Line four</p>'
        '<p class="verse-source">Poet</p>',
        head: '''<style>
          .verse-line {
            font-style: italic; line-height: 130%; text-align: justify;
            text-indent: 2em; margin: 4pt 2em;
          }
          .verse-source {
            font-size: .83333em; line-height: 130%; text-align: right;
            text-indent: 2em; margin: .8em 0 5pt;
          }
        </style>''',
      );

      final quote = section.blocks.single as QuoteBlock;
      expect(quote.body.map((block) => block.plainText), [
        'Line one',
        'Line two',
        'Line three',
        'Line four',
      ]);
      expect(quote.body[2].style.hardBreakAfter, isTrue);
      expect(quote.attribution?.plainText, 'Poet');
    });

    test('repeated inset prose without quote typography remains prose', () {
      final section = parseSection(
        '<p class="indented">First prose paragraph.</p>'
        '<p class="indented">Second prose paragraph.</p>',
        head: '<style>.indented { margin: 1em 2em; }</style>',
      );

      expect(section.blocks, hasLength(2));
      expect(section.blocks.every((block) => block is TextBlock), isTrue);
    });

    test('quote-like class without quote layout remains prose', () {
      final section = parseSection(
        '<p class="quote-status">A normal status paragraph.</p>'
        '<p class="quote-aside">A one-sided aside.</p>',
        head: '''<style>
          .quote-status { margin: 1em 0; text-indent: 0; }
          .quote-aside { margin: 1em 0 1em 2em; }
        </style>''',
      );

      expect(section.blocks, hasLength(2));
      expect(section.blocks.every((block) => block is TextBlock), isTrue);
    });

    test('visually bounded card without role difference is not a quote', () {
      final section = parseSection(
        '<div class="card"><p>Ordinary card text.</p>'
        '<p class="tail">Metadata</p></div>',
        head: '''<style>
          .card { padding: 5px; background-color: #eee; }
          .tail { text-align: right; }
        </style>''',
      );

      expect(section.blocks, hasLength(2));
      expect(section.blocks.every((block) => block is TextBlock), isTrue);
    });

    test('finds sibling quotes inside a mixed-content container', () {
      final section = parseSection(
        '<div>Introduction '
        '<p class="verse-line">First line</p>'
        '<p class="verse-line">Second line</p>'
        '<p class="verse-source">Source</p></div>',
        head: '''<style>
          .verse-line { margin: 4pt 2em; font-style: italic; }
          .verse-source { margin: 4pt 0; font-size: .8em; text-align: right; }
        </style>''',
      );

      expect(section.blocks, hasLength(2));
      expect((section.blocks.first as TextBlock).plainText, 'Introduction');
      final quote = section.blocks.last as QuoteBlock;
      expect(quote.body, hasLength(2));
      expect(quote.attribution?.plainText, 'Source');
    });

    test('semantic blockquote keeps direct cite as attribution', () {
      final section = parseSection(
        '<blockquote><p>Quoted text.</p><cite>Book title</cite></blockquote>',
      );

      final quote = section.blocks.single as QuoteBlock;
      expect(quote.body.single.plainText, 'Quoted text.');
      expect(quote.attribution?.plainText, 'Book title');
      expect(quote.attribution?.style.align, BlockAlign.start);
    });

    test('groups multi-block implicit note definitions', () {
      final section = parseSection(
        '<div class="footnotes"><p id="n1"><a href="#r1">1</a> First paragraph.</p>'
        '<p>Continuation.</p>'
        '<p id="n2"><a href="#r2">2</a> Second note.</p></div>'
        '<p><a id="r1" href="#n1">1</a><a id="r2" href="#n2">2</a></p>',
      );

      final notes = section.blocks.whereType<NoteBlock>().toList();
      expect(notes, hasLength(2));
      expect(notes.first.blocks.whereType<TextBlock>(), hasLength(2));
    });

    test('retains TeX math semantics and standalone block breaks', () {
      final section = parseSection(
        '<p><span class="math math-display">E=mc^2</span></p><br/>',
      );

      final paragraph = section.blocks.first as TextBlock;
      final formula = paragraph.inlines.single as MathInline;
      expect(formula.latex, 'E=mc^2');
      expect(formula.display, isTrue);
      expect(paragraph.style.align, BlockAlign.center);
      expect(section.blocks.last, isA<LineBreakBlock>());
    });

    test('does not center display math mixed with ordinary prose', () {
      final section = parseSection(
        '<p>Before <span class="math math-display">x^2</span></p>',
      );

      expect(
        (section.blocks.single as TextBlock).style.align,
        BlockAlign.start,
      );
    });

    test('classifies only approved thin images as ornaments', () {
      final section = parseSection(
        '<p><img src="rule.png" alt="separator"/></p>',
        isDecorativeSeparatorImage: (href) => href.endsWith('rule.png'),
      );

      final separator = section.blocks.single as SeparatorBlock;
      expect(separator.kind, SeparatorKind.ornament);
      expect(separator.image?.href, 'OPS/text/rule.png');
    });

    test('ordered, unordered, and nested lists', () {
      final section = parseSection(
        '<ol><li>one</li><li>two<ul><li>sub</li></ul></li></ol>',
      );
      expect(section.blocks, hasLength(3));
      final one = textBlock(section, 0);
      expect(one.kind, TextBlockKind.listItem);
      expect(one.listOrdered, isTrue);
      expect(one.listOrdinal, 1);
      expect(one.listDepth, 0);
      final two = textBlock(section, 1);
      expect(two.listOrdinal, 2);
      final sub = textBlock(section, 2);
      expect(sub.listOrdered, isFalse);
      expect(sub.listOrdinal, 1);
      expect(sub.listDepth, 1);
      expect(sub.plainText, 'sub');
    });

    test('ordered lists preserve start, value, and reversed numbering', () {
      final section = parseSection(
        '<ol start="3"><li>a</li><li value="8">b</li></ol>'
        '<ol reversed="reversed"><li>c</li><li>d</li></ol>',
      );
      final items = section.blocks.cast<TextBlock>();
      expect(items.map((item) => item.listOrdinal), [3, 8, 2, 1]);
    });

    test('recovers CSS hanging paragraphs as nested list items', () {
      const head = '''
        <style>
          .bullet { margin-left: 24px; text-indent: -12px; }
          .bulletind { margin-left: 48px; text-indent: -12px; }
          .bulletind2 { margin-left: 72px; text-indent: -12px; }
        </style>
      ''';
      final section = parseSection(
        '<p class="bullet"><span class="enumerator">•</span> Parent</p>'
        '<p class="bulletind">Child continuation</p>'
        '<p class="bulletind2"><span class="enumerator">▪</span> Grandchild</p>'
        '<p class="bullet"><span class="enumerator">•</span> Next parent</p>',
        head: head,
      );
      final items = section.blocks.cast<TextBlock>();

      expect(
        items.map((item) => item.kind),
        everyElement(TextBlockKind.listItem),
      );
      expect(items.map((item) => item.listDepth), [0, 1, 2, 0]);
      expect(items.map((item) => item.listMarkerVisible), [
        true,
        false,
        true,
        true,
      ]);
      expect(items.map((item) => item.plainText), [
        'Parent',
        'Child continuation',
        'Grandchild',
        'Next parent',
      ]);
      expect(items.every((item) => item.style.indent == 0), isTrue);
    });

    test('block paragraphs inside list items keep line boundaries', () {
      final section = parseSection(
        '<ul><li><p>first paragraph</p><p>second paragraph</p></li></ul>',
      );
      final item = textBlock(section, 0);
      expect(item.plainText, 'first paragraphsecond paragraph');
      expect(item.inlines.whereType<BreakInline>(), hasLength(1));
    });

    test('hr becomes a separator block', () {
      final section = parseSection('<p>a</p><hr/><p>b</p>');
      expect(section.blocks[1], isA<SeparatorBlock>());
    });

    test('br becomes a break inline', () {
      final section = parseSection('<p>a<br/>b</p>');
      final block = textBlock(section, 0);
      expect(block.inlines[1], isA<BreakInline>());
      expect(block.plainText, 'a\nb');
    });

    test('transparent containers lift mixed content into paragraphs', () {
      final section = parseSection(
        '<div>loose text<p>para</p><section><p>nested</p></section></div>',
      );
      expect(section.blocks, hasLength(3));
      expect(textBlock(section, 0).plainText, 'loose text');
      expect(textBlock(section, 1).plainText, 'para');
      expect(textBlock(section, 2).plainText, 'nested');
    });

    test(
      'figure keeps its image and trailing caption as one semantic block',
      () {
        final section = parseSection(
          '<figure><img src="i.png" alt="diagram"/>'
          '<figcaption><p>A <b>caption</b></p></figcaption></figure>',
        );
        final figure = section.blocks.single as FigureBlock;

        expect(figure.images, hasLength(1));
        expect(figure.images.single.href, 'OPS/text/i.png');
        expect(figure.images.single.alt, 'diagram');
        expect(figure.captionPosition, CaptionPosition.after);
        expect(figure.captions, hasLength(1));
        expect(figure.captions.single.kind, TextBlockKind.caption);
        expect(figure.captions.single.plainText, 'A caption');
        expect(
          figure.captions.single.inlines.whereType<TextRun>().last.style.bold,
          isTrue,
        );
        expect(figure.images.single.source, same(figure.source));
      },
    );

    test('figure detects a caption placed before its image', () {
      final section = parseSection(
        '<figure><figcaption>Before</figcaption><img src="i.png"/></figure>',
      );
      final figure = section.blocks.single as FigureBlock;

      expect(figure.captionPosition, CaptionPosition.before);
      expect(figure.captions.single.plainText, 'Before');
    });

    test('captionless figure remains a semantic figure', () {
      final section = parseSection('<figure><img src="i.png"/></figure>');
      final figure = section.blocks.single as FigureBlock;

      expect(figure.images, hasLength(1));
      expect(figure.captions, isEmpty);
    });

    test('tables preserve grid cells, headers, spans, and alignment', () {
      final section = parseSection(
        '<table><tr><th colspan="2">H</th></tr>'
        '<tr><td rowspan="2" style="text-align:right">a</td><td>b</td></tr>'
        '<tr><td>c</td></tr></table>',
      );
      final table = section.blocks.single as TableBlock;
      expect(table.rows, hasLength(3));
      final header = table.rows[0].cells.single;
      expect(header.header, isTrue);
      expect(header.columnSpan, 2);
      expect((header.inlines.single as TextRun).style.bold, isTrue);
      final spanning = table.rows[1].cells.first;
      expect(spanning.rowSpan, 2);
      expect(spanning.authoredAlignment, BlockAlign.end);
      expect(table.rows[2].cells.single.plainText, 'c');
    });

    test('table cells retain nested and inherited authored alignment', () {
      final section = parseSection(
        '<table><tr>'
        '<td><p class="left">Left paragraph</p></td>'
        '<td class="right">Right cell</td>'
        '<td>Default cell</td>'
        '</tr></table>'
        '<table class="centered"><tr><td>Inherited center</td></tr></table>',
        head: '''<style>
          .left { text-align: left; }
          .right { text-align: right; }
          .centered { text-align: center; }
        </style>''',
      );

      final first = section.blocks[0] as TableBlock;
      expect(first.rows.single.cells[0].authoredAlignment, BlockAlign.start);
      expect(first.rows.single.cells[1].authoredAlignment, BlockAlign.end);
      expect(first.rows.single.cells[2].authoredAlignment, isNull);
      final inherited = section.blocks[1] as TableBlock;
      expect(
        inherited.rows.single.cells.single.authoredAlignment,
        BlockAlign.center,
      );
    });

    test('table cell paragraphs retain line boundaries', () {
      final section = parseSection(
        '<table><tr><td><p>line one</p><p>line two</p></td></tr></table>',
      );
      final table = section.blocks.single as TableBlock;
      expect(table.rows.single.cells.single.plainText, 'line one\nline two');
    });

    test('page-break-before/after emit PageBreakBlocks', () {
      final section = parseSection(
        '<p style="page-break-before: always; page-break-after: always">x</p>',
      );
      expect(section.blocks[0], isA<PageBreakBlock>());
      expect(section.blocks[1], isA<TextBlock>());
      expect(section.blocks[2], isA<PageBreakBlock>());
    });

    test('only authored blank-line markers become spacing separators', () {
      final section = parseSection(
        '<p>   </p><p>&#160;</p><p><img src="only.png"/></p>',
      );
      expect(section.blocks, hasLength(2));
      expect(
        (section.blocks.first as SeparatorBlock).kind,
        SeparatorKind.spacing,
      );
      expect(section.blocks.last, isA<ImageBlock>());
    });
  });

  group('inline styles', () {
    test('nested styles accumulate', () {
      final section = parseSection('<p>a <b>bold <i>both</i></b> tail</p>');
      final runs = textBlock(section, 0).inlines.cast<TextRun>();
      expect(runs.map((r) => r.text), ['a ', 'bold ', 'both', ' tail']);
      expect(runs[1].style.bold, isTrue);
      expect(runs[1].style.italic, isFalse);
      expect(runs[2].style.bold, isTrue);
      expect(runs[2].style.italic, isTrue);
      expect(runs[3].style.bold, isFalse);
    });

    test('keeps em-sized presentation images inline with heading text', () {
      final section = parseSection('''
        <style>
          img.height-1em { height: 1em; vertical-align: middle; }
        </style>
        <h2><img alt="" class="height-1em" role="presentation"
          src="../images/chapter-icon.jpg"/>Chapter title</h2>
      ''');

      expect(section.blocks, hasLength(1));
      final heading = section.blocks.single as TextBlock;
      expect(heading.kind, TextBlockKind.heading);
      expect(heading.headingLevel, 2);
      expect(heading.inlines, hasLength(2));
      final image = heading.inlines.first as InlineImageRun;
      final text = heading.inlines.last as TextRun;
      expect(image.image.href, 'OPS/images/chapter-icon.jpg');
      expect(image.presentation, isTrue);
      expect(image.intrinsicSizing, isFalse);
      expect(image.verticalAlign, InlineImageAlignment.middle);
      expect(image.sizeScale, text.style.sizeScale);
      expect(text.text, 'Chapter title');
      expect(section.blocks.whereType<ImageBlock>(), isEmpty);
    });

    test('meaningful heading images remain block-level illustrations', () {
      final section = parseSection(
        '<h2><img alt="Diagram" style="display:block;height:1em" '
        'src="../images/diagram.jpg"/>Chapter title</h2>',
      );

      expect(section.blocks, hasLength(2));
      expect(section.blocks.first, isA<TextBlock>());
      expect(section.blocks.last, isA<ImageBlock>());
    });

    test(
      'keeps formula rasters inline from text context rather than class',
      () {
        final section = parseSection('''
        <style>img.block { vertical-align: middle; }</style>
        <p>Compare <img alt="Image" class="block" src="../images/pv.jpg"/>
          versus <span><img alt="Image" class="block"
          src="../images/nv.jpg"/></span> today.</p>
      ''');

        final paragraph = section.blocks.single as TextBlock;
        final images = paragraph.inlines.whereType<InlineImageRun>().toList();
        expect(images, hasLength(2));
        expect(images.every((image) => image.intrinsicSizing), isTrue);
        expect(
          images.every(
            (image) => image.verticalAlign == InlineImageAlignment.middle,
          ),
          isTrue,
        );
        expect(images.first.image.alt, 'Image');
        expect(images.first.image.href, 'OPS/images/pv.jpg');
        expect(images.last.image.href, 'OPS/images/nv.jpg');
      },
    );

    test('keeps image-only equations as block images', () {
      final section = parseSection(
        '<p><img alt="Equation" height="17" width="255" '
        'src="../images/equation.jpg"/></p>',
      );
      expect(section.blocks, hasLength(1));
      expect(section.blocks.single, isA<ImageBlock>());
    });

    test('cite em and i keep distinct semantic roles', () {
      final section = parseSection(
        '<p><cite>Work</cite> <em>stress</em> <i>term</i> '
        '<span style="font-style: italic">visual</span></p>',
      );
      final runs = textBlock(section, 0).inlines.whereType<TextRun>().toList();
      TextRun byText(String value) =>
          runs.firstWhere((run) => run.text.trim() == value);

      expect(byText('Work').style.citation, isTrue);
      expect(byText('Work').style.emphasis, isFalse);
      expect(byText('stress').style.emphasis, isTrue);
      expect(byText('stress').style.alternateVoice, isFalse);
      expect(byText('term').style.alternateVoice, isTrue);
      expect(byText('term').style.citation, isFalse);
      expect(byText('visual').style.italic, isTrue);
      expect(byText('visual').style.emphasis, isFalse);
      expect(byText('visual').style.alternateVoice, isFalse);
      expect(byText('visual').style.citation, isFalse);
    });

    test('a cite quote attribution keeps citation semantics', () {
      final section = parseSection(
        '<blockquote><p>Quoted prose.</p><cite>The source</cite></blockquote>',
      );
      final quote = section.blocks.single as QuoteBlock;
      final run = quote.attribution!.inlines.whereType<TextRun>().single;
      expect(run.style.citation, isTrue);
      expect(run.style.italic, isTrue);
    });

    test('u/ins/s/del/sup/sub', () {
      final section = parseSection(
        '<p><u>u</u><ins>i</ins><s>s</s><del>d</del>x<sup>2</sup>y<sub>n</sub></p>',
      );
      final runs = textBlock(section, 0).inlines.cast<TextRun>();
      TextRun byText(String t) => runs.firstWhere((r) => r.text == t);
      // Adjacent runs with equal style merge.
      expect(byText('ui').style.underline, isTrue);
      expect(byText('sd').style.strikethrough, isTrue);
      expect(byText('2').style.baseline, TextBaselineShift.superscript);
      expect(byText('n').style.baseline, TextBaselineShift.subscript);
    });

    test('preserves inherited CSS hyphenation policy', () {
      final section = parseSection('''
        <p style="hyphens:none">disabled
          <span style="hyphens:manual">manual</span>
          <span style="hyphens:auto">automatic</span></p>
      ''');
      final runs = textBlock(section, 0).inlines.whereType<TextRun>().toList();
      TextRun containing(String value) =>
          runs.firstWhere((run) => run.text.contains(value));
      expect(containing('disabled').style.hyphenation, HyphenationMode.none);
      expect(containing('manual').style.hyphenation, HyphenationMode.manual);
      expect(containing('automatic').style.hyphenation, HyphenationMode.auto);
    });

    test('links resolve root-relative and keep fragments', () {
      final section = parseSection('<p><a href="../ch2.xhtml#s1">go</a></p>');
      final run = textBlock(section, 0).inlines.single as TextRun;
      expect(run.link, 'OPS/ch2.xhtml#s1');
    });

    test('fragment-only link resolves against the section href', () {
      final section = parseSection('<p><a href="#here">go</a></p>');
      final run = textBlock(section, 0).inlines.single as TextRun;
      expect(run.link, 'OPS/text/ch1.xhtml#here');
    });

    test('classifies EPUB footnote references and backlinks', () {
      final section = parseSection('''
        <p id="body">Text<a epub:type="noteref" href="#note-1"><sup>1</sup></a></p>
        <aside id="note-1" epub:type="footnote"><p><a role="doc-backlink" href="#body">1</a> Note text.</p></aside>
      ''');
      final reference = textBlock(
        section,
        0,
      ).inlines.whereType<TextRun>().firstWhere((run) => run.link != null);
      final note = section.blocks[1] as NoteBlock;
      final definition = note.blocks.single as TextBlock;
      final backlink = definition.inlines.whereType<TextRun>().firstWhere(
        (run) => run.link != null,
      );
      expect(reference.style.linkRole, LinkRole.footnoteReference);
      expect(backlink.style.linkRole, LinkRole.footnoteBacklink);
      expect(
        section.anchors.map((anchor) => anchor.fragment),
        containsAll(['body', 'note-1']),
      );
      expect(
        section.anchors
            .firstWhere((anchor) => anchor.fragment == 'note-1')
            .source
            .node,
        definition.nodeId,
      );
    });

    test('turns an image-backed EPUB noteref into a footnote marker', () {
      final section = parseSection('''
        <aside epub:type="footnote" id="footnote-18-20">
          <ol class="duokan-footnote-content">
            <li class="duokan-footnote-item">国际知名的演说家、作家。——译者注</li>
          </ol>
        </aside>
        <p>网站&#160;<sup><a epub:type="noteref" href="#footnote-18-20"> <img
          src="../images/image_010.png"
          alt="国际知名的演说家、作家。——译者注"
          zy-footnote="国际知名的演说家、作家。——译者注"
          class="epub-footnote"/></a></sup>以及其他网站</p>
      ''');

      expect(section.blocks.whereType<ImageBlock>(), isEmpty);
      final definition = section.blocks
          .whereType<NoteBlock>()
          .single
          .blocks
          .whereType<TextBlock>()
          .single;
      expect(definition.kind, TextBlockKind.footnoteDefinition);
      expect(definition.plainText, contains('国际知名的演说家'));

      final paragraph = section.blocks.whereType<TextBlock>().firstWhere(
        (block) => block.kind == TextBlockKind.paragraph,
      );
      final reference = paragraph.inlines.whereType<TextRun>().firstWhere(
        (run) => run.style.linkRole == LinkRole.footnoteReference,
      );
      expect(reference.text, '译');
      expect(reference.style.baseline, TextBaselineShift.superscript);
      expect(reference.link, 'OPS/text/ch1.xhtml#footnote-18-20');
      expect(paragraph.plainText, contains('网站\u00a0译以及'));
    });

    test('classifies legacy reciprocal footnote links', () {
      final section = parseSection('''
        <p>Text<a id="ref-3" href="#note-3"><sup>[3]</sup></a></p>
        <p><a id="note-3" href="#ref-3">[3]</a> Legacy note.</p>
      ''');
      final reference = textBlock(
        section,
        0,
      ).inlines.whereType<TextRun>().firstWhere((run) => run.link != null);
      final note = section.blocks[1] as NoteBlock;
      final definition = note.blocks.single as TextBlock;
      final backlink = definition.inlines.whereType<TextRun>().firstWhere(
        (run) => run.link != null,
      );
      expect(reference.style.linkRole, LinkRole.footnoteReference);
      expect(backlink.style.linkRole, LinkRole.footnoteBacklink);
    });

    test('split reference anchor hides an image-bearing footnote', () {
      final section = parseSection('''
        <h1>Chapter<a id="ref-1"/><a href="#note-1"><sup>*</sup></a></h1>
        <p>Chapter content.</p>
        <div><p id="note-1"><a href="#ref-1"><sup>*</sup></a>Footnote text.<br/>
          <img alt="diagram" src="../images/diagram.jpg"/></p></div>
      ''');

      final heading = section.blocks.whereType<TextBlock>().first;
      final reference = heading.inlines.whereType<TextRun>().firstWhere(
        (run) => run.style.linkRole == LinkRole.footnoteReference,
      );
      expect(reference.link, 'OPS/text/ch1.xhtml#note-1');
      final note = section.blocks.whereType<NoteBlock>().single;
      expect(note.kind, NoteBlockKind.definition);
      expect(note.blocks.whereType<ImageBlock>(), isNotEmpty);
      expect(section.blocks.whereType<ImageBlock>(), isEmpty);
    });

    test('classifies supported inline footnote classes', () {
      final section = parseSection(
        '<p>Body<span class="minor footnote1">Inline note</span></p>',
      );
      final note = textBlock(section, 0).inlines
          .whereType<TextRun>()
          .firstWhere((run) => run.text.contains('Inline note'));
      expect(note.style.inlineRole, InlineRole.footnote);
    });
  });

  group('CSS subset', () {
    test('specificity: id > class > element; inline style wins', () {
      const head = '''<style>
        p { color: #111111; }
        .x { color: #222222; }
        #y { color: #333333; }
      </style>''';
      final section = parseSection(
        '<p class="x" id="y">t</p><p class="x" id="y" style="color: #444444">u</p>',
        head: head,
      );
      final first = textBlock(section, 0).inlines.single as TextRun;
      expect(first.style.color, 0xFF333333);
      final second = textBlock(section, 1).inlines.single as TextRun;
      expect(second.style.color, 0xFF444444);
    });

    test('later rules win at equal specificity', () {
      const head =
          '<style>.a { color: #111111; } .b { color: #222222; }</style>';
      final section = parseSection('<p class="a b">t</p>', head: head);
      final run = textBlock(section, 0).inlines.single as TextRun;
      expect(run.style.color, 0xFF222222);
    });

    test('block properties: align, margins, indent, line-height', () {
      const head =
          '<style>p.body { text-align: center; margin: 2em 0 1em; '
          'text-indent: 24px; line-height: 1.8; }</style>';
      final section = parseSection('<p class="body">t</p>', head: head);
      final style = textBlock(section, 0).style;
      expect(style.align, BlockAlign.center);
      expect(style.marginBefore, closeTo(32, 1e-9));
      expect(style.marginAfter, closeTo(16, 1e-9));
      expect(style.indent, closeTo(24, 1e-9));
      expect(style.lineHeight, closeTo(1.8, 1e-9));
    });

    test('percentage start margins remain relative to the viewport', () {
      final section = parseSection(
        '<div style="margin-left: 10%"><p style="padding-left: 5%">t</p></div>',
      );
      final style = textBlock(section, 0).style;

      expect(style.marginStartFraction, closeTo(0.15, 1e-9));
      expect(style.marginStart, 0);
    });

    test('logical-axis margin and padding shorthands preserve start inset', () {
      final section = parseSection(
        '<div style="margin-inline: 10px 20px; padding-inline: 6px 8px">'
        '<p>t</p></div>',
      );

      expect(textBlock(section, 0).style.marginStart, closeTo(16, 1e-9));
    });

    test('font-size: px absolute vs 16px base; em multiplies', () {
      final section = parseSection(
        '<p style="font-size: 24px">a<span style="font-size: 2em">b</span></p>',
      );
      final runs = textBlock(section, 0).inlines.cast<TextRun>();
      expect(runs[0].style.sizeScale, closeTo(1.5, 1e-9));
      expect(runs[1].style.sizeScale, closeTo(3.0, 1e-9));
    });

    test('authored font size overrides semantic heading and small scales', () {
      final section = parseSection(
        '<h1 style="font-size: 2em">heading</h1>'
        '<p><small style="font-size: 2em">small</small></p>',
      );

      final heading = textBlock(section, 0).inlines.single as TextRun;
      final small = textBlock(section, 1).inlines.single as TextRun;
      expect(heading.style.sizeScale, closeTo(2, 1e-9));
      expect(small.style.sizeScale, closeTo(2, 1e-9));
    });

    test('font-weight/font-style/text-decoration/vertical-align via CSS', () {
      final section = parseSection(
        '<p><span style="font-weight: 700">a</span>'
        '<span style="font-style: oblique">b</span>'
        '<span style="text-decoration: underline">c</span>'
        '<span style="text-decoration-line: line-through">d</span>'
        '<span style="vertical-align: super">e</span></p>',
      );
      final runs = textBlock(section, 0).inlines.cast<TextRun>();
      TextRun byText(String t) => runs.firstWhere((r) => r.text == t);
      expect(byText('a').style.bold, isTrue);
      expect(byText('b').style.italic, isTrue);
      expect(byText('c').style.underline, isTrue);
      expect(byText('d').style.strikethrough, isTrue);
      expect(byText('e').style.baseline, TextBaselineShift.superscript);
    });

    test('color formats: #rgb, #rrggbb, #rrggbbaa, rgb()', () {
      final section = parseSection(
        '<p><span style="color: #f00">a</span>'
        '<span style="color: #123456">b</span>'
        '<span style="color: #11223344">c</span>'
        '<span style="color: rgb(1, 2, 3)">d</span></p>',
      );
      final runs = textBlock(section, 0).inlines.cast<TextRun>();
      TextRun byText(String t) => runs.firstWhere((r) => r.text == t);
      expect(byText('a').style.color, 0xFFFF0000);
      expect(byText('b').style.color, 0xFF123456);
      expect(byText('c').style.color, 0x44112233);
      expect(byText('d').style.color, 0xFF010203);
    });

    test('nested list margin accumulates from ancestors', () {
      final section = parseSection(
        '<div style="margin-left: 10px"><div style="padding-left: 6px">'
        '<p>t</p></div></div>',
      );
      expect(textBlock(section, 0).style.marginStart, closeTo(16, 1e-9));
    });
  });

  group('images', () {
    test('src resolution with .. and attribute dimensions', () {
      final section = parseSection(
        '<img src="../images/pic.png" width="320" height="50%" alt="pic"/>',
      );
      final image = section.blocks.single as ImageBlock;
      expect(image.href, 'OPS/images/pic.png');
      expect(image.alt, 'pic');
      expect(image.style.width, isA<ImagePixels>());
      expect((image.style.width! as ImagePixels).value, 320);
      expect(image.style.height, isA<ImageFraction>());
      expect((image.style.height! as ImageFraction).value, 0.5);
    });

    test('CSS width/max-width on img', () {
      const head = '<style>img.f { width: 80%; max-width: 420px; }</style>';
      final section = parseSection('<img class="f" src="a.png"/>', head: head);
      final image = section.blocks.single as ImageBlock;
      expect((image.style.width! as ImageFraction).value, closeTo(0.8, 1e-9));
      expect((image.style.maxWidth! as ImagePixels).value, 420);
    });

    test('image and image-only container margins are preserved', () {
      final section = parseSection(
        '<div style="margin-top: 25px; margin-bottom: 10px">'
        '<span><img src="a.png" style="margin: 5px 0 18px"/></span>'
        '</div>',
      );
      final image = section.blocks.single as ImageBlock;

      expect(image.style.marginBefore, closeTo(25, 1e-9));
      expect(image.style.marginAfter, closeTo(18, 1e-9));
    });

    test('percent-encoded src is decoded for the canonical href', () {
      final section = parseSection('<img src="my%20image.png"/>');
      final image = section.blocks.single as ImageBlock;
      expect(image.href, 'OPS/text/my image.png');
    });
  });

  group('whitespace', () {
    test('runs collapse and edges trim', () {
      final section = parseSection('<p>  a\n   b\t c  </p>');
      expect(textBlock(section, 0).plainText, 'a b c');
    });

    test('collapsing spans inline element boundaries', () {
      final section = parseSection('<p>a <b> b</b></p>');
      expect(textBlock(section, 0).plainText, 'a b');
    });
  });

  group('node ids and source ranges', () {
    test('sequential ids in document order', () {
      final section = parseSection(
        '<h1>t</h1><p>a</p><p>b</p><img src="i.png"/>',
      );
      final ids = section.blocks
          .map(
            (block) => switch (block) {
              TextBlock(:final nodeId) => nodeId,
              ImageBlock() => 'image',
              _ => 'other',
            },
          )
          .toList();
      expect(ids, ['n0', 'n1', 'n2', 'image']);
    });

    test(
      'source ranges use Unicode scalar offsets of normalized plainText',
      () {
        final section = parseSection('<p>数学 🎓!</p>', spineIndex: 7);
        final block = textBlock(section, 0);
        expect(block.plainText, '数学 🎓!');
        expect(block.source, isNotNull);
        expect(
          block.source!.start,
          const SourceAnchor(
            spine: SpineItemId.generated(7),
            node: 'n0',
            textOffset: 0,
          ),
        );
        expect(
          block.source!.end,
          SourceAnchor(
            spine: SpineItemId.generated(7),
            node: 'n0',
            textOffset: block.plainText.runes.length,
          ),
        );
        // 数学 (2) + space (1) + 🎓 (1 scalar) + ! (1)
        expect(block.source!.end.textOffset, 5);
      },
    );

    test('image blocks carry a zero-length source range', () {
      final section = parseSection('<img src="i.png"/>', spineIndex: 3);
      final image = section.blocks.single as ImageBlock;
      expect(
        image.source!.start,
        const SourceAnchor(
          spine: SpineItemId.generated(3),
          node: 'n0',
          textOffset: 0,
        ),
      );
      expect(
        image.source!.end,
        const SourceAnchor(
          spine: SpineItemId.generated(3),
          node: 'n0',
          textOffset: 0,
        ),
      );
    });
  });

  group('malformed input recovery', () {
    test('stray ampersands are escaped', () {
      final section = parseSection('<p>a & b</p>');
      expect(textBlock(section, 0).plainText, 'a & b');
    });

    test('HTML named entities are replaced', () {
      final section = parseSection('<p>a&nbsp;b &mdash; c</p>');
      // nbsp counts as whitespace and collapses to a plain space.
      expect(textBlock(section, 0).plainText, 'a\u00a0b — c');
    });

    test('UTF-8 BOM and xml declaration are handled', () {
      const xhtml = '﻿<?xml version="1.0"?><html><body><p>ok</p></body></html>';
      final section = const HtmlIrParser().parse(
        spineIndex: 0,
        href: 'a.xhtml',
        xhtml: xhtml,
        basePath: '',
      );
      expect(textBlock(section, 0).plainText, 'ok');
    });

    test('DOCTYPE declarations are stripped', () {
      const xhtml =
          '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" '
          '"http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">'
          '<html><body><p>ok</p></body></html>';
      final section = const HtmlIrParser().parse(
        spineIndex: 0,
        href: 'a.xhtml',
        xhtml: xhtml,
        basePath: '',
      );
      expect(textBlock(section, 0).plainText, 'ok');
    });

    test('completely broken markup yields empty blocks, not an exception', () {
      final section = const HtmlIrParser().parse(
        spineIndex: 0,
        href: 'a.xhtml',
        xhtml: '<html><body><p>unclosed',
        basePath: '',
      );
      expect(section.blocks, isEmpty);
    });
  });
}
