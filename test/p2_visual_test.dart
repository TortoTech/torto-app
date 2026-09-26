import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torto/core/layout/layout_engine.dart';
import 'package:torto/core/layout/layout_types.dart';
import 'package:torto/core/render/page_painter.dart';
import 'package:torto/core/render/formula_rasterizer.dart';
import 'package:torto/core/semantic_layout/inline_semantics.dart';
import 'package:torto/core/semantic_layout/semantic_layout.dart';
import 'core/html_ir_parser_test.dart' show parseSection;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'real-font formulas and reference markers paint in narrow light and dark pages',
    () async {
      await (FontLoader('Literata')
            ..addFont(rootBundle.load('assets/fonts/Literata-opsz-wght.ttf')))
          .load();
      for (final family in [
        'Main',
        'Math',
        'Size1',
        'Size2',
        'Size3',
        'Size4',
        'AMS',
      ]) {
        final loader = FontLoader('packages/flutter_math_fork/KaTeX_$family');
        final variants = family == 'Math'
            ? ['Italic', 'BoldItalic']
            : family == 'Main'
            ? ['Regular', 'Italic', 'Bold', 'BoldItalic']
            : ['Regular'];
        for (final variant in variants) {
          loader.addFont(
            rootBundle.load(
              'packages/flutter_math_fork/lib/katex_fonts/fonts/KaTeX_$family-$variant.ttf',
            ),
          );
        }
        await loader.load();
      }
      final original = parseSection(
        r'''<h2>Mathematics and references</h2>
      <p>A fraction x/2 fits the surrounding text (Smith, 2020). Visit example.com for more information.</p>
      <p>E=mc<sup>2</sup></p>
      <p><span class="math math-display">\int_0^\infty e^{-x^2}\,dx=\frac{\sqrt{\pi}}{2}</span></p>
      <p>Original source text is retained when copying a paragraph. Tap a formula to copy LaTeX.</p>''',
      );
      final annotations = resolveInlineProposals(
        original,
        [0],
        [
          {
            'block': 1,
            'paragraph': 0,
            'original': 'x/2',
            'latex': r'\frac{x}{2}',
          },
          {
            'block': 2,
            'paragraph': 0,
            'original': 'E=mc<sup>2</sup>',
            'latex': r'E=mc^2',
          },
        ],
        0,
        original.blocks.length,
      );
      final section = composeSemanticLayout(original, original, annotations);
      final rasterizer = FormulaRasterizer();
      addTearDown(rasterizer.dispose);
      for (final dark in [false, true]) {
        final fg = dark ? 0xffe6e2d8 : 0xff222222,
            bg = dark ? 0xff17191d : 0xfffaf8f3;
        await rasterizer.prepare(section, fg);
        final pages = LayoutEngine(formulaResolver: rasterizer.lookup).paginate(
          section,
          const LayoutViewport(width: 360, height: 520),
          ReaderStyle(
            baseFontSize: 18,
            foreground: fg,
            background: bg,
            marginLeft: 24,
            marginRight: 24,
          ),
        );
        final links = pages
            .expand((page) => page.items)
            .whereType<TextPlacement>()
            .expand((text) => text.links)
            .toList();
        expect(links.where((l) => l.latex != null), hasLength(3));
        expect(links.where((l) => l.citationOrdinal > 0), hasLength(1));
        expect(links.where((l) => l.websiteIcon), hasLength(1));
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder)..scale(2);
        PagePainter(
          page: pages.first,
          imageResolver: rasterizer.image,
          background: ui.Color(bg),
          foreground: ui.Color(fg),
        ).paint(canvas, const ui.Size(360, 520));
        final picture = recorder.endRecording();
        final image = await picture.toImage(720, 1040);
        final target = Platform.environment['P2_VISUAL_OUTPUT'];
        if (target != null) {
          await Directory(target).create(recursive: true);
          await File('$target/${dark ? 'dark' : 'light'}.png').writeAsBytes(
            (await image.toByteData(
              format: ui.ImageByteFormat.png,
            ))!.buffer.asUint8List(),
          );
        }
        image.dispose();
        picture.dispose();
        for (final page in pages) {
          page.dispose();
        }
      }
    },
  );
}
