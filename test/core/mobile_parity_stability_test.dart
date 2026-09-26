import 'dart:async';
import 'dart:io';
import 'dart:ui' show Size;
import 'package:xml/xml.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torto/core/diagnostics.dart';
import 'package:torto/core/html_ir/html_ir_parser.dart';
import 'package:torto/core/html_ir/tolerant_xml.dart';
import 'package:torto/core/ir/ir.dart';
import 'package:torto/core/layout/layout_engine.dart';
import 'package:torto/core/layout/layout_types.dart';
import 'package:torto/core/translation/translation_markup.dart';

Section parse(String body) => const HtmlIrParser().parse(
  spineIndex: 0,
  href: 'chapter.xhtml',
  basePath: '',
  xhtml: body,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'absolute, parent and root sizes remain distinct and keywords survive translation',
    () {
      final section = parse(
        '<html style="font-size:20px"><body style="font-size:2em">'
        '<p><span style="font-size:16px">A</span><span style="font-size:1rem">B</span>'
        '<span style="font-size:50%">C</span><span style="font-size:large">D</span>'
        '<span style="font-size:12pt">E</span></p></body></html>',
      );
      final runs = (section.blocks.single as TextBlock).inlines
          .whereType<TextRun>()
          .toList();
      expect(runs.map((r) => r.style.sizeScale), [1, 1.25, 1.2, 1]);
      expect(runs[1].text, 'BC');
      expect(runs[2].style.keywordSizeScale, 1.2);
      expect(
        LayoutEngine.debugResolvedFontSize(
          runs[2].style,
          unified: true,
          blockScale: 1.6,
        ),
        24,
      );
      final markup = TranslationMarkupCodec.encode(runs);
      final decoded = TranslationMarkupCodec.decode(
        markup,
        runs,
        language: 'en',
      ).whereType<TextRun>().toList();
      expect(decoded.map((r) => r.style.sizeScale), [1, 1.2, 1]);
      expect(decoded[1].style.keywordSizeScale, 1.2);
      expect(
        () => TranslationMarkupCodec.decode(
          markup.replaceAll('scale="1.2"', 'scale="9"'),
          runs,
          language: 'en',
          requireSizeMarkup: true,
        ),
        throwsFormatException,
      );
    },
  );

  test('root rem resolves once and body keywords do not flatten headings', () {
    final root = parse(
      '<html style="font-size:2rem"><body><p><span style="font-size:1em">Text</span></p></body></html>',
    );
    expect(
      (root.blocks.single as TextBlock).inlines
          .whereType<TextRun>()
          .single
          .style
          .sizeScale,
      2,
    );
    final section = parse(
      '<html><body style="font-size:large"><h1>Title</h1>'
      '<h2 style="font-size:inherit">Inherited</h2><pre>Code</pre><p>Body</p></body></html>',
    );
    final styles = section.blocks
        .whereType<TextBlock>()
        .map((b) => b.inlines.whereType<TextRun>().first.style)
        .toList();
    expect(styles.map((s) => s.keywordSizeScale), [null, 1.2, null, 1.2]);
    expect(
      LayoutEngine.debugResolvedFontSize(
        const TextStyle(
          keywordSizeScale: .75,
          baseline: TextBaselineShift.subscript,
        ),
        unified: true,
      ),
      20 * .75 * .75,
    );
    expect(
      LayoutEngine.debugResolvedFontSize(
        const TextStyle(
          keywordSizeScale: .75,
          baseline: TextBaselineShift.superscript,
        ),
        unified: true,
      ),
      closeTo(20 * .75 * .7, 0.0001),
    );
  });

  test(
    'table cells honor keyword sizes and quote inline images receive dimensions',
    () {
      final table = parse(
        '<html><body><table><tr><td style="font-size:x-large">Big</td>'
        '<td>Normal</td></tr></table></body></html>',
      );
      const viewport = LayoutViewport(width: 500, height: 700);
      const style = ReaderStyle(
        baseFontSize: 20,
        typesettingMode: TypesettingMode.unified,
      );
      final pages = const LayoutEngine().paginate(table, viewport, style);
      final cells = pages
          .expand((p) => p.items)
          .whereType<TableCellPlacement>()
          .toList();
      expect(
        cells[0].paragraph.computeLineMetrics().first.height,
        greaterThan(cells[1].paragraph.computeLineMetrics().first.height * 1.4),
      );
      for (final page in pages) {
        page.dispose();
      }
      final quote = parse(
        '<html><body><blockquote><p>Before<img src="symbol.png" style="height:1em"/>After</p></blockquote></body></html>',
      );
      var resolutions = 0;
      final quoted = const LayoutEngine().paginate(
        quote,
        viewport,
        style,
        imageSizeResolver: (href) {
          resolutions++;
          return const Size(80, 40);
        },
      );
      expect(resolutions, greaterThan(0));
      expect(
        quoted
            .expand((p) => p.items)
            .whereType<TextPlacement>()
            .expand((i) => i.inlineImages)
            .map((i) => i.href),
        contains('symbol.png'),
      );
      for (final page in quoted) {
        page.dispose();
      }
    },
  );

  test(
    'desktop size markup and legacy unmarked translations retain only safe sizes',
    () {
      const sized = TextRun(
        'sized',
        style: TextStyle(sizeScale: 1.2, keywordSizeScale: 1.2),
      );
      const normal = TextRun('normal');
      expect(
        TranslationMarkupCodec.encode([sized, normal]),
        '<torto-size scale="1.2">sized</torto-size>normal',
      );
      final legacy = TranslationMarkupCodec.decode('Old translation', [
        sized,
      ], language: 'en');
      expect((legacy.single as TextRun).style.keywordSizeScale, 1.2);
      final mixed = TranslationMarkupCodec.decode('Old translation', [
        sized,
        normal,
      ], language: 'en');
      expect((mixed.single as TextRun).style.keywordSizeScale, isNull);
      final indexed = TranslationMarkupCodec.decode(
        '<torto-size-0>Old</torto-size-0> normal',
        [sized, normal],
        language: 'en',
      );
      expect((indexed.first as TextRun).style.keywordSizeScale, 1.2);
      for (final markup in [
        '<torto-size>bad</torto-size>',
        '<torto-size scale="NaN">bad</torto-size>',
      ]) {
        expect(
          () => TranslationMarkupCodec.decode(markup, [sized], language: 'en'),
          throwsFormatException,
        );
      }
      expect(
        () => TranslationMarkupCodec.decode(
          'New translation',
          [sized],
          language: 'en',
          requireSizeMarkup: true,
        ),
        throwsFormatException,
      );
    },
  );

  test('many optional paragraph and list endings are shallow HTML', () {
    final doc = tryParsePublicationContent(
      '<html><body>${'<p>Paragraph' * 200}'
      '<ul>${'<li>Item' * 200}</ul></body></html>',
    )!;
    expect(doc.findAllElements('p'), hasLength(200));
    expect(doc.findAllElements('li'), hasLength(200));
    final commented = tryParsePublicationContent(
      '<html><body><!-- ${'<div>' * 200} -->'
      '<p>Visible<br>text</body></html>',
    )!;
    expect(commented.findAllElements('p').single.innerText, 'Visibletext');
    const text =
        '<html><body><!-- <!ENTITY fake "x"> -->'
        '<p><![CDATA[<!DOCTYPE example> A & B &nbsp;]]></p></body></html>';
    expect(
      tryParsePublicationContent(text)!.findAllElements('p').single.innerText,
      '<!DOCTYPE example> A & B &nbsp;',
    );
  });

  test(
    'length declarations reset inherited keyword without changing original mode',
    () {
      final section = parse(
        '<html><body><p style="font-size:large"><span style="font-size:10px">A</span><span>B</span></p></body></html>',
      );
      final runs = (section.blocks.single as TextBlock).inlines
          .whereType<TextRun>()
          .toList();
      expect(runs[0].style.keywordSizeScale, isNull);
      expect(runs[0].style.sizeScale, .625);
      expect(runs[1].style.keywordSizeScale, 1.2);
    },
  );

  test(
    'multi-paragraph captions share a leading edge and quote emphasis stays upright',
    () {
      final section = parse(
        '<html><body><figure><img src="image.png"/><figcaption>'
        '<p>First caption.</p><p>Second caption.</p></figcaption></figure></body></html>',
      );
      final pages = const LayoutEngine().paginate(
        section,
        const LayoutViewport(width: 300, height: 500),
        const ReaderStyle(typesettingMode: TypesettingMode.unified),
      );
      final captions = pages
          .expand((p) => p.items)
          .whereType<TextPlacement>()
          .toList();
      expect(captions, hasLength(2));
      for (final caption in captions) {
        expect(
          caption.paragraph.computeLineMetrics().first.left,
          closeTo(0, .1),
        );
      }
      for (final page in pages) {
        page.dispose();
      }
      expect(
        LayoutEngine.debugResolvedInlineEmphasis(
          const TextStyle(italic: true, emphasis: true),
          isQuote: true,
        ).italic,
        isFalse,
      );
      expect(
        LayoutEngine.debugResolvedInlineEmphasis(
          const TextStyle(italic: true, emphasis: true),
          isQuote: true,
          unified: false,
        ).italic,
        isTrue,
      );
    },
  );

  test('chapter recovery preserves text links and inline resources', () {
    final doc = tryParsePublicationContent(
      '<html><body><p id="p">First<br>line<p>Second <a href="#p">back</a><img src="symbol.png"></body></html>',
    )!;
    expect(doc.findAllElements('p').map((p) => p.innerText), [
      'Firstline',
      'Second back',
    ]);
    expect(doc.findAllElements('a').single.getAttribute('href'), '#p');
    expect(doc.findAllElements('img').single.getAttribute('src'), 'symbol.png');
    expect(tryParsePublicationContent('<html>' * 130), isNull);
    expect(
      tryParsePublicationContent('<!DOCTYPE x [<!ENTITY y "z">]><x/>'),
      isNull,
    );
    expect(tryParseXmlTolerant('<package><metadata></package>'), isNull);
  });

  test('cancelled paused pagination releases work and completes', () async {
    final section = parse(
      '<html><body>${'<p>Some ordinary text.</p>' * 100}</body></html>',
    );
    var paused = false;
    var cancelled = false;
    final pending = const LayoutEngine().paginateAsync(
      section,
      const LayoutViewport(width: 300, height: 500),
      const ReaderStyle(),
      timeSlice: Duration.zero,
      shouldPause: () => paused,
      shouldCancel: () => cancelled,
    );
    paused = true;
    Timer(const Duration(milliseconds: 10), () => cancelled = true);
    expect(await pending.timeout(const Duration(seconds: 2)), isEmpty);
  });

  test(
    'HTML recovery preserves foreign namespaces and first duplicate attribute',
    () {
      final doc = tryParsePublicationContent(
        '<html><body><p id="first" id="second">Text<br>'
        '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink">'
        '<use xlink:href="#symbol"/></svg><math xmlns="http://www.w3.org/1998/Math/MathML"><mi>x</mi></math>'
        '</body></html>',
      )!;
      expect(doc.findAllElements('p').first.getAttribute('id'), 'first');
      expect(
        doc
            .findAllElements('use')
            .single
            .attributes
            .any(
              (a) => a.name.qualified == 'xlink:href' && a.value == '#symbol',
            ),
        isTrue,
      );
      expect(doc.findAllElements('mi').single.innerText, 'x');
    },
  );

  test(
    'oversized paragraph falls back without dropping text or source range',
    () {
      final text = 'A readable sentence. ' * 600;
      final section = parse('<html><body><p>$text</p></body></html>');
      final pages = const LayoutEngine().paginate(
        section,
        const LayoutViewport(width: 300, height: 500),
        const ReaderStyle(),
      );
      expect(pages.length, greaterThan(1));
      final items = pages
          .expand((p) => p.items)
          .whereType<TextPlacement>()
          .toList();
      expect(
        items.last.endLine,
        items.first.paragraph.computeLineMetrics().length,
      );
      for (final page in pages) {
        page.dispose();
      }
    },
  );

  test(
    'diagnostic rotation is bounded and does not include exception messages',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'torto-diagnostics-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final log = ReaderDiagnostics(maxBytes: 350);
      await log.initialize(directory);
      for (var i = 0; i < 20; i++) {
        log.event('test', {'i': i});
      }
      try {
        await log.measure(
          'failure',
          () async => throw Exception('private-key'),
        );
      } catch (_) {}
      final output = await log.export();
      expect(output, contains('failure.failed'));
      expect(output, isNot(contains('private-key')));
      expect(await directory.list().length, lessThanOrEqualTo(3));
    },
  );
}
