import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:torto/app/statistics/statistics_store.dart';

/// FFI normally accepts this misuse. Emulate the Android API restriction while
/// still using a real database for WAL, schema creation and reopening.
class _AndroidConfigureDatabase implements Database {
  final Database delegate;
  _AndroidConfigureDatabase(this.delegate);

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) async {
    if (sql.trim().toUpperCase().startsWith('PRAGMA JOURNAL_MODE')) {
      throw StateError('Queries must use query or rawQuery on Android');
    }
    await delegate.execute(sql, arguments);
  }

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) => delegate.rawQuery(sql, arguments);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _AndroidConfigureFactory implements DatabaseFactory {
  @override
  Future<Database> openDatabase(String path, {OpenDatabaseOptions? options}) =>
      databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: options!.version,
          onConfigure: (database) =>
              options.onConfigure!(_AndroidConfigureDatabase(database)),
          onCreate: options.onCreate,
        ),
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  test(
    'statistics opens with Android query rules and preserves records on reopen',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'torto-statistics-wal-',
      );
      final path = '${directory.path}/statistics.sqlite3';
      ReadingStatisticsStore? store;
      addTearDown(() async {
        await store?.database.close();
        await directory.delete(recursive: true);
      });
      final factory = _AndroidConfigureFactory();
      store = await ReadingStatisticsStore.openAt(
        path,
        'phone',
        factory: factory,
      );
      expect(
        (await store.database.rawQuery(
          'PRAGMA journal_mode',
        )).single.values.single,
        'wal',
      );
      await store.record('book', 'Metadata', {
        'title': 'Test book',
        'authors': '',
        'added': 1,
      });
      final before = (await store.events()).single;
      await store.database.close();

      store = await ReadingStatisticsStore.openAt(
        path,
        'phone',
        factory: factory,
      );
      final after = (await store.events()).single;
      expect(after.toJson(), before.toJson());
      expect(
        (await store.database.rawQuery(
          'PRAGMA journal_mode',
        )).single.values.single,
        'wal',
      );
    },
  );
}
