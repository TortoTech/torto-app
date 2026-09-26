import '../ir/ir.dart';

class SemanticPlan {
  final Section section;
  late final List<SemanticBatch> batches;
  final Map<String, int> nodes = {};
  final Map<String, Set<int>> images = {};
  SemanticPlan(this.section, {Set<String> subsectionNodes = const {}}) {
    batches = semanticBatches(section, subsectionNodes: subsectionNodes);
    for (var i = 0; i < section.blocks.length; i++) {
      final block = section.blocks[i];
      for (final node in semanticNodes(block)) {
        nodes[node] = i;
      }
      final media = switch (block) {
        ImageBlock() => [block],
        FigureBlock(:final images) => images,
        _ => <ImageBlock>[],
      };
      for (final image in media) {
        images.putIfAbsent(image.href, () => {}).add(i);
      }
    }
  }
  Set<int> visibleBlocks(Set<String> visibleNodes, Set<String> visibleImages) =>
      {
        for (final node in visibleNodes) ?nodes[node],
        for (final href in visibleImages) ...?images[href],
      };
}

/// Source-based boundaries: neither translated text nor recognition results
/// participate in this plan, so scrolling and reflow cannot change cache keys.
class SemanticBatch {
  final int start,
      end,
      subsectionStart,
      subsectionEnd,
      contextStart,
      contextEnd;
  const SemanticBatch(
    this.start,
    this.end,
    this.subsectionStart,
    this.subsectionEnd,
    this.contextStart,
    this.contextEnd,
  );
  String get key => '$start:$end';
  bool contains(int block) => start <= block && block < end;
  bool sameSubsection(SemanticBatch other) =>
      subsectionStart == other.subsectionStart &&
      subsectionEnd == other.subsectionEnd;
}

int semanticTextLength(Block block) => switch (block) {
  TextBlock(:final plainText) => plainText.runes.length,
  QuoteBlock(:final textLength) ||
  FigureBlock(:final textLength) ||
  TableBlock(:final textLength) ||
  NoteBlock(:final textLength) => textLength,
  _ => 0,
};

Iterable<String> semanticNodes(Block block) sync* {
  switch (block) {
    case TextBlock(:final source, :final nodeId):
      yield source?.start.node ?? nodeId;
    case ImageBlock(:final source):
      if (source != null) yield source.start.node;
    case FigureBlock(:final images, :final captions):
      for (final child in <Block>[...images, ...captions]) {
        yield* semanticNodes(child);
      }
    case QuoteBlock(:final body, :final attribution):
      for (final child in [...body, ?attribution]) {
        yield* semanticNodes(child);
      }
    case TableBlock(:final before, :final after, :final rows):
      for (final text in [...before, ...after]) {
        yield* semanticNodes(text);
      }
      for (final cell in rows.expand((row) => row.cells)) {
        yield cell.source?.start.node ?? cell.nodeId;
      }
    case NoteBlock(:final blocks):
      for (final child in blocks) {
        yield* semanticNodes(child);
      }
    default:
      break;
  }
}

List<SemanticBatch> semanticBatches(
  Section section, {
  Set<String> subsectionNodes = const {},
  int characterBudget = 5000,
}) {
  if (characterBudget <= 0) throw ArgumentError.value(characterBudget);
  final blocks = section.blocks;
  final boundaries = <int>[0];
  for (var i = 1; i < blocks.length; i++) {
    if (blocks[i] case TextBlock(kind: TextBlockKind.heading)) {
      boundaries.add(i);
    } else if (semanticNodes(blocks[i]).any(subsectionNodes.contains)) {
      boundaries.add(i);
    }
  }
  boundaries.add(blocks.length);
  final result = <SemanticBatch>[];
  bool caption(Block b) => b is TextBlock && b.kind == TextBlockKind.caption;
  bool credit(Block b) =>
      b is TextBlock &&
      (b.kind == TextBlockKind.quoteAttribution ||
          RegExp(r'^[—–]\s*\S').hasMatch(b.plainText.trim()));
  for (var s = 0; s + 1 < boundaries.length; s++) {
    final start = boundaries[s], end = boundaries[s + 1];
    final groups = <(int, int, int)>[];
    for (var i = start; i < end;) {
      var j = i + 1;
      if (blocks[i] is ImageBlock || caption(blocks[i])) {
        while (j < end && (blocks[j] is ImageBlock || caption(blocks[j]))) {
          j++;
        }
      } else if (j < end &&
          credit(blocks[j]) &&
          (blocks[i] is TextBlock || blocks[i] is QuoteBlock)) {
        j++;
      }
      groups.add((
        i,
        j,
        blocks.sublist(i, j).fold(0, (sum, b) => sum + semanticTextLength(b)),
      ));
      i = j;
    }
    for (var g = 0; g < groups.length;) {
      var next = g + 1;
      var chars = groups[g].$3;
      while (next < groups.length &&
          chars + groups[next].$3 <= characterBudget) {
        chars += groups[next].$3;
        next++;
      }
      result.add(
        SemanticBatch(
          groups[g].$1,
          groups[next - 1].$2,
          start,
          end,
          groups[g > 0 ? g - 1 : g].$1,
          groups[next < groups.length ? next : next - 1].$2,
        ),
      );
      g = next;
    }
  }
  return result;
}

/// Only visible subsections activate work. Visible batches lead, then the
/// remaining batches of those subsections in original reading order.
List<SemanticBatch> demandedSemanticBatches(
  List<SemanticBatch> plan,
  Set<int> visible,
) {
  final active = plan.where((batch) => visible.any(batch.contains)).toList();
  return [
    ...active,
    ...plan.where(
      (batch) => !active.contains(batch) && active.any(batch.sameSubsection),
    ),
  ];
}
