import '../ir/ir.dart';
import '../layout/focus_layout.dart';

/// Authored reading boundaries, independent of typography and AI batching.
class ReadingUnitIndex {
  final List<int> starts;
  const ReadingUnitIndex(this.starts);

  factory ReadingUnitIndex.build(
    Section section,
    List<Block> blocks,
    List<TocEntry> toc,
  ) {
    final fragments = <String>{};
    void collect(List<TocEntry> entries) {
      for (final entry in entries) {
        final separator = entry.href.indexOf('#');
        final path = separator < 0
            ? entry.href
            : entry.href.substring(0, separator);
        if (path == section.href && separator >= 0) {
          final raw = entry.href.substring(separator + 1);
          fragments.add(raw);
          try {
            fragments.add(Uri.decodeComponent(raw));
          } on FormatException {
            // Malformed escapes must not make otherwise readable books fail.
          }
        }
        collect(entry.children);
      }
    }

    collect(toc);
    final boundaries = <int>{0};
    for (final anchor in section.anchors) {
      if (!fragments.contains(anchor.fragment)) continue;
      final index = blocks.indexWhere(
        (block) => FocusUnitBuilder.sources(block).any(
          (range) =>
              range.start.node == anchor.source.node ||
              range.end.node == anchor.source.node,
        ),
      );
      if (index >= 0) boundaries.add(index);
    }
    final starts = boundaries.toList()..sort();
    // Fold heading-only chapter preludes into the following child. Illustrated
    // preludes remain separate, just as in desktop build_reading_units.
    for (var i = 0; i + 1 < starts.length;) {
      final content = blocks
          .sublist(starts[i], starts[i + 1])
          .any(
            (block) => switch (block) {
              TextBlock() =>
                block.kind != TextBlockKind.heading &&
                    block.kind != TextBlockKind.footnoteDefinition &&
                    block.plainText.trim().isNotEmpty,
              ImageBlock() ||
              FigureBlock() ||
              TableBlock() ||
              QuoteBlock() => true,
              _ => false,
            },
          );
      if (content) {
        i++;
      } else {
        starts.removeAt(i + 1);
      }
    }
    return ReadingUnitIndex(List.unmodifiable(starts));
  }
}
