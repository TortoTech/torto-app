import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import '../library/library_store.dart';
import '../sync/cloud_settings_store.dart';
import '../sync/webdav_client.dart';
import 'statistics_model.dart';

class ReadingStatisticsStore {
  final Database database;
  final String device;
  ReadingStatisticsStore(this.database, this.device);
  static Future<ReadingStatisticsStore>? _instance;
  static Future<ReadingStatisticsStore> instance() =>
      _instance ??= _open().catchError((Object error) {
        _instance = null;
        throw error;
      });
  static Future<ReadingStatisticsStore> _open() async {
    final dir = await getApplicationDocumentsDirectory();
    final settings = await CloudSettingsStore().load();
    return openAt(
      '${dir.path}/reading-statistics-v1.sqlite3',
      settings.deviceId,
    );
  }

  static Future<ReadingStatisticsStore> openAt(
    String path,
    String device, {
    DatabaseFactory? factory,
  }) async {
    final db = await (factory ?? databaseFactory).openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onConfigure: (db) async {
          // journal_mode returns a row. Android SQLite rejects result-bearing
          // statements through execute(), although desktop FFI permits them.
          await db.rawQuery('PRAGMA journal_mode=WAL');
        },
        onCreate: (db, _) async {
          await db.execute(
            'CREATE TABLE events(id TEXT PRIMARY KEY, device TEXT NOT NULL, at INTEGER NOT NULL, json TEXT NOT NULL)',
          );
          await db.execute('CREATE INDEX events_device ON events(device, at)');
        },
        onOpen: (db) async {
          await db.execute(
            'CREATE TABLE IF NOT EXISTS sync_applied (key TEXT PRIMARY KEY, digest TEXT NOT NULL)',
          );
        },
      ),
    );
    return ReadingStatisticsStore(db, device);
  }

  Future<List<ReadingEvent>> events() async =>
      (await database.query('events', orderBy: 'at,id'))
          .map(
            (row) => ReadingEvent.fromJson(
              jsonDecode(row['json'] as String) as Map<String, dynamic>,
            ),
          )
          .toList();
  Future<void> merge(List<ReadingEvent> events) async {
    // Validate the complete shard before making it visible.
    for (final e in events) {
      ReadingEvent.fromJson(e.toJson());
    }
    await database.transaction((txn) async {
      final batch = txn.batch();
      for (final e in events) {
        batch.insert('events', {
          'id': e.id,
          'device': e.device,
          'at': e.at,
          'json': jsonEncode(e.toJson()),
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> record(String book, String type, Map<String, dynamic> data) =>
      merge([
        ReadingEvent(
          const Uuid().v4(),
          device,
          book,
          DateTime.now().millisecondsSinceEpoch,
          type,
          data,
        ),
      ]);
  Future<void> registerBooks(Iterable<LibraryBook> books) async {
    final existing = aggregateStatistics(await events());
    for (final book in books) {
      if (book.id.isEmpty) continue;
      final previous = existing[book.id];
      if (previous != null &&
          previous.title == book.title &&
          previous.authors == book.authors.join(', ') &&
          previous.added == book.addedAt) {
        continue;
      }
      await record(book.id, 'Metadata', {
        'title': book.title,
        'authors': book.authors.join(', '),
        'added': book.addedAt,
      });
    }
  }

  Future<void> setStatus(String book, ReadingStatus status, String? finished) =>
      record(book, 'Status', {
        'status': switch (status) {
          ReadingStatus.notStarted => 'NotStarted',
          ReadingStatus.reading => 'Reading',
          ReadingStatus.finished => 'Finished',
        },
        'finished': status == ReadingStatus.finished
            ? finished ?? dayKey(DateTime.now())
            : null,
      });
  Future<void> clear(String book) => record(book, 'Clear', {});
  Future<void> sync(WebDavClient webdav) async {
    final files = await webdav.listJsonFiles('statistics/');
    for (final file in files) {
      if (file.contains('/') || file.contains('\\')) continue;
      final object = await webdav.getOptional('statistics/$file');
      if (object == null) continue;
      if (object.bytes.length > 32 * 1024 * 1024) {
        throw const FormatException('Statistics shard too large');
      }
      final digest = sha256.convert(object.bytes).toString();
      // Keep acknowledgments with the events they describe, so recreating
      // this database cannot leave stale acknowledgments in the sync store.
      final appliedKey = '${webdav.accountKey}:$file';
      final applied = await database.query(
        'sync_applied',
        where: 'key = ?',
        whereArgs: [appliedKey],
      );
      if (applied.isNotEmpty && applied.single['digest'] == digest) continue;
      final json = jsonDecode(utf8.decode(object.bytes));
      if (json is! Map ||
          json['version'] != 1 ||
          json['events'] is! List ||
          (json['events'] as List).length > 100000) {
        throw const FormatException('Unsupported statistics shard');
      }
      await merge(
        (json['events'] as List)
            .map(
              (e) => ReadingEvent.fromJson(Map<String, dynamic>.from(e as Map)),
            )
            .toList(),
      );
      await database.insert('sync_applied', {
        'key': appliedKey,
        'digest': digest,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    final shards = <String, List<Map<String, Object?>>>{};
    for (final e in await events()) {
      if (e.device != device) continue;
      final month = dayKey(
        DateTime.fromMillisecondsSinceEpoch(e.at, isUtc: true),
      ).substring(0, 7);
      shards.putIfAbsent(month, () => []).add(e.toJson());
    }
    for (final shard in shards.entries) {
      final file = '$device-${shard.key}.json';
      if (!files.contains(file)) {
        await webdav.invalidatePublished('statistics/$file');
      }
      await webdav.putMutableJson('statistics/$file', {
        'version': 1,
        'events': shard.value,
      });
    }
  }
}
