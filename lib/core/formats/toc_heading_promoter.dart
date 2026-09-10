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
  final blocks = List<Block>.of(section.blocks);
  bool eligible(Block block) =>
      block is TextBlock &&
      (block.kind == TextBlockKind.paragraph ||
          block.kind == TextBlockKind.heading);
  String key(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[\s:.\-‐‑‒–—]'), '');
  String? ordinal(String s) {
    s = s
        .toLowerCase()
        .replaceFirst(RegExp(r'^(chapter|part|book)\s*'), '')
        .replaceAll(RegExp(r'^[\s:.\-–—]+|[\s:.\-–—]+$'), '');
    final words = s.split(RegExp(r'[\s-]+'));
    const numbers = {
      'one',
      'two',
      'three',
      'four',
      'five',
      'six',
      'seven',
      'eight',
      'nine',
      'ten',
      'eleven',
      'twelve',
      'thirteen',
      'fourteen',
      'fifteen',
      'sixteen',
      'seventeen',
      'eighteen',
      'nineteen',
      'twenty',
      'thirty',
      'forty',
      'fifty',
      'sixty',
      'seventy',
      'eighty',
      'ninety',
      'hundred',
      'thousand',
    };
    return s.isNotEmpty &&
            (RegExp(r'^\d+$').hasMatch(s) ||
                s.length <= 12 && RegExp(r'^[ivxlcdm]+$').hasMatch(s) ||
                words.every(numbers.contains))
        ? key(s)
        : null;
  }

  TextBlock promote(TextBlock b, int level, bool isOrdinal) => TextBlock(
    kind: TextBlockKind.heading,
    headingLevel: level,
    headingOrdinal: isOrdinal,
    inlines: b.inlines,
    style: b.style,
    source: b.source,
    nodeId: b.nodeId,
  );
  for (final hint in hints) {
    final anchor = section.anchors
        .where((a) => a.fragment == hint.fragment)
        .firstOrNull;
    final anchored = anchor == null
        ? -1
        : blocks.indexWhere(
            (b) => b is TextBlock && b.source?.start.node == anchor.source.node,
          );
    final start = anchored >= 0 ? (anchored - 1).clamp(0, blocks.length) : 0;
    final end = anchored >= 0
        ? (anchored + 2).clamp(0, blocks.length)
        : blocks.length.clamp(0, _pathOnlyHeadingSearchBlocks);
    final matches = <(int, bool)>[];
    for (var i = start; i < end; i++) {
      if (!eligible(blocks[i])) continue;
      final text = (blocks[i] as TextBlock).plainText;
      if (key(text) == key(hint.label)) {
        matches.add((i, false));
        continue;
      }
      if (ordinal(text) == null ||
          i + 1 >= blocks.length ||
          !eligible(blocks[i + 1])) {
        continue;
      }
      final title = (blocks[i + 1] as TextBlock).plainText;
      final strippedHint = hint.label.replaceFirst(
        RegExp(r'^(chapter|part|book)\s*', caseSensitive: false),
        '',
      );
      final split = RegExp(
        r'^([^\s:.\-–—]+)[\s:.\-–—]+(.+)$',
      ).firstMatch(strippedHint);
      if (key('$text $title') == key(hint.label) ||
          split != null &&
              ordinal(text) == key(split.group(1)!) &&
              key(title) == key(split.group(2)!)) {
        matches.add((i, true));
      }
    }
    if (matches.length != 1) continue;
    final (i, split) = matches.single;
    if (split) {
      blocks[i] = promote(blocks[i] as TextBlock, hint.level, true);
      blocks[i + 1] = promote(blocks[i + 1] as TextBlock, hint.level, false);
    } else if ((blocks[i] as TextBlock).kind == TextBlockKind.paragraph) {
      blocks[i] = promote(blocks[i] as TextBlock, hint.level, false);
    }
  }
  if (List.generate(
    blocks.length,
    (i) => identical(blocks[i], section.blocks[i]),
  ).every((same) => same)) {
    return section;
  }
  return Section(
    id: section.id,
    spineIndex: section.spineIndex,
    href: section.href,
    blocks: blocks,
    anchors: section.anchors,
  );
}

String _normalizeHeadingText(String text) => text
    .split(RegExp(r'\s+'))
    .where((part) => part.isNotEmpty)
    .join(' ')
    .toLowerCase();
