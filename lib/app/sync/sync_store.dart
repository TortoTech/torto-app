import 'dart:convert';

import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../../core/ir/ir.dart';
import 'sync_models.dart';

class BookMembership {
  final String bookId;
  final bool present;
  final HybridTimestamp changedAt;

  const BookMembership({
    required this.bookId,
    required this.present,
    required this.changedAt,
  });
}

/// Regenerable local sync state. This database is never itself uploaded.
class SyncStore {
  final Database database;
  final String deviceId;

  SyncStore._(this.database, this.deviceId);

  static Future<SyncStore> open(String deviceId) async {
    final documents = await getApplicationDocumentsDirectory();
    final path = '${documents.path}/sync-v1.sqlite3';
    return openAt(path, deviceId);
  }

  static Future<SyncStore> openAt(
    String path,
    String deviceId, {
    DatabaseFactory? factory,
  }) async {
    final options = OpenDatabaseOptions(
      version: 2,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE progress (
            book_id TEXT PRIMARY KEY,
            locator_json TEXT NOT NULL,
            wall_time_ms INTEGER NOT NULL,
            counter INTEGER NOT NULL,
            device_id TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE membership (
            book_id TEXT PRIMARY KEY,
            present INTEGER NOT NULL,
            wall_time_ms INTEGER NOT NULL,
            counter INTEGER NOT NULL,
            device_id TEXT NOT NULL
          )
        ''');
        await _createAnnotationsTable(db);
      },
      onUpgrade: (db, oldVersion, _) async {
        if (oldVersion < 2) await _createAnnotationsTable(db);
      },
    );
    final database = factory == null
        ? await openDatabase(
            path,
            version: options.version,
            onCreate: options.onCreate,
            onUpgrade: options.onUpgrade,
          )
        : await factory.openDatabase(path, options: options);
    return SyncStore._(database, deviceId);
  }

  Future<void> close() => database.close();

  static Future<void> _createAnnotationsTable(DatabaseExecutor db) =>
      db.execute('''
        CREATE TABLE IF NOT EXISTS annotations (
          id TEXT PRIMARY KEY,
          book_id TEXT NOT NULL,
          origin_device TEXT NOT NULL,
          deleted INTEGER NOT NULL,
          payload_json TEXT NOT NULL
        )
      ''');

  Future<HybridTimestamp> tick() => database.transaction((txn) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final lastWall = int.tryParse(await _meta(txn, 'hlc_wall') ?? '') ?? 0;
    final lastCounter =
        int.tryParse(await _meta(txn, 'hlc_counter') ?? '') ?? 0;
    final wall = now > lastWall ? now : lastWall;
    final counter = wall == lastWall ? lastCounter + 1 : 0;
    await _setMeta(txn, 'hlc_wall', '$wall');
    await _setMeta(txn, 'hlc_counter', '$counter');
    return HybridTimestamp(
      wallTimeMs: wall,
      counter: counter,
      deviceId: deviceId,
    );
  });

  Future<void> _observe(HybridTimestamp timestamp) =>
      database.transaction((txn) async {
        final lastWall = int.tryParse(await _meta(txn, 'hlc_wall') ?? '') ?? 0;
        final lastCounter =
            int.tryParse(await _meta(txn, 'hlc_counter') ?? '') ?? 0;
        if (timestamp.wallTimeMs > lastWall) {
          await _setMeta(txn, 'hlc_wall', '${timestamp.wallTimeMs}');
          await _setMeta(txn, 'hlc_counter', '${timestamp.counter}');
        } else if (timestamp.wallTimeMs == lastWall &&
            timestamp.counter > lastCounter) {
          await _setMeta(txn, 'hlc_counter', '${timestamp.counter}');
        }
      });

  Future<StoredProgress?> progress(String bookId) async {
    final rows = await database.query(
      'progress',
      where: 'book_id = ?',
      whereArgs: [bookId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    try {
      return _progressFromRow(rows.first);
    } on FormatException {
      await database.delete(
        'progress',
        where: 'book_id = ?',
        whereArgs: [bookId],
      );
      return null;
    } on TypeError {
      await database.delete(
        'progress',
        where: 'book_id = ?',
        whereArgs: [bookId],
      );
      return null;
    }
  }

  Future<List<StoredProgress>> allProgress() async =>
      (await database.query('progress')).map(_progressFromRow).toList();

  /// Records a local reading event only when its cloud-safe locator changed.
  Future<StoredProgress> adoptLocalProgress(LocatorV1 locator) async {
    final existing = await progress(locator.publicationId);
    if (existing != null &&
        canonicalCloudLocator(existing.locator) ==
            canonicalCloudLocator(locator)) {
      return existing;
    }
    final timestamp = await tick();
    final value = StoredProgress(locator: locator, updatedAt: timestamp);
    await _putProgress(value);
    return value;
  }

  /// Applies last-writer-wins using the desktop-compatible HLC ordering.
  Future<bool> mergeProgress(StoredProgress incoming) async {
    await _observe(incoming.updatedAt);
    final existing = await progress(incoming.locator.publicationId);
    if (existing != null &&
        existing.updatedAt.compareTo(incoming.updatedAt) >= 0) {
      return false;
    }
    await _putProgress(incoming);
    return true;
  }

  Future<void> _putProgress(StoredProgress value) =>
      database.insert('progress', {
        'book_id': value.locator.publicationId,
        'locator_json': jsonEncode(value.locator.toJson()),
        'wall_time_ms': value.updatedAt.wallTimeMs,
        'counter': value.updatedAt.counter,
        'device_id': value.updatedAt.deviceId,
      }, conflictAlgorithm: ConflictAlgorithm.replace);

  Future<BookMembership> setMembership(String bookId, bool present) async {
    final current = await membership(bookId);
    if (current != null && current.present == present) return current;
    final timestamp = await tick();
    final value = BookMembership(
      bookId: bookId,
      present: present,
      changedAt: timestamp,
    );
    await database.insert('membership', {
      'book_id': bookId,
      'present': present ? 1 : 0,
      'wall_time_ms': timestamp.wallTimeMs,
      'counter': timestamp.counter,
      'device_id': timestamp.deviceId,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    return value;
  }

  Future<BookMembership?> membership(String bookId) async {
    final rows = await database.query(
      'membership',
      where: 'book_id = ?',
      whereArgs: [bookId],
      limit: 1,
    );
    return rows.isEmpty ? null : _membershipFromRow(rows.first);
  }

  Future<List<BookMembership>> memberships() async =>
      (await database.query('membership')).map(_membershipFromRow).toList();

  Future<List<AnnotationState>> annotationsForBook(
    String bookId, {
    bool includeDeleted = false,
  }) async {
    final rows = await database.query(
      'annotations',
      where: includeDeleted ? 'book_id = ?' : 'book_id = ? AND deleted = 0',
      whereArgs: [bookId],
      orderBy: 'id',
    );
    return rows.map(_annotationFromRow).toList();
  }

  Future<List<AnnotationState>> annotationsForDeviceBook(String bookId) async {
    final rows = await database.query(
      'annotations',
      where: 'book_id = ? AND origin_device = ?',
      whereArgs: [bookId, deviceId],
      orderBy: 'id',
    );
    return rows.map(_annotationFromRow).toList();
  }

  Future<int> mergeAnnotations(List<AnnotationState> incomingValues) async {
    for (final incoming in incomingValues) {
      incoming.validate();
      await _observe(incoming.updatedAt);
    }
    return database.transaction((txn) async {
      var changed = 0;
      for (final incoming in incomingValues) {
        final rows = await txn.query(
          'annotations',
          columns: ['payload_json'],
          where: 'id = ?',
          whereArgs: [incoming.id],
          limit: 1,
        );
        if (rows.isEmpty) {
          await _putAnnotation(txn, incoming);
          changed++;
          continue;
        }
        final current = AnnotationState.fromJson(
          jsonDecode(rows.first['payload_json']! as String)
              as Map<String, dynamic>,
        );
        switch (compareVectorClocks(current.clock, incoming.clock)) {
          case VectorClockOrder.before:
            await _putAnnotation(txn, incoming);
            changed++;
          case VectorClockOrder.after:
          case VectorClockOrder.equal:
            break;
          case VectorClockOrder.concurrent:
            final incomingWins =
                incoming.updatedAt.compareTo(current.updatedAt) > 0;
            final winner = incomingWins ? incoming : current;
            final loser = incomingWins ? current : incoming;
            if (!loser.deleted && loser.conflictOf == null) {
              final conflict = loser.copyWith(
                id: annotationConflictId(loser),
                conflictOf: incoming.id,
              );
              final exists = Sqflite.firstIntValue(
                await txn.rawQuery(
                  'SELECT COUNT(*) FROM annotations WHERE id = ?',
                  [conflict.id],
                ),
              );
              if (exists == 0) await _putAnnotation(txn, conflict);
            }
            await _putAnnotation(txn, winner);
            changed++;
        }
      }
      return changed;
    });
  }

  Future<void> _putAnnotation(DatabaseExecutor db, AnnotationState value) =>
      db.insert('annotations', {
        'id': value.id,
        'book_id': value.bookId,
        'origin_device': value.originDevice,
        'deleted': value.deleted ? 1 : 0,
        'payload_json': jsonEncode(value.toJson()),
      }, conflictAlgorithm: ConflictAlgorithm.replace);

  StoredProgress _progressFromRow(Map<String, Object?> row) => StoredProgress(
    locator: LocatorV1.fromJson(
      jsonDecode(row['locator_json']! as String) as Map<String, dynamic>,
    ),
    updatedAt: HybridTimestamp(
      wallTimeMs: row['wall_time_ms']! as int,
      counter: row['counter']! as int,
      deviceId: row['device_id']! as String,
    ),
  );

  BookMembership _membershipFromRow(Map<String, Object?> row) => BookMembership(
    bookId: row['book_id']! as String,
    present: row['present'] == 1,
    changedAt: HybridTimestamp(
      wallTimeMs: row['wall_time_ms']! as int,
      counter: row['counter']! as int,
      deviceId: row['device_id']! as String,
    ),
  );

  AnnotationState _annotationFromRow(Map<String, Object?> row) =>
      AnnotationState.fromJson(
        jsonDecode(row['payload_json']! as String) as Map<String, dynamic>,
      );

  Future<String?> _meta(DatabaseExecutor db, String key) async {
    final rows = await db.query(
      'meta',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  Future<void> _setMeta(DatabaseExecutor db, String key, String value) =>
      db.insert('meta', {
        'key': key,
        'value': value,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
}
