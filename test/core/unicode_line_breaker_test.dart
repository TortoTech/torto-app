import 'package:flutter_test/flutter_test.dart';
import 'package:torto/core/linebreak/unicode_line_breaker.dart';

void main() {
  final breaker = Icu4xLineBreaker.instance;

  test('keeps a Latin word intact and breaks after its space', () {
    const text = 'alpha beta';
    final breaks = breaker.breakOpportunities(text);

    expect(breaks, containsAll(<int>{6, text.length}));
    expect(breaks.where((boundary) => boundary < 5), isEmpty);
  });

  test('keeps non-breaking spaces and word joiners unbroken', () {
    final nbsp = breaker.breakOpportunities('甲\u00a0乙');
    final wordJoiner = breaker.breakOpportunities('甲\u2060乙');

    expect(nbsp, isNot(contains(1)));
    expect(nbsp, isNot(contains(2)));
    expect(wordJoiner, isNot(contains(1)));
    expect(wordJoiner, isNot(contains(2)));
  });

  test('applies CJK opening and closing punctuation rules', () {
    final closing = breaker.breakOpportunities('天地，玄黄');
    final opening = breaker.breakOpportunities('天地（玄黄');

    expect(closing, contains(1));
    expect(closing, isNot(contains(2)));
    expect(closing, contains(3));
    expect(opening, isNot(contains(3)));
  });

  test('reports supplementary-plane boundaries in UTF-16 units', () {
    const text = '甲𠀀乙';
    final breaks = breaker.breakOpportunities(text);

    expect(text.length, 4);
    expect(breaks, containsAll(<int>{1, 3, 4}));
    expect(breaks, isNot(contains(2)));
  });
}
