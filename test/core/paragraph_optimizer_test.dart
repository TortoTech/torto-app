import 'package:characters/characters.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torto/core/linebreak/paragraph_optimizer.dart';
import 'package:torto/core/linebreak/unicode_line_breaker.dart';

List<MeasuredCluster> clustersFor(String text, {double width = 10}) {
  final clusters = <MeasuredCluster>[];
  var offset = 0;
  for (final grapheme in text.characters) {
    final end = offset + grapheme.length;
    clusters.add(
      MeasuredCluster(start: offset, end: end, advance: width, em: width),
    );
    offset = end;
  }
  return clusters;
}

void main() {
  const optimizer = ParagraphOptimizer();

  test('hard breaks keep paragraph endings and share mixed-script spacing', () {
    const text = '中文中文中文中文 Harry Harlow 中文中文中文中文中文中文。\n\n中文中文中文中文中文中文中文。\n';
    final clusters = clustersFor(text);
    final plan = optimizer.plan(
      text: text,
      clusters: clusters,
      legalBreaks: Icu4xLineBreaker.instance.breakOpportunities(text),
      lineWidth: 155,
      firstLineIndent: 0,
      defaultEm: 10,
    );
    expect(plan, isNotNull);
    expect(plan!.lines.where((line) => line.paragraphEnd).length, 4);
    expect(plan.lines.last.startCluster, clusters.length);
    var checkedMixedLine = false;
    for (final line in plan.lines) {
      if (line.paragraphEnd) continue;
      final spaces = [
        for (var i = line.startCluster; i < line.endCluster; i++)
          if (text.substring(clusters[i].start, clusters[i].end) == ' ') i,
      ];
      final cjk = [
        for (var i = line.startCluster; i + 1 < line.endCluster; i++)
          if (text.substring(clusters[i].start, clusters[i + 1].end) == '中文') i,
      ];
      if (spaces.isEmpty || cjk.isEmpty) continue;
      if (plan.adjustments[cjk.first] <= 0) {
        expect(plan.adjustments[spaces.first], lessThanOrEqualTo(5));
        continue;
      }
      // Space expansion includes its 50% allowance and the same second-stage
      // increment as each eligible Chinese boundary (not an absolute cap).
      expect(
        plan.adjustments[spaces.first],
        closeTo(5 + plan.adjustments[cjk.first], 0.001),
      );
      checkedMixedLine = true;
    }
    expect(checkedMixedLine, isTrue);
    for (var i = 0; i < clusters.length; i++) {
      if (text.substring(clusters[i].start, clusters[i].end) == '\n') {
        expect(plan.adjustments[i], 0);
      }
    }
  });

  test('optimizes a complete CJK paragraph without illegal line starts', () {
    const text = '天地玄黄，宇宙洪荒。日月盈昃，辰宿列张。';
    final clusters = clustersFor(text);
    final plan = optimizer.plan(
      text: text,
      clusters: clusters,
      legalBreaks: Icu4xLineBreaker.instance.breakOpportunities(text),
      lineWidth: 70,
      firstLineIndent: 20,
      defaultEm: 10,
    );

    expect(plan, isNotNull);
    expect(plan!.lines.length, greaterThan(1));
    expect(plan.lines.first.startCluster, 0);
    expect(plan.lines.last.endCluster, clusters.length);
    const forbidden = '，。！？；：、）】》」』';
    for (final line in plan.lines.skip(1)) {
      final first = text.substring(
        clusters[line.startCluster].start,
        clusters[line.startCluster].end,
      );
      expect(forbidden.contains(first), isFalse);
    }
  });

  test('does not break a Latin phrase at a non-breaking space', () {
    const text = 'alpha\u00a0beta gamma delta';
    final clusters = clustersFor(text);
    final plan = optimizer.plan(
      text: text,
      clusters: clusters,
      legalBreaks: Icu4xLineBreaker.instance.breakOpportunities(text),
      lineWidth: 120,
      firstLineIndent: 0,
      defaultEm: 10,
    );

    expect(plan, isNotNull);
    final firstEnd = clusters[plan!.lines.first.endCluster - 1].end;
    expect(text.substring(0, firstEnd), startsWith('alpha\u00a0beta'));
  });

  test('falls back for bidirectional prose', () {
    const text = 'مرحبا بالعالم';
    expect(
      optimizer.plan(
        text: text,
        clusters: clustersFor(text),
        legalBreaks: Icu4xLineBreaker.instance.breakOpportunities(text),
        lineWidth: 100,
        firstLineIndent: 0,
        defaultEm: 10,
      ),
      isNull,
    );
  });

  test('accounts for discretionary hyphen width in Knuth-Plass lines', () {
    const text = 'abcdefghijklmno';
    final plan = optimizer.plan(
      text: text,
      clusters: clustersFor(text),
      legalBreaks: const {text.length},
      hyphenBreaks: const {5: 5, 10: 5},
      lineWidth: 55,
      firstLineIndent: 0,
      defaultEm: 10,
    );

    expect(plan, isNotNull);
    expect(plan!.lines, hasLength(3));
    expect(plan.lines.map((line) => line.hyphenated), [true, true, false]);
    expect(plan.lines.first.naturalWidth, closeTo(55, 1e-9));
    expect(plan.lines[1].naturalWidth, closeTo(55, 1e-9));
    expect(plan.lines.last.naturalWidth, closeTo(50, 1e-9));
  });
}
