import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torto/core/ir/ir.dart';
import 'package:torto/core/layout/layout_engine.dart';
import 'package:torto/core/layout/layout_types.dart';
import 'package:torto/core/linebreak/english_hyphenator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'contextual word fragments retain hyphens without extra native wraps',
    () async {
      await (FontLoader('Literata')
            ..addFont(rootBundle.load('assets/fonts/Literata-opsz-wght.ttf')))
          .load();
      const breaks = {
        'performance': [3, 6],
        'sufficient': [3, 5],
        'practical': [4],
        'demonstration': [3, 5, 9],
        'upcoming': [2, 5],
        'syntactic': [3, 6],
        'category': [3, 4, 6],
        'semantic': [2, 5],
        'representation': [3, 5, 8, 10],
        'influence': [2, 5],
      };
      final hyphenator = EnglishHyphenator.forTesting({
        EnglishHyphenationLocale.enUs: (word) =>
            breaks[word.toLowerCase()] ?? [],
      });
      final block = TextBlock(
        nodeId: 'p',
        inlines: [
          TextRun(
            'Performance is far from perfect, but it is sufficient for a practical '
                    'demonstration. The upcoming word\u2019s likely syntactic category and/or '
                    'semantic representation can influence the result. ' *
                6,
          ),
        ],
      );
      final section = Section(
        id: const SpineItemId.generated(0),
        spineIndex: 0,
        href: 'chapter.xhtml',
        blocks: [block],
      );
      for (final width in [360.0, 393.0, 411.0, 432.0]) {
        for (final size in [18.0, 20.0, 22.0]) {
          final pages = LayoutEngine(hyphenator: hyphenator).paginate(
            section,
            LayoutViewport(width: width, height: 914),
            ReaderStyle(
              baseFontSize: size,
              publicationLanguage: 'en-US',
              writingSystem: WritingSystem.latin,
            ),
          );
          final item = pages.first.items.whereType<TextPlacement>().first;
          final lines = item.paragraph.computeLineMetrics();
          expect(
            lines.take(lines.length - 1).every((line) => line.hardBreak),
            isTrue,
            reason: '$width/$size must retain the explicit plan',
          );
          expect(
            lines.every((line) => line.width <= width - 64 + 0.01),
            isTrue,
          );
          expect(item.displayToSource.last, block.plainText.runes.length);
          // Discretionary hyphens/newlines repeat an offset in the display map;
          // the source text, word selection and progress remain canonical.
          expect(
            item.displayToSource,
            orderedEquals(item.displayToSource.toList()..sort()),
          );
          for (final page in pages) {
            page.dispose();
          }
        }
      }
    },
  );
}
