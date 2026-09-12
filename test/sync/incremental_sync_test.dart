import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:torto/app/sync/sync_store.dart';
import 'package:torto/app/sync/webdav_client.dart';
import 'package:torto/app/sync/sync_engine.dart';
import 'package:torto/app/sync/sync_models.dart';
import 'package:torto/app/progress_store.dart';
import 'package:torto/app/library/library_store.dart';
import 'package:torto/core/ir/ir.dart';
import 'package:crypto/crypto.dart';
import 'package:torto/app/statistics/statistics_store.dart';

class _Library extends LibraryStore {
  final List<LibraryBook> books;
  _Library(Directory directory, this.books) : super(booksDir: directory);
  @override
  Future<List<LibraryBook>> list() async => books;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  const device = '11111111-1111-4111-8111-111111111111';
  late SyncStore store;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = await SyncStore.openAt(
      inMemoryDatabasePath,
      device,
      factory: databaseFactoryFfi,
    );
  });
  tearDown(() => store.close());

  test(
    'full sync checks before transfers and publishes membership after manifests',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'torto-sync-plan-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final books = <LibraryBook>[];
      for (var i = 0; i < 2; i++) {
        final bytes = utf8.encode('test book $i');
        final file = File('${directory.path}/$i.epub');
        await file.writeAsBytes(bytes);
        books.add(
          LibraryBook(
            id: sha256.convert(bytes).toString(),
            file: file,
            title: 'Test $i',
            sizeBytes: bytes.length,
          ),
        );
      }
      final requests = <String>[];
      final dav = WebDavClient(
        baseUrl: 'https://dav.example.test',
        username: 'reader',
        password: 'test',
        cacheStore: store,
        client: MockClient((request) async {
          requests.add('${request.method} ${request.url.path}');
          if (request.method == 'MKCOL' || request.method == 'PUT') {
            return http.Response('', 201);
          }
          if (request.method == 'PROPFIND') {
            return http.Response('<d:multistatus xmlns:d="DAV:"/>', 207);
          }
          return http.Response('', 404);
        }),
      );
      addTearDown(dav.close);
      final phases = <SyncProgress>[];
      final report = await SyncEngine(
        libraryStore: _Library(directory, books),
        progressStore: ProgressStore(await SharedPreferences.getInstance()),
        syncStore: store,
        webdav: dav,
        settings: const CloudSettings(deviceId: device, deviceName: 'Phone'),
        onProgress: phases.add,
      ).sync();
      expect(report.uploadedBooks, 2);
      final firstUpload = requests.indexWhere(
        (r) => r.startsWith('PUT ') && r.contains('/content.'),
      );
      for (final book in books) {
        expect(
          requests.indexOf('GET /Rebook/v1/books/${book.id}/manifest.json'),
          lessThan(firstUpload),
        );
        expect(
          requests.indexOf('PUT /Rebook/v1/books/${book.id}/manifest.json'),
          lessThan(
            requests.indexOf('PUT /Rebook/v1/library/devices/$device.json'),
          ),
        );
      }
      expect(
        phases.where((p) => p.label == 'Uploading books…').last.fraction,
        1,
      );
    },
  );

  WebDavClient client(
    Future<http.Response> Function(http.Request) send, {
    String user = 'reader',
    bool force = false,
  }) => WebDavClient(
    baseUrl: 'https://dav.example.test',
    username: user,
    password: 'test',
    cacheStore: store,
    forceWrite: force,
    client: MockClient(send),
  );

  test(
    'conditional downloads survive client recreation and invalidate on 404',
    () async {
      var calls = 0;
      Future<http.Response> send(http.Request request) async {
        calls++;
        if (calls == 1) {
          return http.Response('{"value":1}', 200, headers: {'etag': '"v1"'});
        }
        if (calls == 2) {
          expect(request.headers['if-none-match'], '"v1"');
          return http.Response('', 304);
        }
        if (calls == 3) return http.Response('', 404);
        expect(request.headers['if-none-match'], isNull);
        return http.Response('{"value":2}', 200);
      }

      final first = client(send);
      expect(await first.getJsonOptional('test.json'), {'value': 1});
      first.close();
      final second = client(send);
      addTearDown(second.close);
      expect(await second.getJsonOptional('test.json'), {'value': 1});
      expect(await second.getOptional('test.json'), isNull);
      expect(await second.getJsonOptional('test.json'), {'value': 2});
    },
  );

  test(
    'unchanged writes are skipped, failures retried, and accounts isolated',
    () async {
      var calls = 0;
      var fail = true;
      Future<http.Response> send(http.Request request) async {
        calls++;
        return http.Response('', fail ? 503 : 201);
      }

      final first = client(send);
      addTearDown(first.close);
      await expectLater(
        first.putMutableJson('state.json', {'value': 1}),
        throwsA(isA<WebDavException>()),
      );
      fail = false;
      await first.putMutableJson('state.json', {'value': 1, 'updated_at': 1});
      await first.putMutableJson('state.json', {'value': 1, 'updated_at': 2});
      expect(calls, 2);
      final other = client(send, user: 'another');
      addTearDown(other.close);
      await other.putMutableJson('state.json', {'value': 1});
      expect(calls, 3);
      final forced = client(send, force: true);
      addTearDown(forced.close);
      await forced.putMutableJson('state.json', {'value': 1});
      expect(calls, 4);
    },
  );

  test(
    'reading sync skips book scans and retries a change made during upload',
    () async {
      final prefs = ProgressStore(await SharedPreferences.getInstance());
      final id = 'a' * 64;
      LocatorV1 locator(double p) => LocatorV1(
        publicationId: id,
        href: 'chapter.xhtml',
        position: 0,
        progression: p,
      );
      await prefs.save(locator(.1));
      var uploads = 0;
      final requests = <String>[];
      final dav = client((request) async {
        final path = request.url.path;
        requests.add('${request.method} $path');
        if (request.method == 'MKCOL') return http.Response('', 201);
        if (path.endsWith('protocol.json')) {
          return http.Response(
            jsonEncode({'version': 1, 'protocol': 'rebook-webdav'}),
            200,
          );
        }
        if (request.method == 'PUT') {
          uploads++;
          if (uploads == 1) await prefs.save(locator(.2));
          return http.Response('', 201);
        }
        if (request.method == 'PROPFIND') {
          return http.Response('<d:multistatus xmlns:d="DAV:"/>', 207);
        }
        throw StateError('Unexpected request: $path');
      });
      addTearDown(dav.close);
      final engine = SyncEngine(
        libraryStore: LibraryStore(booksDir: Directory('unused-reading-only')),
        progressStore: prefs,
        syncStore: store,
        webdav: dav,
        settings: const CloudSettings(deviceId: device, deviceName: 'Phone'),
      );
      await engine.sync(readingOnly: true);
      requests.clear();
      await engine.sync(readingOnly: true);
      expect(uploads, 2);
      expect(requests, [
        'PUT /Rebook/v1/state/$id/devices/$device.json',
        'PROPFIND /Rebook/v1/state/$id/devices/',
      ]);
      final count = requests.length;
      await engine.sync(readingOnly: true);
      expect(requests.length, count);
      expect(
        requests.any(
          (r) =>
              r.contains('manifest.json') ||
              r.contains('PROPFIND /Rebook/v1/library'),
        ),
        isFalse,
      );
    },
  );

  test(
    'directory cache survives clients and repairs deleted parents',
    () async {
      final directories = <String>{};
      final requests = <String>[];
      Future<http.Response> send(http.Request request) async {
        final path = request.url.path;
        requests.add('${request.method} $path');
        if (request.method == 'MKCOL') {
          final parent = request.url.resolve('../').path;
          if (parent != '/' && !directories.contains(parent)) {
            return http.Response('', 409);
          }
          return http.Response('', directories.add(path) ? 201 : 405);
        }
        if (request.method == 'PUT') {
          return http.Response(
            '',
            directories.contains(request.url.resolve('./').path) ? 201 : 409,
          );
        }
        throw StateError('Unexpected request');
      }

      final first = client(send);
      await first.ensureLayout();
      await first.ensureBookCollections('book');
      first.close();
      final second = client(send);
      addTearDown(second.close);
      requests.clear();
      await second.ensureLayout();
      await second.ensureBookCollections('book');
      expect(requests, isEmpty);
      directories.clear();
      await second.putMutableJson('state/book/devices/$device.json', {
        'value': 1,
      });
      expect(requests.where((r) => r.startsWith('PUT ')), hasLength(2));
      expect(directories, contains('/Rebook/v1/state/book/devices/'));
      requests.clear();
      await second.ensureLayout();
      await second.ensureBookCollections('book');
      // Cache hits remain cheap; future writes repair other missing branches.
      expect(requests, isEmpty);
    },
  );

  test('failed directory creation is not cached', () async {
    var fail = true;
    var calls = 0;
    final dav = client((request) async {
      calls++;
      return http.Response('', fail ? 503 : 201);
    });
    addTearDown(dav.close);
    await expectLater(dav.ensureLayout(), throwsA(isA<WebDavException>()));
    fail = false;
    await dav.ensureLayout();
    expect(calls, 10);
  });

  test(
    'book checks are bounded and drain active requests before failing',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'torto-parallel-sync-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final books = <LibraryBook>[];
      for (var i = 0; i < 10; i++) {
        final bytes = utf8.encode('book $i');
        books.add(
          LibraryBook(
            id: sha256.convert(bytes).toString(),
            file: await File('${directory.path}/$i.epub').writeAsBytes(bytes),
            title: 'Book $i',
            sizeBytes: bytes.length,
          ),
        );
      }
      final gate = Completer<void>();
      var started = 0, active = 0, peak = 0;
      final dav = client((request) async {
        if (request.method == 'MKCOL') return http.Response('', 201);
        if (request.url.path.endsWith('protocol.json')) {
          return http.Response('{"version":1,"protocol":"rebook-webdav"}', 200);
        }
        expect(request.method, 'GET');
        expect(request.url.path, endsWith('/manifest.json'));
        final ordinal = ++started;
        active++;
        if (active > peak) peak = active;
        if (started == 4) gate.complete();
        await gate.future.timeout(const Duration(seconds: 3));
        try {
          if (ordinal == 1) return http.Response('', 503);
          await Future<void>.delayed(const Duration(milliseconds: 30));
          return http.Response('', 404);
        } finally {
          active--;
        }
      });
      addTearDown(dav.close);
      await expectLater(
        SyncEngine(
          libraryStore: _Library(directory, books),
          progressStore: ProgressStore(await SharedPreferences.getInstance()),
          syncStore: store,
          webdav: dav,
          settings: const CloudSettings(deviceId: device, deviceName: 'Phone'),
        ).sync(),
        throwsA(isA<WebDavException>()),
      );
      expect(peak, 4);
      expect(started, 4);
      expect(active, 0);
    },
  );

  test(
    'warm full checks skip writes and repair missing device documents',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'torto-warm-sync-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final bytes = utf8.encode('book');
      final id = sha256.convert(bytes).toString();
      final file = await File(
        '${directory.path}/book.epub',
      ).writeAsBytes(bytes);
      final book = LibraryBook(
        id: id,
        file: file,
        title: 'Book',
        sizeBytes: bytes.length,
      );
      final objects = <String, List<int>>{};
      final requests = <String>[];
      Future<http.Response> send(http.Request request) async {
        final path = request.url.path;
        requests.add('${request.method} $path');
        switch (request.method) {
          case 'MKCOL':
            return http.Response('', 201);
          case 'PUT':
            objects[path] = request.bodyBytes;
            return http.Response('', 201);
          case 'PROPFIND':
            return http.Response(
              '<d:multistatus xmlns:d="DAV:">${objects.keys.where((key) => key.startsWith(path) && !key.substring(path.length).contains('/')).map((key) => '<d:response><d:href>$key</d:href></d:response>').join()}</d:multistatus>',
              207,
            );
          case 'GET':
            final body = objects[path];
            if (body == null) return http.Response('', 404);
            final etag = '"${sha256.convert(body)}"';
            if (request.headers['if-none-match'] == etag) {
              return http.Response('', 304);
            }
            return http.Response.bytes(body, 200, headers: {'etag': etag});
        }
        throw StateError('Unexpected request');
      }

      Future<SyncReport> run() async {
        final dav = client(send);
        try {
          return await SyncEngine(
            libraryStore: _Library(directory, [book]),
            progressStore: ProgressStore(await SharedPreferences.getInstance()),
            syncStore: store,
            webdav: dav,
            settings: const CloudSettings(
              deviceId: device,
              deviceName: 'Phone',
            ),
          ).sync();
        } finally {
          dav.close();
        }
      }

      await run();
      requests.clear();
      await run();
      expect(
        requests.where((r) => r.startsWith('PUT ') || r.startsWith('MKCOL ')),
        isEmpty,
      );
      final ownState = '/Rebook/v1/state/$id/devices/$device.json';
      final ownLibrary = '/Rebook/v1/library/devices/$device.json';
      objects.remove(ownState);
      objects.remove(ownLibrary);
      requests.clear();
      await run();
      expect(requests.where((r) => r.startsWith('PUT ')).toSet(), {
        'PUT $ownState',
        'PUT $ownLibrary',
      });
      final remotePath = '/Rebook/v1/state/$id/devices/desktop.json';
      void remoteProgress(double value, int time) {
        final timestamp = HybridTimestamp(
          wallTimeMs: time,
          counter: 0,
          deviceId: 'desktop',
        );
        objects[remotePath] = utf8.encode(
          jsonEncode({
            'version': 1,
            'device_id': 'desktop',
            'book_id': id,
            'updated_at': timestamp.toJson(),
            'annotations': [],
            'progress': StoredProgress(
              locator: LocatorV1(
                publicationId: id,
                href: 'chapter.xhtml',
                position: 0,
                progression: value,
              ),
              updatedAt: timestamp,
            ).toJson(),
          }),
        );
      }

      remoteProgress(.2, 1000);
      expect((await run()).mergedProgress, 1);
      final dav = client(send);
      addTearDown(dav.close);
      final appliedKey = 'applied:state/$id/devices/desktop.json';
      final digest = await dav.cacheGet(appliedKey);
      expect(digest, isNotNull);
      expect((await run()).mergedProgress, 0);
      expect(await dav.cacheGet(appliedKey), digest);
      remoteProgress(.3, 2000);
      expect((await run()).mergedProgress, 1);
      expect(await dav.cacheGet(appliedKey), isNot(digest));
    },
  );

  test(
    'unchanged statistics bypass event inserts and missing shards are repaired',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'torto-stats-cache-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final statistics = await ReadingStatisticsStore.openAt(
        '${directory.path}/stats.sqlite',
        device,
        factory: databaseFactoryFfi,
      );
      addTearDown(statistics.database.close);
      await statistics.database.execute(
        'CREATE TABLE insert_count (n INTEGER)',
      );
      await statistics.database.execute('INSERT INTO insert_count VALUES (0)');
      await statistics.database.execute(
        'CREATE TRIGGER count_events BEFORE INSERT ON events BEGIN UPDATE insert_count SET n = n + 1; END',
      );
      await statistics.record('book', 'Clear', {});
      final objects = <String, String>{};
      var puts = 0;
      final dav = client((request) async {
        if (request.method == 'PROPFIND') {
          return http.Response(
            '<d:multistatus xmlns:d="DAV:">${objects.keys.map((key) => '<d:response><d:href>$key</d:href></d:response>').join()}</d:multistatus>',
            207,
          );
        }
        if (request.method == 'PUT') {
          puts++;
          objects[request.url.path] = request.body;
          return http.Response('', 201);
        }
        return objects.containsKey(request.url.path)
            ? http.Response(objects[request.url.path]!, 200)
            : http.Response('', 404);
      });
      addTearDown(dav.close);
      await statistics.sync(dav);
      await statistics.sync(dav);
      final before = await statistics.database.query('insert_count');
      await statistics.sync(dav);
      expect(await statistics.database.query('insert_count'), before);
      expect(puts, 1);
      objects.clear();
      await statistics.sync(dav);
      expect(puts, 2);
      expect(objects, hasLength(1));
    },
  );
}
