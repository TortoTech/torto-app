import '../ir/ir.dart';
import '../ir/inline_content.dart';
import 'focus_layout.dart';

bool isNumberedFootnote(TextRun run) =>
    run.style.inlineCitation == 0 &&
    (run.style.inlineRole == InlineRole.footnote ||
        (run.link?.contains('#') == true &&
            (run.style.linkRole == LinkRole.footnoteReference ||
                (run.style.linkRole == LinkRole.normal &&
                    run.style.baseline == TextBaselineShift.superscript))));

/// Match desktop scopes: a paragraph/composite block, or a complete list with
/// its introduction. Number before sentence splitting and pagination.
Section numberFootnotes(Section section) {
  final scopes = <Block, int>{};
  for (final group in FocusUnitBuilder.build(section.blocks).values) {
    if (group.any((b) => b is TextBlock && b.kind == TextBlockKind.listItem)) {
      final scope = scopes.length;
      for (final block in group) {
        scopes[block] = scope;
      }
    }
  }
  final counts = <int, int>{};
  final previousStarts = <int, int>{};
  final blocks = <Block>[];
  for (var b = 0; b < section.blocks.length; b++) {
    final block = section.blocks[b];
    final scope = scopes[block];
    final translated =
        block is TextBlock && block.nodeId.endsWith('@translation');
    var next = scope == null
        ? 0
        : (translated ? previousStarts[scope] ?? 0 : counts[scope] ?? 0);
    if (scope != null && !translated) previousStarts[scope] = next;
    final numbers = Map<TextRun, int>.identity();
    for (final text in blockTexts(block)) {
      final values = text.inlines;
      for (var i = 0; i < values.length;) {
        final first = values[i];
        if (first is! TextRun || !isNumberedFootnote(first)) {
          i++;
          continue;
        }
        final group = <TextRun>[first];
        i++;
        while (i < values.length && values[i] is TextRun) {
          final run = values[i] as TextRun;
          if (!isNumberedFootnote(run) ||
              run.link != first.link ||
              run.style.inlineRole != first.style.inlineRole ||
              (first.link != null && run.text == first.text)) {
            break;
          }
          group.add(run);
          i++;
        }
        if (group.every((run) => run.text.trim().isEmpty)) continue;
        next++;
        for (final run in group) {
          numbers[run] = next;
        }
      }
    }
    if (scope != null && !translated) {
      counts[scope] = next;
    }
    final hasReferences =
        numbers.isNotEmpty ||
        blockTexts(block).any(
          (text) => text.inlines.whereType<TextRun>().any(
            (run) => run.style.inlineCitation > 0,
          ),
        );
    final referenceScope =
        '${section.spineIndex}:${scope == null ? 'b$b' : 'l$scope'}';
    blocks.add(
      !hasReferences
          ? block
          : mapBlockContent(
              block,
              (text) => withInlines(text, [
                for (final inline in text.inlines)
                  if (inline is TextRun &&
                      (numbers.containsKey(inline) ||
                          inline.style.inlineCitation > 0))
                    withRun(
                      inline,
                      inline.text,
                      style: inline.style.copyWith(
                        footnoteNumber: numbers[inline],
                        referenceScope: referenceScope,
                      ),
                    )
                  else
                    inline,
              ]),
            ),
    );
  }
  return withBlocks(section, blocks);
}

List<Inline> coalesceNumberedFootnotes(List<Inline> inlines) {
  final out = <Inline>[];
  for (final inline in inlines) {
    final previous = out.lastOrNull;
    if (inline is TextRun &&
        previous is TextRun &&
        inline.style.footnoteNumber > 0 &&
        inline.style.footnoteNumber == previous.style.footnoteNumber &&
        inline.link == previous.link) {
      out[out.length - 1] = withRun(previous, previous.text + inline.text);
    } else {
      out.add(inline);
    }
  }
  return out;
}
