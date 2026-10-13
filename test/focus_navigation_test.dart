import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:torto/app/reader/focus_navigation.dart';
import 'package:torto/core/layout/layout_types.dart';

PageLayout fixture(
  List<Rect> bounds, {
  List<PageItem> items = const [],
  List<List<Rect>>? paint,
  Rect? contentBounds,
}) => PageLayout(
  viewport: const LayoutViewport(width: 400, height: 700),
  items: items,
  firstAnchor: null,
  progression: 0,
  scrollExtent: 5000,
  focusContentBounds: contentBounds,
  focusUnits: [
    for (var i = 0; i < bounds.length; i++)
      FocusUnitLayout(
        bounds: bounds[i],
        sources: const [],
        paintBounds: paint?[i] ?? [bounds[i]],
      ),
  ],
);

void main() {
  test('clipped margins make a nearly page-sized block overflow', () {
    const visible = Rect.fromLTRB(0, 80, 400, 580);
    const block = Rect.fromLTWH(20, 380, 360, 620);
    final page = fixture([
      block,
      const Rect.fromLTWH(20, 1020, 360, 70),
    ], contentBounds: visible);
    final start = FocusNavigation.target(page, 0);
    final stops = FocusNavigation.overflow(page, 0)!;
    expect(block.top - start, greaterThanOrEqualTo(visible.top));
    final middle = FocusNavigation.step(page, 0, start, 1);
    expect(middle.active, 0);
    final next = FocusNavigation.step(page, 0, middle.offset, 1);
    expect(next.active, 0);
    expect(next.offset, stops.bottom);
    expect(block.bottom - next.offset, lessThanOrEqualTo(visible.bottom));
    expect(FocusNavigation.step(page, 0, next.offset, 1).active, 1);
    expect(
      FocusNavigation.step(page, 1, FocusNavigation.target(page, 1), -1),
      next,
    );
  });

  test('fitting blocks and images center in the asymmetric visible area', () {
    const visible = Rect.fromLTRB(0, 100, 400, 620);
    const body = Rect.fromLTWH(20, 500, 360, 510);
    final page = fixture([body], contentBounds: visible);
    final offset = FocusNavigation.target(page, 0);
    expect(body.top - offset, greaterThanOrEqualTo(visible.top));
    expect(body.bottom - offset, lessThanOrEqualTo(visible.bottom));
    expect(body.center.dy - offset, visible.center.dy);
    expect(FocusNavigation.overflow(page, 0), isNull);
  });
  test('first body is positioned without hiding its leading heading', () {
    const headingAndBody = Rect.fromLTWH(20, 380, 360, 150);
    const body = Rect.fromLTWH(20, 460, 360, 70);
    final page = fixture(
      [headingAndBody],
      paint: [
        [body],
      ],
    );
    final offset = FocusNavigation.target(page, 0);
    expect(offset, 230);
    expect(headingAndBody.top - offset, greaterThanOrEqualTo(28));
  });
  test(
    'one navigation step selects one block and section boundaries stay put',
    () {
      final page = fixture([
        const Rect.fromLTWH(20, 380, 360, 70),
        const Rect.fromLTWH(20, 470, 360, 70),
        const Rect.fromLTWH(20, 560, 360, 70),
      ]);
      final next = FocusNavigation.step(page, 0, 0, 1);
      expect(next.active, 1);
      expect(next.offset, 240);
      expect(FocusNavigation.step(page, 2, 330, 1), (active: 2, offset: 330.0));
      expect(FocusNavigation.step(page, 0, 0, -1), (active: 0, offset: 0.0));
      expect(FocusNavigation.duration(10), const Duration(milliseconds: 160));
      expect(FocusNavigation.duration(2000), const Duration(milliseconds: 360));
    },
  );
  test(
    'long content is read to its last stop before changing blocks; reverse entry starts at its bottom',
    () {
      final page = fixture([
        const Rect.fromLTWH(20, 380, 360, 2100),
        const Rect.fromLTWH(20, 2500, 360, 70),
      ]);
      var current = (active: 0, offset: FocusNavigation.target(page, 0));
      var count = 0;
      while (true) {
        final next = FocusNavigation.step(
          page,
          current.active,
          current.offset,
          1,
        );
        if (next.active == 1) break;
        expect(next.offset - current.offset, lessThanOrEqualTo(240));
        expect(next.offset, greaterThan(current.offset));
        current = next;
        expect(++count, lessThan(20));
      }
      expect(count, greaterThan(5));
      final previous = FocusNavigation.step(
        page,
        1,
        FocusNavigation.target(page, 1),
        -1,
      );
      expect(previous, current);
    },
  );
  test('a fitting image and caption have two reversible stops', () {
    const image = Rect.fromLTWH(20, 380, 360, 690);
    const caption = Rect.fromLTWH(20, 1090, 360, 80);
    final page = fixture(
      [image.expandToInclude(caption)],
      items: [const ImagePlacement(href: 'picture', rect: image)],
      paint: [
        [image, caption],
      ],
    );
    final start = FocusNavigation.target(page, 0);
    final end = FocusNavigation.step(page, 0, start, 1);
    expect(end.active, 0);
    expect(end.offset, caption.center.dy - 350);
    expect(FocusNavigation.step(page, 0, end.offset, -1).offset, start);
  });
}
