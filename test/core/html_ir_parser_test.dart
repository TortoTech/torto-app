import 'package:flutter_test/flutter_test.dart';
import 'package:torto/core/html_ir/html_ir_parser.dart';
import 'package:torto/core/ir/ir.dart';

Section parseSection(
  String body, {
  int spineIndex = 2,
  String href = 'OPS/text/ch1.xhtml',
  String basePath = 'OPS/text',
  String head = '',
}) {
  final xhtml = '''<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><head>$head</head><body>$body</body></html>''';
  return const HtmlIrParser().parse(
    spineIndex: spineIndex,
    href: href,
    xhtml: xhtml,
    basePath: basePath,
  );
}

TextBlock textBlock(Section section, int index) {
  final block = section.blocks[index];
  expect(block, isA<TextBlock>());
  return block as TextBlock;
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

    test('blockquote flattens nested paragraphs and indents', () {
      final section = parseSection('<blockquote><p>quoted</p></blockquote>');
      final block = textBlock(section, 0);
      expect(block.kind, TextBlockKind.blockquote);
      expect(block.plainText, 'quoted');
      expect(block.style.indent, 24);
    });

    test('pre preserves whitespace and newlines', () {
      final section = parseSection('<pre>line1\n  line2</pre>');
      final block = textBlock(section, 0);
      expect(block.kind, TextBlockKind.preformatted);
      expect(block.plainText, 'line1\n  line2');
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

    test('block paragraphs inside list items keep line boundaries', () {
      final section = parseSection(
        '<ul><li><p>first paragraph</p><p>second paragraph</p></li></ul>',
      );
      final item = textBlock(section, 0);
      expect(item.plainText, 'first paragraph\nsecond paragraph');
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

    test('figcaption becomes a paragraph', () {
      final section = parseSection(
        '<figure><img src="i.png"/><figcaption>caption</figcaption></figure>',
      );
      expect(section.blocks[0], isA<ImageBlock>());
      expect(textBlock(section, 1).plainText, 'caption');
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

    test('empty blocks are dropped, image-only blocks keep the image', () {
      final section = parseSection('<p>   </p><p><img src="only.png"/></p>');
      expect(section.blocks, hasLength(1));
      expect(section.blocks.single, isA<ImageBlock>());
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
      final backlink = textBlock(
        section,
        1,
      ).inlines.whereType<TextRun>().firstWhere((run) => run.link != null);
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
        textBlock(section, 1).nodeId,
      );
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
      final backlink = textBlock(
        section,
        1,
      ).inlines.whereType<TextRun>().firstWhere((run) => run.link != null);
      expect(reference.style.linkRole, LinkRole.footnoteReference);
      expect(backlink.style.linkRole, LinkRole.footnoteBacklink);
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

    test('font-size: px absolute vs 16px base; em multiplies', () {
      final section = parseSection(
        '<p style="font-size: 24px">a<span style="font-size: 2em">b</span></p>',
      );
      final runs = textBlock(section, 0).inlines.cast<TextRun>();
      expect(runs[0].style.sizeScale, closeTo(1.5, 1e-9));
      expect(runs[1].style.sizeScale, closeTo(3.0, 1e-9));
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

    test('source ranges use UTF-16 offsets of normalized plainText', () {
      final section = parseSection('<p>数学 🎓!</p>', spineIndex: 7);
      final block = textBlock(section, 0);
      expect(block.plainText, '数学 🎓!');
      expect(block.source, isNotNull);
      expect(
        block.source!.start,
        const SourceAnchor(spine: 7, node: 'n0', textOffset: 0),
      );
      expect(
        block.source!.end,
        SourceAnchor(spine: 7, node: 'n0', textOffset: block.plainText.length),
      );
      // 数学 (2) + space (1) + 🎓 (2 UTF-16 units) + ! (1)
      expect(block.source!.end.textOffset, 6);
    });

    test('image blocks carry a zero-length source range', () {
      final section = parseSection('<img src="i.png"/>', spineIndex: 3);
      final image = section.blocks.single as ImageBlock;
      expect(
        image.source!.start,
        const SourceAnchor(spine: 3, node: 'n0', textOffset: 0),
      );
      expect(
        image.source!.end,
        const SourceAnchor(spine: 3, node: 'n0', textOffset: 0),
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
      expect(textBlock(section, 0).plainText, 'a b — c');
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
