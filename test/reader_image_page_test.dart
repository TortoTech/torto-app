import 'dart:io';
import 'dart:ui' as ui;
import 'package:archive/archive.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:torto/app/progress_store.dart';
import 'package:torto/app/reader/reader_controller.dart';
import 'package:torto/core/layout/layout_types.dart';
import 'package:torto/core/render/page_painter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('inline quote and table images survive page-cache eviction', () async {
    final directory = await Directory.systemTemp.createTemp(
      'torto-inline-image-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawRect(
      const ui.Rect.fromLTWH(0, 0, 8, 4),
      ui.Paint()..color = const ui.Color(0xff123456),
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(8, 4);
    final png = (await image.toByteData(
      format: ui.ImageByteFormat.png,
    ))!.buffer.asUint8List();
    image.dispose();
    picture.dispose();
    final archive = Archive();
    void add(String path, String text) =>
        archive.addFile(ArchiveFile.string(path, text));
    add('mimetype', 'application/epub+zip');
    add(
      'META-INF/container.xml',
      '<container><rootfiles><rootfile full-path="book.opf"/></rootfiles></container>',
    );
    add(
      'book.opf',
      '<package><metadata><title>Inline image fixture</title></metadata><manifest>'
          '${List.generate(4, (i) => '<item id="s$i" href="s$i.xhtml" media-type="application/xhtml+xml"/>').join()}'
          '</manifest><spine>${List.generate(4, (i) => '<itemref idref="s$i"/>').join()}</spine></package>',
    );
    for (var i = 0; i < 4; i++) {
      final content = i == 0
          ? '<blockquote><p>Quote <img src="image0.png" style="height:1em"/> text</p></blockquote>'
          : i == 3
          ? '<table><tr><td>Cell <img src="image3.png" style="height:1em"/> text</td></tr></table>'
          : '<p>Section $i</p>';
      add('s$i.xhtml', '<html><body>$content</body></html>');
      archive.addFile(ArchiveFile('image$i.png', png.length, png));
    }
    final file = File('${directory.path}/fixture.epub');
    await file.writeAsBytes(ZipEncoder().encodeBytes(archive));
    SharedPreferences.setMockInitialValues({});
    final controller = ReaderController(
      progressStore: ProgressStore(await SharedPreferences.getInstance()),
    );
    addTearDown(controller.dispose);
    await controller.open(
      file,
      const LayoutViewport(width: 400, height: 700),
      const ReaderStyle(),
    );
    controller.prepareReaderImages([controller.currentPage!], 3);
    await waitForImage(controller, 'image0.png');
    expect(controller.resolveImage('image0.png'), isNotNull);
    await controller.goToSection(1);
    expect(controller.resolveImage('image0.png'), isNotNull);
    await controller.goToSection(3);
    controller.prepareReaderImages([controller.currentPage!], 3);
    await waitForImage(controller, 'image3.png');
    expect(controller.resolveImage('image3.png'), isNotNull);
    expect(controller.resolveImage('image0.png'), isNull);
  });

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
        controller.prepareReaderImages([page], 3);
        await waitForImage(controller, placement.href);
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

Future<void> waitForImage(ReaderController controller, String href) async {
  for (var i = 0; i < 200 && controller.resolveImage(href) == null; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
