import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:torto/app/sync/webdav_client.dart';

void main() {
  test(
    'uses the historical Rebook/v1 root and creates its collections',
    () async {
      final requests = <http.Request>[];
      final client = WebDavClient(
        baseUrl: 'https://dav.example.test/account',
        username: 'reader',
        password: 'secret',
        client: MockClient((request) async {
          requests.add(request);
          return http.Response('', 405);
        }),
      );

      await client.ensureLayout();

      expect(
        client.root.toString(),
        'https://dav.example.test/account/Rebook/v1/',
      );
      expect(requests, hasLength(8));
      expect(requests.first.method, 'MKCOL');
      expect(
        requests.first.url.toString(),
        'https://dav.example.test/account/Rebook/',
      );
      expect(requests.first.headers['authorization'], startsWith('Basic '));
    },
  );

  test('parses JSON file names from a WebDAV multistatus response', () async {
    final client = WebDavClient(
      baseUrl: 'https://dav.example.test/root',
      username: 'u',
      password: 'p',
      client: MockClient((request) async {
        expect(request.method, 'PROPFIND');
        return http.Response(
          '''<?xml version="1.0"?>
          <d:multistatus xmlns:d="DAV:">
            <d:response><d:href>/root/Rebook/v1/library/devices/</d:href></d:response>
            <d:response><d:href>/root/Rebook/v1/library/devices/a.json</d:href></d:response>
            <d:response><d:href>/root/Rebook/v1/library/devices/b%20c.json</d:href></d:response>
          </d:multistatus>''',
          207,
          headers: {'content-type': 'application/xml'},
        );
      }),
    );

    expect(await client.listJsonFiles('library/devices/'), [
      'a.json',
      'b c.json',
    ]);
  });

  test('rejects insecure non-local WebDAV endpoints', () {
    expect(
      () => WebDavClient(
        baseUrl: 'http://dav.example.test',
        username: 'u',
        password: 'p',
      ),
      throwsFormatException,
    );
  });

  test('mutable JSON is overwritten without conditional headers', () async {
    final requests = <http.Request>[];
    final client = WebDavClient(
      baseUrl: 'https://dav.example.test',
      username: 'u',
      password: 'p',
      client: MockClient((request) async {
        requests.add(request);
        expect(request.method, 'PUT');
        expect(request.headers, isNot(contains('if-match')));
        expect(request.headers, isNot(contains('if-none-match')));
        expect(jsonDecode(request.body), {'version': 1});
        return http.Response('', 204);
      }),
    );

    await client.putMutableJson('device.json', {'version': 1});
    expect(requests, hasLength(1));
  });

  test('immutable upload does not treat a missing collection as success', () {
    final client = WebDavClient(
      baseUrl: 'https://dav.example.test',
      username: 'u',
      password: 'p',
      client: MockClient((request) async => http.Response('', 409)),
    );

    expect(
      client.putImmutableBytes('books/id/content.epub', [1, 2, 3]),
      throwsA(
        isA<WebDavException>().having(
          (error) => error.statusCode,
          'statusCode',
          409,
        ),
      ),
    );
  });

  test('resumed download validates the returned Content-Range', () async {
    final directory = await Directory.systemTemp.createTemp(
      'torto-webdav-range-',
    );
    final target = File('${directory.path}${Platform.pathSeparator}book.part');
    await target.writeAsBytes([1, 2]);
    final client = WebDavClient(
      baseUrl: 'https://dav.example.test',
      username: 'u',
      password: 'p',
      client: MockClient((request) async {
        expect(request.headers['range'], 'bytes=2-');
        return http.Response(
          String.fromCharCodes([3, 4]),
          206,
          headers: {'content-range': 'bytes 1-2/4'},
        );
      }),
    );

    try {
      await expectLater(
        client.downloadToFile('books/id/content.epub', target, 4),
        throwsA(isA<WebDavException>()),
      );
      expect(await target.readAsBytes(), [1, 2]);
    } finally {
      client.close();
      await directory.delete(recursive: true);
    }
  });
}
