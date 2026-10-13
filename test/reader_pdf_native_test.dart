import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:torto/app/progress_store.dart';
import 'package:torto/app/reader/reader_controller.dart';
import 'package:torto/core/layout/layout_types.dart';
import 'core/formats/pdf/pdf_book_source_test.dart' show buildFixturePdf;
import 'core/formats/pdf/pdf_native_book_source_test.dart'
    show fixtureManifest, fixtureSection;
import 'core/formats/pdf/pdf_ocr_book_source_test.dart' show document;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'image text search jumps to later displayed glyphs while keeping a zero source anchor',
    () async {
      final root = await Directory.systemTemp.createTemp('reader-ocr-search-');
      addTearDown(() => root.delete(recursive: true));
      final books = await Directory('${root.path}/books').create();
      final file = await File(
        '${books.path}/book.pdf',
      ).writeAsBytes(buildFixturePdf());
      final derived = await Directory(
        '${root.path}/derived-sync-v1/book',
      ).create(recursive: true);
      final manifest = fixtureManifest();
      manifest['page_targets'] = [
        'Text/native-0.xhtml#pdf-page-1',
        'Text/native-1.xhtml#pdf-page-2',
      ];
      final first = fixtureSection(0, ''),
          second = fixtureSection(1, 'Next physical page.');
      (first['section']['anchors'] as List).removeLast();
      (second['section']['anchors'] as List).removeLast();
      second['section']['anchors'][0]['fragment'] = 'pdf-page-2';
      final source = first['section']['blocks'][0]['Text']['source'];
      first['section']['blocks'] = [
        {
          'Image': {
            'href': 'missing.png',
            'alt': '',
            'style': {},
            'source': source,
            'ocr_text': {
              'text': '${'Long image transcript. ' * 120}uniqueneedle',
              'literal': false,
            },
          },
        },
      ];
      final zip = Archive();
      for (final entry in {
        'manifest.json': manifest,
        'sections/0.json': first,
        'sections/1.json': second,
      }.entries) {
        final bytes = utf8.encode(jsonEncode(entry.value));
        zip.add(ArchiveFile(entry.key, bytes.length, bytes));
      }
      await File(
        '${derived.path}/native-pdf.zip',
      ).writeAsBytes(ZipEncoder().encode(zip));
      SharedPreferences.setMockInitialValues({});
      final controller = ReaderController(
        publicationIdHint: 'book',
        progressStore: ProgressStore(await SharedPreferences.getInstance()),
      );
      addTearDown(controller.dispose);
      await controller.open(
        file,
        const LayoutViewport(width: 240, height: 320),
        const ReaderStyle(),
      );
      final batches = await controller
              .searchReadingText('uniqueneedle')
              .toList(),
          match = batches.expand((b) => b.$1).single;
      expect(match.range.start.textOffset, 0);
      expect(match.range.end.textOffset, 0);
      expect(await controller.goToSearchMatch(match), isTrue);
      expect(controller.pageIndex, greaterThan(2));
      expect(controller.readingAnchor!.spine.value, 'pdf-native-v14-0');
      expect(controller.readingAnchor!.textOffset, 0);
    },
  );
  test(
    'joined native chunks restore repeated node IDs and switch to the correct original page',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'torto-reader-native-',
      );
      addTearDown(() => root.delete(recursive: true));
      final books = await Directory('${root.path}/books').create();
      final pdf = await File(
        '${books.path}/book.pdf',
      ).writeAsBytes(buildFixturePdf());
      final derived = await Directory(
        '${root.path}/derived-sync-v1/book',
      ).create(recursive: true);
      final manifest = fixtureManifest();
      manifest['page_targets'] = [
        'Text/native-0.xhtml#pdf-page-1',
        'Text/native-1.xhtml#pdf-page-2',
      ];
      final second = fixtureSection(1, 'The second physical page.');
      final secondAnchors = second['section']['anchors'] as List;
      secondAnchors.removeLast();
      secondAnchors.first['fragment'] = 'pdf-page-2';
      final firstSection = fixtureSection(0, 'The first physical page.');
      (firstSection['section']['anchors'] as List).removeLast();
      final archive = Archive();
      final files = {
        'manifest.json': manifest,
        'sections/0.json': firstSection,
        'sections/1.json': second,
      };
      for (final entry in files.entries) {
        final bytes = utf8.encode(jsonEncode(entry.value));
        archive.add(ArchiveFile(entry.key, bytes.length, bytes));
      }
      await File(
        '${derived.path}/native-pdf.zip',
      ).writeAsBytes(ZipEncoder().encode(archive));
      final ocr = Archive();
      final ocrBytes = utf8.encode(
        jsonEncode(
          document(['# First\nOCR page one.', '# Second\nOCR page two.']),
        ),
      );
      ocr.add(ArchiveFile('document.json', ocrBytes.length, ocrBytes));
      await File(
        '${derived.path}/ocr.zip',
      ).writeAsBytes(ZipEncoder().encode(ocr));
      SharedPreferences.setMockInitialValues({});
      final progress = ProgressStore(await SharedPreferences.getInstance());
      Future<ReaderController> open() async {
        final controller = ReaderController(
          progressStore: progress,
          publicationIdHint: 'book',
        );
        await controller.open(
          pdf,
          const LayoutViewport(width: 360, height: 640),
          const ReaderStyle(focusMode: true),
        );
        return controller;
      }

      final first = await open();
      expect(first.pdfReflowEnabled, isTrue);
      expect(first.sectionCount, 1);
      await first.goToHref('Text/native-0.xhtml#pdf-page-2');
      expect(first.readingAnchor?.spine.value, 'pdf-native-v14-1');
      await first.flushProgress();
      first.dispose();
      final reopened = await open();
      expect(reopened.readingAnchor?.spine.value, 'pdf-native-v14-1');
      expect(await reopened.availablePdfTextSources(), ['ocr', 'native']);
      await reopened.togglePdfReflow();
      expect(reopened.pdfReflowEnabled, isFalse);
      expect(reopened.sectionIndex, 1);
      expect(await reopened.preferPdfTextSource('ocr'), isTrue);
      expect(reopened.preferredPdfTextSource, 'ocr');
      reopened.dispose();
      final ocrReader = await open();
      expect(ocrReader.pdfTextSource, 'ocr');
      expect(ocrReader.pdfReflowEnabled, isTrue);
      expect(await ocrReader.preferPdfTextSource('native'), isTrue);
      expect(ocrReader.sectionIndex, 1);
      ocrReader.dispose();
      final nativeAgain = await open();
      addTearDown(nativeAgain.dispose);
      expect(nativeAgain.pdfTextSource, 'native');
      expect(nativeAgain.readingAnchor?.spine.value, 'pdf-native-v14-1');
    },
  );
}
