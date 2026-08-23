import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:torto/app/progress_store.dart';
import 'package:torto/app/reader/reader_controller.dart';
import 'package:torto/core/layout/layout_types.dart';
import 'package:torto/core/render/page_painter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final fixture in const [
    ('../torto/test-data/Thinking in Systems A Primer.epub', 0, true),
    ('../torto/test-data/1.azw3', 1, false),
  ]) {
    test('image page decodes and paints: ${fixture.$1}', () async {
      final file = File(fixture.$1);
      if (!file.existsSync()) return;

      SharedPreferences.setMockInitialValues({});
      final controller = ReaderController(
        progressStore: ProgressStore(await SharedPreferences.getInstance()),
      );
      addTearDown(controller.dispose);
      await controller.open(
        file,
        const LayoutViewport(width: 412, height: 915),
        const ReaderStyle(baseFontSize: 20),
      );
      if (fixture.$2 != controller.sectionIndex) {
        await controller.goToSection(fixture.$2);
      }

      final page = controller.currentPage;
      expect(page, isNotNull);
      final imagePlacements = page!.items.whereType<ImagePlacement>().toList();
      expect(imagePlacements, isNotEmpty);
      if (fixture.$3) {
        expect(page.items, hasLength(1));
        expect(
          imagePlacements.single.rect.center.dy,
          closeTo(915 / 2, 0.01),
          reason: 'a standalone cover should be vertically centered',
        );
      }
      for (final placement in imagePlacements) {
        expect(
          controller.resolveImage(placement.href),
          isNotNull,
          reason: 'decoded image should be retained for ${placement.href}',
        );
      }

      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      PagePainter(
        page: page,
        imageResolver: controller.resolveImage,
        background: const ui.Color(0xFFFFFFFF),
        foreground: const ui.Color(0xFF000000),
      ).paint(canvas, const ui.Size(412, 915));
      final picture = recorder.endRecording();
      final rendered = await picture.toImage(412, 915);
      final data = await rendered.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      final pixels = data!.buffer.asUint8List();
      var nonWhitePixels = 0;
      for (var offset = 0; offset < pixels.length; offset += 4) {
        if (pixels[offset] < 245 ||
            pixels[offset + 1] < 245 ||
            pixels[offset + 2] < 245) {
          nonWhitePixels++;
        }
      }
      expect(nonWhitePixels, greaterThan(500));

      rendered.dispose();
      picture.dispose();
    });
  }
}
