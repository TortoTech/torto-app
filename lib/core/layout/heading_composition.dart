import '../ir/ir.dart';
import '../ir/inline_content.dart';

class HeadingComposition {
  final TextBlock ordinal, title;
  final TextBlock? translatedOrdinal, translatedTitle;
  final int consumed;
  const HeadingComposition(
    this.ordinal,
    this.title,
    this.translatedOrdinal,
    this.translatedTitle,
    this.consumed,
  );

  static HeadingComposition? at(List<Block> blocks, int start) {
    if (blocks[start]
        case TextBlock(kind: TextBlockKind.heading, headingOrdinal: true) &&
            final ordinal) {
      var next = start + 1;
      bool companion(TextBlock original, Block candidate) =>
          candidate is TextBlock &&
          candidate.kind == original.kind &&
          candidate.headingLevel == original.headingLevel &&
          candidate.nodeId == '${original.nodeId}@translation';
      TextBlock? translatedOrdinal;
      if (next < blocks.length && companion(ordinal, blocks[next])) {
        translatedOrdinal = blocks[next++] as TextBlock;
      }
      if (next >= blocks.length || blocks[next] is! TextBlock) return null;
      final title = blocks[next++] as TextBlock;
      if (title.kind != TextBlockKind.heading ||
          title.headingOrdinal ||
          title.headingLevel != ordinal.headingLevel) {
        return null;
      }
      TextBlock? translatedTitle;
      if (next < blocks.length && companion(title, blocks[next])) {
        translatedTitle = blocks[next++] as TextBlock;
      }
      // A partially received bilingual pair must keep its translated label.
      if (translatedOrdinal != null && translatedTitle == null) return null;
      return HeadingComposition(
        ordinal,
        title,
        translatedOrdinal,
        translatedTitle,
        next - start,
      );
    }
    return null;
  }

  static TextBlock presentation(TextBlock block, {bool reused = false}) =>
      TextBlock(
        kind: block.kind,
        headingLevel: block.headingLevel,
        inlines: [
          for (final i in block.inlines)
            if (i is TextRun)
              withRun(
                i,
                i.text,
                style: i.style.copyWith(clearKeywordSize: true),
              )
            else
              i,
        ],
        nodeId: reused ? '${block.nodeId}@translation' : block.nodeId,
        source: reused ? null : block.source,
        style: block.style,
      );

  bool get canReuseOrdinal => RegExp(
    r'^\s*(?:[0-9０-９]+|[IVXLCDM]+)[.、：:]?\s*$',
  ).hasMatch(ordinal.plainText);
}
