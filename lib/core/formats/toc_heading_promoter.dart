/// TOC-driven body heading inference shared by reflowable book formats.
///
/// Some publications encode chapter titles as plain paragraphs and express
/// their heading semantics only in the table of contents. This mirrors
/// torto's conservative promotion pass: only an exact normalized label match
/// may turn a paragraph into a heading, so ordinary prose is not guessed at.
library;

import '../html_ir/package_path.dart';
import '../ir/ir.dart';

class TocHeadingHint {
  final String label;
  final String? fragment;
  final int level;

  const TocHeadingHint({
    required this.label,
    required this.fragment,
    required this.level,
  });
}

const int _pathOnlyHeadingSearchBlocks = 8;

/// A sole wrapping TOC node adds no useful navigation depth. Its children
/// become the visible roots, matching the desktop reader.
List<TocEntry> promoteSingleTocRoot(List<TocEntry> entries) {
  if (entries.length == 1 && entries.single.children.isNotEmpty) {
    return entries.single.children;
  }
  return entries;
}

/// Collects exact-label heading candidates grouped by section path.
Map<String, List<TocHeadingHint>> collectTocHeadingHints(
  List<TocEntry> entries,
) {
  final hints = <String, List<TocHeadingHint>>{};

  void visit(List<TocEntry> current, int depth) {
    for (final entry in current) {
      final label = _normalizeHeadingText(entry.label);
      if (entry.href.isNotEmpty && label.isNotEmpty) {
        final (rawPath, fragment) = splitPackageFragment(entry.href);
        final path = normalizePackagePath(safePercentDecode(rawPath));
        if (path.isNotEmpty) {
          hints
              .putIfAbsent(path, () => [])
              .add(
                TocHeadingHint(
                  label: label,
                  fragment: fragment?.isEmpty ?? true ? null : fragment,
                  level: depth.clamp(1, 6),
                ),
              );
        }
      }
      visit(entry.children, depth + 1);
    }
  }

  visit(entries, 1);
  return hints;
}

/// Promotes TOC targets that are still plain paragraphs to semantic headings.
/// Existing h1-h6 blocks retain their authored level and styling.
Section promoteTocHeadings(Section section, List<TocHeadingHint> hints) {
  if (hints.isEmpty || section.blocks.isEmpty) return section;
  List<Block>? promotedBlocks;

  for (final hint in hints) {
    int? blockIndex;
    final fragment = hint.fragment;
    if (fragment != null) {
      String? targetNode;
      for (final anchor in section.anchors) {
        if (anchor.fragment == fragment) {
          targetNode = anchor.source.node;
          break;
        }
      }
      if (targetNode != null) {
        final blocks = promotedBlocks ?? section.blocks;
        for (var index = 0; index < blocks.length; index++) {
          final block = blocks[index];
          if (block is TextBlock && block.source?.start.node == targetNode) {
            blockIndex = index;
            break;
          }
        }
      }
    } else {
      final blocks = promotedBlocks ?? section.blocks;
      final searchLength = blocks.length < _pathOnlyHeadingSearchBlocks
          ? blocks.length
          : _pathOnlyHeadingSearchBlocks;
      for (var index = 0; index < searchLength; index++) {
        final block = blocks[index];
        if (block is TextBlock &&
            (block.kind == TextBlockKind.paragraph ||
                block.kind == TextBlockKind.heading) &&
            _normalizeHeadingText(block.plainText) == hint.label) {
          blockIndex = index;
          break;
        }
      }
    }

    if (blockIndex == null) continue;
    final blocks = promotedBlocks ?? section.blocks;
    final target = blocks[blockIndex];
    if (target is! TextBlock ||
        target.kind != TextBlockKind.paragraph ||
        _normalizeHeadingText(target.plainText) != hint.label) {
      continue;
    }

    promotedBlocks ??= List<Block>.of(section.blocks);
    promotedBlocks[blockIndex] = TextBlock(
      kind: TextBlockKind.heading,
      headingLevel: hint.level,
      listOrdered: target.listOrdered,
      listOrdinal: target.listOrdinal,
      listDepth: target.listDepth,
      listMarkerVisible: target.listMarkerVisible,
      inlines: target.inlines,
      style: target.style,
      source: target.source,
      nodeId: target.nodeId,
    );
  }

  if (promotedBlocks == null) return section;
  return Section(
    spineIndex: section.spineIndex,
    href: section.href,
    blocks: promotedBlocks,
    anchors: section.anchors,
  );
}

String _normalizeHeadingText(String text) => text
    .split(RegExp(r'\s+'))
    .where((part) => part.isNotEmpty)
    .join(' ')
    .toLowerCase();
