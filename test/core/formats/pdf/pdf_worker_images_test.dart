import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_cos/pdf_cos.dart';
import 'package:pdf_document/pdf_document.dart';
import 'package:pdf_graphics/pdf_graphics.dart';
import 'package:torto/core/formats/pdf/pdf_book_source.dart';
import 'package:torto/core/formats/pdf/pdf_worker_images.dart';

Uint8List twoImagePdf() {
  String stream(String content) =>
      '<< /Length ${content.length} >>\nstream\n$content\nendstream';
  final objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] /Resources << /XObject << /Red 4 0 R /Blue 5 0 R >> >> /Contents 6 0 R >>',
    '<< /Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Length 3 >>\nstream\n\xff\x00\x00\nendstream',
    '<< /Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Length 3 >>\nstream\n\x00\x00\xff\nendstream',
    stream('q 100 0 0 100 0 0 cm /Red Do Q q 100 0 0 100 100 0 cm /Blue Do Q'),
  ];
  final output = BytesBuilder(copy: false)..add('%PDF-1.4\n'.codeUnits);
  final offsets = <int>[];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(output.length);
    output.add('${i + 1} 0 obj\n${objects[i]}\nendobj\n'.codeUnits);
  }
  final xref = output.length;
  output.add('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n'.codeUnits);
  for (final offset in offsets) {
    output.add('${offset.toString().padLeft(10, '0')} 00000 n \n'.codeUnits);
  }
  output.add(
    'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n'
        .codeUnits,
  );
  return output.takeBytes();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('rebinds images nested in soft masks and tiled cells', () {
    final document = PdfDocument.open(twoImagePdf());
    final placeholder = CosStream(CosDictionary(), Uint8List(0));
    PdfDrawImageCommand draw(int id) => PdfDrawImageCommand(
      PdfImageRequest(
        stream: placeholder,
        sourceReference: CosReference(id, 0),
        transform: const PdfMatrix(1, 0, 0, 1, 0, 0),
        alpha: .4,
      ),
    );
    final bound = bindPdfWorkerImages([
      PdfEndSoftMaskedCommand(
        luminosity: true,
        backdrop: const PdfRect(0, 0, 10, 10),
        maskCommands: [draw(4)],
        transferScale: .5,
        transferOffset: .1,
      ),
      PdfDrawTiledCellCommand(
        [draw(5)],
        Float64List.fromList([0]),
        Float64List.fromList([0]),
      ),
    ], document.cos);
    final mask = bound[0] as PdfEndSoftMaskedCommand;
    final tile = bound[1] as PdfDrawTiledCellCommand;
    final red = (mask.maskCommands.single as PdfDrawImageCommand).request;
    final blue = (tile.cellCommands.single as PdfDrawImageCommand).request;
    expect(
      identical(red.stream, document.cos.resolve(const CosReference(4, 0))),
      isTrue,
    );
    expect(identical(red.stream, blue.stream), isFalse);
    expect(red.alpha, .4);
    expect(mask.transferScale, .5);
    expect(mask.transferOffset, .1);
  });
  testWidgets(
    'worker XObjects keep independent image identities through replay and cache hits',
    (tester) async {
      await tester.runAsync(() async {
        final source =
            await openPdf(twoImagePdf(), 'two-images.pdf') as PdfBookSource;
        try {
          for (var i = 0; i < 2; i++) {
            final image = (await source.rasterResource(
              'Pages/page-00001.png',
              maxDimension: 200,
            ))!;
            try {
              final data = (await image.toByteData(
                format: ui.ImageByteFormat.rawRgba,
              ))!.buffer.asUint8List();
              final left = (50 * image.width + 50) * 4;
              final right = (50 * image.width + 150) * 4;
              expect(data.sublist(left, left + 4), [255, 0, 0, 255]);
              expect(data.sublist(right, right + 4), [0, 0, 255, 255]);
            } finally {
              image.dispose();
            }
          }
        } finally {
          source.dispose();
        }
      });
    },
  );
}
