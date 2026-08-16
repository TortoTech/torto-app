import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:torto/app/progress_store.dart';
import 'package:torto/app/reader/reader_controller.dart';
import 'package:torto/app/reader/toc_drawer.dart';
import 'package:torto/app/reader/toc_items.dart';
import 'package:torto/core/ir/ir.dart';
import 'package:torto/core/layout/layout_types.dart';

TocEntry _entry(
  String label,
  int? spine, [
  List<TocEntry> children = const [],
]) => TocEntry(
  label: label,
  href: spine == null ? '' : 'text/s$spine.xhtml',
  spineIndex: spine,
  children: children,
);

void main() {
  group('flattenToc', () {
    test('flattens nested entries with path ids and ancestry', () {
      final items = flattenToc([
        _entry('Part 1', 0, [
          _entry('Ch 1', 1),
          _entry('Ch 2', 2, [_entry('§1', 3)]),
        ]),
        _entry('Part 2', 10),
      ]);

      expect(items.map((i) => i.id), ['0', '0/0', '0/1', '0/1/0', '1']);
      expect(items.map((i) => i.depth), [0, 1, 1, 2, 0]);
      expect(items.map((i) => i.hasChildren), [
        true,
        false,
        true,
        false,
        false,
      ]);
      expect(items[3].ancestors, ['0', '0/1']);
      expect(items[1].ancestors, ['0']);
      expect(items[0].ancestors, isEmpty);
      expect(items.map((i) => i.spineIndex), [0, 1, 2, 3, 10]);
    });

    test('empty toc yields no items', () {
      expect(flattenToc(const []), isEmpty);
    });
  });

  group('visibleTocItems', () {
    final items = flattenToc([
      _entry('Part 1', 0, [_entry('Ch 1', 1)]),
      _entry('Part 2', 10),
    ]);

    test('roots always visible; children need expanded ancestors', () {
      expect(visibleTocItems(items, {}).map((i) => i.id), ['0', '1']);
      expect(visibleTocItems(items, {'0'}).map((i) => i.id), ['0', '0/0', '1']);
    });
  });

  group('activeTocId', () {
    test('last entry at or before the current section wins', () {
      final items = flattenToc([
        _entry('Front', 0),
        _entry('Ch 1', 2),
        _entry('Ch 2', 5),
      ]);
      expect(activeTocId(items, 0), '0');
      expect(activeTocId(items, 1), '0');
      expect(activeTocId(items, 2), '1');
      expect(activeTocId(items, 4), '1');
      expect(activeTocId(items, 99), '2');
    });

    test('grouping nodes without a target are never active', () {
      final items = flattenToc([
        _entry('Group', null, [_entry('Ch 1', 3)]),
      ]);
      expect(activeTocId(items, 2), isNull);
      expect(activeTocId(items, 3), '0/0');
    });

    test('before the first entry: null', () {
      final items = flattenToc([_entry('Ch 1', 4)]);
      expect(activeTocId(items, 2), isNull);
    });
  });

  testWidgets('TocDrawer reveals a newly active nested row', (tester) async {
    final items = flattenToc([
      _entry('Part', 0, [_entry('Chapter', 1)]),
    ]);

    Widget drawer(String activeId) => MaterialApp(
      home: TocDrawer(items: items, activeId: activeId, onNavigate: (_) {}),
    );

    await tester.pumpWidget(drawer('0'));
    expect(find.text('Chapter'), findsNothing);

    await tester.pumpWidget(drawer('0/0'));
    await tester.pump();
    expect(find.text('Chapter'), findsOneWidget);
  });

  group('ReaderController.goToSection', () {
    test('jumps to the first page of the target section', () async {
      final file = File(
        '../torto/test-data/Structured Writing Rhetoric and Process.epub',
      );
      if (!file.existsSync()) {
        // ignore: avoid_print
        print('SKIP: ${file.path} not found');
        return;
      }
      SharedPreferences.setMockInitialValues({});
      final controller = ReaderController(
        progressStore: ProgressStore(await SharedPreferences.getInstance()),
      );
      addTearDown(controller.dispose);

      const viewport = LayoutViewport(width: 411, height: 914);
      await controller.open(file, viewport, const ReaderStyle());
      expect(controller.opened, isTrue);

      final target = controller.sectionCount > 3 ? 3 : 1;
      await controller.goToSection(target);
      expect(controller.sectionIndex, target);
      expect(controller.pageIndex, 0);
      expect(controller.currentPage, isNotNull);

      // Same-section jump is a no-op that stays on page 0.
      await controller.goToSection(target);
      expect(controller.sectionIndex, target);
      expect(controller.pageIndex, 0);

      // TOC data is exposed for the drawer.
      expect(controller.toc, isNotEmpty);
    }, timeout: const Timeout(Duration(minutes: 5)));
  });
}
