import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:torto/core/diagnostics.dart';
import 'package:torto/core/formats/pdf/pdf_book_source.dart';
import 'package:torto/core/formats/pdf/pdf_raster_cache.dart';
import 'pdf_worker_images_test.dart' show twoImagePdf;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('torto-pdf-cache-');
  });
  tearDown(() => root.delete(recursive: true));

  test(
    'cache keys include content, page and dimensions; eviction respects hits',
    () async {
      final cache = PdfRasterCache(root, 'a' * 64, maxBytes: 8, maxEntries: 2);
      final bytes = Uint8List.fromList([1, 2, 3, 4]);
      await cache.write(0, 200, bytes);
      await cache.write(1, 200, bytes);
      for (final file in await root.list().toList()) {
        await (file as File).setLastModified(DateTime(2010));
      }
      expect(await cache.read(0, 200), bytes);
      expect(await cache.read(0, 201), isNull);
      expect(await PdfRasterCache(root, 'b' * 64).read(0, 200), isNull);
      await cache.write(2, 200, bytes);
      expect(await cache.read(0, 200), bytes);
      expect(await cache.read(1, 200), isNull);
      expect(await root.list().length, 2);
      await cache.write(3, 200, Uint8List(9));
      expect(await cache.read(3, 200), isNull);
      expect(await root.list().length, 2);
    },
  );

  test('an unavailable cache is a miss, never a failed book open', () async {
    final blocker = File('${root.path}/file');
    await blocker.writeAsString('unchanged');
    final cache = PdfRasterCache(Directory('${blocker.path}/child'), 'a' * 64);
    await cache.write(0, 200, Uint8List(4));
    expect(await cache.read(0, 200), isNull);
    expect(await blocker.readAsString(), 'unchanged');
  });

  testWidgets(
    'reopened pages use a lossless disk hit and changed bytes miss it',
    (tester) async {
      await tester.runAsync(() async {
        final cacheRoot = Directory('${root.path}/pages');
        await ReaderDiagnostics.instance.initialize(
          Directory('${root.path}/logs'),
        );
        final bytes = twoImagePdf();
        final first =
            await openPdf(
                  bytes,
                  'same.pdf',
                  publicationIdHint: 'same-id',
                  rasterCacheDirectory: cacheRoot,
                )
                as PdfBookSource;
        final png = await first.resource('Pages/page-00001.png');
        expect(png, isNotNull);
        first.dispose();
        final second =
            await openPdf(
                  bytes,
                  'same.pdf',
                  publicationIdHint: 'same-id',
                  rasterCacheDirectory: cacheRoot,
                )
                as PdfBookSource;
        final image = (await second.rasterResource(
          'Pages/page-00001.png',
          maxDimension: 2048,
        ))!;
        final data = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!.buffer.asUint8List();
        final pixel =
            ((image.height ~/ 2) * image.width + image.width ~/ 4) * 4;
        expect(data.sublist(pixel, pixel + 4), [255, 0, 0, 255]);
        expect(
          await ReaderDiagnostics.instance.export(),
          contains('pdf.cache.hit'),
        );
        image.dispose();
        second.dispose();
        // Same filename/publication ID, different valid image bytes: cannot reuse old pixels.
        final modified = Uint8List.fromList(bytes);
        final red = modified.indexOf(255);
        modified[red] = 0;
        modified[red + 1] = 255;
        final third =
            await openPdf(
                  modified,
                  'same.pdf',
                  publicationIdHint: 'same-id',
                  rasterCacheDirectory: cacheRoot,
                )
                as PdfBookSource;
        final changed = (await third.rasterResource(
          'Pages/page-00001.png',
          maxDimension: 200,
        ))!;
        final changedData = (await changed.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!.buffer.asUint8List();
        final changedPixel =
            ((changed.height ~/ 2) * changed.width + changed.width ~/ 4) * 4;
        expect(changedData.sublist(changedPixel, changedPixel + 4), [
          0,
          255,
          0,
          255,
        ]);
        // Drain the same page's cache write before deleting its test directory.
        await third.resource('Pages/page-00001.png');
        changed.dispose();
        third.dispose();
        await PdfRasterCache(cacheRoot, 'a' * 64).flush();
        await ReaderDiagnostics.instance.export();
      });
    },
  );
}
