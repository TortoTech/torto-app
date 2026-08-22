import '../../core/ir/ir.dart';

/// Flattened, render-ready TOC row. Port of torto's `TocViewItem`
/// (crates/reader): the tree-shaped [TocEntry] list is flattened once and
/// rows carry their depth/ancestry so the drawer can filter visibility and
/// indent without walking the tree.
class TocViewItem {
  /// Path-style id of dot-separated sibling indices, e.g. "0/2/1".
  final String id;
  final String label;

  /// Jump target: spine index of the entry's href, when resolvable.
  /// Null marks a pure grouping node (or a dangling href).
  final int? spineIndex;
  final int depth;

  /// Ids of all ancestor rows, outermost first.
  final List<String> ancestors;
  final bool hasChildren;

  const TocViewItem({
    required this.id,
    required this.label,
    required this.spineIndex,
    required this.depth,
    required this.ancestors,
    required this.hasChildren,
  });
}

/// Port of torto's `flatten_toc`: pre-order traversal assigning each entry a
/// path-style id ("0/2/1") matching its sibling indices from the root.
List<TocViewItem> flattenToc(List<TocEntry> entries) {
  final items = <TocViewItem>[];
  void append(List<TocEntry> level, int depth, List<String> ancestors) {
    for (var i = 0; i < level.length; i++) {
      final entry = level[i];
      final id = ancestors.isEmpty ? '$i' : '${ancestors.last}/$i';
      items.add(
        TocViewItem(
          id: id,
          label: entry.label,
          spineIndex: entry.spineIndex,
          depth: depth,
          ancestors: List.unmodifiable(ancestors),
          hasChildren: entry.children.isNotEmpty,
        ),
      );
      append(entry.children, depth + 1, [...ancestors, id]);
    }
  }

  append(entries, 0, const []);
  return items;
}

/// Rows currently visible given [expandedIds]: a row is visible iff every
/// ancestor is expanded (roots are always visible). Mirrors torto's
/// `visible_toc_row_indices`.
List<TocViewItem> visibleTocItems(
  List<TocViewItem> items,
  Set<String> expandedIds,
) => items.where((item) => item.ancestors.every(expandedIds.contains)).toList();

/// Id of the active row for [currentSection]: the LAST item in document
/// order whose spine index is at or before the current section. Items
/// without a resolvable target can never be active.
///
/// torto computes this at fragment-anchor granularity; this v1 matches at
/// section granularity (see design doc, "后续迭代").
String? activeTocId(List<TocViewItem> items, int currentSection) {
  String? best;
  for (final item in items) {
    final spine = item.spineIndex;
    if (spine != null && spine <= currentSection) best = item.id;
  }
  return best;
}
