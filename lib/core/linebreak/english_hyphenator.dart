import 'dart:collection';

import 'package:hyphen/hyphen.dart';
import 'package:flutter/foundation.dart';

import '../ir/ir.dart';

/// English dictionaries deliberately supported by the first mobile release.
enum EnglishHyphenationLocale { enUs, enGb }

extension EnglishHyphenationLocaleTag on EnglishHyphenationLocale {
  String get languageTag => switch (this) {
    EnglishHyphenationLocale.enUs => 'en-US',
    EnglishHyphenationLocale.enGb => 'en-GB',
  };

  String get assetPath => switch (this) {
    EnglishHyphenationLocale.enUs => 'assets/hyphenation/hyph_en_US.dic',
    EnglishHyphenationLocale.enGb => 'assets/hyphenation/hyph_en_GB.dic',
  };
}

/// Source range with the nearest authored language and layout exclusions.
class HyphenationSpan {
  final int start;
  final int end;
  final String? language;
  final bool suppress;
  final HyphenationMode mode;

  const HyphenationSpan({
    required this.start,
    required this.end,
    this.language,
    this.suppress = false,
    this.mode = HyphenationMode.auto,
  });
}

/// Synchronous paragraph-facing API. Implementations may prepare their
/// dictionaries asynchronously before layout starts.
abstract interface class ParagraphHyphenator {
  Set<int> breakOpportunities({
    required String text,
    required List<HyphenationSpan> spans,
    required String? publicationLanguage,
  });
}

typedef EnglishWordBreakResolver = List<int> Function(String word);

/// Lazy libhyphen adapter for US and British English.
///
/// The adapter never inserts soft hyphens into source text. It returns UTF-16
/// source offsets that the Knuth-Plass stage may choose as discretionary line
/// endings. Failed or not-yet-loaded dictionaries simply produce no extra
/// opportunities, leaving ICU4X line breaking intact.
final class EnglishHyphenator implements ParagraphHyphenator {
  EnglishHyphenator._({
    Map<EnglishHyphenationLocale, EnglishWordBreakResolver> testingResolvers =
        const {},
  }) : _testingResolvers = testingResolvers;

  static final EnglishHyphenator instance = EnglishHyphenator._();

  @visibleForTesting
  factory EnglishHyphenator.forTesting(
    Map<EnglishHyphenationLocale, EnglishWordBreakResolver> resolvers,
  ) => EnglishHyphenator._(testingResolvers: resolvers);

  static const int _wordCacheLimit = 4096;
  static final RegExp _asciiEnglishWord = RegExp(r'[A-Za-z]{5,}');

  final Map<EnglishHyphenationLocale, Hyphen> _engines = {};
  final Map<EnglishHyphenationLocale, EnglishWordBreakResolver>
  _testingResolvers;
  final Map<EnglishHyphenationLocale, Future<void>> _loads = {};
  final Map<EnglishHyphenationLocale, Object> _failures = {};
  final Map<EnglishHyphenationLocale, LinkedHashMap<String, List<int>>>
  _wordBreakCache = {};

  /// Resolves only the two supported regional variants. A generic `en` tag
  /// inherits the publication variant and otherwise defaults to en-US.
  static EnglishHyphenationLocale? localeForLanguageTag(
    String? language, {
    EnglishHyphenationLocale? genericEnglishFallback,
  }) {
    final normalized = language?.trim().replaceAll('_', '-').toLowerCase();
    if (normalized == null || normalized.isEmpty) return null;
    final subtags = normalized
        .split('-')
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
    if (subtags.isEmpty || (subtags.first != 'en' && subtags.first != 'eng')) {
      return null;
    }
    if (subtags.contains('us')) return EnglishHyphenationLocale.enUs;
    if (subtags.contains('gb')) return EnglishHyphenationLocale.enGb;

    // Do not silently apply US/GB patterns to a different declared region.
    final hasOtherRegion = subtags
        .skip(1)
        .any(
          (value) =>
              value.length == 2 &&
              value != 'us' &&
              value != 'gb' &&
              value != 'latn',
        );
    if (hasOtherRegion) return null;
    return genericEnglishFallback ?? EnglishHyphenationLocale.enUs;
  }

  /// Loads only dictionaries needed by this parsed section and its
  /// publication fallback. Safe to call repeatedly.
  Future<void> ensureLoadedForSection(
    Section section, {
    String? publicationLanguage,
  }) async {
    final fallback = localeForLanguageTag(publicationLanguage);
    final needed = <EnglishHyphenationLocale>{?fallback};

    void collectInlines(List<Inline> inlines) {
      for (final inline in inlines) {
        if (inline case TextRun(:final language)) {
          final locale = localeForLanguageTag(
            language,
            genericEnglishFallback: fallback,
          );
          if (locale != null) needed.add(locale);
        }
      }
    }

    void collectBlock(Block block) {
      switch (block) {
        case TextBlock(:final inlines):
          collectInlines(inlines);
        case TableBlock(:final rows):
          for (final row in rows) {
            for (final cell in row.cells) {
              collectInlines(cell.inlines);
            }
          }
        case FigureBlock(:final captions):
          for (final caption in captions) {
            collectInlines(caption.inlines);
          }
        case QuoteBlock(:final body, :final attribution):
          for (final paragraph in body) {
            collectInlines(paragraph.inlines);
          }
          if (attribution != null) collectInlines(attribution.inlines);
        case NoteBlock(:final blocks):
          for (final nested in blocks) {
            collectBlock(nested);
          }
        default:
          break;
      }
    }

    for (final block in section.blocks) {
      collectBlock(block);
    }
    await Future.wait(needed.map(_ensureLoaded));
  }

  /// Prepares one publication-level fallback for plain text that no longer
  /// carries the original inline language spans, such as a footnote popup.
  Future<void> ensureLoadedForLanguage(String? language) {
    final locale = localeForLanguageTag(language);
    return locale == null ? Future.value() : _ensureLoaded(locale);
  }

  Future<void> _ensureLoaded(EnglishHyphenationLocale locale) {
    if (_engines.containsKey(locale) || _failures.containsKey(locale)) {
      return Future.value();
    }
    return _loads.putIfAbsent(locale, () async {
      try {
        _engines[locale] = await Hyphen.fromDictionaryPath(locale.assetPath);
      } catch (error) {
        _failures[locale] = error;
        debugPrint('Could not load ${locale.languageTag} hyphenation: $error');
      }
    });
  }

  @override
  Set<int> breakOpportunities({
    required String text,
    required List<HyphenationSpan> spans,
    required String? publicationLanguage,
  }) {
    if (text.isEmpty || spans.isEmpty) return const {};
    final fallback = localeForLanguageTag(publicationLanguage);
    final paragraphCanUseFallback = _looksPredominantlyEnglish(text);
    final breaks = <int>{};
    for (final span in spans) {
      if (span.suppress || span.mode == HyphenationMode.none) continue;
      final start = span.start.clamp(0, text.length);
      final end = span.end.clamp(start, text.length);
      for (var offset = start; offset < end; offset++) {
        if (text.codeUnitAt(offset) == 0x00ad) breaks.add(offset + 1);
      }
    }
    var spanIndex = 0;

    for (final match in _asciiEnglishWord.allMatches(text)) {
      final word = match.group(0)!;
      if (_looksLikeIdentifierBoundary(text, match.start, match.end)) continue;
      while (spanIndex + 1 < spans.length &&
          spans[spanIndex].end <= match.start) {
        spanIndex++;
      }

      EnglishHyphenationLocale? locale;
      var current = spanIndex;
      var coveredUntil = match.start;
      var eligible = true;
      while (current < spans.length && spans[current].start < match.end) {
        final span = spans[current];
        if (span.end <= match.start) {
          current++;
          continue;
        }
        if (span.start > coveredUntil ||
            span.suppress ||
            span.mode != HyphenationMode.auto) {
          eligible = false;
          break;
        }
        final declared = span.language?.trim();
        final spanLocale = declared != null && declared.isNotEmpty
            ? localeForLanguageTag(declared, genericEnglishFallback: fallback)
            : (paragraphCanUseFallback ? fallback : null);
        if (spanLocale == null || (locale != null && locale != spanLocale)) {
          eligible = false;
          break;
        }
        locale = spanLocale;
        coveredUntil = span.end;
        if (coveredUntil >= match.end) break;
        current++;
      }
      if (!eligible || coveredUntil < match.end || locale == null) continue;
      final resolver = _testingResolvers[locale];
      final engine = _engines[locale];
      if (resolver == null && engine == null) continue;
      final wordBreaks =
          resolver?.call(word) ?? _wordBreaks(engine!, locale, word);
      for (final offset in wordBreaks) {
        breaks.add(match.start + offset);
      }
    }
    return breaks;
  }

  List<int> _wordBreaks(
    Hyphen engine,
    EnglishHyphenationLocale locale,
    String word,
  ) {
    final key = word.toLowerCase();
    final cache = _wordBreakCache.putIfAbsent(locale, LinkedHashMap.new);
    final cached = cache.remove(key);
    if (cached != null) {
      cache[key] = cached;
      return cached;
    }
    final parts = engine.hyphenate(key, lhmin: 2, rhmin: 3);
    final offsets = <int>[];
    var offset = 0;
    for (var index = 0; index + 1 < parts.length; index++) {
      offset += parts[index].length;
      if (offset >= 2 && key.length - offset >= 3) offsets.add(offset);
    }
    final result = List<int>.unmodifiable(offsets);
    if (cache.length >= _wordCacheLimit) cache.remove(cache.keys.first);
    cache[key] = result;
    return result;
  }

  static bool _looksPredominantlyEnglish(String text) {
    var latin = 0;
    var competing = 0;
    for (final rune in text.runes) {
      if ((rune >= 0x41 && rune <= 0x5a) || (rune >= 0x61 && rune <= 0x7a)) {
        latin++;
      } else if ((rune >= 0x0370 && rune <= 0x052f) ||
          (rune >= 0x0590 && rune <= 0x08ff) ||
          (rune >= 0x3040 && rune <= 0x30ff) ||
          (rune >= 0x3400 && rune <= 0x9fff) ||
          (rune >= 0xac00 && rune <= 0xd7af)) {
        competing++;
      }
    }
    // CJK characters carry more lexical information per scalar than Latin
    // letters, so weight competing scripts before deciding that a whole
    // untagged paragraph may inherit the publication's English dictionary.
    return latin >= 5 && latin * 100 >= (latin + competing * 2) * 70;
  }

  static bool _looksLikeIdentifierBoundary(String text, int start, int end) {
    const identifierPunctuation = '/@_\\';
    return (start > 0 && identifierPunctuation.contains(text[start - 1])) ||
        (end < text.length && identifierPunctuation.contains(text[end]));
  }
}
