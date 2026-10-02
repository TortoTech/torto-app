import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:torto/app/reader/reader_controller.dart';
import 'package:torto/core/layout/layout_types.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'a many-image EPUB keeps full layout dimensions and upgrades only visible textures for DPR',
    () async {
      SharedPreferences.setMockInitialValues({});
      final root = await Directory.systemTemp.createTemp(
        'torto-image-quality-',
      );
      addTearDown(() => root.delete(recursive: true));
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawRect(
        const ui.Rect.fromLTWH(0, 0, 1800, 1200),
        ui.Paint()..color = const ui.Color(0xff336699),
      );
      final picture = recorder.endRecording();
      final original = await picture.toImage(1800, 1200);
      final png = (await original.toByteData(
        format: ui.ImageByteFormat.png,
      ))!.buffer.asUint8List();
      original.dispose();
      picture.dispose();
      final archive = Archive();
      void text(String path, String value) {
        final bytes = utf8.encode(value);
        archive.addFile(ArchiveFile(path, bytes.length, bytes));
      }

      text('mimetype', 'application/epub+zip');
      text(
        'META-INF/container.xml',
        '<container><rootfiles><rootfile full-path="book.opf"/></rootfiles></container>',
      );
      text(
        'book.opf',
        '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">image-test</dc:identifier><dc:title>Images</dc:title></metadata><manifest><item id="a" href="a.xhtml" media-type="application/xhtml+xml"/>${List.generate(50, (i) => '<item id="im$i" href="im$i.png" media-type="image/png"/>').join()}</manifest><spine><itemref idref="a"/></spine></package>',
      );
      text(
        'a.xhtml',
        '<html><body>${List.generate(50, (i) => '<p><img src="im$i.png"/></p>').join()}</body></html>',
      );
      for (var i = 0; i < 50; i++) {
        archive.addFile(ArchiveFile('im$i.png', png.length, png));
      }
      final file = await File(
        '${root.path}/book.epub',
      ).writeAsBytes(ZipEncoder().encode(archive));
      final controller = ReaderController();
      addTearDown(controller.dispose);
      await controller.open(
        file,
        const LayoutViewport(width: 411, height: 700),
        const ReaderStyle(),
      );
      final page = controller.currentPage!;
      final placement = page.items.whereType<ImagePlacement>().first;
      controller.prepareReaderImages([page], 1);
      for (
        var i = 0;
        i < 100 && controller.resolveImage(placement.href) == null;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final low = controller.resolveImage(placement.href)!;
      final lowWidth = low.width;
      controller.prepareReaderImages([page], 3);
      for (
        var i = 0;
        i < 100 && controller.resolveImage(placement.href)!.width == lowWidth;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(controller.resolveImage(placement.href)!.width, greaterThan(900));
      expect(controller.resolveImage('im49.png'), isNull);
      expect(controller.currentPage, same(page));
      expect(
        controller.currentPage!.items.whereType<ImagePlacement>().first.rect,
        placement.rect,
      );
      final preview = await controller.imagePreview(placement.href);
      expect(preview!.width, 1800);
      expect(preview.height, 1200);
      preview.dispose();
    },
  );
}
