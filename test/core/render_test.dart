import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:torto/core/ir/ir.dart';
import 'package:torto/core/layout/layout_engine.dart';
import 'package:torto/core/layout/layout_types.dart';
import 'package:torto/core/render/page_painter.dart';

Section _section() => Section(spineIndex: 0, href: 's.xhtml', blocks: [
      TextBlock(inlines: [
        TextRun('Some body text to paint. ' * 40),
      ]),
      const ImageBlock(href: 'img/missing.png'),
      const SeparatorBlock(),
    ]);

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

void main() {
  test('PagePainter paints a page onto a PictureRecorder without throwing',
      () {
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

  testWidgets('PageWidget builds a CustomPaint at viewport size',
      (tester) async {
    final pages = _pages();
    addTearDown(() {
      for (final page in pages) {
        page.dispose();
      }
    });
    await tester.pumpWidget(Center(
      child: PageWidget(
        page: pages.first,
        background: const Color(0xFFFAF8F3),
      ),
    ));
    expect(find.byType(CustomPaint), findsOneWidget);
    final box = tester.renderObject<RenderBox>(find.byType(PageWidget));
    expect(box.size, const ui.Size(300, 500));
  });
}
