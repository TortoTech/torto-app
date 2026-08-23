import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:torto/app/reader/reader_controller.dart';
import 'package:torto/app/reader/reader_page.dart';
import 'package:torto/app/reader/reader_preferences_store.dart';
import 'package:torto/core/layout/layout_types.dart';
import 'package:torto/core/render/page_painter.dart';

class _FakeReaderController extends ReaderController {
  static const _viewport = LayoutViewport(width: 411, height: 914);
  final bool neighbourPreviewReady;
  final List<PageLayout> _pages = List.generate(
    5,
    (index) => PageLayout(
      viewport: _viewport,
      items: const [],
      firstAnchor: null,
      progression: index / 4,
    ),
  );

  _FakeReaderController({this.neighbourPreviewReady = true}) {
    opened = true;
    title = 'Gesture test';
    sectionIndex = 0;
    pageIndex = 1;
  }

  @override
  int get sectionCount => 1;

  @override
  List<PageLayout> get currentPages => _pages;

  @override
  PageLayout? get currentPage => _pages[pageIndex];

  @override
  double get totalProgression => pageIndex / (_pages.length - 1);

  @override
  PageLayout? peekPage(int pageOffset) {
    final target = pageIndex + pageOffset;
    if (pageOffset != 0 && !neighbourPreviewReady) return null;
    return target >= 0 && target < _pages.length ? _pages[target] : null;
  }

  @override
  bool canPeek(int pageOffset) {
    final target = pageIndex + pageOffset;
    return target >= 0 && target < _pages.length;
  }

  @override
  Future<void> ensurePeek() async {}

  @override
  Future<void> nextPage() async {
    if (pageIndex + 1 >= _pages.length) return;
    pageIndex++;
    notifyListeners();
  }

  @override
  Future<void> prevPage() async {
    if (pageIndex == 0) return;
    pageIndex--;
    notifyListeners();
  }

  @override
  ui.Image? resolveImage(String href) => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('rapid page turns settle deterministically', (tester) async {
    final controller = _FakeReaderController();
    await tester.binding.setSurfaceSize(const Size(411, 914));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(
      MaterialApp(
        home: ReaderPage(file: File('unused.epub'), controller: controller),
      ),
    );
    await tester.pump();
    expect(controller.opened, isTrue);
    await controller.ensurePeek();
    await tester.pump();

    final forward = await tester.startGesture(const Offset(340, 450));
    await forward.moveBy(const Offset(-40, 0));
    await tester.pump();
    await forward.moveBy(const Offset(-140, 0));
    await tester.pump();
    expect(find.byType(PageWidget), findsNWidgets(2));
    await forward.up();

    // A second swipe during the first commit animation completes that stable
    // endpoint and immediately controls the following page; it must not be
    // dropped or strand the intermediate frame.
    await tester.pump(const Duration(milliseconds: 40));
    final rapidForward = await tester.startGesture(const Offset(340, 450));
    await rapidForward.moveBy(const Offset(-40, 0));
    await tester.pump();
    await rapidForward.moveBy(const Offset(-140, 0));
    await rapidForward.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 180));

    final afterForward = (controller.sectionIndex, controller.pageIndex);
    expect(afterForward, (0, 3));
    expect(find.byType(PageWidget), findsOneWidget);

    // A short drag must settle back to the same page.
    final shortDrag = await tester.startGesture(const Offset(340, 450));
    await shortDrag.moveBy(const Offset(-25, 0));
    await tester.pump();
    await shortDrag.moveBy(const Offset(-20, 0));
    await shortDrag.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    expect((controller.sectionIndex, controller.pageIndex), afterForward);
    expect(find.byType(PageWidget), findsOneWidget);

    // Backward uses the inverse committed transition.
    final backward = await tester.startGesture(const Offset(180, 450));
    await backward.moveBy(const Offset(40, 0));
    await tester.pump();
    await backward.moveBy(const Offset(120, 0));
    await tester.pump();
    expect(find.byType(PageWidget), findsNWidgets(2));
    await backward.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 240));
    expect((controller.sectionIndex, controller.pageIndex), (0, 2));
    expect(find.byType(PageWidget), findsOneWidget);
  }, timeout: const Timeout(Duration(minutes: 5)));

  testWidgets('logical neighbour commits before its preview is ready', (
    tester,
  ) async {
    final controller = _FakeReaderController(neighbourPreviewReady: false);
    await tester.binding.setSurfaceSize(const Size(411, 914));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(
      MaterialApp(
        home: ReaderPage(file: File('unused.epub'), controller: controller),
      ),
    );
    await tester.pump();

    final forward = await tester.startGesture(const Offset(340, 450));
    await forward.moveBy(const Offset(-40, 0));
    await tester.pump();
    await forward.moveBy(const Offset(-140, 0));
    await forward.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 180));

    expect((controller.sectionIndex, controller.pageIndex), (0, 2));
    expect(find.byType(PageWidget), findsOneWidget);
  });

  testWidgets('reader overlay exposes contents and persistent layout mode', (
    tester,
  ) async {
    final controller = _FakeReaderController();
    SharedPreferences.setMockInitialValues({});
    final preferences = ReaderPreferencesStore(
      await SharedPreferences.getInstance(),
    );
    await tester.binding.setSurfaceSize(const Size(411, 914));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                key: const Key('open-reader'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ReaderPage(
                      file: File('unused.epub'),
                      controller: controller,
                      preferencesStore: preferences,
                    ),
                  ),
                ),
                child: const Text('Open reader'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('open-reader')));
    await tester.pumpAndSettle();

    await tester.tapAt(const Offset(205, 450));
    await tester.pump();

    final back = find.byKey(const Key('reader-back-button'));
    final contents = find.byKey(const Key('reader-toc-button'));
    final style = find.byKey(const Key('reader-style-button'));
    final header = find.byKey(const Key('reader-header'));
    final footer = find.byKey(const Key('reader-footer'));
    expect(back, findsOneWidget);
    expect(contents, findsOneWidget);
    expect(style, findsOneWidget);
    expect(find.text('目录'), findsNothing);
    expect(find.text('Gesture test'), findsNothing);
    expect(find.textContaining('section'), findsNothing);
    expect(tester.getTopLeft(header), Offset.zero);
    expect(tester.getSize(header).width, 411);
    expect(tester.getBottomRight(footer), const Offset(411, 914));
    expect(tester.getSize(footer).width, 411);
    expect(tester.getCenter(back).dy, lessThan(100));
    expect(tester.getCenter(contents).dy, greaterThan(800));
    expect(tester.getCenter(contents).dx, lessThan(100));

    await tester.tap(style);
    await tester.pumpAndSettle();
    expect(find.text('统一版式'), findsOneWidget);
    expect(find.text('跟随书籍'), findsOneWidget);
    await tester.tap(find.byKey(const Key('typesetting-book')));
    await tester.pumpAndSettle();
    expect(await preferences.loadTypesettingMode(), TypesettingMode.book);

    // Reopen the overlay after the sheet dismissed it.
    await tester.tapAt(const Offset(205, 450));
    await tester.pump();

    // A page-turn gesture dismisses both bars immediately.
    await tester.tapAt(const Offset(350, 450));
    await tester.pump();
    expect(header, findsNothing);
    expect(footer, findsNothing);
    expect(controller.pageIndex, 2);

    await tester.tapAt(const Offset(205, 450));
    await tester.pump();
    expect(header, findsOneWidget);
    expect(footer, findsOneWidget);

    await tester.tap(contents);
    await tester.pumpAndSettle();
    expect(find.text('No table of contents'), findsOneWidget);
    Navigator.of(tester.element(find.text('No table of contents'))).pop();
    await tester.pumpAndSettle();

    await tester.tap(back);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('open-reader')), findsOneWidget);
  });
}
