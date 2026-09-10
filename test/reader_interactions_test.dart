import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'dart:async';
import 'dart:isolate';
import 'package:archive/archive.dart';
import 'package:torto/app/reader/book_search_page.dart';
import 'package:flutter/material.dart' hide TextStyle;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:torto/app/reader/annotations_repository.dart';
import 'package:torto/app/sync/sync_store.dart';
import 'package:torto/core/layout/layout_engine.dart';
import 'package:torto/core/layout/layout_types.dart';
import 'package:torto/core/layout/source_offset_map.dart';
import 'package:torto/core/render/page_painter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torto/core/formats/epub_book_source.dart';
import 'package:torto/core/formats/toc_heading_promoter.dart';
import 'package:torto/core/ir/ir.dart';
import 'package:torto/core/ir/text_index.dart';
import 'package:torto/app/reader/text_selection_layer.dart';
import 'package:torto/core/html_ir/html_ir_parser.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('mixed font selection boxes have one top and bottom per line', () {
    final builder = ui.ParagraphBuilder(
      ui.ParagraphStyle(textDirection: ui.TextDirection.ltr),
    );
    builder.pushStyle(ui.TextStyle(fontSize: 18));
    builder.addText('中文 ');
    builder.pop();
    builder.pushStyle(ui.TextStyle(fontSize: 28));
    builder.addText('Latin');
    builder.pop();
    final paragraph = builder.build()
      ..layout(const ui.ParagraphConstraints(width: 360));
    addTearDown(paragraph.dispose);
    final boxes = selectionLineBoxes(paragraph, 0, 8);
    expect(boxes.length, greaterThan(1));
    expect(boxes.map((b) => b.top).toSet(), hasLength(1));
    expect(boxes.map((b) => b.bottom).toSet(), hasLength(1));
  });
  test(
    'background search returns literal case-insensitive matches and source ranges',
    () async {
      final archive = Archive();
      archive.addFile(
        ArchiveFile.string(
          'META-INF/container.xml',
          '<container><rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles></container>',
        ),
      );
      archive.addFile(
        ArchiveFile.string(
          'OPS/book.opf',
          '<package xmlns="http://www.idpf.org/2007/opf" version="3.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
              '<dc:title>Search fixture</dc:title></metadata><manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>'
              '</manifest><spine><itemref idref="chapter"/></spine></package>',
        ),
      );
      archive.addFile(
        ArchiveFile.string(
          'OPS/chapter.xhtml',
          await File('test/fixtures/semantic-parity.xhtml').readAsString(),
        ),
      );
      final directory = await Directory.systemTemp.createTemp(
        'torto-search-test',
      );
      final file = File('${directory.path}/book.epub');
      await file.writeAsBytes(ZipEncoder().encode(archive));
      addTearDown(() async {
        await file.delete();
        await directory.delete();
      });
      final port = ReceivePort();
      final complete = Completer<void>();
      final matches = <TextMatch>[];
      port.listen((message) {
        if (message case (List<TextMatch> batch, double _)) {
          matches.addAll(batch);
        }
        if (message == 'done') complete.complete();
        if (message is Map) complete.completeError(message);
      });
      addTearDown(port.close);
      await searchWorker((file.path, 'QUOTE', port.sendPort));
      await complete.future.timeout(const Duration(seconds: 15));
      expect(matches, hasLength(2));
      expect(matches.map((m) => m.range.start.node), ['n5', 'n6']);
      expect(matches.every((m) => m.text == 'Quote'), isTrue);
    },
  );
  test(
    'split TOC headings and marked zero-margin epigraph match desktop semantics',
    () {
      final section = const HtmlIrParser().parse(
        spineIndex: 0,
        href: 'chapter.xhtml',
        basePath: '',
        xhtml: '<html><body><p>Chapter One</p><p>A Title</p></body></html>',
      );
      final promoted = promoteTocHeadings(section, const [
        TocHeadingHint(label: 'Chapter One: A Title', fragment: null, level: 1),
      ]);
      expect((promoted.blocks.first as TextBlock).headingOrdinal, isTrue);
      expect((promoted.blocks[1] as TextBlock).kind, TextBlockKind.heading);
      final quote = const HtmlIrParser().parse(
        spineIndex: 0,
        href: 'chapter.xhtml',
        basePath: '',
        xhtml:
            '<html><body><p style="margin:0 1.5em;font-size:90%">An epigraph.</p>'
            '<p style="margin:.5em 1.5em 2em;text-align:right"><i>—Author</i></p></body></html>',
      );
      expect(quote.blocks.single, isA<QuoteBlock>());
      expect(
        (quote.blocks.single as QuoteBlock).attribution!.plainText,
        '—Author',
      );
    },
  );
  test('semantic node contract matches the desktop parser snapshot', () async {
    final section = const HtmlIrParser().parse(
      spineIndex: 0,
      href: 'chapter.xhtml',
      basePath: '',
      xhtml: await File('test/fixtures/semantic-parity.xhtml').readAsString(),
    );
    final expected = await File(
      'test/fixtures/semantic-parity.tsv',
    ).readAsLines();
    final reference = <String, String>{};
    for (final line in expected) {
      final cols = line.split('\t');
      reference[cols[2]] = utf8.decode([
        for (var i = 0; i < cols[3].length; i += 2)
          int.parse(cols[3].substring(i, i + 2), radix: 16),
      ]);
    }
    final actual = {
      for (final node in sectionTextNodes(section, includeNotes: true))
        node.source.start.node: node.text,
    };
    expect(actual, reference);
  });
  test(
    'annotation edits keep identity and increment causal clocks; deletion is a tombstone',
    () async {
      sqfliteFfiInit();
      final store = await SyncStore.openAt(
        inMemoryDatabasePath,
        'phone',
        factory: databaseFactoryFfi,
      );
      addTearDown(store.close);
      final repository = AnnotationsRepository(store);
      final range = SourceRange.fromJson({
        'start': {'spine': 'chapter', 'node': 'n1', 'text_offset': 0},
        'end': {'spine': 'chapter', 'node': 'n1', 'text_offset': 5},
      });
      await repository.save(book: 'book', ranges: [range], quote: 'Hello');
      final first = (await repository.list('book')).single;
      await repository.save(
        book: 'book',
        ranges: [range],
        quote: 'Hello',
        note: 'My note',
        previous: first,
      );
      final edited = (await repository.list('book')).single;
      expect(edited.id, first.id);
      expect(edited.note, 'My note');
      expect(edited.clock['phone'], first.clock['phone']! + 1);
      await repository.save(
        book: 'book',
        ranges: [range],
        quote: 'Hello',
        previous: edited,
        delete: true,
      );
      expect(await repository.list('book'), isEmpty);
      expect(
        (await store.annotationsForDeviceBook('book')).single.deleted,
        isTrue,
      );
    },
  );
  testWidgets(
    'long press selects retained text and emits a source-backed highlight',
    (tester) async {
      final section = const HtmlIrParser().parse(
        spineIndex: 0,
        href: 's.xhtml',
        basePath: '',
        xhtml: '<html><body><p>Hello 😀 world.</p></body></html>',
      );
      final pages = const LayoutEngine().paginate(
        section,
        const LayoutViewport(width: 360, height: 640),
        const ReaderStyle(),
      );
      final placement = pages.first.items.whereType<TextPlacement>().first;
      final box = placement.paragraph
          .getBoxesForRange(
            placement.syntheticPrefixLength,
            placement.syntheticPrefixLength + 1,
          )
          .first
          .toRect();
      ReaderSelection? saved;
      await tester.binding.setSurfaceSize(const Size(360, 640));
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        for (final page in pages) {
          page.dispose();
        }
        await tester.binding.setSurfaceSize(null);
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReaderSelectionLayer(
              page: pages.first,
              nodes: sectionTextNodes(section).toList(),
              mode: ReaderSelectionMode.paragraph,
              onSelecting: (_) {},
              onSave: (selection, note) => saved = selection,
              onMarkTap: (_) {},
              child: PageWidget(
                page: pages.first,
                background: Colors.white,
                foreground: Colors.black,
              ),
            ),
          ),
        ),
      );
      await tester.longPressAt(
        box.center + Offset(placement.x, placement.y - placement.sliceTop),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byKey(const Key('selection-toolbar'))).width,
        200,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('selection-toolbar')),
          matching: find.byType(TextButton),
        ),
        findsNothing,
      );
      await tester.tap(find.byTooltip('高亮'));
      expect(saved!.quote, 'Hello 😀 world.');
      expect(saved!.ranges.single.start.textOffset, 0);
      expect(
        saved!.ranges.single.end.textOffset,
        'Hello 😀 world.'.runes.length,
      );
      expect(tester.takeException(), isNull);
    },
  );
  test('canonical offsets preserve emoji and reject split surrogate pairs', () {
    const text = 'A😀字e\u0301';
    expect(utf16ToScalar(text, 3), 2);
    expect(scalarToUtf16(text, 2), 3);
    expect(() => utf16ToScalar(text, 2), throwsFormatException);
    final unit = selectionUnit(text, 4, ReaderSelectionMode.free);
    expect(sourceSlice(text, unit.$1, unit.$2), 'e\u0301');
    final word = selectionUnit('hello world', 8, ReaderSelectionMode.word);
    expect(word, (6, 11));
  });
  test(
    'desktop allocations reserve empty paragraphs and table before its cells',
    () {
      final section = const HtmlIrParser().parse(
        spineIndex: 0,
        basePath: '',
        href: 's.xhtml',
        xhtml:
            '<html><body><p></p><p>First</p><table><tr><td>Cell</td></tr></table><p>Last</p></body></html>',
      );
      final nodes = sectionTextNodes(section).toList();
      expect(nodes.map((n) => n.source.start.node), ['n1', 'n3', 'n4']);
    },
  );
  test(
    'desktop symbolic separators preserve text but exclude prose contexts',
    () {
      final section = const HtmlIrParser().parse(
        spineIndex: 0,
        basePath: '',
        href: 's.xhtml',
        xhtml:
            '<html><body><p>***</p><p>…</p><p><a href="#n">***</a></p></body></html>',
      );
      expect(section.blocks.first, isA<SeparatorBlock>());
      expect((section.blocks.first as SeparatorBlock).text!.plainText, '***');
      expect(section.blocks.whereType<TextBlock>(), hasLength(2));
    },
  );
  const bookPath = String.fromEnvironment('PARITY_BOOK');
  const desktopPath = String.fromEnvironment('PARITY_DESKTOP');
  test(
    'desktop and Dart normalize identical source nodes in a real EPUB',
    () async {
      final source = await EpubBookSource.fromBytes(
        await File(bookPath).readAsBytes(),
      );
      final desktop = await File(desktopPath).readAsLines();
      final reference = <String, String>{};
      for (final line in desktop) {
        final cols = line.split('\t');
        if (cols.length < 4) continue;
        expect(source.book.spine[int.parse(cols[0])].id.value, cols[1]);
        final hex = cols[3];
        final text = utf8.decode([
          for (var i = 0; i < hex.length; i += 2)
            int.parse(hex.substring(i, i + 2), radix: 16),
        ]);
        reference['${cols[0]}:${cols[2]}'] = text;
      }
      final mismatches = <String>[];
      var total = 0;
      for (var i = 0; i < source.book.spine.length; i++) {
        final section = await source.parseSection(i);
        for (final node in sectionTextNodes(section, includeNotes: true)) {
          if (!node.selectable || node.text.isEmpty) continue;
          expect(node.source.start.spine, section.id);
          expect(node.source.end.textOffset, node.text.runes.length);
          total++;
          final key = '$i:${node.source.start.node}';
          if (reference[key] != node.text) {
            mismatches.add(
              '$key Dart=${node.text.substring(0, node.text.length.clamp(0, 70))} Desktop=${reference[key]?.substring(0, reference[key]!.length.clamp(0, 70))}',
            );
          }
        }
      }
      // ignore: avoid_print
      print(
        'Parity nodes=$total mismatches=${mismatches.length}\n${mismatches.take(15).join('\n')}',
      );
      expect(mismatches, isEmpty);
    },
    skip: bookPath.isEmpty || desktopPath.isEmpty,
  );
}
