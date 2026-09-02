import 'package:characters/characters.dart';

import '../ir/ir.dart';

class TranslationMarkupCodec {
  static final _tokenPattern = RegExp(
    r'</?(?:strong|em|i|cite|torto-italic|u|s|sup|sub|noteref|noteback|inlinefootnote)>|<torto-math-(\d+)/>',
  );

  static String encode(List<Inline> inlines) {
    final output = StringBuffer();
    var mathIndex = 0;
    for (final inline in inlines) {
      switch (inline) {
        case TextRun():
          final tags = <String>[];
          void open(String tag) {
            output.write('<$tag>');
            tags.add(tag);
          }

          if (inline.style.inlineRole == InlineRole.footnote) {
            open('inlinefootnote');
          }
          switch (inline.style.linkRole) {
            case LinkRole.normal:
              break;
            case LinkRole.footnoteReference:
              open('noteref');
            case LinkRole.footnoteBacklink:
              open('noteback');
          }
          if (inline.style.bold) open('strong');
          if (inline.style.emphasis) open('em');
          if (inline.style.alternateVoice) open('i');
          if (inline.style.citation) open('cite');
          if (inline.style.italic &&
              !inline.style.emphasis &&
              !inline.style.alternateVoice &&
              !inline.style.citation) {
            open('torto-italic');
          }
          if (inline.style.underline) open('u');
          if (inline.style.strikethrough) open('s');
          switch (inline.style.baseline) {
            case TextBaselineShift.none:
              break;
            case TextBaselineShift.superscript:
              open('sup');
            case TextBaselineShift.subscript:
              open('sub');
          }
          output.write(_escape(inline.text));
          for (final tag in tags.reversed) {
            output.write('</$tag>');
          }
        case BreakInline():
          output.write('\n');
        case MathInline():
          output.write('<torto-math-${mathIndex++}/>');
        case InlineImageRun():
          break;
      }
    }
    return output.toString();
  }

  static List<Inline> decode(
    String translated,
    List<Inline> original, {
    required String language,
  }) {
    _validateMathPlaceholders(translated, original);
    final math = original.whereType<MathInline>().toList(growable: false);
    final base = _neutralStyle(original);
    final output = <Inline>[];
    final stack = <_StyleFrame>[_StyleFrame('', base)];
    var cursor = 0;
    for (final match in _tokenPattern.allMatches(translated)) {
      _appendText(
        output,
        translated.substring(cursor, match.start),
        stack.last.style,
        original,
        language,
      );
      final token = match.group(0)!;
      final mathIndex = match.group(1);
      if (mathIndex != null) {
        output.add(math[int.parse(mathIndex)]);
      } else if (token.startsWith('</')) {
        final tag = token.substring(2, token.length - 1);
        if (stack.length == 1 || stack.last.tag != tag) {
          throw const FormatException('Translation changed inline markup.');
        }
        stack.removeLast();
      } else {
        final tag = token.substring(1, token.length - 1);
        stack.add(_StyleFrame(tag, _applyTag(stack.last.style, tag)));
      }
      cursor = match.end;
    }
    _appendText(
      output,
      translated.substring(cursor),
      stack.last.style,
      original,
      language,
    );
    if (stack.length != 1) {
      throw const FormatException('Translation left inline markup unclosed.');
    }
    _restoreInlineImages(output, original);
    return output;
  }

  static void _restoreInlineImages(List<Inline> output, List<Inline> original) {
    final originalLength = original.fold<int>(
      0,
      (total, inline) => total + _translationUnits(inline),
    );
    final translatedLength = output.fold<int>(
      0,
      (total, inline) => total + _translationUnits(inline),
    );
    var cursor = 0;
    final images = <(int, InlineImageRun)>[];
    for (final inline in original) {
      if (inline case InlineImageRun()) {
        final target = originalLength == 0
            ? 0
            : cursor * translatedLength ~/ originalLength;
        images.add((target, inline));
      } else {
        cursor += _translationUnits(inline);
      }
    }
    for (final (target, image) in images.reversed) {
      _insertInlineAtOffset(output, target, image);
    }
  }

  static int _translationUnits(Inline inline) => switch (inline) {
    TextRun(:final text) => text.characters.length,
    MathInline() || BreakInline() => 1,
    InlineImageRun() => 0,
  };

  static void _insertInlineAtOffset(
    List<Inline> output,
    int offset,
    Inline value,
  ) {
    var cursor = 0;
    for (var index = 0; index < output.length; index++) {
      final inline = output[index];
      final length = _translationUnits(inline);
      if (offset <= cursor) {
        output.insert(index, value);
        return;
      }
      if (inline case TextRun(
        :final text,
        :final style,
        :final link,
        :final language,
      ) when offset < cursor + length) {
        final graphemes = text.characters.toList(growable: false);
        final split = offset - cursor;
        final replacement = <Inline>[
          if (split > 0)
            TextRun(
              graphemes.take(split).join(),
              style: style,
              link: link,
              language: language,
            ),
          value,
          if (split < graphemes.length)
            TextRun(
              graphemes.skip(split).join(),
              style: style,
              link: link,
              language: language,
            ),
        ];
        output.replaceRange(index, index + 1, replacement);
        return;
      }
      cursor += length;
    }
    output.add(value);
  }

  static void _validateMathPlaceholders(
    String translated,
    List<Inline> original,
  ) {
    final expected = List<int>.generate(
      original.whereType<MathInline>().length,
      (index) => index,
    );
    final actual =
        RegExp(r'<torto-math-(\d+)/>')
            .allMatches(translated)
            .map((match) => int.parse(match.group(1)!))
            .toList()
          ..sort();
    if (actual.length != expected.length) {
      throw const FormatException('Translation changed formula placeholders.');
    }
    for (var index = 0; index < expected.length; index++) {
      if (actual[index] != expected[index]) {
        throw const FormatException(
          'Translation changed formula placeholders.',
        );
      }
    }
  }

  static TextStyle _neutralStyle(List<Inline> original) {
    final fallback = original
        .whereType<TextRun>()
        .map((run) => run.style)
        .firstOrNull;
    final style = fallback ?? TextStyle.plain;
    return TextStyle(sizeScale: style.sizeScale, color: style.color);
  }

  static TextStyle _applyTag(TextStyle style, String tag) => TextStyle(
    bold: style.bold || tag == 'strong',
    italic:
        style.italic || const {'em', 'i', 'cite', 'torto-italic'}.contains(tag),
    emphasis: style.emphasis || tag == 'em',
    alternateVoice: style.alternateVoice || tag == 'i',
    citation: style.citation || tag == 'cite',
    underline: style.underline || tag == 'u',
    strikethrough: style.strikethrough || tag == 's',
    sizeScale: style.sizeScale,
    color: style.color,
    baseline: switch (tag) {
      'sup' => TextBaselineShift.superscript,
      'sub' => TextBaselineShift.subscript,
      _ => style.baseline,
    },
    linkRole: switch (tag) {
      'noteref' => LinkRole.footnoteReference,
      'noteback' => LinkRole.footnoteBacklink,
      _ => style.linkRole,
    },
    inlineRole: tag == 'inlinefootnote'
        ? InlineRole.footnote
        : style.inlineRole,
  );

  static void _appendText(
    List<Inline> output,
    String value,
    TextStyle style,
    List<Inline> original,
    String language,
  ) {
    final decoded = _unescape(value);
    for (var index = 0; index < decoded.split('\n').length; index++) {
      final part = decoded.split('\n')[index];
      if (index > 0) output.add(const BreakInline());
      if (part.isEmpty) continue;
      output.add(
        TextRun(
          part,
          style: style,
          link: _matchingLink(part, style, original),
          language: language,
        ),
      );
    }
  }

  static String? _matchingLink(
    String translatedText,
    TextStyle style,
    List<Inline> original,
  ) {
    if (style.linkRole == LinkRole.normal) return null;
    final candidates = original.whereType<TextRun>().where(
      (run) => run.style.linkRole == style.linkRole && run.link != null,
    );
    final marker = translatedText.trim();
    for (final run in candidates) {
      if (run.text.trim() == marker) return run.link;
    }
    return candidates.firstOrNull?.link;
  }

  static String _escape(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  static String _unescape(String value) => value
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&amp;', '&');
}

class _StyleFrame {
  final String tag;
  final TextStyle style;

  const _StyleFrame(this.tag, this.style);
}
