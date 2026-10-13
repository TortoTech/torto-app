import 'dart:io';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:torto/app/sync/derived_data_store.dart';
import 'package:torto/app/sync/webdav_client.dart';

void main() {
  test(
    'local native generation publishes under a lock and clears its pending flag',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'torto-native-upload-',
      );
      addTearDown(() => root.delete(recursive: true));
      final books = await Directory('${root.path}/books').create(),
          store = DerivedDataStore.fromBooksDirectory(books);
      final local = await Directory(
        '${store.root.path}/book',
      ).create(recursive: true);
      final bytes = [4, 3, 2, 1];
      await File('${local.path}/native-pdf.zip').writeAsBytes(bytes);
      await File('${local.path}/native-pdf.json').writeAsString(
        jsonEncode({
          'version': 1,
          'book_id': 'book',
          'content_length': bytes.length,
          'content_sha256': sha256.convert(bytes).toString(),
          'pending_upload': true,
          'base_content_sha256': null,
        }),
      );
      final operations = <String>[];
      final webdav = WebDavClient(
        baseUrl: 'https://example.test/dav',
        username: 'u',
        password: 'p',
        client: MockClient((request) async {
          operations.add(request.method);
          if (request.method == 'MKCOL') return http.Response('', 201);
          if (request.method == 'LOCK') {
            return http.Response(
              '',
              200,
              headers: {'lock-token': '<opaquelocktoken:test>'},
            );
          }
          if (request.method == 'UNLOCK') return http.Response('', 204);
          if (request.method == 'PUT') {
            expect(request.headers['if'], '(<opaquelocktoken:test>)');
            if (request.url.path.endsWith('.zip')) {
              expect(request.bodyBytes, bytes);
            } else {
              expect(
                jsonDecode(request.body).containsKey('pending_upload'),
                isFalse,
              );
            }
            return http.Response('', 201);
          }
          return http.Response('', 404);
        }),
      );
      addTearDown(webdav.close);
      expect(await store.syncRemoteBook(webdav, 'book'), 1);
      expect(operations.where((o) => o == 'PUT'), hasLength(2));
      expect(operations.indexOf('LOCK'), lessThan(operations.indexOf('PUT')));
      expect(operations.last, 'UNLOCK');
      expect(
        jsonDecode(
          await File('${local.path}/native-pdf.json').readAsString(),
        ).containsKey('pending_upload'),
        isFalse,
      );
    },
  );
  test(
    'a newer cloud generation does not overwrite a pending phone generation',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'torto-native-conflict-',
      );
      addTearDown(() => root.delete(recursive: true));
      final books = await Directory('${root.path}/books').create(),
          store = DerivedDataStore.fromBooksDirectory(books);
      final local = await Directory(
        '${store.root.path}/book',
      ).create(recursive: true);
      await File('${local.path}/native-pdf.zip').writeAsString('phone');
      await File('${local.path}/native-pdf.json').writeAsString(
        jsonEncode({
          'version': 1,
          'book_id': 'book',
          'content_length': 5,
          'content_sha256': sha256.convert(utf8.encode('phone')).toString(),
          'pending_upload': true,
          'base_content_sha256': 'previous',
        }),
      );
      final webdav = WebDavClient(
        baseUrl: 'https://example.test/dav',
        username: 'u',
        password: 'p',
        client: MockClient((request) async {
          expect(request.method, 'GET');
          return request.url.path.endsWith('native-pdf.json')
              ? http.Response(jsonEncode({'content_sha256': 'newer'}), 200)
              : http.Response('', 404);
        }),
      );
      addTearDown(webdav.close);
      await expectLater(
        store.syncRemoteBook(webdav, 'book'),
        throwsA(isA<WebDavException>()),
      );
      expect(
        await File('${local.path}/native-pdf.zip').readAsString(),
        'phone',
      );
    },
  );
  test(
    'native archive downloads without OCR and is hash-checked and reused',
    () async {
      final root = await Directory.systemTemp.createTemp('torto-native-sync-');
      addTearDown(() => root.delete(recursive: true));
      final books = await Directory('${root.path}/books').create();
      final store = DerivedDataStore.fromBooksDirectory(books);
      final bytes = [1, 2, 3, 4];
      var downloads = 0;
      final webdav = WebDavClient(
        baseUrl: 'https://example.test/dav',
        username: 'u',
        password: 'p',
        client: MockClient((request) async {
          if (request.url.path.endsWith('/native-pdf.json')) {
            return http.Response(
              jsonEncode({
                'version': 1,
                'book_id': 'book',
                'content_length': bytes.length,
                'content_sha256': sha256.convert(bytes).toString(),
              }),
              200,
            );
          }
          if (request.url.path.endsWith('/native-pdf.zip')) {
            downloads++;
            return http.Response.bytes(bytes, 200);
          }
          return http.Response('', 404);
        }),
      );
      addTearDown(webdav.close);
      expect(await store.syncRemoteBook(webdav, 'book'), 1);
      expect(await store.syncRemoteBook(webdav, 'book'), 0);
      expect(downloads, 1);
      expect(
        await File('${store.root.path}/book/native-pdf.zip').readAsBytes(),
        bytes,
      );
    },
  );
}
