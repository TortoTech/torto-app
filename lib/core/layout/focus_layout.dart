import 'dart:ui' as ui;
import '../ir/ir.dart';
import 'layout_types.dart';

/// Boundaries are computed before layout, so authored groups never split.
class FocusUnitBuilder {
  static Map<int, List<Block>> build(
    List<Block> blocks, {
    Set<int> boundaries = const {},
  }) {
    final groups = <int, List<Block>>{};
    var start = -1;
    int? listDepth;
    var headingsOnly = false;
    for (var i = 0; i < blocks.length; i++) {
      final block = blocks[i];
      if (boundaries.contains(i)) {
        start = -1;
        listDepth = null;
        headingsOnly = false;
      }
      if (block is PageBreakBlock ||
          block is LineBreakBlock ||
          block is SeparatorBlock) {
        continue;
      }
      final heading = block is TextBlock && block.kind == TextBlockKind.heading;
      final previous = start < 0 ? null : groups[start]!.last;
      final companion =
          block is TextBlock &&
          previous is TextBlock &&
          block.nodeId == '${previous.nodeId}@translation';
      final caption =
          block is TextBlock &&
          block.kind == TextBlockKind.caption &&
          previous is ImageBlock;
      final previousBody = start < 0
          ? null
          : groups[start]!
                .whereType<TextBlock>()
                .where((b) => !b.nodeId.endsWith('@translation'))
                .lastOrNull;
      final descendant =
          block is TextBlock &&
          block.kind == TextBlockKind.listItem &&
          listDepth != null &&
          block.listDepth >= listDepth &&
          (block.listGroupId == previousBody?.listGroupId);
      final introduction =
          block is TextBlock &&
          block.kind == TextBlockKind.listItem &&
          listDepth == null &&
          previousBody?.kind == TextBlockKind.paragraph &&
          !previousBody!.inlines.any((inline) => inline is InlineImageRun);
      final attach =
          start >= 0 &&
          (headingsOnly || companion || caption || descendant || introduction);
      if (!attach) {
        start = i;
        groups[start] = [];
        listDepth = null;
        headingsOnly = heading;
      }
      groups[start]!.add(block);
      if (!heading && !companion) headingsOnly = false;
      if (block is TextBlock && block.kind == TextBlockKind.listItem) {
        listDepth ??= block.listDepth;
      } else if (!companion) {
        listDepth = null;
      }
    }
    return groups;
  }

  static List<List<Block>> overflowParts(List<Block> blocks) {
    final roots = blocks
        .whereType<TextBlock>()
        .where((b) => b.kind == TextBlockKind.listItem)
        .toList();
    if (roots.isEmpty) return [blocks];
    final depth = roots.map((b) => b.listDepth).reduce((a, b) => a < b ? a : b);
    final parts = <List<Block>>[];
    for (final block in blocks) {
      if (parts.isEmpty ||
          block is TextBlock &&
              block.kind == TextBlockKind.listItem &&
              block.listDepth == depth &&
              !block.nodeId.endsWith('@translation')) {
        parts.add([]);
      }
      parts.last.add(block);
    }
    return parts;
  }

  static List<SourceRange> sources(Block block) => switch (block) {
    TextBlock(:final source) || ImageBlock(:final source) => [?source],
    FigureBlock(:final source, :final images, :final captions) => [
      ?source,
      ...images.expand(sources),
      ...captions.expand(sources),
    ],
    QuoteBlock(:final source, :final body, :final attribution) => [
      ?source,
      ...body.expand(sources),
      if (attribution != null) ...sources(attribution),
    ],
    TableBlock(:final source, :final before, :final after, :final rows) => [
      ?source,
      ...before.expand(sources),
      ...after.expand(sources),
      for (final row in rows)
        for (final cell in row.cells)
          if (cell.source != null) cell.source!,
    ],
    NoteBlock(:final blocks) => blocks.expand(sources).toList(),
    _ => [],
  };
}

/// Move retained display data without reshaping or losing source/link metadata.
PageItem shiftPageItem(PageItem item, double dy) => switch (item) {
  TextPlacement() => TextPlacement(
    baselineRegions: item.baselineRegions,
    displayToSource: item.displayToSource,
    syntheticPrefixLength: item.syntheticPrefixLength,
    paragraph: item.paragraph,
    startLine: item.startLine,
    endLine: item.endLine,
    x: item.x,
    y: item.y + dy,
    width: item.width,
    source: item.source,
    nodeId: item.nodeId,
    spineIndex: item.spineIndex,
    textOffsetAtStart: item.textOffsetAtStart,
    lineMetrics: item.lineMetrics,
    sliceTop: item.sliceTop,
    sliceHeight: item.sliceHeight,
    sectionTextOffset: item.sectionTextOffset,
    links: item.links,
    inlineImages: item.inlineImages,
  ),
  TableCellPlacement() => TableCellPlacement(
    baselineRegions: item.baselineRegions,
    displayToSource: item.displayToSource,
    paragraph: item.paragraph,
    rect: item.rect.shift(ui.Offset(0, dy)),
    padding: item.padding,
    header: item.header,
    source: item.source,
    nodeId: item.nodeId,
    spineIndex: item.spineIndex,
    sectionTextOffset: item.sectionTextOffset,
    links: item.links,
    inlineImages: item.inlineImages,
  ),
  ListMarkerPlacement() => ListMarkerPlacement(
    marker: item.marker,
    paragraph: item.paragraph,
    x: item.x,
    y: item.y + dy,
    width: item.width,
    height: item.height,
  ),
  ImagePlacement() => ImagePlacement(
    href: item.href,
    rect: item.rect.shift(ui.Offset(0, dy)),
    latex: item.latex,
    originalImage: item.originalImage,
  ),
  QuotePlacement() => QuotePlacement(
    x: item.x,
    y: item.y + dy,
    width: item.width,
    height: item.height,
    color: item.color,
    continuedBefore: item.continuedBefore,
    continuedAfter: item.continuedAfter,
  ),
  SeparatorPlacement() => SeparatorPlacement(
    rect: item.rect.shift(ui.Offset(0, dy)),
  ),
};
