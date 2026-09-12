import 'dart:math' as math;
import 'statistics_model.dart';

/// The same readable time steps and headroom used by the desktop chart.
double distributionTickStep(int maxMilliseconds) {
  final minutes = maxMilliseconds / 60000 * 1.08 / 3;
  for (final step in [
    1.0,
    2.0,
    5.0,
    10.0,
    15.0,
    30.0,
    60.0,
    120.0,
    180.0,
    300.0,
    600.0,
    1200.0,
  ]) {
    if (step >= minutes) return step * 60000;
  }
  final hours = minutes / 60;
  final magnitude = math
      .pow(10, (math.log(hours) / math.ln10).floor())
      .toDouble();
  return [
        1.0,
        2.0,
        5.0,
        10.0,
      ].firstWhere((factor) => factor * magnitude >= hours) *
      magnitude *
      3600000;
}

/// Calendar dates use UTC only for arithmetic; they represent local date labels,
/// not instants. This keeps weeks and months stable across DST transitions.
enum StatisticsPeriod {
  week,
  month,
  year,
  all;

  StatisticsRange range(DateTime today, [int offset = 0]) {
    final day = DateTime.utc(today.year, today.month, today.day);
    if (this == all) return StatisticsRange(null, day);
    final start = switch (this) {
      week =>
        day
            .subtract(Duration(days: day.weekday - 1))
            .add(Duration(days: offset * 7)),
      month => DateTime.utc(day.year, day.month + offset),
      year => DateTime.utc(day.year + offset),
      all => throw StateError('Handled above'),
    };
    final end = switch (this) {
      week => start.add(const Duration(days: 6)),
      month => DateTime.utc(start.year, start.month + 1, 0),
      year => DateTime.utc(start.year, 12, 31),
      all => throw StateError('Handled above'),
    };
    return StatisticsRange(start, end);
  }

  List<StatisticsBin> distribution(
    StatisticsRange range,
    Map<String, int> daily,
  ) {
    final totals = <String, int>{};
    for (final entry in daily.entries.where((e) => range.contains(e.key))) {
      final key = switch (this) {
        week || month => entry.key,
        year => entry.key.substring(0, 7),
        all => entry.key.substring(0, 4),
      };
      totals[key] = (totals[key] ?? 0) + entry.value;
    }
    if (this == all) {
      final years = totals.keys.map(int.parse).toList()..sort();
      final first = years.isEmpty ? range.end.year : years.first;
      return [
        for (var y = first; y <= range.end.year; y++)
          StatisticsBin(DateTime.utc(y), totals['$y'] ?? 0),
      ];
    }
    if (this == year) {
      return [
        for (var m = 1; m <= 12; m++)
          StatisticsBin(
            DateTime.utc(range.start!.year, m),
            totals[dayKey(
                  DateTime.utc(range.start!.year, m),
                ).substring(0, 7)] ??
                0,
          ),
      ];
    }
    return [
      for (
        var date = range.start!;
        !date.isAfter(range.end);
        date = date.add(const Duration(days: 1))
      )
        StatisticsBin(date, totals[dayKey(date)] ?? 0),
    ];
  }
}

class StatisticsRange {
  final DateTime? start;
  final DateTime end;
  const StatisticsRange(this.start, this.end);

  bool contains(String day) =>
      day.compareTo(dayKey(end)) <= 0 &&
      (start == null || day.compareTo(dayKey(start!)) >= 0);
  int total(Map<String, int> daily) => daily.entries
      .where((e) => contains(e.key))
      .fold(0, (sum, entry) => sum + entry.value);
}

class StatisticsBin {
  final DateTime date;
  final int milliseconds;
  const StatisticsBin(this.date, this.milliseconds);
}

List<({BookReadingStats book, int duration})> longestReading(
  Iterable<BookReadingStats> books,
  StatisticsRange range,
) {
  final ranked = [
    for (final book in books)
      (book: book, duration: range.total(dailyReading(book.intervals))),
  ];
  ranked.removeWhere((entry) => entry.duration <= 0);
  ranked.sort((a, b) {
    final time = b.duration.compareTo(a.duration);
    if (time != 0) return time;
    final title = a.book.title.compareTo(b.book.title);
    return title != 0 ? title : a.book.id.compareTo(b.book.id);
  });
  return ranked;
}
