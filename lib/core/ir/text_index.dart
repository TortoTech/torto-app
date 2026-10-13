import 'ir.dart';
import 'inline_content.dart';

/// A normalized source node shared by search, selection and annotation anchors.
class BookTextNode {
  final List<int>? sourceOffsets;
  int sourceOffset(int display) =>
      source.start.textOffset +
      (sourceOffsets == null
          ? display
          : sourceOffsets![display.clamp(0, sourceOffsets!.length - 1)]);
  final String? _displayId;
  String get displayId => _displayId ?? source.start.node;
  final SourceRange source;
  final String text;
  final bool selectable;
  const BookTextNode(
    this.source,
    this.text, {
    this.selectable = true,
    this.sourceOffsets,
    String? displayId,
  }) : _displayId = displayId;
}

Iterable<BookTextNode> sectionTextNodes(
  Section section, {
  bool includeNotes = false,
  bool includeImageText = false,
}) sync* {
  Iterable<BookTextNode> visit(Block block) sync* {
    switch (block) {
      case TextBlock():
        if (block.source != null) {
          final projection = includeImageText
              ? imageTextProjection(block.inlines)
              : null;
          yield BookTextNode(
            block.source!,
            projection?.$1 ?? block.plainText,
            sourceOffsets: projection?.$2,
            displayId: block.nodeId,
            selectable:
                !block.nodeId.endsWith('@rewrite') &&
                !block.inlines.any(
                  (run) =>
                      run is MathInline &&
                      run.original == null &&
                      run.originalImage == null,
                ),
          );
        }
      case QuoteBlock():
        for (final text in block.body) {
          yield* visit(text);
        }
        if (block.attribution != null) yield* visit(block.attribution!);
      case TableBlock():
        for (final text in block.before) {
          yield* visit(text);
        }
        for (final row in block.rows) {
          for (final cell in row.cells) {
            if (cell.source != null) {
              final projection = includeImageText
                  ? imageTextProjection(cell.inlines)
                  : null;
              yield BookTextNode(
                cell.source!,
                projection?.$1 ?? cell.plainText,
                sourceOffsets: projection?.$2,
                displayId: cell.nodeId,
                selectable: !cell.inlines.any(
                  (run) =>
                      run is MathInline &&
                      run.original == null &&
                      run.originalImage == null,
                ),
              );
            }
          }
        }
        for (final text in block.after) {
          yield* visit(text);
        }
      case FigureBlock():
        for (final image in block.images) {
          yield* visit(image);
        }
        for (final caption in block.captions) {
          yield* visit(caption);
        }
      case NoteBlock():
        if (includeNotes) {
          for (final child in block.blocks) {
            yield* visit(child);
          }
        }
      case SeparatorBlock():
        if (block.text != null) yield* visit(block.text!);
      case ImageBlock():
        if (includeImageText && block.ocrText != null && block.source != null) {
          final text = block.ocrText!.displayText;
          yield BookTextNode(
            block.source!,
            text,
            displayId:
                '${block.source!.start.spine.value}/${block.source!.start.node}@image-text',
            sourceOffsets: List.filled(text.runes.length + 1, 0),
          );
        }
      default:
        break;
    }
  }

  for (final block in section.blocks) {
    yield* visit(block);
  }
}

String sourceSlice(String text, int start, int end) {
  final scalars = text.runes.toList();
  if (start < 0 || end < start || end > scalars.length) {
    throw const FormatException('Invalid source range');
  }
  return String.fromCharCodes(scalars.sublist(start, end));
}

class TextMatch {
  final String? displayNodeId;
  final int? displayStart, displayEnd;

  /// Transient ordering hint; [range] carries the persistent section identity.
  final int sectionIndex;
  final String title, excerpt, text;
  final SourceRange range;
  const TextMatch(
    this.sectionIndex,
    this.title,
    this.excerpt,
    this.text,
    this.range, {
    this.displayNodeId,
    this.displayStart,
    this.displayEnd,
  });
}

/// Paragraph-level translation annotations resolve through original identity,
/// never by treating translated character offsets as original offsets.
Future<(List<SourceRange>, String)> resolveOriginalParagraphSelection(
  BookSource source,
  List<SourceRange> displayed, {
  String fallbackQuote = '',
}) async {
  final ranges = <SourceRange>[], quotes = <String>[];
  final seen = <String>{};
  for (final range in displayed) {
    if (!seen.add('${range.start.spine.value}/${range.start.node}')) continue;
    final index = source.book.indexOfSpine(range.start.spine);
    if (index < 0) throw StateError('Unknown original paragraph');
    final section = await source.parseSection(index);
    final node = sectionTextNodes(section, includeNotes: true)
        .where(
          (n) =>
              n.source.start.node == range.start.node &&
              n.source.start.spine == range.start.spine,
        )
        .firstOrNull;
    if (node == null) {
      SourceRange? owner;
      for (final block in section.blocks) {
        mapBlockContent(
          block,
          (text) => text,
          image: (image) {
            final candidate = image.source;
            if (candidate?.start.spine == range.start.spine &&
                candidate?.start.node == range.start.node) {
              owner = candidate;
            }
            return image;
          },
        );
      }
      if (owner == null || fallbackQuote.trim().isEmpty) {
        throw StateError('Unknown original paragraph');
      }
      ranges.add(owner!);
      quotes.add(fallbackQuote);
      continue;
    }
    if (!node.selectable) {
      throw StateError('Original paragraph is not selectable');
    }
    ranges.add(node.source);
    quotes.add(node.text);
  }
  if (ranges.isEmpty) throw StateError('No original paragraph selected');
  return (ranges, quotes.join('\n'));
}

/// Public matches use scalar offsets. Dart's RegExp UTF-16 indices are confined
/// to this string-operation adapter and never escape in a source range.
Iterable<(int, int)> sourceMatches(
  String text,
  String query, {
  bool caseSensitive = true,
}) sync* {
  if (query.isEmpty) return;
  final matcher = RegExp(
    RegExp.escape(query),
    caseSensitive: caseSensitive,
    unicode: true,
  );
  var units = 0, scalars = 0;
  for (final match in matcher.allMatches(text)) {
    scalars += text.substring(units, match.start).runes.length;
    final end = scalars + match.group(0)!.runes.length;
    yield (scalars, end);
    units = match.end;
    scalars = end;
  }
}
