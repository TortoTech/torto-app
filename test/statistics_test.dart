import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:torto/app/statistics/statistics_model.dart';
import 'package:torto/app/statistics/statistics_store.dart';
import 'package:torto/app/statistics/reading_tracker.dart';
import 'package:torto/app/statistics/statistics_page.dart';
import 'package:torto/app/library/library_store.dart';
import 'package:torto/app/progress_store.dart';
import 'package:torto/app/sync/webdav_client.dart';

ReadingEvent interval(
  String id,
  int start,
  int end, {
  String book = 'book',
  String session = 'session',
  int offset = 0,
  String device = 'desktop',
}) => ReadingEvent(id, device, book, end, 'Reading', {
  'session': session,
  'start': start,
  'end': end,
  'offset': offset,
  'from': 0.0,
  'to': 0.4,
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  test('desktop event JSON round trips with external enum tags', () {
    final source = interval('id', 1000, 16000).toJson();
    expect(
      ReadingEvent.fromJson(Map<String, dynamic>.from(source)).toJson(),
      source,
    );
    final clear = ReadingEvent('clear', 'phone', 'book', 20000, 'Clear', {});
    expect(clear.toJson()['kind'], 'Clear');
    expect(
      ReadingEvent.fromJson(Map<String, dynamic>.from(clear.toJson())).type,
      'Clear',
    );
  });
  test('overlapping device and book intervals are unioned', () {
    final stats = aggregateStatistics([
      interval('a', 1000, 41000),
      interval('b', 21000, 61000, device: 'phone'),
      interval('c', 31000, 71000, book: 'other'),
    ]);
    expect(stats['book']!.duration, 60000);
    expect(readingDuration(stats.values.expand((b) => b.intervals)), 70000);
    expect(stats.values.fold<int>(0, (sum, b) => sum + b.duration), 100000);
  });
  test('midnight splits using captured local UTC offset', () {
    final midnight = DateTime.utc(2026, 9, 8, 16).millisecondsSinceEpoch;
    final days = dailyReading([
      ReadingInterval(midnight - 10000, midnight + 20000, 28800),
    ]);
    expect(days, {'2026-09-08': 10000, '2026-09-09': 20000});
  });
  test(
    'short session retains duration but not reading days; checkpoints join',
    () {
      final first = interval('a', 1000, 16000);
      var stats = aggregateStatistics([first]);
      expect(stats['book']!.duration, 15000);
      expect(stats['book']!.started, isNull);
      expect(stats['book']!.readingDays, 0);
      stats = aggregateStatistics([first, interval('b', 16000, 31000)]);
      expect(stats['book']!.readingDays, 1);
      expect(stats['book']!.status, ReadingStatus.reading);
    },
  );
  test('clear survives reimport; metadata remains and new sessions count', () {
    final metadata = ReadingEvent('meta', 'phone', 'book', 0, 'Metadata', {
      'title': 'Book',
      'authors': '',
      'added': 1,
    });
    final old = interval('old', 1000, 41000);
    final clear = ReadingEvent('clear', 'phone', 'book', 42000, 'Clear', {});
    var stats = aggregateStatistics([old, metadata, clear, old]);
    expect(stats['book']!.duration, 0);
    expect(stats['book']!.title, 'Book');
    stats = aggregateStatistics([
      metadata,
      old,
      clear,
      interval('new', 43000, 58000),
    ]);
    expect(stats['book']!.duration, 15000);
  });
  test(
    'finished status remains during rereading and resolves tied edits by ID',
    () {
      final stats = aggregateStatistics([
        ReadingEvent('a', 'desktop', 'book', 1000, 'Status', {
          'status': 'Reading',
          'finished': null,
        }),
        ReadingEvent('b', 'phone', 'book', 1000, 'Status', {
          'status': 'Finished',
          'finished': '2026-09-01',
        }),
        interval('c', 2000, 42000),
      ]);
      expect(stats['book']!.status, ReadingStatus.finished);
      expect(stats['book']!.finished, '2026-09-01');
    },
  );
  test(
    'tracker checkpoints, excludes inactivity and suspension, flushes exit',
    () {
      final writes = <Map<String, dynamic>>[];
      final tracker = ReadingTracker(writes.add);
      void tick(int ms, {bool eligible = true, bool activity = false}) =>
          tracker.tick(
            monotonicMs: ms,
            wallMs: 100000 + ms,
            offsetSeconds: 0,
            eligible: eligible,
            activity: activity,
            progress: .2,
          );
      tick(0, activity: true);
      for (var i = 1; i <= 302; i++) {
        tick(i * 1000);
      }
      expect(
        writes.fold<int>(
          0,
          (sum, d) => sum + (d['end'] as int) - (d['start'] as int),
        ),
        300000,
      );
      tick(360000, activity: true); // suspended gap cannot count
      tick(361000);
      tick(362000, eligible: false);
      expect(
        writes.fold<int>(
          0,
          (sum, d) => sum + (d['end'] as int) - (d['start'] as int),
        ),
        301000,
      );
      expect(writes.first['session'], isNot(writes.last['session']));
    },
  );
  test('background tracker does not produce reading events', () {
    final writes = <Map<String, dynamic>>[];
    final tracker = ReadingTracker(writes.add);
    for (var i = 0; i < 40; i++) {
      tracker.tick(
        monotonicMs: i * 1000,
        wallMs: 10000 + i * 1000,
        offsetSeconds: 0,
        eligible: false,
        activity: true,
        progress: 0,
      );
    }
    tracker.flush();
    expect(writes, isEmpty);
  });
  test(
    'SQLite and WebDAV restore local shards without double counting',
    () async {
      final store = await ReadingStatisticsStore.openAt(
        inMemoryDatabasePath,
        'phone',
        factory: databaseFactoryFfi,
      );
      addTearDown(store.database.close);
      final remote = interval('remote', 1000, 41000);
      final own = interval('own', 2000, 42000, device: 'phone');
      final shard = {
        'version': 1,
        'events': [remote.toJson(), own.toJson()],
      };
      final uploads = <Map<String, dynamic>>[];
      final client = WebDavClient(
        baseUrl: 'https://example.test/dav',
        username: '',
        password: '',
        client: MockClient((request) async {
          if (request.method == 'PROPFIND') {
            return http.Response(
              '<d:multistatus xmlns:d="DAV:"><d:response><d:href>${request.url.path}desktop-2026-09.json</d:href></d:response></d:multistatus>',
              207,
            );
          }
          if (request.method == 'GET') {
            return http.Response(jsonEncode(shard), 200);
          }
          if (request.method == 'PUT') {
            uploads.add(jsonDecode(request.body) as Map<String, dynamic>);
            return http.Response('', 201);
          }
          return http.Response('', 201);
        }),
      );
      addTearDown(client.close);
      await store.sync(client);
      await store.sync(client);
      expect((await store.events()).length, 2);
      expect(uploads, hasLength(2));
      expect((uploads.last['events'] as List).single['device'], 'phone');
      expect(
        aggregateStatistics(await store.events())['book']!.duration,
        41000,
      );
    },
  );
  testWidgets(
    'overview and detail fit a narrow dark phone without timer controls',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      late Directory dir;
      late ReadingStatisticsStore store;
      await tester.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('torto-stats-test');
        store = await ReadingStatisticsStore.openAt(
          inMemoryDatabasePath,
          'phone',
          factory: databaseFactoryFfi,
        );
        await store.merge([
          ReadingEvent('meta', 'phone', 'book', 0, 'Metadata', {
            'title': 'A book with a long title',
            'authors': 'Author',
            'added': 1,
          }),
          const ReadingEvent(
            'empty-meta',
            'phone',
            'empty-book',
            0,
            'Metadata',
            {'title': 'No reading history book', 'authors': '', 'added': 1},
          ),
          interval(
            'reading',
            DateTime.now().millisecondsSinceEpoch - 40000,
            DateTime.now().millisecondsSinceEpoch,
          ),
        ]);
      });
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.binding.setSurfaceSize(null);
        await tester.runAsync(() async {
          await store.database.close();
          await dir.delete();
        });
      });
      for (final bookId in <String?>[null, 'book']) {
        await tester.runAsync(() async {
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData.dark(),
              home: ReadingStatisticsPage(
                key: ValueKey(bookId),
                bookId: bookId,
                store: store,
                libraryStore: LibraryStore(booksDir: dir),
                progressStore: ProgressStore(preferences),
              ),
            ),
          );
          await Future<void>.delayed(const Duration(milliseconds: 300));
        });
        await tester.pumpAndSettle();
        expect(
          find.byType(ReadingTrend),
          bookId == null ? findsOneWidget : findsNothing,
        );
        if (bookId == null) {
          expect(find.text('No reading history book'), findsNothing);
          expect(find.byType(TextField), findsNothing);
          await tester.tap(find.text('总'));
          await tester.pumpAndSettle();
          expect(find.text('全部阅读记录'), findsNothing);
          expect(
            find.byKey(const ValueKey('statistics-period-navigation')),
            findsNothing,
          );
          await tester.tap(find.text('周'));
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<Wrap>(
                  find.byKey(const ValueKey('statistics-period-navigation')),
                )
                .alignment,
            WrapAlignment.start,
          );
          await tester.tap(find.text('年'));
          await tester.pumpAndSettle();
          expect(
            tester.widget<ReadingTrend>(find.byType(ReadingTrend)).start!.month,
            1,
          );
          await tester.tap(find.byTooltip('上一周期'));
          await tester.pumpAndSettle();
          expect(
            tester.widget<ReadingTrend>(find.byType(ReadingTrend)).start!.year,
            DateTime.now().year - 1,
          );
          await tester.tap(find.text('今年'));
          await tester.pumpAndSettle();
          expect(
            tester.widget<ReadingTrend>(find.byType(ReadingTrend)).start!.year,
            DateTime.now().year,
          );
          final selectedStart = tester
              .widget<ReadingTrend>(find.byType(ReadingTrend))
              .start;
          final bookRow = find.text('A book with a long title');
          await tester.ensureVisible(bookRow);
          await tester.tap(bookRow);
          for (var i = 0; i < 12; i++) {
            await tester.pump(const Duration(milliseconds: 100));
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 100)),
            );
          }
          await tester.pumpAndSettle();
          expect(find.text('阅读详情'), findsOneWidget);
          expect(find.byType(ReadingTrend), findsNothing);
          expect(find.byType(LinearProgressIndicator), findsNothing);
          expect(
            find.byKey(const ValueKey('statistics-reading-position')),
            findsOneWidget,
          );
          expect(find.byType(ExpansionTile), findsNothing);
          expect(find.text('阅读会话'), findsNothing);
          expect(find.byType(ListTile), findsWidgets);
          await tester.pageBack();
          for (var i = 0; i < 12; i++) {
            await tester.pump(const Duration(milliseconds: 100));
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 100)),
            );
          }
          await tester.pumpAndSettle();
          expect(
            tester.widget<ReadingTrend>(find.byType(ReadingTrend)).start,
            selectedStart,
          );
        }
        expect(find.text('计时中'), findsNothing);
        expect(find.text('暂停计时'), findsNothing);
        expect(tester.takeException(), isNull);
      }
      await tester.runAsync(() async {
        await store.setStatus(
          'book',
          ReadingStatus.finished,
          dayKey(DateTime.now()),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: ReadingStatisticsPage(
              key: const ValueKey('finished-detail'),
              bookId: 'book',
              store: store,
              libraryStore: LibraryStore(booksDir: dir),
              progressStore: ProgressStore(preferences),
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pumpAndSettle();
      expect(find.text('已读完'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('statistics-reading-position')),
        findsNothing,
      );
      expect(find.byType(LinearProgressIndicator), findsNothing);
    },
  );
}
