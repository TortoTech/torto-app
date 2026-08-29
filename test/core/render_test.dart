import 'dart:ui' as ui;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:torto/core/ir/ir.dart';
import 'package:torto/core/layout/layout_engine.dart';
import 'package:torto/core/layout/layout_types.dart';
import 'package:torto/core/render/page_painter.dart';

Section _section() => Section(
  spineIndex: 0,
  href: 's.xhtml',
  blocks: [
    TextBlock(inlines: [TextRun('Some body text to paint. ' * 40)]),
    const ImageBlock(href: 'img/missing.png'),
    const SeparatorBlock(),
  ],
);

List<PageLayout> _pages() => const LayoutEngine().paginate(
  _section(),
  const LayoutViewport(width: 300, height: 500),
  const ReaderStyle(
    baseFontSize: 10,
    marginTop: 10,
    marginBottom: 10,
    marginLeft: 10,
    marginRight: 10,
  ),
);

ui.Paragraph _emptyParagraph(double width) {
  final paragraph = ui.ParagraphBuilder(
    ui.ParagraphStyle(fontSize: 10),
  ).build();
  paragraph.layout(ui.ParagraphConstraints(width: width));
  return paragraph;
}

List<int> _pixel(Uint8List pixels, int width, int x, int y) {
  final offset = (y * width + x) * 4;
  return pixels.sublist(offset, offset + 4);
}

void main() {
  test('footnote icons use the desktop blue palette', () {
    expect(footnoteIconColor(const Color(0xFFFAF8F3)), const Color(0xFF2563EB));
    expect(footnoteIconColor(const Color(0xFF121212)), const Color(0xFF60A5FA));
  });

  test('PagePainter paints a page onto a PictureRecorder without throwing', () {
    final pages = _pages();
    expect(pages, isNotEmpty);
    for (final page in pages) {
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      PagePainter(
        page: page,
        imageResolver: (_) => null, // images skipped silently
        background: const Color(0xFFFAF8F3),
      ).paint(canvas, const ui.Size(300, 500));
      recorder.endRecording();
    }
    for (final page in pages) {
      page.dispose();
    }
  });

  test('table outer and inner rules are painted with equal weight', () async {
    const pixelWidth = 100;
    const pixelHeight = 70;
    final paragraph = _emptyParagraph(40);
    final cells = <TableCellPlacement>[
      for (final rect in const [
        ui.Rect.fromLTRB(10.5, 10.5, 50.5, 30.5),
        ui.Rect.fromLTRB(50.5, 10.5, 90.5, 30.5),
        ui.Rect.fromLTRB(10.5, 30.5, 50.5, 50.5),
        ui.Rect.fromLTRB(50.5, 30.5, 90.5, 50.5),
      ])
        TableCellPlacement(
          paragraph: paragraph,
          rect: rect,
          padding: 0,
          header: false,
          source: null,
          nodeId: '',
          spineIndex: 0,
          sectionTextOffset: 0,
        ),
    ];
    final page = PageLayout(
      viewport: const LayoutViewport(width: 100, height: 70),
      items: cells,
      firstAnchor: null,
      progression: 1,
    );
    addTearDown(page.dispose);

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    PagePainter(
      page: page,
      imageResolver: (_) => null,
      background: Colors.white,
      foreground: Colors.black,
    ).paint(canvas, const ui.Size(100, 70));
    final picture = recorder.endRecording();
    final image = await picture.toImage(pixelWidth, pixelHeight);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    expect(byteData, isNotNull);
    final pixels = byteData!.buffer.asUint8List();

    expect(
      _pixel(pixels, pixelWidth, 10, 20),
      _pixel(pixels, pixelWidth, 50, 20),
    );
    expect(
      _pixel(pixels, pixelWidth, 30, 10),
      _pixel(pixels, pixelWidth, 30, 30),
    );
    expect(_pixel(pixels, pixelWidth, 10, 20), isNot([255, 255, 255, 255]));

    image.dispose();
    picture.dispose();
  });

  testWidgets('PageWidget builds a CustomPaint at viewport size', (
    tester,
  ) async {
    final pages = _pages();
    addTearDown(() {
      for (final page in pages) {
        page.dispose();
      }
    });
    await tester.pumpWidget(
      Center(
        child: PageWidget(
          page: pages.first,
          background: const Color(0xFFFAF8F3),
        ),
      ),
    );
    expect(find.byType(CustomPaint), findsOneWidget);
    final box = tester.renderObject<RenderBox>(find.byType(PageWidget));
    expect(box.size, const ui.Size(300, 500));
  });
}
