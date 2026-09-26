import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torto/app/statistics/reading_history.dart';

void main() {
  testWidgets(
    'history filters daily totals and aligns time columns on a narrow screen',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const daily = {
        '2026-09-18': 60000,
        '2026-09-17': 39660000,
        '2026-09-16': 7200000,
        '2026-09-15': 59999,
        '2026-09-14': 0,
      };
      for (final scale in [1.0, 1.5, 2.0]) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                child: const Padding(
                  padding: EdgeInsets.all(16),
                  child: ReadingHistory(daily: daily),
                ),
              ),
            ),
          ),
        );
        expect(find.text('2026/09/15'), findsNothing);
        expect(find.text('2026/09/14'), findsNothing);
        expect(find.text('2026/09/18'), findsOneWidget);
        final units = find.text('小时');
        expect(units, findsNWidgets(3));
        final x = tester.getTopLeft(units.first).dx;
        for (var i = 1; i < 3; i++) {
          expect(tester.getTopLeft(units.at(i)).dx, x);
        }
        final minutes = find.text('分');
        for (var i = 1; i < 3; i++) {
          expect(
            tester.getTopLeft(minutes.at(i)).dx,
            tester.getTopLeft(minutes.first).dx,
          );
        }
        expect(tester.takeException(), isNull);
      }
      expect(daily['2026-09-15'], 59999);
    },
  );
}
