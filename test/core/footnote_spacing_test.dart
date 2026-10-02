import 'dart:ui' as ui;
import 'package:flutter/material.dart' as m;
import 'package:torto/core/render/page_painter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torto/core/ir/ir.dart';
import 'package:torto/core/layout/footnote_spacing.dart';
import 'package:torto/core/layout/layout_engine.dart';
import 'package:torto/core/layout/layout_types.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Latin period keeps a visible gap before the painted superscript',
    () async {
      await (FontLoader('Literata')
            ..addFont(rootBundle.load('assets/fonts/Literata-opsz-wght.ttf')))
          .load();
      for (final fontSize in [18.0, 20.0, 28.0]) {
        for (final strategy in LineBreakStrategy.values) {
          final block = TextBlock(
            nodeId: 'p',
            inlines: const [
              TextRun('Sentence.'),
              TextRun(
                'Note',
                style: TextStyle(inlineRole: InlineRole.footnote),
              ),
              TextRun(' Next sentence.'),
            ],
          );
          final section = Section(
            id: const SpineItemId.generated(0),
            spineIndex: 0,
            href: 'a',
            blocks: [block],
          );
          final style = ReaderStyle(
            baseFontSize: fontSize,
            lineBreakStrategy: strategy,
          );
          await FootnoteSpacing.prepare(section, style);
          final pages = LayoutEngine().paginate(
            section,
            const LayoutViewport(width: 360, height: 700),
            style,
          );
          final p = pages.first.items.whereType<TextPlacement>().first;
          final link = p.links.single;
          expect(link.referencePaintOffset, greaterThan(0));
          final recorder = ui.PictureRecorder();
          PagePainter(
            page: pages.first,
            imageResolver: (_) => null,
            background: m.Colors.white,
          ).paint(ui.Canvas(recorder), const ui.Size(360, 700));
          final picture = recorder.endRecording();
          final image = await picture.toImage(360, 700);
          final data = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          var markerLeft = 360;
          for (var y = 0; y < 700; y++) {
            for (var x = 0; x < 360; x++) {
              final i = (y * 360 + x) * 4;
              if (data.getUint8(i + 2) - data.getUint8(i) > 25 &&
                  data.getUint8(i + 2) - data.getUint8(i + 1) > 15) {
                markerLeft = markerLeft < x ? markerLeft : x;
              }
            }
          }
          var previousRight = -1;
          for (var y = 0; y < 700; y++) {
            for (var x = 0; x < markerLeft; x++) {
              final i = (y * 360 + x) * 4;
              if (data.getUint8(i) < 100 &&
                  data.getUint8(i + 1) < 100 &&
                  data.getUint8(i + 2) < 100) {
                previousRight = x > previousRight ? x : previousRight;
              }
            }
          }
          expect(markerLeft, lessThan(360));
          expect(previousRight, greaterThanOrEqualTo(0));
          expect(markerLeft - previousRight - 1, greaterThanOrEqualTo(2));
          expect(p.displayToSource.last, block.plainText.runes.length);
          image.dispose();
          picture.dispose();
          for (final page in pages) {
            page.dispose();
          }
        }
      }
    },
  );
  test('CJK markers keep visible painted gaps on both sides', () async {
    await (FontLoader(
      'Literata',
    )..addFont(rootBundle.load('assets/fonts/Literata-opsz-wght.ttf'))).load();
    await (FontLoader(
      'LXGW WenKai GB Screen',
    )..addFont(rootBundle.load('assets/fonts/LXGWWenKaiGBScreen.ttf'))).load();
    for (final prefix in ['\u6c49\u5b57', '\u53e5\u3002']) {
      for (final fontSize in [18.0, 20.0, 28.0]) {
        for (final strategy in LineBreakStrategy.values) {
          final section = Section(
            id: const SpineItemId.generated(0),
            spineIndex: 0,
            href: 'a',
            blocks: [
              TextBlock(
                nodeId: 'p',
                inlines: [
                  TextRun(prefix),
                  const TextRun(''),
                  const TextRun(
                    'Note',
                    style: TextStyle(inlineRole: InlineRole.footnote),
                  ),
                  const TextRun(''),
                  TextRun('\u4e2d\u6587\u7ee7\u7eed' * 12),
                ],
              ),
            ],
          );
          final style = ReaderStyle(
            writingSystem: WritingSystem.cjk,
            baseFontSize: fontSize,
            lineBreakStrategy: strategy,
          );
          await FootnoteSpacing.prepare(section, style);
          final pages = LayoutEngine().paginate(
            section,
            const LayoutViewport(width: 360, height: 700),
            style,
          );
          final p = pages.first.items.whereType<TextPlacement>().first,
              link = p.links.single;
          final recorder = ui.PictureRecorder();
          PagePainter(
            page: pages.first,
            imageResolver: (_) => null,
            background: m.Colors.white,
          ).paint(ui.Canvas(recorder), const ui.Size(360, 700));
          final picture = recorder.endRecording(),
              image = await picture.toImage(360, 700),
              bytes = (await image.toByteData(
                format: ui.ImageByteFormat.rawRgba,
              ))!;
          final line = p.paragraph
              .computeLineMetrics()[p.paragraph.getLineNumberAt(link.start)!];
          final minY = (p.y - p.sliceTop + line.baseline - line.ascent)
              .floor()
              .clamp(0, 699);
          final maxY = (p.y - p.sliceTop + line.baseline + line.descent)
              .ceil()
              .clamp(0, 700);
          var left = 360, right = -1;
          for (var y = minY; y < maxY; y++) {
            for (var x = 0; x < 360; x++) {
              final i = (y * 360 + x) * 4;
              if (bytes.getUint8(i + 2) - bytes.getUint8(i) > 25 &&
                  bytes.getUint8(i + 2) - bytes.getUint8(i + 1) > 15) {
                left = left < x ? left : x;
                right = right > x ? right : x;
              }
            }
          }
          var previous = -1, next = 360;
          for (var y = minY; y < maxY; y++) {
            for (var x = 0; x < 360; x++) {
              final i = (y * 360 + x) * 4;
              if (bytes.getUint8(i) < 100 &&
                  bytes.getUint8(i + 1) < 100 &&
                  bytes.getUint8(i + 2) < 100) {
                if (x < left) previous = previous > x ? previous : x;
                if (x > right) next = next < x ? next : x;
              }
            }
          }
          expect(
            right,
            greaterThanOrEqualTo(left),
            reason: 'painted numeral must exist',
          );
          expect(
            left - previous - 1,
            greaterThanOrEqualTo(2),
            reason: 'visible gap after CJK text',
          );
          expect(
            next - right - 1,
            inInclusiveRange(2, (fontSize * .3).ceil()),
            reason: 'right glyph must follow the same advance as marker paint',
          );
          expect(
            p.displayToSource.last,
            (section.blocks.first as TextBlock).plainText.runes.length,
          );
          expect(p.paragraph.computeLineMetrics().length, greaterThan(1));
          image.dispose();
          picture.dispose();
          for (final page in pages) {
            page.dispose();
          }
        }
      }
    }
  });
  test(
    'optical footnotes close punctuation gaps and keep canonical hit regions',
    () async {
      await (FontLoader('Literata')
            ..addFont(rootBundle.load('assets/fonts/Literata-opsz-wght.ttf')))
          .load();
      await (FontLoader('LXGW WenKai GB Screen')
            ..addFont(rootBundle.load('assets/fonts/LXGWWenKaiGBScreen.ttf')))
          .load();
      final block = TextBlock(
        nodeId: 'p',
        inlines: [
          const TextRun('\u9605\u8bfb\u7ed3\u675f\u3002'),
          const TextRun(
            'Explanatory note',
            style: TextStyle(inlineRole: InlineRole.footnote),
          ),
          const TextRun(
            '\u4e2d\u6587\u7ee7\u7eed\uff0c\u540e\u7eed\u8fd8\u6709\u6b63\u6587\u3002',
          ),
        ],
      );
      final section = Section(
        id: const SpineItemId.generated(0),
        spineIndex: 0,
        href: 'a',
        blocks: [block],
      );
      const style = ReaderStyle(writingSystem: WritingSystem.cjk);
      await FootnoteSpacing.prepare(section, style);
      for (final strategy in LineBreakStrategy.values) {
        final pages = LayoutEngine().paginate(
          section,
          const LayoutViewport(width: 360, height: 700),
          style.copyWith(lineBreakStrategy: strategy),
        );
        final p = pages.first.items.whereType<TextPlacement>().first;
        final link = p.links.single;
        final note = p.paragraph
            .getBoxesForRange(link.start, link.end)
            .firstWhere((box) => box.right - box.left > 0.5);
        final punctuation = p.paragraph
            .getBoxesForRange(
              p.displayToSource.indexOf(4),
              p.displayToSource.indexOf(4) + 1,
            )
            .first;
        expect(
          note.left + link.referencePaintOffset,
          lessThan(punctuation.right - 1),
          reason: 'compress unused punctuation advance',
        );
        expect(link.referenceGlyphAdvance, greaterThan(0));
        final line = p.paragraph.getLineNumberAt(link.start)!;
        final baseline =
            p.y - p.sliceTop + p.paragraph.computeLineMetrics()[line].baseline;
        expect(
          pages.first.linkAt(
            Offset(
              p.x +
                  note.left +
                  link.referencePaintOffset +
                  link.referenceGlyphAdvance / 2,
              baseline -
                  link.referenceBaselineRise -
                  link.referenceFontSize / 2,
            ),
          ),
          same(link),
        );
        expect(p.displayToSource.last, block.plainText.runes.length);
        expect(
          p.displayToSource,
          orderedEquals(p.displayToSource.toList()..sort()),
        );
        for (final page in pages) {
          page.dispose();
        }
      }
    },
  );
}
