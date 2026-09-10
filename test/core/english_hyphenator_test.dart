import 'package:flutter_test/flutter_test.dart';
import 'package:torto/core/ir/ir.dart';
import 'package:torto/core/linebreak/english_hyphenator.dart';

void main() {
  test('resolves only en-US, en-GB and generic English', () {
    expect(
      EnglishHyphenator.localeForLanguageTag('en_US'),
      EnglishHyphenationLocale.enUs,
    );
    expect(
      EnglishHyphenator.localeForLanguageTag('en-Latn-GB'),
      EnglishHyphenationLocale.enGb,
    );
    expect(
      EnglishHyphenator.localeForLanguageTag('en'),
      EnglishHyphenationLocale.enUs,
    );
    expect(
      EnglishHyphenator.localeForLanguageTag('eng'),
      EnglishHyphenationLocale.enUs,
    );
    expect(
      EnglishHyphenator.localeForLanguageTag(
        'en',
        genericEnglishFallback: EnglishHyphenationLocale.enGb,
      ),
      EnglishHyphenationLocale.enGb,
    );
    expect(EnglishHyphenator.localeForLanguageTag('en-CA'), isNull);
    expect(EnglishHyphenator.localeForLanguageTag('zh-CN'), isNull);
  });

  test('uses authored run language before paragraph/publication fallback', () {
    final requested = <EnglishHyphenationLocale>[];
    final hyphenator = EnglishHyphenator.forTesting({
      EnglishHyphenationLocale.enUs: (word) {
        requested.add(EnglishHyphenationLocale.enUs);
        return const [2, 6];
      },
      EnglishHyphenationLocale.enGb: (word) {
        requested.add(EnglishHyphenationLocale.enGb);
        return const [3, 6];
      },
    });
    const text = 'hyphenation hyphenation';
    final breaks = hyphenator.breakOpportunities(
      text: text,
      spans: const [
        HyphenationSpan(start: 0, end: 11, language: 'en-US'),
        HyphenationSpan(start: 11, end: 12),
        HyphenationSpan(start: 12, end: 23, language: 'en-GB'),
      ],
      publicationLanguage: 'en-US',
    );

    expect(breaks, {2, 6, 15, 18});
    expect(requested, [
      EnglishHyphenationLocale.enUs,
      EnglishHyphenationLocale.enGb,
    ]);
  });

  test('does not apply book English to an untagged CJK paragraph', () {
    final hyphenator = EnglishHyphenator.forTesting({
      EnglishHyphenationLocale.enUs: (_) => const [2, 6],
    });
    const text = '中文 hyphenation 文本';

    expect(
      hyphenator.breakOpportunities(
        text: text,
        spans: const [HyphenationSpan(start: 0, end: text.length)],
        publicationLanguage: 'en-US',
      ),
      isEmpty,
    );
    expect(
      hyphenator.breakOpportunities(
        text: text,
        spans: const [
          HyphenationSpan(start: 0, end: 3),
          HyphenationSpan(start: 3, end: 14, language: 'en-US'),
          HyphenationSpan(start: 14, end: text.length),
        ],
        publicationLanguage: 'en-US',
      ),
      {5, 9},
    );
  });

  test('manual mode uses soft hyphens and none suppresses all breaks', () {
    final hyphenator = EnglishHyphenator.forTesting({
      EnglishHyphenationLocale.enUs: (_) => const [2, 6],
    });
    const text = 'hy\u00adphenation';

    expect(
      hyphenator.breakOpportunities(
        text: text,
        spans: const [
          HyphenationSpan(
            start: 0,
            end: text.length,
            language: 'en-US',
            mode: HyphenationMode.manual,
          ),
        ],
        publicationLanguage: 'en-US',
      ),
      {3},
    );
    expect(
      hyphenator.breakOpportunities(
        text: text,
        spans: const [
          HyphenationSpan(
            start: 0,
            end: text.length,
            language: 'en-US',
            mode: HyphenationMode.none,
          ),
        ],
        publicationLanguage: 'en-US',
      ),
      isEmpty,
    );
  });
}
