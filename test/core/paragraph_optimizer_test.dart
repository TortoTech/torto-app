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
}
