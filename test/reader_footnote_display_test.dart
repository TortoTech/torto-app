import 'dart:ui' as ui;
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torto/app/reader/footnote_sheet.dart';
import 'package:torto/app/reader/reader_controller.dart';
import 'package:torto/core/ir/ir.dart' as ir;
import 'package:torto/core/layout/layout_engine.dart';
import 'package:torto/core/layout/layout_types.dart';
import 'package:torto/core/render/page_painter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'footnote numerals retain desktop font scale and superscript baseline',
    () async {
      await (FontLoader('Literata')
            ..addFont(rootBundle.load('assets/fonts/Literata-opsz-wght.ttf')))
          .load();
      for (final fontSize in [18.0, 20.0, 28.0]) {
        for (final strategy in LineBreakStrategy.values) {
          final pages = LayoutEngine().paginate(
            ir.Section(
              id: const ir.SpineItemId.generated(0),
              spineIndex: 0,
              href: 'a',
              blocks: [
                ir.TextBlock(
                  nodeId: 'p',
                  inlines: [
                    ir.TextRun('Body text beside a footnote marker. ' * 2),
                    const ir.TextRun(
                      'A note',
                      style: ir.TextStyle(inlineRole: ir.InlineRole.footnote),
                    ),
                  ],
                ),
              ],
            ),
            const LayoutViewport(width: 360, height: 700),
            ReaderStyle(baseFontSize: fontSize, lineBreakStrategy: strategy),
          );
          final item = pages.first.items.whereType<TextPlacement>().first;
          final link = item.links.single;
          expect(link.referenceFontSize, closeTo(fontSize * 0.78, 0.001));
          expect(link.referenceBaselineRise, closeTo(fontSize * 0.35, 0.001));
          final markerBox = item.paragraph
              .getBoxesForRange(link.start, link.end)
              .firstWhere((box) => box.right - box.left > 0.5);
          final recorder = ui.PictureRecorder();
          final canvas = ui.Canvas(recorder);
          PagePainter(
            page: pages.first,
            imageResolver: (_) => null,
            background: const Color(0xfffaf8f3),
          ).paint(canvas, const ui.Size(360, 700));
          final picture = recorder.endRecording();
          final image = await picture.toImage(360, 700);
          final bytes = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          var top = 700, bottom = -1;
          for (var y = 0; y < 700; y++) {
            for (
              var x = (item.x + markerBox.left).floor();
              x < (item.x + markerBox.right).ceil();
              x++
            ) {
              final offset = (y * 360 + x) * 4;
              if (bytes.getUint8(offset + 2) - bytes.getUint8(offset) > 25 &&
                  bytes.getUint8(offset + 2) - bytes.getUint8(offset + 1) >
                      15) {
                top = top < y ? top : y;
                bottom = bottom > y ? bottom : y;
              }
            }
          }
          expect(
            bottom - top + 1,
            greaterThanOrEqualTo(link.referenceFontSize * 0.55),
            reason: 'number glyph must not be squeezed into an icon box',
          );
          final line = item.paragraph.getLineNumberAt(link.start)!;
          final baseline =
              item.y -
              item.sliceTop +
              item.paragraph.computeLineMetrics()[line].baseline;
          expect(
            bottom,
            lessThanOrEqualTo(baseline - link.referenceBaselineRise + 1),
          );
          final preview = Platform.environment['TORTO_SUPERSCRIPT_PREVIEW'];
          if (preview != null &&
              fontSize == 20 &&
              strategy == LineBreakStrategy.optimized) {
            final png = await image.toByteData(format: ui.ImageByteFormat.png);
            await File(preview).writeAsBytes(png!.buffer.asUint8List());
          }
          image.dispose();
          picture.dispose();
          for (final page in pages) {
            page.dispose();
          }
        }
      }
    },
  );
  test('citations use desktop scale and rise while retaining source text', () {
    for (final entry in [
      (const ir.TextStyle(inlineCitation: 1), 15.6),
      (const ir.TextStyle(inlineCitation: 1, keywordSizeScale: 1.5), 23.4),
      (
        const ir.TextStyle(
          inlineCitation: 1,
          baseline: ir.TextBaselineShift.superscript,
        ),
        10.92,
      ),
    ]) {
      for (final strategy in LineBreakStrategy.values) {
        final block = ir.TextBlock(
          nodeId: 'p',
          inlines: [
            ir.TextRun('Refer to the research for further details. ' * 6),
            ir.TextRun('(Smith, 2000)', style: entry.$1),
            const ir.TextRun(' A final explanation follows.'),
          ],
        );
        final pages = LayoutEngine().paginate(
          ir.Section(
            id: const ir.SpineItemId.generated(0),
            spineIndex: 0,
            href: 'a',
            blocks: [block],
          ),
          const LayoutViewport(width: 360, height: 700),
          ReaderStyle(lineBreakStrategy: strategy),
        );
        final placement = pages.first.items.whereType<TextPlacement>().first;
        final link = placement.links.single;
        expect(link.referenceFontSize, closeTo(entry.$2, 0.001));
        expect(link.referenceBaselineRise, closeTo(entry.$2 * 0.35, 0.001));
        expect(link.citationOrdinal, 1);
        expect(link.footnoteNumber, 0);
        expect(link.inlineNote, '(Smith, 2000)');
        expect(placement.displayToSource.last, block.plainText.runes.length);
        for (final page in pages) {
          page.dispose();
        }
      }
    }
  });
  testWidgets('popup marker occupies only the first line and keeps its color', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            child: ReaderFootnoteSheet(
              text: '',
              foreground: Colors.black,
              markerColor: const Color(0xff2563eb),
              entries: [
                ReaderFootnote(
                  marker: '[40]',
                  footnoteNumber: 1,
                  text: 'Alpha beta gamma delta epsilon zeta eta theta. ' * 8,
                ),
                const ReaderFootnote(
                  marker: '[12]',
                  text: 'Beta reference.',
                  citationOrdinal: 12,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final rich = find.byWidgetPredicate(
      (w) => w is RichText && w.text.toPlainText().contains('Alpha'),
    );
    final paragraph = tester.renderObject<RenderParagraph>(rich);
    final content = tester.widget<RichText>(rich).text.toPlainText();
    final first = paragraph
        .getBoxesForSelection(
          const TextSelection(baseOffset: 1, extentOffset: 2),
        )
        .first;
    final secondStart = content.indexOf('\n') + 1;
    expect(secondStart, greaterThan(1));
    final second = paragraph
        .getBoxesForSelection(
          TextSelection(baseOffset: secondStart, extentOffset: secondStart + 1),
        )
        .first;
    expect(first.left, lessThan(45));
    expect(first.left, greaterThan(tester.getSize(find.text('[12]')).width));
    expect(
      tester.getCenter(find.text('1')).dx,
      closeTo(tester.getCenter(find.text('[12]')).dx, 0.01),
    );
    expect(second.left, lessThan(1));
    expect(
      tester.widget<Text>(find.text('1')).style!.color,
      const Color(0xff2563eb),
    );
    expect(find.text('[40]'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('popup markers share a slot and retain both citation brackets', (
    tester,
  ) async {
    await (FontLoader(
      'Literata',
    )..addFont(rootBundle.load('assets/fonts/Literata-opsz-wght.ttf'))).load();
    for (final scale in [1.0, 1.7]) {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: Scaffold(
              body: DefaultTextStyle(
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  letterSpacing: 3,
                ),
                child: ReaderFootnoteSheet(
                  text: '',
                  foreground: Colors.black,
                  entries: const [
                    ReaderFootnote(
                      marker: '12',
                      footnoteNumber: 12,
                      text: 'Explanatory note.',
                    ),
                    ReaderFootnote(
                      marker: '[12]',
                      citationOrdinal: 12,
                      text: 'Citation text.',
                    ),
                    ReaderFootnote(
                      marker: '[123]',
                      citationOrdinal: 123,
                      text: 'Another citation.',
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      double? slotWidth;
      for (final marker in ['12', '[12]', '[123]']) {
        final finder = find.text(marker);
        final rich = find.descendant(
          of: finder,
          matching: find.byType(RichText),
        );
        final render = tester.renderObject<RenderParagraph>(rich);
        final boxes = render.getBoxesForSelection(
          TextSelection(baseOffset: 0, extentOffset: marker.length),
        );
        expect(
          boxes,
          hasLength(1),
          reason: 'the entire marker stays on one line',
        );
        final slot = find.ancestor(
          of: finder,
          matching: find.byWidgetPredicate(
            (w) =>
                w is SizedBox &&
                w.width != null &&
                w.width!.isFinite &&
                w.height != null,
          ),
        );
        final width = tester.getSize(slot).width;
        expect(boxes.single.right, lessThan(width));
        slotWidth ??= width;
        expect(width, closeTo(slotWidth, .01));
        expect(
          tester.getCenter(finder).dx,
          closeTo(tester.getCenter(find.text('12')).dx, .01),
        );
      }
      expect(tester.takeException(), isNull);
    }
  });
  test('focus painting hides inactive reference markers', () async {
    ir.TextBlock body(String id) => ir.TextBlock(
      nodeId: id,
      inlines: [
        const ir.TextRun('Body text'),
        const ir.TextRun(
          'A note',
          style: ir.TextStyle(inlineRole: ir.InlineRole.footnote),
        ),
      ],
    );
    final pages = LayoutEngine().paginate(
      ir.Section(
        id: const ir.SpineItemId.generated(0),
        spineIndex: 0,
        href: 'a',
        blocks: [body('a'), body('b')],
      ),
      const LayoutViewport(width: 360, height: 700),
      const ReaderStyle(),
    );
    final areas = [
      for (final p in pages.first.items.whereType<TextPlacement>())
        ui.Rect.fromLTWH(p.x, p.y, p.width, p.sliceHeight),
    ];
    Future<List<int>> pixels(List<ui.Rect>? visible) async {
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      PagePainter(
        page: pages.first,
        imageResolver: (_) => null,
        background: const Color(0xfffaf8f3),
        visibleFootnoteBounds: visible,
      ).paint(canvas, const ui.Size(360, 700));
      final picture = recorder.endRecording();
      final image = await picture.toImage(360, 700);
      final bytes = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      final counts = <int>[];
      for (final area in areas) {
        var count = 0;
        for (var y = area.top.floor(); y < area.bottom.ceil(); y++) {
          for (var x = area.left.floor(); x < area.right.ceil(); x++) {
            final offset = (y * 360 + x) * 4;
            if (bytes.getUint8(offset + 2) - bytes.getUint8(offset) > 25 &&
                bytes.getUint8(offset + 2) - bytes.getUint8(offset + 1) > 15) {
              count++;
            }
          }
        }
        counts.add(count);
      }
      image.dispose();
      picture.dispose();
      return counts;
    }

    expect(await pixels(null), everyElement(greaterThan(0)));
    final focused = await pixels([areas.first]);
    expect(focused.first, greaterThan(0));
    expect(focused.last, 0);
    for (final page in pages) {
      page.dispose();
    }
  });
}
