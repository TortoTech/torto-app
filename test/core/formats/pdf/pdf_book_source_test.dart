import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:torto/core/formats/pdf/pdf_book_source.dart';
import 'package:torto/core/ir/ir.dart';

Uint8List buildFixturePdf() {
  List<int> ascii(String value) => Uint8List.fromList(value.codeUnits);

  List<int> stream(String value) =>
      ascii('<< /Length ${value.length} >>\nstream\n$value\nendstream');

  final objects = <List<int>>[
    ascii('<< /Type /Catalog /Pages 2 0 R /Outlines 8 0 R >>'),
    ascii('<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>'),
    ascii(
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] '
      '/Resources << /Font << /F1 5 0 R >> >> /Contents 6 0 R >>',
    ),
    ascii(
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] '
      '/Resources << /Font << /F1 5 0 R >> >> /Contents 7 0 R >>',
    ),
    ascii('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'),
    stream('BT /F1 16 Tf 20 50 Td (Hello PDF) Tj ET'),
    stream('BT /F1 16 Tf 20 50 Td (Second page) Tj ET'),
    ascii('<< /Type /Outlines /First 9 0 R /Last 9 0 R /Count 1 >>'),
    ascii('<< /Title (Chapter Two) /Parent 8 0 R /Dest [4 0 R /Fit] >>'),
    ascii('<< /Title (Fixture PDF) /Author (Test Author) >>'),
  ];

  final output = BytesBuilder(copy: false)..add(ascii('%PDF-1.4\n'));
  final offsets = <int>[];
  for (var index = 0; index < objects.length; index++) {
    offsets.add(output.length);
    output
      ..add(ascii('${index + 1} 0 obj\n'))
      ..add(objects[index])
      ..add(ascii('\nendobj\n'));
  }
  final xref = output.length;
  output.add(ascii('xref\n0 ${objects.length + 1}\n'));
  output.add(ascii('0000000000 65535 f \n'));
  for (final offset in offsets) {
    output.add(ascii('${offset.toString().padLeft(10, '0')} 00000 n \n'));
  }
  output.add(
    ascii(
      'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R '
      '/Info 10 0 R >>\nstartxref\n$xref\n%%EOF\n',
    ),
  );
  return output.takeBytes();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('adapts package metadata, page tree, outline, and text layer', () async {
    final source =
        await openPdf(buildFixturePdf(), 'fallback.pdf') as PdfBookSource;

    expect(source.book.metadata.title, 'Fixture PDF');
    expect(source.book.metadata.authors, ['Test Author']);
    expect(source.book.spine, hasLength(2));
    expect(source.book.toc, hasLength(1));
    expect(source.book.toc.single.label, 'Chapter Two');
    expect(source.book.toc.single.spineIndex, 1);
    expect(source.pageText(0)?.text, contains('Hello PDF'));
    expect(source.pageText(1)?.text, contains('Second page'));
  });

  test('honors synced identity and title hints', () async {
    final source = await openPdf(
      buildFixturePdf(),
      'fallback.pdf',
      titleHint: 'Synced title',
      publicationIdHint: 'book-id',
    );

    expect(source.book.id, 'book-id');
    expect(source.book.metadata.title, 'Synced title');
    final pdfSource = source as PdfBookSource;
    pdfSource.dispose();
    expect(() => pdfSource.pageText(0), throwsStateError);
  });

  testWidgets('renders fixed pages directly with the pure-Dart renderer', (
    tester,
  ) async {
    final source =
        await openPdf(buildFixturePdf(), 'fixture.pdf') as PdfBookSource;
    final section = await source.parseSection(0);
    final block = section.blocks.single as ImageBlock;

    expect(block.href, 'Pages/page-00001.png');
    expect(block.fixedPage, isTrue);
    final image = await tester.runAsync(
      () => source.rasterResource(block.href, maxDimension: 256),
    );
    addTearDown(() => image?.dispose());
    expect(image, isNotNull);
    expect(image!.width, 256);
    expect(image.height, 128);

    final cover = await tester.runAsync(
      () => source.resource(source.book.coverHref!),
    );
    expect(cover, isNotNull);
    expect(cover!.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
  });

  test('rejects non-PDF bytes even when a file path is supplied', () async {
    expect(
      () => openPdf(
        Uint8List.fromList(List.filled(64, 0x41)),
        'x.pdf',
        filePath: '/books/x.pdf',
      ),
      throwsFormatException,
    );
  });

  test('opens the real 四千周 PDF fixture when available', () async {
    final file = File('../torto/test-data/四千周.pdf');
    if (!file.existsSync()) return;

    final source =
        await openPdf(await file.readAsBytes(), '四千周.pdf') as PdfBookSource;
    expect(source.book.spine.length, greaterThan(100));
    expect(source.book.toc.length, greaterThan(10));

    final sample = source.pageText(10)?.text ?? '';
    expect(sample, contains(RegExp(r'[\u4e00-\u9fff]')));
  });
}
