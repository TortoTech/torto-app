import 'dart:io';
import 'package:crypto/crypto.dart';
import 'dart:math' as math;
import 'package:pdf_cos/pdf_cos.dart';
import 'package:pdf_document/pdf_document.dart';
import 'package:pdf_graphics/pdf_graphics.dart';

void main(List<String> args) {
  final document = PdfDocument.open(File(args[0]).readAsBytesSync());
  for (final pageIndex in [15, 16, 15]) {
    final page = document.page(pageIndex);
    final recorder = RecordingPdfDevice();
    final clock = Stopwatch()..start();
    PdfInterpreter(
      cos: document.cos,
      device: recorder,
    ).drawPageContent(page, page.contentBytes());
    stdout.writeln(
      'page=$pageIndex interpret_ms=${clock.elapsedMilliseconds} images=${recorder.imageRequests.length}',
    );
    for (final request in recorder.imageRequests) {
      int integer(String key) =>
          (document.cos.resolve(request.stream.dictionary[key]) as CosInteger)
              .value;
      final width = integer('Width'), height = integer('Height');
      final ratio = math.min(1.0, 2048 / math.max(width, height));
      clock.reset();
      final base = decodePdfImageBase(
        document.cos,
        request.stream,
        targetWidth: (width * ratio).round(),
        targetHeight: (height * ratio).round(),
      );
      final baseMs = clock.elapsedMilliseconds;
      clock.reset();
      final mask = pdfImageSoftMask(
        document.cos,
        request.stream.dictionary,
        targetWidth: base?.width,
        targetHeight: base?.height,
      );
      stdout.writeln(
        'image=${width}x$height filter=${pdfImageFilters(document.cos, request.stream.dictionary)} base_ms=$baseMs mask_ms=${clock.elapsedMilliseconds} masked=${mask != null} base_sha256=${base == null ? 'null' : sha256.convert(base.rgba)}',
      );
    }
  }
}
