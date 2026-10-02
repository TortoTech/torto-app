import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:torto/core/ir/ir.dart';
import 'package:torto/core/ir/inline_content.dart';
import 'package:torto/core/ir/text_index.dart';
import 'package:torto/core/layout/layout_engine.dart';
import 'package:torto/core/layout/layout_types.dart';
import 'package:torto/core/render/formula_rasterizer.dart';
import 'package:torto/core/semantic_layout/formula_validation.dart';
import 'package:torto/core/semantic_layout/inline_semantics.dart';
import 'package:torto/core/semantic_layout/image_formulas.dart';
import 'package:torto/core/semantic_layout/semantic_layout.dart';
import 'package:torto/core/semantic_layout/web_links.dart';
import 'package:torto/core/translation/translation_markup.dart';
import 'html_ir_parser_test.dart' show parseSection;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'overlapping formulas are rejected together and duplicate proposals are harmless',
    () {
      final source = parseSection('<p>x+y=z</p>');
      Map<String, dynamic> proposal(String original, String latex) => {
        'block': 0,
        'paragraph': 0,
        'original': original,
        'latex': latex,
      };
      expect(
        resolveInlineProposals(
          source,
          [],
          [proposal('x+y', 'x+y'), proposal('y=z', 'y=z')],
          0,
          1,
        ),
        isEmpty,
      );
      expect(
        resolveInlineProposals(
          source,
          [],
          [proposal('x+y', 'x+y'), proposal('x+y', 'x+y')],
          0,
          1,
        ),
        hasLength(1),
      );
    },
  );
  test(
    'authored equation numbers win and conflicts retain the original image',
    () {
      for (final number in ['(1)', '(2)']) {
        final source = parseSection('<p><img src="eq.png"/></p><p>$number</p>');
        final displayed = composeImageAnnotations(source, [
          {
            'kind': 'image_formula',
            'block': 0,
            'href': 'OPS/text/eq.png',
            'latex': 'x=1',
            'equation_number': '(1)',
          },
        ]);
        final image = displayed.blocks.first as ImageBlock;
        if (number == '(1)') {
          expect(image.formula, isNotNull);
          expect(image.formula!.equationNumber, isNull);
        } else {
          expect(image.formula, isNull);
        }
        expect((displayed.blocks.last as TextBlock).plainText, number);
      }
    },
  );
  test('table source notes use annotation sizing without body indentation', () {
    final source = parseSection(
      '<div class="table"><p>Table 1: Values</p><table><tr><td>A</td></tr></table><p>Source: Author</p></div>',
    );
    final table = source.blocks.single as TableBlock;
    final pages = LayoutEngine().paginate(
      source,
      const LayoutViewport(width: 320, height: 600),
      const ReaderStyle(),
    );
    final note = pages
        .expand((p) => p.items)
        .whereType<TextPlacement>()
        .singleWhere((t) => t.nodeId == table.after.single.nodeId);
    expect(note.syntheticPrefixLength, 0);
    for (final page in pages) {
      page.dispose();
    }
  });
  test('citations preserve styled source and fold to one ordinal per group', () {
    final source = parseSection(
      '<p>Works (Smith <i>et al.</i>, 2020) and [12]. A note (see this explanation).</p>',
    );
    final candidates = citationCandidates(source);
    expect(candidates, hasLength(2));
    final groups = resolveInlineProposals(source, [0, 1], [], 0, 1);
    final displayed = composeSemanticLayout(source, source, groups);
    final text = displayed.blocks.single as TextBlock;
    expect(text.plainText, (source.blocks.single as TextBlock).plainText);
    expect(
      text.inlines.whereType<TextRun>().where(
        (r) => r.style.inlineCitation == 1,
      ),
      hasLength(3),
    );
    for (final strategy in LineBreakStrategy.values) {
      final pages = LayoutEngine().paginate(
        displayed,
        const LayoutViewport(width: 320, height: 600),
        ReaderStyle(lineBreakStrategy: strategy),
      );
      final links = pages
          .expand((p) => p.items)
          .whereType<TextPlacement>()
          .expand((p) => p.links)
          .where((l) => l.citationOrdinal > 0)
          .toList();
      expect(links.map((l) => l.citationOrdinal), [1, 2]);
      expect(links.first.inlineNote, '(Smith et al., 2020)');
      final textPlacement = pages.first.items.whereType<TextPlacement>().first;
      expect(textPlacement.displayToSource.last, text.plainText.runes.length);
      for (final page in pages) {
        page.dispose();
      }
    }
  });
  test(
    'website detection excludes email and filenames and preserves punctuation',
    () {
      final runs = detectWebLinks([
        const TextRun(
          'See example.com/path, https://example.org/a(b). Mail x@example.com or chapter.xhtml.',
        ),
      ]).cast<TextRun>();
      expect(runs.where((r) => r.style.website).map((r) => r.link), [
        'https://example.com/path',
        'https://example.org/a(b)',
      ]);
      expect(
        runs.map((r) => r.text).join(),
        'See example.com/path, https://example.org/a(b). Mail x@example.com or chapter.xhtml.',
      );
      expect(websiteUrl('javascript:alert(1)'), isNull);
    },
  );
  test(
    'citations websites and math survive translation placeholders without renumbering',
    () {
      final original = [
        const TextRun('(Smith, 2020)', style: TextStyle(inlineCitation: 1)),
        const TextRun(' example.com '),
        const MathInline(r'\frac{x}{2}', original: [TextRun('x/2')]),
      ];
      final encoded = TranslationMarkupCodec.encode(original);
      expect(encoded, contains('<citation id="1">(Smith, 2020)</citation>'));
      expect(encoded, contains('<t-web-0/>'));
      final decoded = TranslationMarkupCodec.decode(
        encoded,
        original,
        language: 'zh-CN',
        requireSizeMarkup: true,
      );
      expect(decoded.whereType<MathInline>().single.sourceText, 'x/2');
      expect(
        decoded
            .whereType<TextRun>()
            .where((r) => r.style.inlineCitation > 0)
            .single
            .text,
        '(Smith, 2020)',
      );
      expect(
        decoded.whereType<TextRun>().where((r) => r.style.website).single.link,
        'https://example.com',
      );
      expect(
        () => TranslationMarkupCodec.decode(
          encoded.replaceAll('<citation id="1">(Smith, 2020)</citation>', ''),
          original,
          language: 'zh-CN',
          requireSizeMarkup: true,
        ),
        throwsFormatException,
      );
    },
  );
  test('text formulas protect scripts ambiguity links and citations', () {
    final source = parseSection(
      '<p>😀 E=mc<sup>2</sup> and x+y and x+y. <a href="notes.xhtml">a=b</a></p>',
    );
    Map<String, dynamic> proposal(
      String original,
      String latex, {
      String before = '',
      String after = '',
    }) => {
      'block': 0,
      'paragraph': 0,
      'original': original,
      'latex': latex,
      'before': before,
      'after': after,
    };
    final groups = resolveInlineProposals(
      source,
      [],
      [
        proposal('E=mc<sup>2</sup>', r'E=mc^2'),
        proposal('x+y', r'x+y'),
        proposal('a=b', 'a=b'),
        proposal('mc', r'mc'),
      ],
      0,
      1,
    );
    expect(groups, hasLength(1));
    final result = composeSemanticLayout(source, source, groups);
    final text = result.blocks.single as TextBlock;
    expect(text.plainText, (source.blocks.single as TextBlock).plainText);
    expect(text.inlines.whereType<MathInline>().single.sourceText, 'E=mc2');
    expect(sectionTextNodes(result).single.selectable, isTrue);
  });
  test(
    'formula limits reject recursive macros and unsupported rendering commands',
    () {
      expect(formulaError(r'\frac{a}{b}+\sqrt{x}'), isNull);
      expect(formulaError(r'\def\a{\a}\a'), isNotNull);
      expect(formulaError(r'\include{file}'), isNotNull);
      expect(formulaError('${'{' * 40}x${'}' * 40}'), isNotNull);
      expect(formulaError(r'\unknown{x}'), isNotNull);
    },
  );
  test(
    'math is rendered to pixels with baseline metrics and original text mapping',
    () async {
      final renderer = FormulaRasterizer();
      addTearDown(renderer.dispose);
      const math = MathInline(r'\frac{x^2}{2}', original: [TextRun('x2/2')]);
      final raster = await renderer.render(math, 0xff123456);
      expect(raster, isNotNull);
      expect(raster!.width, greaterThan(0));
      expect(raster.height, greaterThan(0));
      final pixels = await raster.image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      expect(pixels!.buffer.asUint8List().where((v) => v != 0), isNotEmpty);
      final source = parseSection('<p>Before x2/2 after</p>');
      final text = source.blocks.single as TextBlock;
      final shown = withBlocks(source, [
        withInlines(text, [
          const TextRun('Before '),
          math,
          const TextRun(' after'),
        ]),
      ]);
      final engine = LayoutEngine(formulaResolver: renderer.lookup);
      final pages = engine.paginate(
        shown,
        const LayoutViewport(width: 320, height: 600),
        const ReaderStyle(foreground: 0xff123456),
      );
      final placement = pages.first.items.whereType<TextPlacement>().single;
      expect(placement.inlineImages, hasLength(1));
      expect(placement.links.single.latex, math.latex);
      expect(placement.displayToSource.last, text.plainText.runes.length);
      final bookPages = engine.paginate(
        shown,
        const LayoutViewport(width: 320, height: 600),
        const ReaderStyle(typesettingMode: TypesettingMode.book),
      );
      expect(
        bookPages
            .expand((p) => p.items)
            .whereType<TextPlacement>()
            .expand((p) => p.inlineImages),
        isEmpty,
      );
      for (final page in [...pages, ...bookPages]) {
        page.dispose();
      }
    },
  );
  test(
    'image tables retain both caption sides through composition and layout',
    () {
      final source = parseSection(
        '<div class="table"><p>Table 1: Data</p><img src="table.png"/><p>Source: Author</p></div>',
      );
      final figure = source.blocks.single as FigureBlock;
      expect(figure.primaryCaptions.single.plainText, 'Table 1: Data');
      expect(figure.afterCaptions.single.plainText, 'Source: Author');
      final pages = LayoutEngine().paginate(
        source,
        const LayoutViewport(width: 320, height: 600),
        const ReaderStyle(),
        imageSizeResolver: (_) => const ui.Size(160, 100),
      );
      final items = pages
          .expand((p) => p.items)
          .where((i) => i is TextPlacement || i is ImagePlacement)
          .toList();
      expect(items[0], isA<TextPlacement>());
      expect(items[1], isA<ImagePlacement>());
      expect(items[2], isA<TextPlacement>());
      for (final page in pages) {
        page.dispose();
      }
    },
  );
}
