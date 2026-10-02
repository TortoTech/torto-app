import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:torto/app/progress_store.dart';
import 'package:torto/app/reader/reader_controller.dart';
import 'package:torto/core/layout/layout_types.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'focus progress persists active blocks and long-block positions across reflow and reopen',
    () async {
      SharedPreferences.setMockInitialValues({});
      final dir = await Directory.systemTemp.createTemp('torto-focus-');
      addTearDown(() => dir.delete(recursive: true));
      final archive = Archive();
      void add(String name, String value) {
        final bytes = utf8.encode(value);
        archive.addFile(ArchiveFile(name, bytes.length, bytes));
      }

      add('mimetype', 'application/epub+zip');
      add(
        'META-INF/container.xml',
        '<container><rootfiles><rootfile full-path="book.opf"/></rootfiles></container>',
      );
      add(
        'book.opf',
        '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">focus-test</dc:identifier><dc:title>Focus</dc:title><dc:language>en</dc:language></metadata><manifest><item id="a" href="a.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="a"/></spine></package>',
      );
      add(
        'a.xhtml',
        '<html><body><h1>Heading</h1><p>First short paragraph.</p><p>Second short paragraph.</p><p>${'Long text to read. ' * 250}</p><p>Last paragraph.</p></body></html>',
      );
      final file = await File(
        '${dir.path}/book.epub',
      ).writeAsBytes(ZipEncoder().encode(archive));
      final store = ProgressStore(await SharedPreferences.getInstance());
      final controller = ReaderController(progressStore: store);
      addTearDown(controller.dispose);
      const viewport = LayoutViewport(width: 411, height: 700);
      const style = ReaderStyle(focusMode: true);
      await controller.open(file, viewport, style);
      expect(controller.currentPages, hasLength(1));
      expect(controller.currentPage!.focusUnits.length, 4);
      controller.activateFocusUnit(1);
      final shortAnchor = controller.readingAnchor!;
      await controller.updateStyle(style.copyWith(baseFontSize: 22));
      expect(controller.readingAnchor!.node, shortAnchor.node);
      await controller.updateStyle(style.copyWith(focusMode: false));
      expect(controller.currentPage!.focusUnits, isEmpty);
      await controller.updateStyle(style);
      expect(controller.readingAnchor!.node, shortAnchor.node);
      await controller.goToTextRange(
        controller.currentPages.first.focusUnits[1].sources.first,
      );
      expect(controller.readingAnchor!.node, shortAnchor.node);
      expect(controller.currentPage!.scrollExtent, greaterThan(0));
      controller.scrollFocus(controller.currentPage!.scrollExtent / 2);
      final anchor = controller.readingAnchor!;
      await controller.updateStyle(style.copyWith(sentenceSplit: true));
      expect(controller.readingAnchor!.node, anchor.node);
      expect(
        controller.readingAnchor!.textOffset,
        closeTo(anchor.textOffset, 80),
      );
      expect(controller.currentPage!.focusUnits, hasLength(4));
      await controller.updateStyle(style.copyWith(baseFontSize: 23));
      expect(controller.readingAnchor!.node, anchor.node);
      expect(
        controller.readingAnchor!.textOffset,
        closeTo(anchor.textOffset, 80),
      );
      await controller.updateViewport(
        const LayoutViewport(width: 700, height: 411),
      );
      expect(controller.currentPage!.viewport.width, 700);
      expect(controller.readingAnchor!.node, anchor.node);
      expect(
        controller.readingAnchor!.textOffset,
        closeTo(anchor.textOffset, 100),
      );
      await controller.flushProgress();
      final saved = await store.load(controller.statisticsBookId);
      expect(saved!.source!.start.node, anchor.node);
      expect(saved.source!.start.textOffset, greaterThan(0));
      final restored = ReaderController(progressStore: store);
      addTearDown(restored.dispose);
      await restored.open(file, viewport, style.copyWith(baseFontSize: 23));
      expect(restored.readingAnchor!.node, anchor.node);
      expect(
        restored.readingAnchor!.textOffset,
        closeTo(saved.source!.start.textOffset, 80),
      );
      expect(restored.focusReading.offset, greaterThan(0));
    },
  );
}
