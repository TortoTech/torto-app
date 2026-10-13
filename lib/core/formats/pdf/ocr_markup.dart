/// OCR prose sometimes contains an unquoted HTML tag name. Preserve it as text
/// without flattening genuine paired HTML tables or touching Markdown code.
String escapeUnpairedOcrTags(String markdown) {
  final protected = RegExp(
    r'```[\s\S]*?```|~~~[\s\S]*?~~~|`+[^`\n]*`+',
  ).allMatches(markdown).toList();
  final tags =
      RegExp(
            r'</?(div|table|thead|tbody|tfoot|tr|td|th|caption)\b[^>]*>',
            caseSensitive: false,
          )
          .allMatches(markdown)
          .where(
            (m) => !protected.any((p) => p.start <= m.start && m.start < p.end),
          )
          .toList();
  final stack = <RegExpMatch>[];
  final literal = <RegExpMatch>[];
  bool inline(RegExpMatch m) {
    final start = markdown.lastIndexOf('\n', m.start - 1) + 1;
    return markdown.substring(start, m.start).trim().isNotEmpty;
  }

  for (final tag in tags) {
    final value = tag[0]!;
    if (value.endsWith('/>')) continue;
    if (value.startsWith('</')) {
      final i = stack.lastIndexWhere(
        (open) => open[1]!.toLowerCase() == tag[1]!.toLowerCase(),
      );
      if (i >= 0) {
        stack.removeAt(i);
      } else if (inline(tag)) {
        literal.add(tag);
      }
    } else {
      stack.add(tag);
    }
  }
  literal.addAll(stack.where(inline));
  literal.sort((a, b) => b.start.compareTo(a.start));
  for (final tag in literal) {
    markdown = markdown.replaceRange(
      tag.start,
      tag.end,
      tag[0]!.replaceAll('<', '&lt;').replaceAll('>', '&gt;'),
    );
  }
  return markdown;
}
