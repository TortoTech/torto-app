import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torto/core/formats/pdf/pdf_book_source.dart';
import 'package:torto/core/formats/pdf/pdf_native_generator.dart';
import 'package:torto/core/formats/pdf/pdf_native_book_source.dart';
import 'package:torto/core/ir/text_index.dart';
import 'pdf_book_source_test.dart' show buildFixturePdf;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('changed input preserves the last archive', () async {
    final root = await Directory.systemTemp.createTemp('native-input-test-');
    addTearDown(() => root.delete(recursive: true));
    final file = await File(
      '${root.path}/book.pdf',
    ).writeAsBytes(buildFixturePdf());
    final source =
        await openPdf(buildFixturePdf(), 'book.pdf') as PdfBookSource;
    addTearDown(source.dispose);
    await File('${root.path}/native-pdf.zip').writeAsString('previous');
    await file.writeAsBytes([...buildFixturePdf(), 10]);
    await expectLater(
      PdfNativeGenerator().generate(file: file, original: source, root: root),
      throwsStateError,
    );
    expect(
      await File('${root.path}/native-pdf.zip').readAsString(),
      'previous',
    );
  });
  test(
    'phone produces a desktop-readable v14 archive with targets and provenance',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'native-generator-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = await File(
        '${directory.path}/test.pdf',
      ).writeAsBytes(buildFixturePdf());
      final source =
          await openPdf(buildFixturePdf(), 'test.pdf') as PdfBookSource;
      addTearDown(source.dispose);
      final root = Directory('${directory.path}/derived');
      final progress = <int>[];
      final stats = await PdfNativeGenerator().generate(
        file: file,
        original: source,
        root: root,
        onProgress: (page, total) => progress.add(page),
      );
      expect(stats['text_pages'], 2);
      expect(progress, [1, 2]);
      final archive = ZipDecoder().decodeBytes(
        await File('${root.path}/native-pdf.zip').readAsBytes(),
      );
      final manifest = jsonDecode(
        utf8.decode(archive.find('manifest.json')!.readBytes()!),
      );
      expect(manifest['version'], 14);
      expect(manifest['book']['sections'][0]['href'], {
        'path': 'Text/native-0.xhtml',
      });
      final section = jsonDecode(
        utf8.decode(archive.find('sections/0.json')!.readBytes()!),
      );
      final sidecar = section['provenance_resource'] as String;
      final mapping = archive.find(sidecar)!.readBytes()!;
      expect(ascii.decode(mapping.take(8).toList()), 'TRTPRV01');
      expect(ZLibCodec().decode(mapping.skip(8).toList()), isNotEmpty);
      final native = await loadPdfNativeBookSource(source, root);
      expect(native, isNotNull);
      expect(
        sectionTextNodes(await native!.parseSection(0)).single.text,
        'Hello PDF',
      );
      expect(native.reflowTarget(1), 'Text/native-1.xhtml#pdf-page-2');
      expect(native.physicalPage(1, null, null), 1);
      final sync = jsonDecode(
        await File('${root.path}/native-pdf.json').readAsString(),
      );
      expect(sync['pending_upload'], isTrue);
      expect(sync['producer'], 'torto-app');
    },
  );
  test(
    'cancelled conversion preserves the previous published generation',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'native-cancel-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = await File(
        '${directory.path}/test.pdf',
      ).writeAsBytes(buildFixturePdf());
      final source =
          await openPdf(buildFixturePdf(), 'test.pdf') as PdfBookSource;
      addTearDown(source.dispose);
      final previous = await File(
        '${directory.path}/native-pdf.zip',
      ).writeAsString('previous');
      final generator = PdfNativeGenerator()..cancel();
      await expectLater(
        generator.generate(file: file, original: source, root: directory),
        throwsStateError,
      );
      expect(await previous.readAsString(), 'previous');
    },
  );
}
