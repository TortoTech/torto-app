import '../ir/ir.dart';
import '../ir/inline_content.dart';

Section markNoteReferences(Section section, Book book) {
  final paths = <String>{};
  void visit(List<TocEntry> entries) {
    for (final entry in entries) {
      if (!entry.href.contains('#') &&
          RegExp(
            r'^(?:footnotes?|endnotes?|notes?|脚注|尾注|注释|注解)(?:\s+\d+)?$',
            caseSensitive: false,
          ).hasMatch(entry.label.trim())) {
        paths.add(entry.href);
      }
      visit(entry.children);
    }
  }

  visit(book.toc);
  if (paths.isEmpty) return section;
  return withBlocks(section, [
    for (final block in section.blocks)
      mapBlockContent(
        block,
        (text) => withInlines(text, [
          for (final i in text.inlines)
            if (i is TextRun &&
                i is! RubyRun &&
                i.link != null &&
                i.link!.contains('#') &&
                paths.contains(i.link!.split('#').first) &&
                i.style.linkRole == LinkRole.normal &&
                (i.style.sizeScale <= .85 ||
                    i.style.baseline == TextBaselineShift.superscript) &&
                RegExp(
                  r'^[\s\[\]()（）【】.]*[0-9*†‡§]{1,8}[\s\[\]()（）【】.]*$',
                ).hasMatch(i.text))
              withRun(
                i,
                i.text,
                style: i.style.copyWith(linkRole: LinkRole.footnoteReference),
              )
            else
              i,
        ]),
      ),
  ]);
}
