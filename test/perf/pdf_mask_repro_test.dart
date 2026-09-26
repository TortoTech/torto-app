import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:pdf_document/pdf_document.dart';
import 'package:pdf_cos/perf.dart';
import 'package:torto/core/formats/pdf/pdf_book_source.dart';
import 'package:torto/core/formats/pdf/pdf_rasterizer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fixture = Platform.environment['TORTO_PDF_MASK_FIXTURE'];
  testWidgets(
    'real MRC page retains its text mask in the worker render',
    (tester) async {
      await tester.runAsync(() async {
        final bytes = await File(fixture!).readAsBytes();
        final directory = Directory('../output/torto-device-test-20260922');
        await directory.create(recursive: true);
        final source =
            await openPdf(bytes, 'mask-fixture.pdf') as PdfBookSource;
        final document = PdfDocument.open(bytes);
        try {
          for (final worker in [false, true]) {
            PdfPerf.enabled = true;
            PdfPerf.reset();
            final clock = Stopwatch()..start();
            final image = worker
                ? (await source.rasterResource(
                    'Pages/page-00016.png',
                    maxDimension: 1500,
                  ))!
                : await rasterizePdfPage(document.page(15), maxDimension: 1500);
            final png = await image.toByteData(format: ui.ImageByteFormat.png);
            await File(
              '${directory.path}/pdf-${worker ? 'worker' : 'local'}-16.png',
            ).writeAsBytes(png!.buffer.asUint8List());
            final raw = await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            );
            final pixels = raw!.buffer.asUint8List();
            var dark = 0;
            for (var i = 0; i < pixels.length; i += 4) {
              if (pixels[i] < 100 &&
                  pixels[i + 1] < 100 &&
                  pixels[i + 2] < 100 &&
                  pixels[i + 3] > 128) {
                dark++;
              }
            }
            // A page of black printed text must contain foreground ink.
            debugPrint(
              'PDF_MASK worker=$worker elapsed_ms=${clock.elapsedMilliseconds} dark_pixels=$dark',
            );
            if (!worker) debugPrint('PDF_PHASES ${PdfPerf.snapshot().toJson()}');
            image.dispose();
            expect(
              dark,
              greaterThan(1000),
              reason: 'The foreground text mask must be painted',
            );
          }
        } finally {
          PdfPerf.enabled = false;
          source.dispose();
        }
      });
    },
    skip: fixture == null,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
