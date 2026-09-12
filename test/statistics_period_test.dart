import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:torto/app/statistics/statistics_distribution.dart';
import 'package:torto/app/statistics/statistics_model.dart';
import 'package:torto/app/statistics/statistics_period.dart';

void main() {
  testWidgets('distribution stays readable on narrow screens in every period', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final brightness in Brightness.values) {
      for (final period in StatisticsPeriod.values) {
        final range = period.range(DateTime(2026, 9, 12));
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: brightness),
            home: Scaffold(
              body: MediaQuery(
                data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: ReadingTrend(
                    key: ValueKey('$brightness-$period'),
                    daily: const {
                      '2024-01-01': 3600000,
                      '2026-01-03': 1800000,
                      '2026-09-10': 5400000,
                    },
                    period: period,
                    start: range.start,
                    end: range.end,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final gesture = find.byKey(
          const ValueKey('statistics-distribution-plot'),
        );
        final visible = tester.getRect(find.byType(ReadingTrend));
        await tester.tapAt(
          Offset(visible.left + 30, tester.getRect(gesture).top + 80),
        );
        await tester.pump();
        expect(
          find.byKey(const ValueKey('statistics-distribution-tooltip')),
          findsOneWidget,
        );
        final tooltipRect = tester.getRect(
          find.byKey(const ValueKey('statistics-distribution-tooltip')),
        );
        expect(tooltipRect.left, greaterThanOrEqualTo(0));
        expect(tooltipRect.right, lessThanOrEqualTo(320));
        await tester.tapAt(const Offset(310, 650));
        await tester.pump();
        expect(
          find.byKey(const ValueKey('statistics-distribution-tooltip')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      }
    }
  });
  testWidgets(
    'empty distribution shows only zero and period changes dismiss tooltip',
    (tester) async {
      final period = ValueNotifier(StatisticsPeriod.week);
      addTearDown(period.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder(
              valueListenable: period,
              builder: (context, value, _) => Padding(
                padding: const EdgeInsets.all(16),
                child: ReadingTrend(
                  period: value,
                  daily: const {},
                  end: DateTime(2026, 9, 12),
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.text('0'), findsOneWidget);
      expect(find.text('1min'), findsNothing);
      final plot = find.byKey(const ValueKey('statistics-distribution-plot'));
      await tester.tapAt(tester.getTopLeft(plot) + const Offset(25, 80));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('statistics-distribution-tooltip')),
        findsOneWidget,
      );
      period.value = StatisticsPeriod.month;
      await tester.pump();
      expect(
        find.byKey(const ValueKey('statistics-distribution-tooltip')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );
  test('axis labels match the desktop calendar and units', () {
    expect(
      distributionAxisLabel(
        StatisticsPeriod.week,
        DateTime(2026, 9, 7),
        chinese: false,
      ),
      'Mon',
    );
    expect(
      distributionAxisLabel(StatisticsPeriod.month, DateTime(2026, 9, 1)),
      '1',
    );
    expect(
      distributionAxisLabel(StatisticsPeriod.month, DateTime(2026, 9, 2)),
      '',
    );
    expect(
      distributionAxisLabel(StatisticsPeriod.month, DateTime(2026, 9, 5)),
      '5',
    );
    expect(
      distributionAxisLabel(StatisticsPeriod.month, DateTime(2026, 1, 31)),
      '',
    );
    expect(
      distributionAxisLabel(StatisticsPeriod.year, DateTime(2026, 9)),
      '9',
    );
    expect(distributionAxisLabel(StatisticsPeriod.all, DateTime(2026)), '2026');
    expect(distributionTickLabel(0, 60000), '0');
    expect(distributionTickLabel(600000, 300000), '10min');
    expect(distributionTickLabel(7200000, 3600000), '2h');
  });
  testWidgets(
    'dense periods scroll horizontally without moving the value axis',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: ReadingTrend(
                period: StatisticsPeriod.year,
                daily: const {'2026-01-03': 7200000},
                end: DateTime(2026, 9, 12),
              ),
            ),
          ),
        ),
      );
      final chart = find.byType(ReadingTrend);
      final plot = find.byKey(const ValueKey('statistics-distribution-plot'));
      final viewport = tester.getRect(chart);
      await tester.tapAt(
        Offset(viewport.left + 30, tester.getRect(plot).top + 70),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('statistics-distribution-tooltip')),
        findsOneWidget,
      );
      final axis = tester.getRect(find.text('3h'));
      await tester.dragFrom(
        Offset(viewport.left + 140, viewport.top + 120),
        const Offset(-100, 0),
      );
      await tester.pumpAndSettle();
      final scroll = tester.widget<SingleChildScrollView>(
        find.descendant(
          of: chart,
          matching: find.byType(SingleChildScrollView),
        ),
      );
      expect(scroll.controller!.offset, greaterThan(0));
      expect(tester.getRect(find.text('3h')), axis);
      expect(
        find.byKey(const ValueKey('statistics-distribution-tooltip')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );
  test('calendar weeks start Monday and cross years', () {
    final range = StatisticsPeriod.week.range(DateTime(2026, 1, 1));
    expect(dayKey(range.start!), '2025-12-29');
    expect(dayKey(range.end), '2026-01-04');
    expect(
      dayKey(StatisticsPeriod.week.range(DateTime(2026, 1, 1), -1).end),
      '2025-12-28',
    );
    expect(StatisticsPeriod.week.distribution(range, {}).length, 7);
  });

  test('months include all dates including leap day and day 31', () {
    for (final entry in [
      (DateTime(2024, 2), 29),
      (DateTime(2025, 2), 28),
      (DateTime(2026, 1), 31),
    ]) {
      final range = StatisticsPeriod.month.range(entry.$1);
      final bins = StatisticsPeriod.month.distribution(range, {
        dayKey(range.end): 123,
      });
      expect(bins.length, entry.$2);
      expect(bins.last.milliseconds, 123);
    }
    expect(
      dayKey(StatisticsPeriod.month.range(DateTime(2026, 1), -1).start!),
      '2025-12-01',
    );
  });

  test(
    'year and all-time distributions include older data and empty periods',
    () {
      final daily = {
        '2023-03-01': 60,
        '2025-06-10': 120,
        '2026-01-03': 180,
        '2026-09-10': 240,
        '2027-01-01': 600,
      };
      final year = StatisticsPeriod.year.range(DateTime(2026, 9, 12));
      final bins = StatisticsPeriod.year.distribution(year, daily);
      expect(bins.length, 12);
      expect(bins.first.milliseconds, 180);
      expect(bins[8].milliseconds, 240);
      expect(
        bins.fold<int>(0, (sum, b) => sum + b.milliseconds),
        year.total(daily),
      );
      final all = StatisticsPeriod.all.range(DateTime(2026, 9, 12));
      final years = StatisticsPeriod.all.distribution(all, daily);
      expect(years.map((b) => b.date.year), [2023, 2024, 2025, 2026]);
      expect(years.map((b) => b.milliseconds), [60, 0, 120, 420]);
      expect(StatisticsPeriod.all.distribution(all, {}).single.milliseconds, 0);
    },
  );

  test(
    'ranking uses the selected period rather than lifetime or last activity',
    () {
      final a = BookReadingStats('a')..title = 'A';
      final b = BookReadingStats('b')..title = 'B';
      final empty = BookReadingStats('empty');
      void add(BookReadingStats book, DateTime day, int minutes) {
        final start = day.millisecondsSinceEpoch;
        book.intervals.add(ReadingInterval(start, start + minutes * 60000, 0));
      }

      add(a, DateTime.utc(2026, 8, 1), 600);
      add(a, DateTime.utc(2026, 9, 9), 10);
      add(b, DateTime.utc(2026, 9, 10), 30);
      final week = StatisticsPeriod.week.range(DateTime(2026, 9, 12));
      final ranked = longestReading([empty, a, b], week);
      expect(ranked.map((entry) => entry.book.id), ['b', 'a']);
      expect(ranked.map((entry) => entry.duration), [1800000, 600000]);
      final all = longestReading([
        a,
        b,
      ], StatisticsPeriod.all.range(DateTime(2026, 9, 12)));
      expect(all.first.book.id, 'a');
    },
  );
}
