import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:torto/app/sync/sync_models.dart';
import 'package:torto/app/sync/sync_store.dart';

void main() {
  late Directory temporary;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('torto-sync-db-');
  });

  tearDown(() => temporary.delete(recursive: true));

  test('upgrades the phase-one database without losing its tables', () async {
    final path = '${temporary.path}${Platform.pathSeparator}sync.sqlite3';
    final old = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, _) async {
          await db.execute(
            'CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
          );
          await db.execute('''
            CREATE TABLE progress (
              book_id TEXT PRIMARY KEY, locator_json TEXT NOT NULL,
              wall_time_ms INTEGER NOT NULL, counter INTEGER NOT NULL,
              device_id TEXT NOT NULL
            )
          ''');
          await db.execute('''
            CREATE TABLE membership (
              book_id TEXT PRIMARY KEY, present INTEGER NOT NULL,
              wall_time_ms INTEGER NOT NULL, counter INTEGER NOT NULL,
              device_id TEXT NOT NULL
            )
          ''');
          await db.insert('membership', {
            'book_id': 'book',
            'present': 1,
            'wall_time_ms': 1,
            'counter': 0,
            'device_id': 'mobile',
          });
        },
      ),
    );
    await old.close();

    final store = await SyncStore.openAt(
      path,
      'mobile',
      factory: databaseFactoryFfi,
    );

    expect((await store.membership('book'))?.present, isTrue);
    expect(await store.annotationsForBook('book'), isEmpty);
    await store.close();
  });

  test('retains a visible conflict copy for concurrent annotations', () async {
    final store = await SyncStore.openAt(
      '${temporary.path}${Platform.pathSeparator}sync.sqlite3',
      'mobile',
      factory: databaseFactoryFfi,
    );
    final first = _annotation(
      note: 'mobile edit',
      device: 'mobile',
      wallTime: 100,
      clock: {'mobile': 1},
    );
    final incoming = _annotation(
      note: 'desktop edit',
      device: 'desktop',
      wallTime: 110,
      clock: {'desktop': 1},
    );

    expect(await store.mergeAnnotations([first]), 1);
    expect(await store.mergeAnnotations([incoming]), 1);
    final values = await store.annotationsForBook('book');

    expect(values, hasLength(2));
    expect(
      values.firstWhere((value) => value.id == 'note').note,
      'desktop edit',
    );
    expect(values.any((value) => value.conflictOf == 'note'), isTrue);
    await store.close();
  });

  test('drops locally cached progress using the obsolete href shape', () async {
    final store = await SyncStore.openAt(
      '${temporary.path}${Platform.pathSeparator}sync.sqlite3',
      'mobile',
      factory: databaseFactoryFfi,
    );
    await store.database.insert('progress', {
      'book_id': 'book',
      'locator_json':
          '{"version":1,"publication_id":"book","href":"chapter.xhtml"}',
      'wall_time_ms': 1,
      'counter': 0,
      'device_id': 'mobile',
    });

    expect(await store.progress('book'), isNull);
    expect(await store.database.query('progress'), isEmpty);
    await store.close();
  });
}

AnnotationState _annotation({
  required String note,
  required String device,
  required int wallTime,
  required Map<String, int> clock,
}) => AnnotationState(
  id: 'note',
  bookId: 'book',
  ranges: const [],
  quote: 'quote',
  note: note,
  createdAt: 1,
  updatedAt: HybridTimestamp(
    wallTimeMs: wallTime,
    counter: 0,
    deviceId: device,
  ),
  clock: clock,
  originDevice: device,
);
