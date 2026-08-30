import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:torto/app/library/library_page.dart';
import 'package:torto/app/library/library_store.dart';
import 'package:torto/app/progress_store.dart';
import 'package:torto/core/ir/ir.dart';

void main() {
  test('ProgressStore round-trips a locator with a source anchor', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = ProgressStore(prefs);

    const anchor = SourceAnchor(spine: 3, node: 'n7', textOffset: 42);
    const locator = LocatorV1(
      publicationId: 'pub-1',
      href: 'OEBPS/ch3.xhtml',
      position: 3,
      progression: 0.5,
      totalProgression: 0.25,
      source: SourceRange(start: anchor, end: anchor),
    );

    await store.save(locator, activityTimeMs: 100);
    final loaded = await store.load('pub-1');

    expect(loaded, isNotNull);
    expect(loaded!.publicationId, 'pub-1');
    expect(loaded.href, 'OEBPS/ch3.xhtml');
    expect(loaded.position, 3);
    expect(loaded.progression, 0.5);
    expect(loaded.totalProgression, 0.25);
    expect(loaded.source, isNotNull);
    expect(loaded.source!.start, anchor);
    expect(loaded.source!.end, anchor);

    expect(await store.load('no-such-book'), isNull);
    expect(await store.activityTimes(), {'pub-1': 100});
    await store.markActivity('pub-1', activityTimeMs: 50);
    expect(await store.activityTimes(), {'pub-1': 100});
    await store.markActivity('pub-1', activityTimeMs: 200);
    expect(await store.activityTimes(), {'pub-1': 200});
  });

  testWidgets('LibraryPage renders the empty state', (tester) async {
    // A directory that never exists → empty library, no temp dirs needed.
    final store = LibraryStore(
      booksDir: Directory('test/__no_such_books_dir__'),
    );
    SharedPreferences.setMockInitialValues({});
    final progressStore = ProgressStore(await SharedPreferences.getInstance());
    await tester.pumpWidget(
      MaterialApp(
        home: LibraryPage(store: store, progressStore: progressStore),
      ),
    );
    // Let the real async directory check complete, then rebuild.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();

    expect(find.textContaining('书架还是空的'), findsOneWidget);
    expect(find.byTooltip('导入书籍'), findsOneWidget);
  });
}
