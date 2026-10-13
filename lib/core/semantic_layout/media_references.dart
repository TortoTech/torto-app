import '../ir/ir.dart';
import '../ir/inline_content.dart';

class MediaReference {
  final int start, end;
  final String kind, number;
  const MediaReference(this.start, this.end, this.kind, this.number);
  String get href => 'torto-media:$kind/$number';
}

class MediaReferences {
  /// A complete parenthesized reference, rather than explanatory prose which
  /// happens to mention a figure. It can share bibliographic citation order.
  static bool isCitation(String text) {
    final value = text.trim();
    if (value.length < 3) return false;
    const pairs = {'(': ')', '（': '）', '[': ']', '［': '］'};
    if (pairs[value[0]] != value[value.length - 1]) return false;
    var body = value.substring(1, value.length - 1).trim();
    body = body.replaceFirst(
      RegExp(
        r'^(?:see\s+|cf\.\s*|e\.g\.,?\s*|参见|如见|如|见)',
        caseSensitive: false,
      ),
      '',
    );
    final refs = references(body);
    if (refs.isEmpty) return false;
    for (final ref in refs.reversed) {
      body = body.replaceRange(ref.start, ref.end, '');
    }
    return RegExp(
      r'^(?:\s|[,，、;；/&]|and\b|及|和|与)*$',
      caseSensitive: false,
    ).hasMatch(body);
  }

  static const _number =
      r'(?:[A-Z][.-]?)?[0-9０-９]+(?:[.．\-‐‑–][0-9０-９]+)*(?:[a-zA-Z]|\([a-zA-Z]\))?|[一二三四五六七八九十百零〇]+[A-Za-z]?';
  static final _label = RegExp(
    '(figures?|figs?\\.?|tables?|tab\\.?|图片|图表|插图|图版|表格|图|表)\\s*($_number)',
    caseSensitive: false,
  );
  static final _next = RegExp(
    '^\\s*(?:、|,|，|and\\b|及|和|与)\\s*($_number)',
    caseSensitive: false,
  );
  static String normalize(String value) {
    final buffer = StringBuffer();
    for (final r in value.runes) {
      if (r >= 0xFF10 && r <= 0xFF19) {
        buffer.writeCharCode(r - 0xFF10 + 48);
      } else {
        buffer.write(String.fromCharCode(r));
      }
    }
    final normalized = buffer
        .toString()
        .toLowerCase()
        .replaceAll(RegExp(r'[\s()]'), '')
        .replaceAll('．', '.')
        .replaceAll(RegExp('[‐‑–]'), '-');
    if (!RegExp(r'[一二三四五六七八九十百零〇]').hasMatch(normalized)) return normalized;
    const digits = {
      '零': 0,
      '〇': 0,
      '一': 1,
      '二': 2,
      '三': 3,
      '四': 4,
      '五': 5,
      '六': 6,
      '七': 7,
      '八': 8,
      '九': 9,
    };
    var total = 0, digit = 0;
    final suffix = StringBuffer();
    for (final c in normalized.split('')) {
      if (digits.containsKey(c)) {
        digit = digits[c]!;
      } else if (c == '十' || c == '百') {
        total += (digit == 0 ? 1 : digit) * (c == '十' ? 10 : 100);
        digit = 0;
      } else {
        suffix.write(c);
      }
    }
    return '${total + digit}$suffix';
  }

  static List<MediaReference> references(String text) {
    final result = <MediaReference>[];
    for (final match in _label.allMatches(text)) {
      if (match.start > 0 &&
          RegExp(r'[A-Za-z]').hasMatch(text[match.start - 1])) {
        continue;
      }
      final label = match[1]!.toLowerCase();
      final kind = label.startsWith('tab') || label.startsWith('表')
          ? 'table'
          : 'figure';
      result.add(
        MediaReference(match.start, match.end, kind, normalize(match[2]!)),
      );
      var at = match.end;
      while (at < text.length) {
        final next = _next.firstMatch(text.substring(at));
        if (next == null) break;
        result.add(
          MediaReference(at, at + next.end, kind, normalize(next[1]!)),
        );
        at += next.end;
      }
    }
    return result;
  }

  static String? captionKey(String text) {
    final first = references(text).firstOrNull;
    return first != null && text.substring(0, first.start).trim().isEmpty
        ? first.href
        : null;
  }

  static List<Inline> link(List<Inline> inlines) {
    bool eligible(Inline i) =>
        i is TextRun &&
        i is! RubyRun &&
        !(i is ImageTextRun && i.literal) &&
        i.link == null &&
        i.style.inlineCitation == 0 &&
        i.style.inlineRole == InlineRole.normal &&
        i.style.linkRole == LinkRole.normal;
    final out = <Inline>[];
    for (var i = 0; i < inlines.length;) {
      if (!eligible(inlines[i])) {
        out.add(inlines[i++]);
        continue;
      }
      final runs = <TextRun>[];
      while (i < inlines.length && eligible(inlines[i])) {
        runs.add(inlines[i++] as TextRun);
      }
      final refs = references(runs.map((r) => r.text).join());
      var base = 0;
      for (final run in runs) {
        final end = base + run.text.length;
        final cuts = <int>{base, end};
        for (final r in refs) {
          if (base < r.start && r.start < end) cuts.add(r.start);
          if (base < r.end && r.end < end) cuts.add(r.end);
        }
        final sorted = cuts.toList()..sort();
        for (var j = 0; j + 1 < sorted.length; j++) {
          final start = sorted[j], stop = sorted[j + 1];
          final ref = refs
              .where((r) => r.start <= start && stop <= r.end)
              .firstOrNull;
          out.add(
            withRun(
              run,
              run.text.substring(start - base, stop - base),
              link: ref?.href,
            ),
          );
        }
        base = end;
      }
    }
    return out;
  }
}
