import '../ir/ir.dart';
import '../ir/inline_content.dart';

List<Inline> translationInlines(List<Inline> inlines) => coalesceReferences(
  detectWebLinks([
    for (final inline in inlines)
      if (inline is InlineImageRun && inline.image.formula != null)
        MathInline(
          inline.image.formula!.latex,
          originalImage: inline.image.href,
          originalInlineImage: inline,
          equationNumber: inline.image.formula!.equationNumber,
        )
      else
        inline,
  ]),
);

String? websiteUrl(String value) {
  final text = value.trim();
  if (text.isEmpty || text.contains(RegExp(r'\s|[<>"@]'))) return null;
  final explicit = RegExp(r'^https?://', caseSensitive: false).hasMatch(text);
  final uri = Uri.tryParse(explicit ? text : 'https://$text');
  if (uri == null ||
      !const {'https', 'http'}.contains(uri.scheme) ||
      uri.userInfo.isNotEmpty ||
      uri.host.isEmpty) {
    return null;
  }
  final host = uri.host.toLowerCase();
  if (!explicit &&
      !RegExp(
        r'^(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+(?:com|org|net|edu|gov|io|dev|app|ai|co|uk|cn|de|fr|jp|info|me|tech)$',
      ).hasMatch(host)) {
    return null;
  }
  return uri.toString();
}

List<Inline> detectWebLinks(List<Inline> inlines) {
  final output = <Inline>[];
  for (final inline in inlines) {
    if (inline is! TextRun ||
        inline.style.inlineCitation > 0 ||
        inline.style.inlineRole != InlineRole.normal ||
        inline.style.linkRole != LinkRole.normal) {
      output.add(inline);
      continue;
    }
    if (inline.link != null) {
      final url = websiteUrl(inline.link!);
      output.add(
        url == null
            ? inline
            : withRun(
                inline,
                inline.text,
                style: inline.style.copyWith(website: true),
                link: url,
              ),
      );
      continue;
    }
    var at = 0;
    for (final match in RegExp(
      r'(?:https?://|www\.)?[a-zA-Z0-9][^\s<>"\[\],;\u0080-\uffff]*',
    ).allMatches(inline.text)) {
      if (match.start > 0 &&
          RegExp(r'[a-zA-Z0-9@._-]').hasMatch(inline.text[match.start - 1])) {
        continue;
      }
      var raw = match.group(0)!.replaceFirst(RegExp(r'[.,;:!?]+$'), '');
      while (raw.endsWith(')') &&
          ')'.allMatches(raw).length > '('.allMatches(raw).length) {
        raw = raw.substring(0, raw.length - 1);
      }
      final url = websiteUrl(raw);
      if (url == null) continue;
      if (at < match.start) {
        output.add(withRun(inline, inline.text.substring(at, match.start)));
      }
      output.add(
        withRun(
          inline,
          raw,
          style: inline.style.copyWith(website: true),
          link: url,
        ),
      );
      at = match.start + raw.length;
    }
    if (at < inline.text.length) {
      output.add(withRun(inline, inline.text.substring(at)));
    }
  }
  return output;
}

/// One marker per reference even when authored emphasis splits it into runs.
List<Inline> coalesceReferences(List<Inline> inlines) {
  final out = <Inline>[];
  for (final inline in inlines) {
    if (inline is TextRun && out.lastOrNull is TextRun) {
      final previous = out.last as TextRun;
      if ((inline.style.inlineCitation > 0 &&
              inline.style.inlineCitation == previous.style.inlineCitation) ||
          (inline.style.website &&
              previous.style.website &&
              inline.link == previous.link)) {
        out[out.length - 1] = withRun(previous, previous.text + inline.text);
        continue;
      }
    }
    out.add(inline);
  }
  return out;
}
