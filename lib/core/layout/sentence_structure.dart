import 'package:icu4x/icu4x.dart' show SentenceSegmenter;

import '../ir/ir.dart';
import '../ir/inline_content.dart';

/// Desktop-style sentence subparagraphs. Added breaks are presentation-only:
/// the original block, inline objects and canonical source text remain intact.
class SentenceStructure {
  static final _segmenter = SentenceSegmenter();
  static const _pairs = {
    '“': '”',
    '‘': '’',
    '《': '》',
    '〈': '〉',
    '（': '）',
    '(': ')',
    '【': '】',
    '[': ']',
    '〔': '〕',
    '「': '」',
    '『': '』',
    '{': '}',
  };
  static const _continuations = '，、；：,;:';
  static const _terminators = '。！？.!?';
  static const _parentheses = '（(【[〔';
  static final _word = RegExp(r'[a-zA-Z0-9]');
  static final _abbreviation = RegExp(
    r'(?:\b(?:Mr|Mrs|Ms|Dr|Prof|Sr|Jr|St|vs|etc|e\.g|i\.e)|\b[A-Z]|(?:\b[A-Za-z]\.)+[A-Za-z])\.$',
    caseSensitive: false,
  );

  static bool supports(TextBlockKind kind) => switch (kind) {
    TextBlockKind.paragraph ||
    TextBlockKind.blockquote ||
    TextBlockKind.caption ||
    TextBlockKind.listItem => true,
    _ => false,
  };

  static List<Inline> apply(
    List<Inline> inlines, {
    bool splitSemicolons = true,
  }) {
    final buffer = StringBuffer();
    final spans = <(Inline, int, int)>[];
    final protected = <(int, int)>[];
    final footnotes = <(int, int)>[];
    for (final inline in inlines) {
      final start = buffer.length;
      final value = switch (inline) {
        TextRun(:final text) => text,
        MathInline() =>
          inline.sourceText.isEmpty ? inline.latex : inline.sourceText,
        BreakInline() => '\n',
        InlineImageRun() => '\uFFFC',
      };
      buffer.write(value);
      final end = buffer.length;
      spans.add((inline, start, end));
      final note = switch (inline) {
        TextRun(:final style) =>
          style.linkRole == LinkRole.footnoteReference ||
              style.inlineRole == InlineRole.footnote ||
              style.inlineCitation > 0,
        MathInline(:final display, :final latex) =>
          !display && RegExp(r'^\^\{?\d+\}?$').hasMatch(latex.trim()),
        _ => false,
      };
      if (note || inline is MathInline || inline is InlineImageRun) {
        protected.add((start, end));
      }
      if (note) footnotes.add((start, end));
    }
    final text = buffer.toString();
    if (text.trim().isEmpty) return inlines;
    final cuts = boundaries(
      text,
      protected: protected,
      footnotes: footnotes,
      splitSemicolons: splitSemicolons,
    );
    if (cuts.isEmpty) return inlines;
    final output = <Inline>[];
    var cutIndex = 0;
    for (final (inline, start, end) in spans) {
      while (cutIndex < cuts.length && cuts[cutIndex] == start) {
        output.add(const BreakInline(synthetic: true));
        cutIndex++;
      }
      if (inline is TextRun) {
        var local = start;
        while (cutIndex < cuts.length &&
            cuts[cutIndex] > local &&
            cuts[cutIndex] < end) {
          final cut = cuts[cutIndex++];
          output.add(withRun(inline, text.substring(local, cut)));
          output.add(const BreakInline(synthetic: true));
          local = cut;
        }
        if (local < end) {
          output.add(withRun(inline, text.substring(local, end)));
        }
      } else {
        output.add(inline);
      }
    }
    return output;
  }

  /// UTF-16 boundaries, matching ICU and Dart substring. Source mapping remains
  /// Unicode-scalar based in the layout engine, including non-BMP characters.
  static List<int> boundaries(
    String text, {
    List<(int, int)> protected = const [],
    List<(int, int)> footnotes = const [],
    bool splitSemicolons = true,
  }) {
    bool inside(int i) => protected.any((r) => r.$1 <= i && i < r.$2);
    bool space(int i) => i >= 0 && i < text.length && text[i].trim().isEmpty;
    int skipSpace(int i, {bool newline = true}) {
      while (i < text.length && space(i) && (newline || text[i] != '\n')) {
        i++;
      }
      return i;
    }

    final masked = text.codeUnits.toList();
    for (final (start, end) in protected) {
      for (var i = start; i < end; i++) {
        masked[i] = 32;
      }
    }
    final iterator = _segmenter.segment(String.fromCharCodes(masked));
    final candidates = <int>{};
    for (var end = iterator.next(); end >= 0; end = iterator.next()) {
      if (end > 0 && end < text.length) {
        final prefix = text.substring(0, end).trimRight();
        // ICU's generic sentence boundaries need the abbreviation/initial
        // protection also used by desktop sentence segmentation.
        if (!_abbreviation.hasMatch(prefix)) candidates.add(end);
      }
    }

    final pairs = <(int, int)>[];
    final stack = <(String, int)>[];
    for (var i = 0; i < text.length; i++) {
      if (inside(i)) continue;
      final c = text[i];
      if (c == '"' || c == "'") {
        var slashes = 0;
        for (var j = i - 1; j >= 0 && text[j] == '\\'; j--) {
          slashes++;
        }
        final before = i > 0 && _word.hasMatch(text[i - 1]);
        final after = i + 1 < text.length && _word.hasMatch(text[i + 1]);
        if (slashes.isOdd || c == "'" && before && after) continue;
        if (stack.isNotEmpty && stack.last.$1 == c) {
          pairs.add((stack.removeLast().$2, i + 1));
        } else if (c == '"' || !before) {
          stack.add((c, i));
        }
        continue;
      }
      if (_pairs[c] case final closer?) {
        stack.add((closer, i));
        continue;
      }
      if (_pairs.containsValue(c)) {
        final index = stack.lastIndexWhere((entry) => entry.$1 == c);
        if (index >= 0) {
          pairs.add((stack[index].$2, i + 1));
          stack.removeRange(index, stack.length);
        }
        continue;
      }
      if (stack.isEmpty &&
          ('。！？'.contains(c) || splitSemicolons && ';；'.contains(c))) {
        var end = i + 1;
        while (end < text.length &&
            (space(end) || '；;。.!！?？'.contains(text[end]))) {
          end++;
        }
        candidates.add(end);
      }
    }
    // An unmatched quote/bracket protects its remaining contents as well.
    pairs.addAll(stack.map((entry) => (entry.$2, text.length)));
    for (final pair in pairs) {
      if (!'“‘「『"'.contains(text[pair.$1])) continue;
      var last = pair.$2 - 1;
      while (last > pair.$1 && ('”’」』"'.contains(text[last]) || space(last))) {
        last--;
      }
      if (_terminators.contains(text[last])) candidates.add(skipSpace(pair.$2));
    }

    var cuts = <int>{};
    for (var boundary in candidates) {
      var changed = true;
      while (changed) {
        changed = false;
        for (final (start, end) in [...pairs, ...protected]) {
          if (start < boundary && boundary < end) {
            boundary = end;
            changed = true;
          }
        }
      }
      boundary = skipSpace(boundary);
      if (boundary > 0 && boundary < text.length) cuts.add(boundary);
    }
    List<(int, int)> atoms(Set<int> cuts) {
      final ends = [...cuts, text.length]..sort();
      var start = 0;
      final result = <(int, int)>[];
      for (final end in ends) {
        if (text.substring(start, end).trim().isNotEmpty) {
          result.add((start, end));
        } else if (result.isNotEmpty) {
          result[result.length - 1] = (result.last.$1, end);
        }
        start = end;
      }
      return result;
    }

    // ICU may include an opening parenthesis in the preceding sentence.
    // Extending that boundary must not split a noun prefix from its predicate.
    for (final (start, end) in pairs) {
      if (!_parentheses.contains(text[start]) || end >= text.length) continue;
      final interior = text
          .substring(start + 1, end - 1)
          .trimRight()
          .replaceFirst(RegExp(r'[”’」』]+$'), '')
          .trimRight();
      if (interior.isNotEmpty &&
          !_terminators.contains(interior[interior.length - 1])) {
        cuts.remove(end);
      }
    }
    var parts = atoms(cuts);
    for (var i = 1; i < parts.length; i++) {
      final (start, end) = parts[i];
      final first = skipSpace(start);
      final last = text.substring(start, end).trimRight().length + start;
      if (first == end) continue;
      final completeAside =
          _parentheses.contains(text[first]) &&
          pairs.any((pair) => pair.$1 == first && pair.$2 == last);
      if (completeAside || _continuations.contains(text[first])) {
        cuts.remove(start);
      }
    }
    parts = atoms(cuts);
    for (var i = 1; i < parts.length; i++) {
      final (start, end) = parts[i];
      final first = skipSpace(start);
      final pair = pairs
          .where((p) => p.$1 == first && _parentheses.contains(text[first]))
          .firstOrNull;
      if (pair == null || pair.$2 >= end) continue;
      final prior = text.substring(parts[i - 1].$1, start).trimRight();
      final interior = text
          .substring(pair.$1 + 1, pair.$2 - 1)
          .trimRight()
          .replaceFirst(RegExp(r'[”’」』]+$'), '')
          .trimRight();
      final quoteSuffix =
          prior.isNotEmpty && '”’」』'.contains(prior[prior.length - 1]);
      final sentenceAside =
          prior.isNotEmpty &&
          _terminators.contains(prior[prior.length - 1]) &&
          !text
              .substring(parts[i - 1].$1 + prior.length, first)
              .contains('\n') &&
          interior.isNotEmpty &&
          _terminators.contains(interior[interior.length - 1]);
      if (quoteSuffix || sentenceAside) {
        cuts.remove(start);
        cuts.add(pair.$2);
      }
    }

    final attached = <int>{};
    for (var cut in cuts) {
      var changed = true;
      while (changed) {
        changed = false;
        final next = skipSpace(cut, newline: false);
        for (final (start, end) in footnotes) {
          if (start <= next && next < end) {
            cut = skipSpace(end, newline: false);
            changed = true;
          }
        }
      }
      // Preserve authored hard breaks without inserting another blank line.
      final before = text.substring(0, cut);
      final whitespace = RegExp(r'\s*$').firstMatch(before)!.group(0)!;
      if (cut > 0 &&
          cut < text.length &&
          !whitespace.contains('\n') &&
          !text.substring(cut).startsWith('\n')) {
        attached.add(cut);
      }
    }
    return attached.toList()..sort();
  }
}
