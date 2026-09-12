import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:torto/app/library/library_store.dart';
import 'package:torto/app/progress_store.dart';
import 'package:torto/app/reader/reader_controller.dart';
import 'package:torto/app/reader/reader_session_cache.dart';
import 'package:torto/core/ir/ir.dart';
import 'package:torto/core/layout/layout_types.dart';

class _TrackedReader extends ReaderController {
  int disposals = 0;
  bool reusable = true;
  @override
  bool get canReuseSession => reusable;
  @override
  void dispose() {
    disposals++;
    super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  LibraryBook book(String id) =>
      LibraryBook(id: id, file: File('$id.epub'), title: id, sizeBytes: 100);
  test(
    'session cache retains one reader and invalidates changed display or book',
    () {
      final cache = ReaderSessionCache();
      final first = _TrackedReader();
      cache.keep(book('a'), first, displayKey: 'portrait');
      expect(
        identical(cache.take(book('a'), displayKey: 'portrait'), first),
        isTrue,
      );
      expect(first.disposals, 0);
      cache.keep(book('a'), first, displayKey: 'portrait');
      expect(cache.take(book('a'), displayKey: 'landscape'), isNull);
      expect(first.disposals, 1);
      final second = _TrackedReader();
      cache.keep(book('b'), second);
      expect(cache.take(book('c')), isNull);
      expect(second.disposals, 1);
      final third = _TrackedReader();
      cache.keep(book('c'), third);
      cache.invalidate('c');
      cache.clear();
      expect(third.disposals, 1);
      final unsafe = _TrackedReader()..reusable = false;
      cache.keep(book('a'), unsafe);
      expect(unsafe.disposals, 1);
      expect(cache.take(book('a')), isNull);
    },
  );

  Future<File> fixture(Directory directory) async {
    final archive = Archive();
    void add(String path, String text) {
      final bytes = utf8.encode(text);
      archive.addFile(ArchiveFile(path, bytes.length, bytes));
    }

    add(
      'META-INF/container.xml',
      '<container><rootfiles><rootfile full-path="book.opf"/></rootfiles></container>',
    );
    add(
      'book.opf',
      '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">warm-book</dc:identifier><dc:title>Warm book</dc:title></metadata><manifest><item id="a" href="a.xhtml" media-type="application/xhtml+xml"/><item id="b" href="b.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="a"/><itemref idref="b"/></spine></package>',
    );
    add(
      'a.xhtml',
      '<html><body>${List.generate(30, (i) => '<p>Paragraph $i with some readable text.</p>').join()}</body></html>',
    );
    add('b.xhtml', '<html><body><p>Another chapter.</p></body></html>');
    return File(
      '${directory.path}/book.epub',
    ).writeAsBytes(ZipEncoder().encode(archive));
  }

  test(
    'warm restore reuses pages and honors remote position without writing it back',
    () async {
      SharedPreferences.setMockInitialValues({});
      final directory = await Directory.systemTemp.createTemp(
        'torto-warm-reader-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = await fixture(directory);
      final prefs = await SharedPreferences.getInstance();
      final progress = ProgressStore(prefs);
      final reader = ReaderController(
        progressStore: progress,
        publicationIdHint: 'warm-book',
      );
      addTearDown(reader.dispose);
      await reader.open(
        file,
        const LayoutViewport(width: 360, height: 600),
        const ReaderStyle(),
      );
      await reader.nextPage();
      await reader.flushProgress();
      final page = reader.currentPage;
      expect(reader.canReuseSession, isTrue);
      reader.setReaderVisible(false);
      reader.setReaderVisible(true);
      await reader.restoreSavedPosition();
      expect(identical(reader.currentPage, page), isTrue);
      await progress.save(
        const LocatorV1(
          publicationId: 'warm-book',
          position: 1,
          href: 'b.xhtml',
          progression: 0,
        ),
      );
      final remote = prefs.getString('progress:warm-book');
      await reader.restoreSavedPosition();
      expect(reader.sectionIndex, 1);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(prefs.getString('progress:warm-book'), remote);
      reader.translationEnabled = true;
      expect(reader.canReuseSession, isFalse);
    },
  );

  test('closing while opening cannot resurrect a disposed reader', () async {
    SharedPreferences.setMockInitialValues({});
    final directory = await Directory.systemTemp.createTemp(
      'torto-cancel-open-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final reader = ReaderController(
      progressStore: ProgressStore(await SharedPreferences.getInstance()),
    );
    final file = await fixture(directory);
    final opening = reader.open(
      file,
      const LayoutViewport(width: 360, height: 600),
      const ReaderStyle(),
    );
    reader.dispose();
    await expectLater(opening, throwsStateError);
    expect(reader.opened, isFalse);
  });
}
