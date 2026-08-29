import 'package:flutter_test/flutter_test.dart';
import 'package:torto/core/formats/toc_heading_promoter.dart';
import 'package:torto/core/ir/ir.dart';

void main() {
  test('path-only hints inspect only the first eight top-level blocks', () {
    final section = Section(
      spineIndex: 0,
      href: 'Text/chapter.xhtml',
      blocks: [
        for (var index = 0; index < 8; index++)
          TextBlock(inlines: [TextRun('Lead $index')]),
        TextBlock(inlines: const [TextRun('Late heading')]),
      ],
    );
    final hints = collectTocHeadingHints(const [
      TocEntry(label: 'Late heading', href: 'Text/chapter.xhtml'),
    ]);

    final result = promoteTocHeadings(section, hints['Text/chapter.xhtml']!);

    expect(result, same(section));
    expect((result.blocks.last as TextBlock).kind, TextBlockKind.paragraph);
  });

  test('nested TOC depth is clamped to h6', () {
    TocEntry nested(int depth) => depth == 7
        ? const TocEntry(label: 'Deep', href: 'Text/chapter.xhtml#deep')
        : TocEntry(label: 'Level $depth', children: [nested(depth + 1)]);

    final hints = collectTocHeadingHints([nested(1)]);

    expect(hints['Text/chapter.xhtml']!.single.level, 6);
  });
}
