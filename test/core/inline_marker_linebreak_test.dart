import 'package:flutter_test/flutter_test.dart';
import 'package:torto/core/ir/ir.dart';
import 'package:torto/core/layout/layout_engine.dart';
import 'package:torto/core/layout/layout_types.dart';
import 'package:torto/core/linebreak/english_hyphenator.dart';

void main() {
  test('inline reference icons retain optimized breaks and source offsets', () {
    final hyphenator = EnglishHyphenator.forTesting({
      EnglishHyphenationLocale.enUs: (word) => [
        for (var i = 2; i <= word.length - 3; i++) i,
      ],
    });
    for (final markerStyle in [
      const TextStyle(inlineCitation: 1),
      const TextStyle(linkRole: LinkRole.footnoteReference),
      const TextStyle(website: true),
    ]) {
      final block = TextBlock(
        nodeId: 'p',
        inlines: [
          for (var i = 0; i < 8; i++) ...[
            const TextRun('This is internationalization documentation '),
            TextRun('(Smith, 2020)', style: markerStyle, link: '#note'),
            const TextRun(' representation performance. '),
          ],
        ],
      );
      final section = Section(
        id: const SpineItemId.generated(0),
        spineIndex: 0,
        href: 'chapter.xhtml',
        blocks: [block],
      );
      final pages = LayoutEngine(hyphenator: hyphenator).paginate(
        section,
        const LayoutViewport(width: 600, height: 900),
        const ReaderStyle(
          publicationLanguage: 'en-US',
          typesettingMode: TypesettingMode.unified,
        ),
      );
      final placement = pages.first.items.whereType<TextPlacement>().first;
      final lines = placement.paragraph.computeLineMetrics();
      expect(
        lines.take(lines.length - 1).every((line) => line.hardBreak),
        isTrue,
        reason: 'marker $markerStyle must not force native fallback',
      );
      expect(placement.displayToSource.last, block.plainText.runes.length);
      expect(placement.links.where((link) => link.footnoteIcon), hasLength(8));
      for (final page in pages) {
        page.dispose();
      }
    }
  });
}
