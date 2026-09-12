import 'package:flutter_test/flutter_test.dart';
import 'package:torto/core/ir/ir.dart';
import 'package:torto/core/layout/layout_engine.dart';
import 'package:torto/core/layout/layout_types.dart';
import 'package:torto/core/linebreak/english_hyphenator.dart';

class _ManyBreaks implements ParagraphHyphenator {
  @override
  Set<int> breakOpportunities({
    required String text,
    required List<HyphenationSpan> spans,
    required String? publicationLanguage,
  }) => {
    for (final match in RegExp(r'[A-Za-z]{8,}').allMatches(text)) ...[
      match.start + 3,
      match.start + 5,
    ],
  };
}

void main() {
  test('hyphen advance reuse preserves every page and reduces glyph shaping', () {
    final section = Section(
      id: const SpineItemId.generated(0),
      spineIndex: 0,
      href: 'chapter.xhtml',
      blocks: [
        for (var i = 0; i < 40; i++)
          TextBlock(
            nodeId: 'p$i',
            inlines: [
              TextRun(
                'Internationalization documentation representation performance. ' *
                    8,
              ),
            ],
          ),
      ],
    );
    const viewport = LayoutViewport(width: 360, height: 720);
    const style = ReaderStyle(
      typesettingMode: TypesettingMode.unified,
      publicationLanguage: 'en-US',
    );
    var beforeCount = 0, afterCount = 0;
    final baseline = LayoutEngine(
      hyphenator: _ManyBreaks(),
      cacheHyphenMeasurements: false,
      onHyphenMeasurement: () => beforeCount++,
    );
    final optimized = LayoutEngine(
      hyphenator: _ManyBreaks(),
      onHyphenMeasurement: () => afterCount++,
    );
    final before = baseline.paginate(section, viewport, style);
    final after = optimized.paginate(section, viewport, style);
    List<Object> signature(List<PageLayout> pages) => [
      for (final page in pages)
        [
          page.progression,
          for (final item in page.items.whereType<TextPlacement>())
            [
              item.nodeId,
              item.startLine,
              item.endLine,
              item.x,
              item.y,
              item.textOffsetAtStart,
            ],
        ],
    ];
    expect(signature(after), signature(before));
    expect(beforeCount, greaterThan(1000));
    expect(afterCount, 40);
    for (final page in [...before, ...after]) {
      page.dispose();
    }
    final beforeTimes = <int>[], afterTimes = <int>[];
    for (var iteration = 0; iteration < 5; iteration++) {
      for (final entry
          in iteration.isEven
              ? [(baseline, beforeTimes), (optimized, afterTimes)]
              : [(optimized, afterTimes), (baseline, beforeTimes)]) {
        final watch = Stopwatch()..start();
        final pages = entry.$1.paginate(section, viewport, style);
        entry.$2.add(watch.elapsedMicroseconds);
        for (final page in pages) {
          page.dispose();
        }
      }
    }
    beforeTimes.sort();
    afterTimes.sort();
    // Benchmark output is diagnostic, not a machine-speed-dependent assertion.
    // ignore: avoid_print
    print(
      'hyphen benchmark baseline_us=${beforeTimes[2]} optimized_us=${afterTimes[2]} measurements=$beforeCount/$afterCount',
    );
  });
}
