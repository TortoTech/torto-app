import '../ir/ir.dart';
import '../ir/inline_content.dart';
import 'formula_validation.dart';

class MathText {
  final String text;
  final Map<int, int> boundaries;
  final List<(int, int)> protected;
  MathText(this.text, this.boundaries, this.protected);
}

MathText mathText(TextBlock block) {
  final text = StringBuffer();
  final boundaries = <int, int>{0: 0};
  final protected = <(int, int)>[];
  var offset = 0;
  for (final inline in block.inlines) {
    if (inline is TextRun) {
      final start = offset;
      if (inline.link != null ||
          inline.style.inlineRole != InlineRole.normal ||
          inline.style.linkRole != LinkRole.normal ||
          inline.style.inlineCitation > 0) {
        boundaries[text.length] = offset;
        text.write('<protected/>');
        offset += inline.text.runes.length;
        protected.add((start, offset));
        boundaries[text.length] = offset;
        continue;
      }
      final tags = <String>[
        if (inline.style.bold) 'b',
        if (inline.style.italic) 'i',
        if (inline.style.baseline == TextBaselineShift.superscript) 'sup',
        if (inline.style.baseline == TextBaselineShift.subscript) 'sub',
      ];
      boundaries[text.length] = offset;
      for (final tag in tags) {
        text.write('<$tag>');
      }
      for (final rune in inline.text.runes) {
        boundaries[text.length] = offset;
        text.write(switch (rune) {
          38 => '&amp;',
          60 => '&lt;',
          62 => '&gt;',
          _ => String.fromCharCode(rune),
        });
        offset++;
        boundaries[text.length] = offset;
      }
      for (final tag in tags.reversed) {
        text.write('</$tag>');
      }
      boundaries[text.length] = offset;
      if (inline.link != null ||
          inline.style.inlineRole != InlineRole.normal ||
          inline.style.linkRole != LinkRole.normal ||
          inline.style.inlineCitation > 0) {
        protected.add((start, offset));
      }
    } else {
      final len = inline is BreakInline
          ? 1
          : inline is MathInline
          ? inline.sourceText.runes.length
          : 0;
      protected.add((offset, offset + (len > 0 ? len : 1)));
      text.write('<protected/>');
      offset += len;
      boundaries[text.length] = offset;
    }
  }
  return MathText(text.toString(), boundaries, protected);
}

List<Map<String, dynamic>> citationCandidates(Section section) {
  final out = <Map<String, dynamic>>[];
  for (var b = 0; b < section.blocks.length; b++) {
    final paragraphs = blockTexts(section.blocks[b]);
    for (var p = 0; p < paragraphs.length; p++) {
      final paragraph = paragraphs[p];
      if (paragraph.source == null ||
          !const {
            TextBlockKind.paragraph,
            TextBlockKind.blockquote,
            TextBlockKind.listItem,
          }.contains(paragraph.kind)) {
        continue;
      }
      final chars = paragraph.plainText.runes.toList();
      final stack = <int>[];
      var start = 0;
      final encoded = mathText(paragraph);
      for (var i = 0; i < chars.length; i++) {
        final c = chars[i];
        const pairs = {40: 41, 91: 93, 0xff08: 0xff09, 0xff3b: 0xff3d};
        if (pairs.containsKey(c)) {
          if (stack.isEmpty) start = i;
          stack.add(pairs[c]!);
        } else if (stack.isNotEmpty && c == stack.last) {
          stack.removeLast();
          if (stack.isNotEmpty) continue;
          if (i - start >= 600 ||
              encoded.protected.any((r) => r.$1 < i + 1 && start < r.$2)) {
            continue;
          }
          final value = String.fromCharCodes(chars.sublist(start, i + 1));
          if (!RegExp(r'[0-9]').hasMatch(value) ||
              (chars[start] != 91 &&
                  chars[start] != 0xff3b &&
                  RegExp(r'\p{L}', unicode: true).allMatches(value).length <
                      2)) {
            continue;
          }
          out.add({
            'id': out.length,
            'block': b,
            'paragraph': p,
            'start': start,
            'end': i + 1,
            'text': value,
            'before': String.fromCharCodes(
              chars.sublist((start - 120).clamp(0, chars.length), start),
            ),
            'after': String.fromCharCodes(
              chars.sublist(i + 1, (i + 121).clamp(0, chars.length)),
            ),
          });
        }
      }
    }
  }
  return out;
}

List<Map<String, dynamic>> resolveInlineProposals(
  Section section,
  List<int> citations,
  List<dynamic> formulas,
  int start,
  int end,
) {
  final out = <Map<String, dynamic>>[];
  final candidates = citationCandidates(section);
  for (final id in citations.toSet()) {
    if (id < 0 || id >= candidates.length) continue;
    final c = candidates[id];
    if (c['block'] < start || c['block'] >= end) continue;
    out.add({
      'kind': 'citation',
      for (final key in ['block', 'paragraph', 'start', 'end', 'text'])
        key: c[key],
    });
  }
  for (final proposal in formulas) {
    try {
      final b = proposal['block'] as int, p = proposal['paragraph'] as int;
      if (b < start || b >= end) continue;
      final block = blockTexts(section.blocks[b])[p];
      if (block.source == null) continue;
      final original = proposal['original'] as String,
          latex = proposal['latex'] as String;
      if (original.trim().isEmpty || formulaError(latex) != null) continue;
      final encoded = mathText(block);
      final hits = original.allMatches(encoded.text).toList();
      final matches = hits
          .where(
            (m) =>
                hits.length == 1 ||
                (encoded.text
                        .substring(0, m.start)
                        .endsWith(proposal['before'] as String? ?? '') &&
                    encoded.text
                        .substring(m.end)
                        .startsWith(proposal['after'] as String? ?? '')),
          )
          .toList();
      if (matches.length != 1) continue;
      final a = encoded.boundaries[matches.single.start],
          z = encoded.boundaries[matches.single.end];
      if (a == null ||
          z == null ||
          a >= z ||
          encoded.protected.any((r) => r.$1 < z && a < r.$2)) {
        continue;
      }
      var offset = 0, valid = true;
      for (final inline in block.inlines) {
        if (inline is TextRun) {
          final len = inline.text.runes.length;
          if (inline.style.baseline != TextBaselineShift.none &&
              ((a >= offset && a < offset + len) ||
                  (z >= offset && z < offset + len))) {
            valid = false;
          }
          offset += len;
        } else if (inline is BreakInline) {
          offset++;
        }
      }
      if (!valid ||
          out.any(
            (g) =>
                g['kind'] == 'citation' &&
                g['block'] == b &&
                g['paragraph'] == p &&
                g['start'] < z &&
                a < g['end'],
          )) {
        continue;
      }
      if (out.any(
        (g) =>
            g['kind'] == 'text_formula' &&
            g['block'] == b &&
            g['paragraph'] == p &&
            g['start'] == a &&
            g['end'] == z &&
            g['latex'] == latex,
      )) {
        continue;
      }
      out.add({
        'kind': 'text_formula',
        'block': b,
        'paragraph': p,
        'start': a,
        'end': z,
        'text': String.fromCharCodes(block.plainText.runes.skip(a).take(z - a)),
        'latex': latex,
      });
    } on Object {
      /* Invalid siblings do not discard valid proposals. */
    }
  }
  // Reject all overlapping formula proposals, not just whichever arrived last.
  return out
      .where(
        (g) =>
            g['kind'] != 'text_formula' ||
            !out.any(
              (other) =>
                  !identical(g, other) &&
                  g['block'] == other['block'] &&
                  g['paragraph'] == other['paragraph'] &&
                  g['start'] < other['end'] &&
                  other['start'] < g['end'],
            ),
      )
      .toList();
}

bool validInlineAnnotation(
  Section section,
  Map<String, dynamic> g,
  int start,
  int end,
) {
  try {
    final b = g['block'] as int,
        p = g['paragraph'] as int,
        a = g['start'] as int,
        z = g['end'] as int;
    if (b < start || b >= end || p < 0 || a < 0 || z <= a) return false;
    final block = blockTexts(section.blocks[b])[p];
    if (z > block.plainText.runes.length) return false;
    if (String.fromCharCodes(block.plainText.runes.skip(a).take(z - a)) !=
        g['text']) {
      return false;
    }
    if (g['kind'] == 'citation') {
      return citationCandidates(section).any(
        (c) =>
            c['block'] == b &&
            c['paragraph'] == p &&
            c['start'] == a &&
            c['end'] == z &&
            c['text'] == g['text'],
      );
    }
    return g['kind'] == 'text_formula' &&
        formulaError(g['latex'] as String) == null &&
        !mathText(block).protected.any((r) => r.$1 < z && a < r.$2);
  } on Object {
    return false;
  }
}

List<Inline> applyTextAnnotations(
  TextBlock text,
  List<Map<String, dynamic>> annotations,
) {
  final positioned = <Map<String, dynamic>>[];
  for (final g in annotations) {
    final original = g['text'] as String;
    final exact = original.allMatches(text.plainText).toList();
    final a = g['start'] as int, z = g['end'] as int;
    int? found;
    if (String.fromCharCodes(text.plainText.runes.skip(a).take(z - a)) ==
        original) {
      found = a;
    } else if (exact.length == 1) {
      found = text.plainText.substring(0, exact.single.start).runes.length;
    }
    if (found != null) {
      positioned.add({
        ...g,
        'start': found,
        'end': found + original.runes.length,
      });
    }
  }
  positioned.sort((a, b) => (a['start'] as int).compareTo(b['start'] as int));
  final out = <Inline>[];
  var offset = 0, ordinal = 0;
  final mathOriginal = <Map<String, dynamic>, List<TextRun>>{};
  for (final g in positioned) {
    if (g['kind'] == 'citation') g['ordinal'] = ++ordinal;
  }
  for (final inline in text.inlines) {
    if (inline is! TextRun) {
      out.add(inline);
      offset += inline is BreakInline
          ? (inline.synthetic ? 0 : 1)
          : inline is MathInline
          ? inline.sourceText.runes.length
          : 0;
      continue;
    }
    final chars = inline.text.runes.toList();
    var at = 0;
    while (at < chars.length) {
      final pos = offset + at;
      final g = positioned
          .where((g) => g['start'] <= pos && pos < g['end'])
          .firstOrNull;
      final next =
          (g == null
              ? positioned
                    .where((g) => g['start'] > pos)
                    .map((g) => g['start'] as int)
                    .firstOrNull
              : g['end'] as int) ??
          offset + chars.length;
      final last = next.clamp(pos + 1, offset + chars.length);
      final part = withRun(
        inline,
        String.fromCharCodes(chars.sublist(at, last - offset)),
      );
      if (g == null) {
        out.add(part);
      } else if (g['kind'] == 'citation') {
        out.add(
          withRun(
            part,
            part.text,
            style: part.style.copyWith(inlineCitation: g['ordinal'] as int),
          ),
        );
      } else {
        final runs = mathOriginal.putIfAbsent(g, () => []);
        runs.add(part);
        if (last == g['end']) {
          out.add(
            MathInline(
              g['latex'] as String,
              original: List.unmodifiable(runs),
              display: (g['text'] as String).trim() == text.plainText.trim(),
            ),
          );
        }
      }
      at = last - offset;
    }
    offset += chars.length;
  }
  return out;
}

Section composeInlineAnnotations(
  Section original,
  Section displayed,
  List<Map<String, dynamic>> groups,
) {
  final byNode = <String, List<Map<String, dynamic>>>{};
  for (final g in groups.where(
    (g) => const {'citation', 'text_formula'}.contains(g['kind']),
  )) {
    final source = blockTexts(
      original.blocks[g['block'] as int],
    )[g['paragraph'] as int];
    final key = source.source?.start.node ?? source.nodeId;
    byNode.putIfAbsent(key, () => []).add(g);
  }
  if (byNode.isEmpty) return displayed;
  return withBlocks(displayed, [
    for (final block in displayed.blocks)
      mapBlockContent(block, (text) {
        final annotations = byNode[text.source?.start.node ?? text.nodeId];
        if (annotations == null ||
            text.inlines.any(
              (inline) => inline is TextRun && inline.style.inlineCitation > 0,
            )) {
          return text;
        }
        return withInlines(text, applyTextAnnotations(text, annotations));
      }),
  ]);
}
