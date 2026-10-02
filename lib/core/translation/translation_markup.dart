import 'package:characters/characters.dart';

import '../ir/ir.dart';
import '../semantic_layout/web_links.dart';

class TranslationMarkupCodec {
  static final _tokenPattern = RegExp(
    r'</?(?:strong|em|i|cite|citation|torto-italic|u|s|sup|sub|noteref|noteback|inlinefootnote|torto-size|torto-size-[0-9]+)>|<torto-math-(\d+)/>|<torto-size scale="([^"<>]*)">|<torto-protected-(\d+)/>|<citation id="([1-9][0-9]*)">',
  );

  static String encode(List<Inline> inlines) {
    inlines = translationInlines(inlines);
    final output = StringBuffer();
    var mathIndex = 0;
    var websiteIndex = 0, noteIndex = 0, inlineNoteIndex = 0, citation = 0;
    for (final inline in inlines) {
      final nextCitation = inline is TextRun ? inline.style.inlineCitation : 0;
      if (nextCitation != citation) {
        if (citation != 0) output.write('</citation>');
        if (nextCitation != 0) output.write('<citation id="$nextCitation">');
        citation = nextCitation;
      }
      if (inline is TextRun &&
          inline.style.linkRole == LinkRole.footnoteReference) {
        output.write('<t-note-${noteIndex++}/>');
        continue;
      }
      if (inline is TextRun && inline.style.website) {
        output.write('<t-web-${websiteIndex++}/>');
        continue;
      }
      switch (inline) {
        case TextRun():
          final tags = <String>[];
          void open(String tag) {
            output.write('<$tag>');
            tags.add(tag);
          }

          final size = inline.style.keywordSizeScale;
          if (size != null && size.isFinite && size > 0) {
            output.write('<torto-size scale="$size">');
            tags.add('torto-size');
          }
          if (inline.style.inlineRole == InlineRole.footnote) {
            output.write('<inlinefootnote id="${inlineNoteIndex++}">');
            tags.add('inlinefootnote');
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
    if (citation != 0) output.write('</citation>');
    return output.toString().replaceAllMapped(
      RegExp(r'(</?)torto-(math-[0-9]+|size|italic)'),
      (m) => '${m[1]}t-${m[2]}',
    );
  }

  static List<Inline> decode(
    String translated,
    List<Inline> original, {
    required String language,
    bool requireSizeMarkup = false,
  }) {
    original = translationInlines(original);
    final identity =
        (requireSizeMarkup && !translated.contains('<torto-')) ||
        translated.contains(
          RegExp(
            r'<(?:t-size |t-italic|t-math-|t-note-|t-web-|citation id=|inlinefootnote id=)',
          ),
        );
    translated = translated.replaceAllMapped(
      RegExp(r'(</?)t-(math-[0-9]+|size(?:-[0-9]+)?|italic|protected-[0-9]+)'),
      (m) => '${m[1]}torto-${m[2]}',
    );
    final websites = original
        .whereType<TextRun>()
        .where((r) => r.style.website)
        .toList();
    final notes = original
        .whereType<TextRun>()
        .where((r) => r.style.linkRole == LinkRole.footnoteReference)
        .toList();
    final protected = identity
        ? <TextRun>[...websites, ...notes]
        : original
              .whereType<TextRun>()
              .where((run) => run.style.inlineCitation > 0 || run.style.website)
              .toList();
    if (identity) {
      translated = translated.replaceAllMapped(
        RegExp(r'<t-(web|note)-(\d+)/>'),
        (m) =>
            '<torto-protected-${int.parse(m[2]!) + (m[1] == 'note' ? websites.length : 0)}/>',
      );
      final expectedCitations =
          original
              .whereType<TextRun>()
              .map((r) => r.style.inlineCitation)
              .where((id) => id > 0)
              .toSet()
              .toList()
            ..sort();
      final actualCitations = RegExp(
        r'<citation id="([1-9][0-9]*)">',
      ).allMatches(translated).map((m) => int.parse(m[1]!)).toList()..sort();
      if (expectedCitations.join(',') != actualCitations.join(',')) {
        throw const FormatException('Translation changed citation identities.');
      }
      final expectedNotes = original
          .whereType<TextRun>()
          .where((r) => r.style.inlineRole == InlineRole.footnote)
          .length;
      final actualNotes = RegExp(
        r'<inlinefootnote id="([0-9]+)">',
      ).allMatches(translated).map((m) => int.parse(m[1]!)).toList()..sort();
      if (actualNotes.join(',') !=
          List.generate(expectedNotes, (i) => i).join(',')) {
        throw const FormatException(
          'Translation changed inline note identities.',
        );
      }
      translated = translated.replaceAll(
        RegExp(r'<inlinefootnote id="[0-9]+">'),
        '<inlinefootnote>',
      );
    }
    final protectedIds =
        RegExp(
            r'<torto-protected-(\d+)/>',
          ).allMatches(translated).map((m) => int.parse(m.group(1)!)).toList()
          ..sort();
    if (requireSizeMarkup || identity || protectedIds.isNotEmpty) {
      if (protectedIds.length != protected.length ||
          List.generate(
            protectedIds.length,
            (i) => i,
          ).any((i) => protectedIds[i] != i)) {
        throw const FormatException(
          'Translation changed citation or link placeholders.',
        );
      }
    }
    if (translated.replaceAll(_tokenPattern, '').contains('torto-protected')) {
      throw const FormatException('Malformed reference placeholder.');
    }
    _validateMathPlaceholders(translated, original);
    final sizes = original
        .whereType<TextRun>()
        .where(
          (run) =>
              run.style.keywordSizeScale != null || run.style.sizeScale != 1,
        )
        .map((run) => run.style)
        .toList();
    final tokens = _tokenPattern.allMatches(translated).toList();
    final indexed = tokens.any((m) => m.group(0)!.startsWith('<torto-size-'));
    final canonical = tokens.where((m) => m.group(2) != null).toList();
    if ((indexed && canonical.isNotEmpty) ||
        tokens.any((m) => m.group(0) == '<torto-size>')) {
      throw const FormatException('Mixed or incomplete font-size markup.');
    }
    if (translated
        .replaceAll(_tokenPattern, '')
        .contains(RegExp(r'</?torto-size'))) {
      throw const FormatException('Malformed font-size markup.');
    }
    if (indexed) {
      for (var i = 0; i < sizes.length; i++) {
        if ('<torto-size-$i>'.allMatches(translated).length != 1 ||
            '</torto-size-$i>'.allMatches(translated).length != 1) {
          throw const FormatException('Translation changed font-size markup.');
        }
      }
    } else if (requireSizeMarkup) {
      final expected =
          original
              .whereType<TextRun>()
              .map((run) => run.style.keywordSizeScale)
              .whereType<double>()
              .where((scale) => scale.isFinite && scale > 0)
              .toList()
            ..sort();
      final actual =
          canonical
              .map((m) => double.tryParse(m.group(2)!) ?? double.nan)
              .toList()
            ..sort();
      if (expected.length != actual.length ||
          List.generate(expected.length, (i) => i).any(
            (i) =>
                !actual[i].isFinite ||
                (actual[i] - expected[i]).abs() > 0.000001,
          )) {
        throw const FormatException('Translation changed font-size markup.');
      }
    }
    final math = original.whereType<MathInline>().toList(growable: false);
    final base = _neutralStyle(
      original,
      markedSizes: indexed || canonical.isNotEmpty,
    );
    final output = <Inline>[];
    final stack = <_StyleFrame>[_StyleFrame('', base)];
    var cursor = 0;
    for (final match in tokens) {
      _appendText(
        output,
        translated.substring(cursor, match.start),
        stack.last.style,
        original,
        language,
      );
      final token = match.group(0)!;
      final mathIndex = match.group(1);
      if (match.group(3) != null) {
        output.add(protected[int.parse(match.group(3)!)]);
      } else if (match.group(4) != null) {
        stack.add(
          _StyleFrame(
            'citation',
            stack.last.style.copyWith(
              inlineCitation: int.parse(match.group(4)!),
            ),
          ),
        );
      } else if (mathIndex != null) {
        final index = int.tryParse(mathIndex);
        if (index == null || index < 0 || index >= math.length) {
          throw const FormatException('Unknown formula placeholder.');
        }
        output.add(math[index]);
      } else if (match.group(2) != null) {
        final scale = double.tryParse(match.group(2)!);
        if (scale == null || !scale.isFinite || scale <= 0) {
          throw const FormatException('Invalid font-size markup.');
        }
        stack.add(
          _StyleFrame(
            'torto-size',
            stack.last.style.copyWith(
              sizeScale: scale,
              keywordSizeScale: scale,
            ),
          ),
        );
      } else if (token.startsWith('</')) {
        final tag = token.substring(2, token.length - 1);
        if (stack.length == 1 || stack.last.tag != tag) {
          throw const FormatException('Translation changed inline markup.');
        }
        stack.removeLast();
      } else {
        final tag = token.substring(1, token.length - 1);
        if (tag.startsWith('torto-size-')) {
          final index = int.parse(tag.substring(11));
          if (index >= sizes.length) {
            throw const FormatException('Unknown font-size markup.');
          }
          final size = sizes[index];
          stack.add(
            _StyleFrame(
              tag,
              stack.last.style.copyWith(
                sizeScale: size.sizeScale,
                keywordSizeScale: size.keywordSizeScale,
                clearKeywordSize: size.keywordSizeScale == null,
              ),
            ),
          );
        } else {
          stack.add(_StyleFrame(tag, _applyTag(stack.last.style, tag)));
        }
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

  static TextStyle _neutralStyle(
    List<Inline> original, {
    required bool markedSizes,
  }) {
    final fallback = original
        .whereType<TextRun>()
        .map((run) => run.style)
        .firstOrNull;
    final style = fallback ?? TextStyle.plain;
    final runs = original.whereType<TextRun>().toList();
    final uniformKeyword =
        !markedSizes &&
        runs.every((r) => r.style.keywordSizeScale == style.keywordSizeScale);
    final uniformScale =
        !markedSizes && runs.every((r) => r.style.sizeScale == style.sizeScale);
    return TextStyle(
      sizeScale: uniformScale ? style.sizeScale : 1,
      keywordSizeScale: uniformKeyword ? style.keywordSizeScale : null,
      color: style.color,
      hyphenation: style.hyphenation,
    );
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
    keywordSizeScale: style.keywordSizeScale,
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
    hyphenation: style.hyphenation,
  );

  static void _appendText(
    List<Inline> output,
    String value,
    TextStyle style,
    List<Inline> original,
    String language,
  ) {
    final decoded = _unescape(value);
    final parts = decoded.split('\n');
    for (var index = 0; index < parts.length; index++) {
      final part = parts[index];
      if (index > 0) output.add(const BreakInline());
      if (part.isEmpty) continue;
      output.add(
        TextRun(
          part,
          displayWritingSystem: BookMetadata(
            languages: [language],
          ).writingSystem,
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
