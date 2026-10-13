import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torto/core/ir/ir.dart';
import 'package:torto/core/ir/text_index.dart';
import 'package:torto/core/layout/layout_engine.dart';
import 'package:torto/core/layout/layout_types.dart';
import 'package:torto/core/render/page_painter.dart';
import 'html_ir_parser_test.dart' show parseSection;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader(
      'Literata',
    )..addFont(rootBundle.load('assets/fonts/Literata-opsz-wght.ttf'))).load();
    await (FontLoader(
      'LXGW WenKai GB Screen',
    )..addFont(rootBundle.load('assets/fonts/LXGWWenKaiGBScreen.ttf'))).load();
  });
  test(
    'paragraph lists retain markers in source and hide them once in unified display',
    () {
      final section = parseSection(
        '<p>Introduction.</p><p>1. First item</p><p>2. Second item</p>'
        '<p>Ordinary barrier.</p><p>一、 第一项</p><p>二、 第二项</p>'
        '<p>1999. This is prose.</p><p>2000. This is prose.</p>',
      );
      final texts = section.blocks.cast<TextBlock>().toList();
      expect(texts[1].kind, TextBlockKind.listItem);
      expect(texts[2].listOrdinal, 2);
      expect(texts[4].kind, TextBlockKind.listItem);
      expect(texts[6].kind, TextBlockKind.paragraph);
      expect(texts[1].plainText, '1. First item');
      final pages = LayoutEngine().paginate(
        section,
        const LayoutViewport(width: 360, height: 640),
        const ReaderStyle(),
      );
      final placement = pages
          .expand((p) => p.items)
          .whereType<TextPlacement>()
          .firstWhere((p) => p.nodeId == texts[1].nodeId);
      expect(placement.displayToSource.first, 3);
      expect(placement.displayToSource.last, texts[1].plainText.runes.length);
      expect(
        pages.expand((p) => p.items).whereType<ListMarkerPlacement>(),
        hasLength(4),
      );
      for (final page in pages) {
        page.dispose();
      }
    },
  );

  test('table ruby keeps annotations and base-only source offsets', () {
    final section = parseSection(
      '<table><tr><td><ruby>漢字<rt>かんじ</rt></ruby></td></tr></table>',
    );
    final pages = LayoutEngine().paginate(
      section,
      const LayoutViewport(width: 360, height: 640),
      const ReaderStyle(),
    );
    final cell = pages
        .expand((p) => p.items)
        .whereType<TableCellPlacement>()
        .single;
    expect(cell.inlineImages.single.ruby, isNotNull);
    expect(cell.displayToSource.last, 2);
    for (final page in pages) {
      page.dispose();
    }
  });

  test(
    'ruby preserves base prose, scalar anchors, adjacent spaces and separate annotations',
    () async {
      final section = parseSection(
        '<p>Read <ruby>漢<rt>かん</rt>字<rt>じ</rt></ruby> now.</p>'
        '<p><ruby style="ruby-position:under"><rb>東京</rb><rt>とうきょう</rt></ruby></p>',
      );
      final texts = section.blocks.cast<TextBlock>().toList();
      expect(texts.first.plainText, 'Read 漢字 now.');
      expect(texts.first.inlines.whereType<RubyRun>().map((r) => r.text), [
        '漢',
        '字',
      ]);
      expect(texts.last.inlines.whereType<RubyRun>().single.below, isTrue);
      expect(sectionTextNodes(section).first.text, 'Read 漢字 now.');
      final pages = LayoutEngine().paginate(
        section,
        const LayoutViewport(width: 360, height: 640),
        const ReaderStyle(),
      );
      final placement = pages.first.items.whereType<TextPlacement>().first;
      expect(
        placement.displayToSource.last,
        texts.first.plainText.runes.length,
      );
      expect(placement.inlineImages.where((i) => i.ruby != null), hasLength(2));
      final recorder = ui.PictureRecorder(), canvas = ui.Canvas(recorder);
      PagePainter(
        page: pages.first,
        imageResolver: (_) => null,
        background: const ui.Color(0xFFFAF8F3),
        foreground: const ui.Color(0xFF222222),
      ).paint(canvas, const ui.Size(360, 640));
      final picture = recorder.endRecording(),
          image = await picture.toImage(360, 640);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      final output = Directory('../output/torto-app-081')
        ..createSync(recursive: true);
      await File(
        '${output.path}/ruby.png',
      ).writeAsBytes(png!.buffer.asUint8List());
      image.dispose();
      picture.dispose();
      for (final page in pages) {
        page.dispose();
        page.dispose();
      }
    },
  );
}
