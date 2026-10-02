import 'dart:ui' as ui;
import '../../core/ir/ir.dart';
import '../../core/layout/layout_types.dart';
import '../../core/layout/focus_layout.dart';
import 'focus_navigation.dart';

/// Reading state is independent of widget lifetime and uses canonical anchors.
class FocusReadingState {
  PageLayout? _page;
  PageLayout? _display;
  final Map<Object, (int, double, SourceAnchor?, SourceAnchor?, int)> _visited =
      {};
  int active = 0;
  double offset = 0;
  double _top = 0;
  SourceAnchor? _ordinaryAnchor;
  SourceAnchor? target;
  bool backwards = false;
  bool _usesVisibleAnchor = false;

  void detach(List<PageLayout> pages) {
    if (_page == null || !pages.contains(_page)) return;
    _remember();
    _page = null;
    _display = null;
  }

  void _remember() {
    final page = _page;
    if (page == null) return;
    _visited[page.focusId ?? page] = (
      active,
      offset,
      page.focusUnits.elementAtOrNull(active)?.anchor,
      anchor,
      identityHashCode(page),
    );
    while (_visited.length > 8) {
      _visited.remove(_visited.keys.first);
    }
  }

  void attach(PageLayout page, double top) {
    if (identical(_page, page) && target == null) return;
    _remember();
    _page = page;
    _top = top;
    _display = null;
    final saved = _visited[page.focusId ?? page];
    active =
        saved?.$1 ??
        (backwards && page.focusUnits.isNotEmpty
            ? page.focusUnits.length - 1
            : 0);
    offset = saved?.$2 ?? (backwards ? page.scrollExtent : 0);
    active = active.clamp(0, (page.focusUnits.length - 1).clamp(0, 1 << 30));
    if (saved == null && page.focusUnits.isNotEmpty) {
      offset = backwards
          ? FocusNavigation.overflow(page, active)?.bottom ??
                FocusNavigation.target(page, active)
          : FocusNavigation.target(page, active);
    }
    if (saved?.$3 case final activeAnchor?) {
      final selected = page.focusUnits.indexWhere(
        (unit) => unit.contains(activeAnchor),
      );
      if (selected >= 0) active = selected;
    }
    _usesVisibleAnchor =
        offset > 0 &&
        (page.focusUnits.elementAtOrNull(active)?.bounds.height ?? 0) >
            page.viewport.height;
    backwards = false;
    final anchor =
        target ??
        (saved != null && saved.$5 != identityHashCode(page) ? saved.$4 : null);
    target = null;
    _ordinaryAnchor = page.focusUnits.isEmpty ? anchor : null;
    if (anchor == null || page.focusUnits.isEmpty) return;
    final match = page.focusUnits.indexWhere((unit) => unit.contains(anchor));
    if (match >= 0) active = match;
    offset = 0;
    if (page.scrollExtent <= 0) return;
    if (match >= 0 && page.focusUnits[match].anchor == anchor) {
      // Entry geometry includes leading headings when restoring a body start.
      offset = FocusNavigation.target(page, match);
      _usesVisibleAnchor =
          offset > 0 &&
          (page.focusUnits.elementAtOrNull(active)?.bounds.height ?? 0) >
              page.viewport.height;
      return;
    }
    for (final item in page.items) {
      if (item is TextPlacement &&
          item.source?.start.spine == anchor.spine &&
          item.source?.start.node == anchor.node &&
          item.source!.start.textOffset <= anchor.textOffset &&
          (item.source!.end.node != anchor.node ||
              anchor.textOffset <= item.source!.end.textOffset)) {
        final local = anchor.textOffset - item.source!.start.textOffset;
        var displayOffset = item.displayToSource.indexWhere(
          (value) => value >= local,
        );
        if (displayOffset < 0) displayOffset = item.displayToSource.length - 1;
        final boxes = item.paragraph.getBoxesForRange(
          displayOffset,
          displayOffset + 1,
        );
        final y = boxes.isEmpty ? 0.0 : boxes.first.top;
        offset = (item.y - item.sliceTop + y - top).clamp(
          0.0,
          page.scrollExtent,
        );
        break;
      }
      if (item is TableCellPlacement &&
          item.source?.start.spine == anchor.spine &&
          item.source?.start.node == anchor.node) {
        offset = (item.rect.top - top).clamp(0.0, page.scrollExtent);
        break;
      }
    }
    _usesVisibleAnchor =
        offset > 0 &&
        (page.focusUnits.elementAtOrNull(active)?.bounds.height ?? 0) >
            page.viewport.height;
  }

  SourceAnchor? get anchor {
    final page = _page;
    if (page == null || page.focusUnits.isEmpty) {
      return _ordinaryAnchor ?? page?.firstAnchor;
    }
    if (_usesVisibleAnchor && page.scrollExtent > 0) {
      final y = offset + _top;
      for (final item in page.items) {
        final itemSource = switch (item) {
          TextPlacement(:final source) ||
          TableCellPlacement(:final source) => source,
          _ => null,
        };
        if (itemSource != null &&
            !page.focusUnits[active].contains(itemSource.start)) {
          continue;
        }
        if (item is TextPlacement &&
            item.source != null &&
            item.y + item.sliceHeight > y) {
          final displayOffset = item.paragraph
              .getPositionForOffset(
                ui.Offset(
                  0,
                  (y - item.y + item.sliceTop).clamp(
                    0.0,
                    item.paragraph.height,
                  ),
                ),
              )
              .offset;
          final mapping = item.displayToSource;
          final local = mapping.isEmpty
              ? 0
              : mapping[displayOffset.clamp(0, mapping.length - 1)];
          return SourceAnchor(
            spine: item.source!.start.spine,
            node: item.source!.start.node,
            textOffset: item.source!.start.textOffset + local,
          );
        }
        if (item is TableCellPlacement &&
            item.source != null &&
            item.rect.bottom > y) {
          return item.source!.start;
        }
      }
    }
    return page.focusUnits[active].anchor ?? page.firstAnchor;
  }

  bool activate(int index) {
    final units = _page?.focusUnits ?? [];
    if (index < 0 || index >= units.length || index == active) return false;
    active = index;
    _usesVisibleAnchor = false;
    return true;
  }

  void activateVisible() {
    final page = _page;
    if (page == null || page.focusUnits.isEmpty) return;
    final y = offset + _top + page.viewport.height * .2;
    final index = page.focusUnits.indexWhere((unit) => unit.bounds.bottom > y);
    if (index >= 0) active = index;
  }

  double get progression {
    final page = _page;
    if (page == null) return 0;
    if (offset >= page.scrollExtent && page.scrollExtent > 0) {
      return page.endProgression ?? page.progression;
    }
    if (page.sourceTextLength > 0) {
      final source = anchor;
      for (final item in page.items) {
        if (item is TextPlacement && item.source?.start.node == source?.node) {
          return ((item.sectionTextOffset + (source?.textOffset ?? 0)) /
                  page.sourceTextLength)
              .clamp(0.0, 1.0);
        }
        if (item is TableCellPlacement &&
            item.source?.start.node == source?.node) {
          return (item.sectionTextOffset / page.sourceTextLength).clamp(
            0.0,
            1.0,
          );
        }
      }
    }
    return page.progression;
  }

  bool scroll(double value, {bool usesVisibleAnchor = true}) {
    final next = value.clamp(0.0, _page?.scrollExtent ?? 0.0);
    if (next == offset) return false;
    offset = next;
    _usesVisibleAnchor = usesVisibleAnchor;
    _display = null;
    return true;
  }

  (PageLayout, int) preview(PageLayout page, {required bool backwards}) {
    final preview = FocusReadingState()..backwards = backwards;
    preview._visited.addAll(_visited);
    preview.attach(page, _top);
    return (preview.display(page), preview.active);
  }

  PageLayout display(PageLayout page) => _display ??= _displayAt(page, offset);

  static PageLayout _displayAt(PageLayout page, double offset) {
    if (page.scrollExtent == 0) return page;
    bool visible(PageItem item) {
      final bounds = switch (item) {
        TextPlacement(:final y, :final sliceHeight) => (y, y + sliceHeight),
        ListMarkerPlacement(:final y, :final height) ||
        QuotePlacement(:final y, :final height) => (y, y + height),
        ImagePlacement(:final rect) ||
        TableCellPlacement(:final rect) ||
        SeparatorPlacement(:final rect) => (rect.top, rect.bottom),
      };
      return bounds.$2 >= offset && bounds.$1 <= offset + page.viewport.height;
    }

    return PageLayout(
      focusId: page.focusId,
      sourceTextLength: page.sourceTextLength,
      endProgression: page.endProgression,
      viewport: page.viewport,
      items: page.items
          .where(visible)
          .map((item) => shiftPageItem(item, -offset))
          .toList(),
      firstAnchor: page.firstAnchor,
      progression: page.progression,
      disposalPool: page.disposalPool,
      scrollExtent: page.scrollExtent,
      focusUnits: [
        for (final unit in page.focusUnits)
          FocusUnitLayout(
            bounds: unit.bounds.shift(ui.Offset(0, -offset)),
            paintBounds: unit.paintBounds
                .map((rect) => rect.shift(ui.Offset(0, -offset)))
                .toList(),
            sources: unit.sources,
            anchor: unit.anchor,
          ),
      ],
    );
  }
}
