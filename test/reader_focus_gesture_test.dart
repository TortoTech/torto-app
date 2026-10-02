import 'package:torto/app/reader/text_selection_layer.dart';
import 'package:torto/app/reader/focus_reading_state.dart';
import 'package:torto/app/reader/focus_navigation.dart';
import 'package:torto/core/ir/text_index.dart';
import 'package:torto/core/render/page_painter.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:torto/app/reader/reader_controller.dart';
import 'package:torto/app/reader/reader_page.dart';
import 'package:torto/core/ir/ir.dart' as ir;
import 'package:torto/core/layout/layout_engine.dart';
import 'package:torto/core/layout/layout_types.dart';

class FocusController extends ReaderController {
  final List<PageLayout> pages;
  FocusController(this.pages) {
    opened = true;
    title = 'Focus test';
  }
  @override
  List<PageLayout> get currentPages => pages;
  @override
  int get sectionCount => 1;
  @override
  Future<void> ensurePeek() async {}
  @override
  PageLayout? peekPage(int offset) {
    final target = pageIndex + offset;
    return target >= 0 && target < pages.length ? pages[target] : null;
  }

  @override
  bool canPeek(int offset) => peekPage(offset) != null;
  @override
  Future<void> nextPage() async {
    if (!canPeek(1)) return;
    focusReading.backwards = false;
    pageIndex++;
    notifyListeners();
  }

  @override
  Future<void> prevPage() async {
    if (!canPeek(-1)) return;
    focusReading.backwards = true;
    pageIndex--;
    notifyListeners();
  }
}

Future<FocusController> mount(WidgetTester tester, {bool long = false}) async {
  SharedPreferences.setMockInitialValues({'reader_focus_mode_v1': true});
  tester.view.physicalSize = const Size(411, 914);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final spine = ir.SpineItemId.generated(0);
  ir.TextBlock block(String node, String text) => ir.TextBlock(
    nodeId: node,
    inlines: [ir.TextRun(text)],
    source: ir.SourceRange(
      start: ir.SourceAnchor(spine: spine, node: node, textOffset: 0),
      end: ir.SourceAnchor(spine: spine, node: node, textOffset: text.length),
    ),
  );
  final pages = LayoutEngine().paginate(
    ir.Section(
      id: spine,
      spineIndex: 0,
      href: 'a',
      anchors: [
        ir.SectionAnchor(
          fragment: 'last',
          source: ir.SourceAnchor(spine: spine, node: 'last', textOffset: 0),
        ),
      ],
      blocks: [
        if (long)
          block('long', 'Long paragraph text. ' * 400)
        else
          ...List.generate(
            35,
            (i) => block('n$i', 'Short paragraph number $i.'),
          ),
        const ir.PageBreakBlock(),
        block('last', 'Last paragraph'),
      ],
    ),
    const LayoutViewport(width: 411, height: 914),
    const ReaderStyle(focusMode: true, baseFontSize: 20),
    readingToc: const [ir.TocEntry(label: 'Last', href: 'a#last')],
  );
  final controller = FocusController(pages);
  addTearDown(() {
    controller.dispose();
    for (final page in pages) {
      page.dispose();
    }
  });
  await tester.pumpWidget(
    MaterialApp(
      home: ReaderPage(file: File('focus.epub'), controller: controller),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

void main() {
  testWidgets(
    'horizontal focus transition moves both subsection surfaces together',
    (tester) async {
      final controller = await mount(tester);
      final gesture = await tester.startGesture(const Offset(330, 420));
      await gesture.moveBy(const Offset(-30, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(-110, 0));
      await tester.pump();
      final current = tester.widget<Positioned>(
        find.byKey(const Key('reader-focus-current-slide')),
      );
      final neighbour = tester.widget<Positioned>(
        find.byKey(const Key('reader-focus-neighbour-slide')),
      );
      expect(current.left, lessThan(0));
      expect(neighbour.left! - current.left!, 411);
      expect(controller.pageIndex, 0);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(controller.pageIndex, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'diagonal focus gestures lock to one axis and short drags return to the same block',
    (tester) async {
      final controller = await mount(tester);
      await tester.dragFrom(const Offset(250, 420), const Offset(-250, -20));
      await tester.pumpAndSettle();
      expect(controller.pageIndex, 1);
      await tester.dragFrom(const Offset(70, 420), const Offset(250, 20));
      await tester.pumpAndSettle();
      expect(controller.pageIndex, 0);
      final before = controller.focusReading.active;
      await tester.dragFrom(const Offset(210, 420), const Offset(20, -160));
      await tester.pumpAndSettle();
      expect(controller.pageIndex, 0);
      expect(controller.focusReading.active, before + 1);
      final settled = controller.focusReading.offset;
      final gesture = await tester.startGesture(const Offset(210, 420));
      await gesture.moveBy(const Offset(0, -25));
      await tester.pump(const Duration(milliseconds: 500));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(controller.focusReading.active, before + 1);
      expect(controller.focusReading.offset, settled);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('sentence splitting is a persistent global focus-only switch', (
    tester,
  ) async {
    final controller = await mount(tester);
    Future<void> openSheet() async {
      await tester.tapAt(const Offset(205, 30));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('reader-focus-previous-page')), findsNothing);
      expect(find.byKey(const Key('reader-focus-next-page')), findsNothing);
      await tester.tap(find.byKey(const Key('reader-style-button')));
      await tester.pumpAndSettle();
    }

    await openSheet();
    final toggle = find.byKey(const Key('reader-sentence-split-switch'));
    expect(find.text('按句分段'), findsOneWidget);
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    expect(tester.widget<SwitchListTile>(toggle).onChanged, isNotNull);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(controller.style.sentenceSplit, isTrue);
    expect(
      (await SharedPreferences.getInstance()).getBool(
        'reader_sentence_split_v1',
      ),
      isTrue,
    );
    await openSheet();
    await tester.tap(find.byKey(const Key('reader-focus-mode-switch')));
    await tester.pumpAndSettle();
    await openSheet();
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    expect(tester.widget<SwitchListTile>(toggle).onChanged, isNull);
    expect(find.text('专注模式'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'scrolled links and selections use the visible position and canonical source',
    (tester) async {
      tester.view.physicalSize = const Size(411, 914);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final spine = ir.SpineItemId.generated(0);
      final prefix = 'Reading text. ' * 300;
      final text = [prefix, 'Targetword linked'].join();
      final source = ir.SourceRange(
        start: ir.SourceAnchor(spine: spine, node: 'n1', textOffset: 0),
        end: ir.SourceAnchor(spine: spine, node: 'n1', textOffset: text.length),
      );
      final pages = LayoutEngine().paginate(
        ir.Section(
          id: spine,
          spineIndex: 0,
          href: 'a',
          blocks: [
            ir.TextBlock(
              nodeId: 'n1',
              source: source,
              inlines: [
                ir.TextRun([prefix, 'Targetword '].join()),
                const ir.TextRun('linked', link: 'https://example.com'),
              ],
            ),
          ],
        ),
        const LayoutViewport(width: 411, height: 914),
        const ReaderStyle(focusMode: true),
      );
      addTearDown(() {
        for (final page in pages) {
          page.dispose();
        }
      });
      final state = FocusReadingState()..attach(pages.single, 24);
      state.scroll(pages.single.scrollExtent);
      final page = state.display(pages.single);
      final placed = page.items.whereType<TextPlacement>().single;
      Offset positionAt(int sourceOffset) {
        final display = placed.displayToSource.indexWhere(
          (value) => value >= sourceOffset,
        );
        final box = placed.paragraph
            .getBoxesForRange(display, display + 1)
            .first;
        return box.toRect().center +
            Offset(placed.x, placed.y - placed.sliceTop);
      }

      expect(
        page.linkAt(positionAt(text.length - 3))?.href,
        'https://example.com',
      );
      ReaderSelection? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReaderSelectionLayer(
              page: page,
              nodes: [BookTextNode(source, text)],
              mode: ReaderSelectionMode.word,
              onSelecting: (_) {},
              onSave: (selection, _) => saved = selection,
              onMarkTap: (_) {},
              child: PageWidget(page: page, background: Colors.white),
            ),
          ),
        ),
      );
      await tester.longPressAt(positionAt(prefix.length + 3));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('selection-toolbar')), findsOneWidget);
      await tester.tap(find.byIcon(Icons.highlight_outlined));
      expect(saved!.quote, 'Targetword');
      expect(saved!.ranges.single.start.textOffset, prefix.length);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'focus switch is available in typography and persists independently',
    (tester) async {
      final controller = await mount(tester);
      await tester.tapAt(const Offset(205, 30));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('reader-style-button')));
      await tester.pumpAndSettle();
      final toggle = find.byKey(const Key('reader-focus-mode-switch'));
      expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(controller.style.focusMode, isFalse);
      expect(
        (await SharedPreferences.getInstance()).getBool('reader_focus_mode_v1'),
        isFalse,
      );
      expect(controller.style.typesettingMode, TypesettingMode.unified);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'vertical swipes advance one focus block; taps activate and settle visible blocks',
    (tester) async {
      final controller = await mount(tester);
      final first = controller.currentPage!;
      final bounds = first.focusUnits.map((u) => u.bounds).toList();
      await tester.dragFrom(const Offset(210, 420), const Offset(0, -140));
      await tester.pumpAndSettle();
      expect(controller.pageIndex, 0);
      expect(controller.focusReading.active, 1);
      expect(controller.focusReading.offset, greaterThan(0));
      expect(controller.currentPage, same(first));
      expect(controller.currentPage!.focusUnits.map((u) => u.bounds), bounds);
      final visible = controller.displayPage!.focusUnits;
      final target = visible.indexWhere(
        (unit) => unit.bounds.top > 50 && unit.bounds.bottom < 850,
      );
      await tester.tapAt(visible[target].paintBounds.first.center);
      await tester.pumpAndSettle();
      expect(controller.focusReading.active, target);
      expect(controller.pageIndex, 0);
      controller.activateFocusUnit(first.focusUnits.length - 1);
      await tester.pump();
      await tester.flingFrom(
        const Offset(210, 400),
        const Offset(0, -180),
        1800,
      );
      await tester.pumpAndSettle();
      expect(controller.pageIndex, 1);
      expect(controller.focusReading.active, 0);
      expect(find.byType(Scrollbar), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('horizontal page turn restores the previously active unit', (
    tester,
  ) async {
    final controller = await mount(tester);
    controller.activateFocusUnit(2);
    await tester.pump();
    await tester.flingFrom(const Offset(330, 400), const Offset(-270, 0), 1200);
    await tester.pumpAndSettle();
    expect(controller.pageIndex, 1);
    expect(controller.focusReading.active, 0);
    await tester.flingFrom(const Offset(70, 400), const Offset(270, 0), 1200);
    await tester.pumpAndSettle();
    expect(controller.pageIndex, 0);
    expect(controller.focusReading.active, 2);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'long block advances one window then a fresh edge swipe changes subsection',
    (tester) async {
      final controller = await mount(tester, long: true);
      expect(controller.currentPage!.scrollExtent, greaterThan(0));
      await tester.flingFrom(
        const Offset(210, 620),
        const Offset(0, -250),
        1000,
      );
      await tester.pump(const Duration(milliseconds: 100));
      final mid = controller.focusReading.offset;
      expect(mid, greaterThan(200));
      await tester.pumpAndSettle();
      expect(controller.focusReading.offset, greaterThan(mid));
      expect(controller.pageIndex, 0);
      controller.scrollFocus(controller.currentPage!.scrollExtent);
      await tester.pump();
      await tester.flingFrom(
        const Offset(210, 620),
        const Offset(0, -200),
        1600,
      );
      await tester.pumpAndSettle();
      expect(controller.pageIndex, 1);
      expect(controller.focusReading.active, 0);
      expect(find.byType(Scrollbar), findsNothing);
      await tester.flingFrom(
        const Offset(210, 400),
        const Offset(0, 180),
        1200,
      );
      await tester.pumpAndSettle();
      expect(controller.pageIndex, 0);
      expect(
        controller.focusReading.offset,
        FocusNavigation.overflow(controller.currentPage!, 0)!.bottom,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('short edge drags and book boundaries do not change subsection', (
    tester,
  ) async {
    final controller = await mount(tester);
    await tester.dragFrom(const Offset(210, 400), const Offset(0, 150));
    await tester.pumpAndSettle();
    expect(controller.pageIndex, 0);
    controller.activateFocusUnit(controller.currentPage!.focusUnits.length - 1);
    await tester.pump();
    await tester.dragFrom(const Offset(210, 400), const Offset(0, -25));
    await tester.pumpAndSettle();
    expect(controller.pageIndex, 0);
    await tester.flingFrom(const Offset(210, 400), const Offset(0, -160), 1200);
    await tester.pumpAndSettle();
    expect(controller.pageIndex, 1);
    await tester.flingFrom(const Offset(210, 400), const Offset(0, -160), 1200);
    await tester.pumpAndSettle();
    expect(controller.pageIndex, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
