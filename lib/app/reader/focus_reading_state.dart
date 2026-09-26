import 'dart:ui' as ui;
import '../../core/ir/ir.dart';
import '../../core/layout/layout_types.dart';
import '../../core/layout/focus_layout.dart';

/// Reading state is independent of widget lifetime and uses canonical anchors.
class FocusReadingState {
  PageLayout? _page;
  PageLayout? _display;
  final Map<PageLayout, (int, double)> _visited = {};
  int active = 0;
  double offset = 0;
  double _top = 0;
  SourceAnchor? _ordinaryAnchor;
  SourceAnchor? target;
  bool backwards = false;

  void attach(PageLayout page, double top) {
    if (identical(_page, page) && target == null) return;
    if (_page != null) {
      _visited[_page!] = (active, offset);
      while (_visited.length > 32) {
        _visited.remove(_visited.keys.first);
      }
    }
    _page = page;
    _top = top;
    _display = null;
    final saved = _visited[page];
    active =
        saved?.$1 ??
        (backwards && page.focusUnits.isNotEmpty
            ? page.focusUnits.length - 1
            : 0);
    offset = saved?.$2 ?? (backwards ? page.scrollExtent : 0);
    backwards = false;
    final anchor = target;
    target = null;
    _ordinaryAnchor = page.focusUnits.isEmpty ? anchor : null;
    if (anchor == null || page.focusUnits.isEmpty) return;
    final match = page.focusUnits.indexWhere((unit) => unit.contains(anchor));
    if (match < 0) return;
    active = match;
    offset = 0;
    if (page.scrollExtent <= 0) return;
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
  }

  SourceAnchor? get anchor {
    final page = _page;
    if (page == null || page.focusUnits.isEmpty) {
      return _ordinaryAnchor ?? page?.firstAnchor;
    }
    if (page.scrollExtent > 0) {
      final y = offset + _top;
      for (final item in page.items) {
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
    return true;
  }

  bool scroll(double value) {
    final next = value.clamp(0.0, _page?.scrollExtent ?? 0.0);
    if (next == offset) return false;
    offset = next;
    _display = null;
    return true;
  }

  (PageLayout, int) preview(PageLayout page, {required bool backwards}) {
    final saved = _visited[page];
    final index = saved?.$1 ?? (backwards ? page.focusUnits.length - 1 : 0);
    final scroll = saved?.$2 ?? (backwards ? page.scrollExtent : 0);
    return (_displayAt(page, scroll), index);
  }

  PageLayout display(PageLayout page) => _display ??= _displayAt(page, offset);

  static PageLayout _displayAt(PageLayout page, double offset) {
    if (page.scrollExtent == 0 || page.focusUnits.isEmpty) return page;
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
            sources: unit.sources,
            anchor: unit.anchor,
          ),
      ],
    );
  }
}
