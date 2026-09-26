import 'dart:io';
import 'dart:ui' as ui;
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:torto/core/formats/pdf/pdf_book_source.dart';
import 'package:torto/core/formats/pdf/pdf_raster_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fixture = Platform.environment['TORTO_PDF_MASK_FIXTURE'];
  testWidgets(
    'same real PDF reopens from a bit-identical lossless page cache',
    (tester) async {
      await tester.runAsync(() async {
        final root = await Directory.systemTemp.createTemp(
          'torto-real-raster-',
        );
        final bytes = await File(fixture!).readAsBytes();
        final fingerprint = sha256.convert(bytes).toString();
        final cache = PdfRasterCache(root, fingerprint);
        String? expected;
        try {
          for (var attempt = 0; attempt < 3; attempt++) {
            final total = Stopwatch()..start();
            final source =
                await openPdf(bytes, 'real.pdf', rasterCacheDirectory: root)
                    as PdfBookSource;
            try {
              final openedMs = total.elapsedMilliseconds;
              final image = (await source.rasterResource(
                'Pages/page-00016.png',
                maxDimension: 2048,
              ))!;
              final readyMs = total.elapsedMilliseconds;
              final data = (await image.toByteData(
                format: ui.ImageByteFormat.rawRgba,
              ))!;
              final hash = sha256.convert(data.buffer.asUint8List()).toString();
              image.dispose();
              expected ??= hash;
              expect(hash, expected);
              await cache.flush();
              debugPrint(
                'PDF_CACHE attempt=$attempt metadata_ms=$openedMs ready_ms=$readyMs rgba_sha256=$hash',
              );
            } finally {
              source.dispose();
            }
          }
        } finally {
          await cache.flush();
          await root.delete(recursive: true);
        }
      });
    },
    skip: fixture == null,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
