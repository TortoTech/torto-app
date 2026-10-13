import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:torto/app/progress_store.dart';
import 'package:torto/app/reader/reader_controller.dart';
import 'package:torto/core/ir/ir.dart';
import 'package:torto/core/layout/layout_types.dart';
import 'core/formats/pdf/pdf_book_source_test.dart' show buildFixturePdf;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late File pdf;
  late Directory derived;
  late ProgressStore progress;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('torto-reader-ocr-');
    final books = await Directory('${root.path}/books').create();
    pdf = await File('${books.path}/book.pdf').writeAsBytes(buildFixturePdf());
    derived = await Directory(
      '${root.path}/derived-sync-v1/book',
    ).create(recursive: true);
    final value = {
      'version': 1,
      'book_id': 'book',
      'view_mode': 'reflow',
      'pages': [
        {
          'markdown':
              '# First chapter\n\nOriginal OCR text on the first physical page.',
        },
        {'markdown': '# Chapter Two\n\nSecond physical page OCR text.'},
      ],
      'resources': [],
      'page_roles': [],
    };
    final archive = Archive()
      ..add(ArchiveFile('document.json', 0, utf8.encode(jsonEncode(value))));
    await File(
      '${derived.path}/ocr.zip',
    ).writeAsBytes(ZipEncoder().encode(archive));
    SharedPreferences.setMockInitialValues({});
    progress = ProgressStore(await SharedPreferences.getInstance());
  });
  tearDown(() => root.delete(recursive: true));

  Future<ReaderController> open() async {
    final controller = ReaderController(
      progressStore: progress,
      publicationIdHint: 'book',
    );
    addTearDown(controller.dispose);
    await controller.open(
      pdf,
      const LayoutViewport(width: 360, height: 640),
      const ReaderStyle(),
    );
    return controller;
  }

  test(
    'synced OCR opens as reflow and switches to original at the same physical page',
    () async {
      await progress.save(
        const LocatorV1(
          publicationId: 'book',
          href: 'Text/section-2.xhtml',
          position: 1,
        ),
      );
      final controller = await open();
      expect(controller.pdfOcrAvailable, isTrue);
      expect(controller.pdfReflowEnabled, isTrue);
      expect(controller.focusModeAllowed, isTrue);
      expect(controller.pdfSource, isNotNull);
      expect(
        controller.currentPage!.items.whereType<TextPlacement>(),
        isNotEmpty,
      );
      await controller.goToHref(controller.toc.single.href);
      expect(controller.sectionIndex, 1);
      expect(controller.currentPage, isNotNull);
      await controller.togglePdfReflow();
      expect(controller.pdfReflowEnabled, isFalse);
      expect(controller.focusModeAllowed, isFalse);
      expect(controller.sectionIndex, 1);
      expect(
        controller.currentPage!.items.whereType<ImagePlacement>(),
        isNotEmpty,
      );
      await controller.togglePdfReflow();
      expect(controller.pdfReflowEnabled, isTrue);
      expect(controller.sectionIndex, 1);
      expect(
        controller.currentPage!.items.whereType<TextPlacement>(),
        isNotEmpty,
      );
      await controller.flushProgress();
      controller.dispose();
      final reopened = await open();
      expect(reopened.pdfReflowEnabled, isTrue);
      expect(reopened.sectionIndex, 1);
    },
  );

  test(
    'damaged OCR falls back to original PDF without blocking reading',
    () async {
      await File('${derived.path}/ocr.zip').writeAsBytes([1, 2, 3]);
      final controller = await open();
      expect(controller.pdfOcrAvailable, isFalse);
      expect(
        controller.currentPage!.items.whereType<ImagePlacement>(),
        isNotEmpty,
      );
    },
  );
}
