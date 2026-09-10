import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:torto/app/reader/reader_controller.dart';
import 'package:torto/app/reader/text_selection_layer.dart';
import 'package:torto/app/reader/reader_page.dart';
import 'package:torto/app/reader/reader_preferences_store.dart';
import 'package:torto/app/settings/app_preferences.dart';
import 'package:torto/core/ir/book.dart';
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
  testWidgets(
    'translation locks paragraph selection and restores the normal preference',
    (tester) async {
      SharedPreferences.setMockInitialValues({'reader_selection_mode': 'word'});
      final controller = _FakeReaderController()..translationEnabled = true;
      await tester.binding.setSurfaceSize(const Size(411, 914));
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
        await tester.binding.setSurfaceSize(null);
      });
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderPage(file: File('unused.epub'), controller: controller),
        ),
      );
      await tester.pumpAndSettle();
      final layer = tester.widget<ReaderSelectionLayer>(
        find.byType(ReaderSelectionLayer),
      );
      expect(layer.mode, ReaderSelectionMode.paragraph);
      expect(layer.canAnnotate, isTrue);
      expect(layer.wholeParagraphMarks, isTrue);
      await tester.tapAt(const Offset(205, 450));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<IconButton>(
              find.byKey(const Key('reader-selection-button')),
            )
            .onPressed,
        isNull,
      );
      controller.translationEnabled = false;
      controller.notifyListeners();
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ReaderSelectionLayer>(find.byType(ReaderSelectionLayer))
            .mode,
        ReaderSelectionMode.word,
      );
    },
  );
  testWidgets(
    'completion action belongs to the end screen after the last page',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final controller = _FakeReaderController()..pageIndex = 4;
      await tester.binding.setSurfaceSize(const Size(411, 914));
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
        await tester.binding.setSurfaceSize(null);
      });
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderPage(file: File('unused.epub'), controller: controller),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('book-end-finish-button')), findsNothing);
      await tester.tapAt(const Offset(350, 450));
      await tester.pumpAndSettle();
      expect(find.text('已到书籍结尾'), findsOneWidget);
      expect(find.byKey(const Key('book-end-finish-button')), findsOneWidget);
      await tester.tap(find.text('返回最后一页'));
      await tester.pumpAndSettle();
      expect(controller.pageIndex, 4);
      expect(find.byKey(const Key('book-end-finish-button')), findsNothing);
    },
  );

  testWidgets('reader restores the configured body font size', (tester) async {
    final controller = _FakeReaderController();
    SharedPreferences.setMockInitialValues({});
    final preferences = ReaderPreferencesStore(
      await SharedPreferences.getInstance(),
    );
    await preferences.saveTypography(const ReaderTypography(fontSize: 24));
    await controller.updateStyle(
      const ReaderStyle(
        writingSystem: WritingSystem.cjk,
        publicationLanguage: 'en-GB',
      ),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: ReaderPage(
          file: File('unused.epub'),
          controller: controller,
          preferencesStore: preferences,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(controller.style.baseFontSize, 24);
    expect(controller.style.typography.fontSize, 24);
    expect(controller.style.writingSystem, WritingSystem.cjk);
    expect(controller.style.publicationLanguage, 'en-GB');
  });

  testWidgets('reader first frame inherits the dark app theme', (tester) async {
    final controller = _FakeReaderController();
    SharedPreferences.setMockInitialValues({});
    final preferences = AppPreferencesController(
      preferences: await SharedPreferences.getInstance(),
    );
    await preferences.setTheme(AppThemePreference.dark);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      preferences.dispose();
    });

    await tester.pumpWidget(
      AppPreferencesScope(
        controller: preferences,
        child: MaterialApp(
          theme: ThemeData.dark(),
          home: ReaderPage(file: File('unused.epub'), controller: controller),
        ),
      ),
    );

    final scaffold = find.descendant(
      of: find.byType(ReaderPage),
      matching: find.byType(Scaffold),
    );
    expect(tester.widget<Scaffold>(scaffold).backgroundColor, Colors.black);
    final systemUi = tester.widget<AnnotatedRegion<SystemUiOverlayStyle>>(
      find.descendant(
        of: find.byType(ReaderPage),
        matching: find.byType(AnnotatedRegion<SystemUiOverlayStyle>),
      ),
    );
    expect(systemUi.value.statusBarIconBrightness, Brightness.light);
    expect(systemUi.value.systemNavigationBarIconBrightness, Brightness.light);
  });

  testWidgets('tap zones reserve the middle sixty percent for controls', (
    tester,
  ) async {
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

    await tester.tapAt(const Offset(83, 450));
    await tester.pump();
    expect(controller.pageIndex, 1);
    expect(find.byKey(const Key('reader-header')), findsOneWidget);

    await tester.tapAt(const Offset(82, 450));
    await tester.pump();
    expect(controller.pageIndex, 0);

    await tester.tapAt(const Offset(328, 450));
    await tester.pump();
    expect(controller.pageIndex, 0);
    expect(find.byKey(const Key('reader-header')), findsOneWidget);

    await tester.tapAt(const Offset(329, 450));
    await tester.pump();
    expect(controller.pageIndex, 1);
  });

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
    final theme = find.byKey(const Key('reader-theme-button'));
    final header = find.byKey(const Key('reader-header'));
    final footer = find.byKey(const Key('reader-footer'));
    expect(back, findsOneWidget);
    expect(contents, findsOneWidget);
    expect(style, findsOneWidget);
    expect(theme, findsOneWidget);
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
    expect(tester.getSize(contents), const Size(64, 56));
    expect(tester.getSize(style), const Size(64, 56));
    expect(tester.getSize(theme), const Size(64, 56));
    expect(tester.widget<IconButton>(contents).iconSize, 32);
    expect(tester.widget<IconButton>(style).iconSize, 32);
    expect(tester.widget<IconButton>(theme).iconSize, 32);
    expect(tester.widget<IconButton>(theme).tooltip, '深色模式');
    final orderedKeys = [
      'reader-toc-button',
      'reader-marks-button',
      'reader-translation-button',
      'reader-selection-button',
      'reader-style-button',
      'reader-theme-button',
    ];
    final positions = orderedKeys
        .map((key) => tester.getCenter(find.byKey(Key(key))).dx)
        .toList();
    expect(positions, orderedEquals(List<double>.of(positions)..sort()));
    expect(find.byTooltip('标记已读完'), findsNothing);

    await tester.tap(theme);
    await tester.pumpAndSettle();
    expect(await preferences.loadDarkMode(), isTrue);
    expect(
      tester.widget<PageWidget>(find.byType(PageWidget)).background,
      const Color(0xFF000000),
    );
    expect(
      tester.widget<PageWidget>(find.byType(PageWidget)).foreground,
      const Color(0xFF959595),
    );
    expect(tester.widget<Material>(header).color, const Color(0xFF1C1C1C));
    expect(tester.widget<Material>(footer).color, const Color(0xFF1C1C1C));
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('reader-theme-button')))
          .tooltip,
      '浅色模式',
    );

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
    expect(find.text('没有目录'), findsOneWidget);
    Navigator.of(tester.element(find.text('没有目录'))).pop();
    await tester.pumpAndSettle();

    await tester.tap(back);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('open-reader')), findsOneWidget);
  });
}
