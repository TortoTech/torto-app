import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

class WebDavObject {
  final Uint8List bytes;

  const WebDavObject(this.bytes);
}

class WebDavException implements Exception {
  final String message;
  final int? statusCode;

  const WebDavException(this.message, [this.statusCode]);

  @override
  String toString() =>
      statusCode == null ? message : '$message (HTTP $statusCode)';
}

/// Small WebDAV client constrained to the Torto/Rebook v1 remote root.
class WebDavClient {
  static const _timeout = Duration(seconds: 45);

  final Uri root;
  final String username;
  final String password;
  final bool cstCloudCompatibility;
  final String userAgent;
  final http.Client _client;

  WebDavClient({
    required String baseUrl,
    required this.username,
    required this.password,
    this.cstCloudCompatibility = false,
    this.userAgent = 'Torto/0.1.0 Zotero/7.0',
    http.Client? client,
  }) : root = _protocolRoot(baseUrl),
       _client = client ?? http.Client();

  void close() => _client.close();

  static Uri _protocolRoot(String value) {
    final base = Uri.parse(value.trim());
    if (!base.hasScheme || base.host.isEmpty) {
      throw const FormatException('WebDAV URL is invalid.');
    }
    final local =
        base.host == 'localhost' ||
        base.host == '127.0.0.1' ||
        base.host == '::1';
    if (base.scheme != 'https' && !(local && base.scheme == 'http')) {
      throw const FormatException('WebDAV must use HTTPS.');
    }
    final segments = [
      ...base.pathSegments.where((segment) => segment.isNotEmpty),
      'Rebook',
      'v1',
    ];
    return base.replace(pathSegments: [...segments, '']);
  }

  Uri _uri(String path) => root.resolve(_physicalPath(path));

  String _physicalPath(String logicalPath) {
    if (!cstCloudCompatibility || logicalPath.endsWith('/')) {
      return logicalPath;
    }
    final lower = logicalPath.toLowerCase();
    if (lower.endsWith('.json')) return '$logicalPath.prop';
    if (lower.endsWith('.zip') || lower.endsWith('.prop')) return logicalPath;
    return '$logicalPath.zip';
  }

  Map<String, String> get _baseHeaders => {
    HttpHeaders.authorizationHeader:
        'Basic ${base64Encode(utf8.encode('$username:$password'))}',
    if (cstCloudCompatibility) HttpHeaders.userAgentHeader: userAgent,
  };

  Future<void> ensureLayout() async {
    for (final uri in [root.resolve('../'), root]) {
      final response = await _sendUri('MKCOL', uri);
      if (response.statusCode != 201 &&
          response.statusCode != 200 &&
          response.statusCode != 405) {
        throw WebDavException(
          'Could not create the sync folder.',
          response.statusCode,
        );
      }
    }
    final collections = <String>[
      'library/',
      'library/devices/',
      'books/',
      'state/',
      'derived/',
      'tmp/',
    ];
    for (final path in collections) {
      final response = await _send('MKCOL', path);
      if (response.statusCode != 201 &&
          response.statusCode != 200 &&
          response.statusCode != 405) {
        throw WebDavException(
          'Could not create the sync folder.',
          response.statusCode,
        );
      }
    }
  }

  Future<void> ensureBookCollections(String bookId) async {
    for (final path in [
      'books/$bookId/',
      'state/$bookId/',
      'state/$bookId/devices/',
    ]) {
      final response = await _send('MKCOL', path);
      if (response.statusCode != 201 &&
          response.statusCode != 200 &&
          response.statusCode != 405) {
        throw WebDavException(
          'Could not create a book sync folder.',
          response.statusCode,
        );
      }
    }
  }

  Future<WebDavObject?> getOptional(String path) async {
    final response = await _send('GET', path);
    if (response.statusCode == 404) return null;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw WebDavException('Could not download $path.', response.statusCode);
    }
    return WebDavObject(response.bodyBytes);
  }

  Future<Map<String, dynamic>?> getJsonOptional(String path) async {
    final object = await getOptional(path);
    if (object == null) return null;
    final decoded = jsonDecode(utf8.decode(object.bytes));
    if (decoded is! Map<String, dynamic>) {
      throw WebDavException('$path is not a JSON object.');
    }
    return decoded;
  }

  Future<bool> putImmutableBytes(
    String path,
    List<int> bytes, {
    String contentType = 'application/octet-stream',
  }) async {
    if (cstCloudCompatibility && await _exists(path)) return false;
    final response = await _send(
      'PUT',
      path,
      headers: {
        if (!cstCloudCompatibility) HttpHeaders.ifNoneMatchHeader: '*',
        HttpHeaders.contentTypeHeader: contentType,
      },
      body: bytes,
    );
    if (response.statusCode == 412) return false;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw WebDavException('Could not upload $path.', response.statusCode);
    }
    return true;
  }

  Future<bool> putImmutableFile(String path, File file) async {
    if (cstCloudCompatibility && await _exists(path)) return false;
    final request = http.StreamedRequest('PUT', _uri(path));
    request.headers.addAll({
      ..._baseHeaders,
      if (!cstCloudCompatibility) HttpHeaders.ifNoneMatchHeader: '*',
      HttpHeaders.contentTypeHeader: 'application/octet-stream',
    });
    request.contentLength = await file.length();
    final sending = _client.send(request).timeout(_timeout);
    await request.sink.addStream(file.openRead());
    await request.sink.close();
    final response = await sending;
    await response.stream.drain<void>();
    if (response.isRedirect) {
      throw const WebDavException(
        'WebDAV redirected a file upload; update the server URL.',
      );
    }
    if (response.statusCode == 412) return false;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw WebDavException('Could not upload $path.', response.statusCode);
    }
    return true;
  }

  Future<void> putMutableJson(String path, Map<String, Object?> value) async {
    final response = await _send(
      'PUT',
      path,
      headers: {HttpHeaders.contentTypeHeader: 'application/json'},
      body: utf8.encode(const JsonEncoder.withIndent('  ').convert(value)),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw WebDavException('Could not update $path.', response.statusCode);
    }
  }

  Future<List<String>> listJsonFiles(String path) async {
    final response = await _send(
      'PROPFIND',
      path,
      headers: {'Depth': '1', HttpHeaders.contentTypeHeader: 'application/xml'},
      body: utf8.encode(
        '<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>',
      ),
    );
    if (response.statusCode == 404) return const [];
    if (response.statusCode != 207 &&
        (response.statusCode < 200 || response.statusCode >= 300)) {
      throw WebDavException('Could not list $path.', response.statusCode);
    }
    final document = XmlDocument.parse(response.body);
    final names = <String>{};
    for (final hrefElement in document.descendants.whereType<XmlElement>()) {
      if (hrefElement.name.local != 'href') continue;
      final href = Uri.tryParse(hrefElement.innerText.trim());
      final segments = href?.pathSegments
          .where((value) => value.isNotEmpty)
          .toList();
      if (segments == null || segments.isEmpty) continue;
      final name = Uri.decodeComponent(segments.last);
      final lower = name.toLowerCase();
      if (lower.endsWith('.json')) {
        names.add(name);
      } else if (cstCloudCompatibility && lower.endsWith('.json.prop')) {
        names.add(name.substring(0, name.length - '.prop'.length));
      }
    }
    return names.toList()..sort();
  }

  /// Resumes an interrupted download and validates the final byte count.
  Future<void> downloadToFile(
    String path,
    File target,
    int expectedLength, {
    void Function(int received, int total)? onProgress,
  }) async {
    await target.parent.create(recursive: true);
    var offset = await target.exists() ? await target.length() : 0;
    if (offset > expectedLength) {
      await target.delete();
      offset = 0;
    }
    if (offset == expectedLength) {
      onProgress?.call(offset, expectedLength);
      return;
    }

    final request = http.Request('GET', _uri(path));
    request.headers.addAll(_baseHeaders);
    if (offset > 0) request.headers[HttpHeaders.rangeHeader] = 'bytes=$offset-';
    request.followRedirects = false;
    final response = await _client.send(request).timeout(_timeout);
    if (response.isRedirect) {
      throw const WebDavException(
        'WebDAV redirected a download; update the server URL.',
      );
    }
    if (response.statusCode == 404) {
      throw WebDavException('Remote book content is missing.', 404);
    }
    if (response.statusCode != 200 && response.statusCode != 206) {
      throw WebDavException('Could not download $path.', response.statusCode);
    }
    if (offset > 0 && response.statusCode == 206) {
      final rangeStart = _contentRangeStart(
        response.headers[HttpHeaders.contentRangeHeader],
      );
      if (rangeStart != offset) {
        await response.stream.drain<void>();
        throw const WebDavException(
          'WebDAV returned an invalid Content-Range.',
        );
      }
    }
    if (offset > 0 && response.statusCode == 200) {
      offset = 0;
    }
    final sink = target.openWrite(
      mode: offset == 0 ? FileMode.write : FileMode.append,
    );
    var received = offset;
    try {
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, expectedLength);
      }
    } finally {
      await sink.close();
    }
    if (received != expectedLength) {
      throw WebDavException(
        'Downloaded size mismatch: expected $expectedLength bytes, got $received.',
      );
    }
  }

  Future<http.Response> _send(
    String method,
    String path, {
    Map<String, String> headers = const {},
    List<int>? body,
  }) => _sendUri(method, _uri(path), headers: headers, body: body);

  Future<http.Response> _sendUri(
    String method,
    Uri initialUri, {
    Map<String, String> headers = const {},
    List<int>? body,
  }) async {
    var uri = initialUri;
    for (var redirects = 0; redirects <= 5; redirects++) {
      final request = http.Request(method, uri)
        ..headers.addAll(_baseHeaders)
        ..headers.addAll(headers)
        ..followRedirects = false;
      if (body != null) request.bodyBytes = body;
      final streamed = await _client.send(request).timeout(_timeout);
      final response = await http.Response.fromStream(streamed);
      if (!response.isRedirect) return response;
      final location = response.headers[HttpHeaders.locationHeader];
      if (location == null) return response;
      final next = uri.resolve(location);
      if (!_sameOrigin(uri, next)) {
        throw const WebDavException('WebDAV redirected to an untrusted host.');
      }
      uri = next;
    }
    throw const WebDavException('WebDAV redirected too many times.');
  }

  static bool _sameOrigin(Uri a, Uri b) =>
      a.scheme == b.scheme && a.host == b.host && a.port == b.port;

  Future<bool> _exists(String path) async {
    final response = await _send(
      'GET',
      path,
      headers: {HttpHeaders.rangeHeader: 'bytes=0-0'},
    );
    if (response.statusCode == 404) return false;
    if (response.statusCode >= 200 && response.statusCode < 300) return true;
    throw WebDavException(
      'Could not check whether $path already exists.',
      response.statusCode,
    );
  }

  static int? _contentRangeStart(String? value) {
    if (value == null || !value.startsWith('bytes ')) return null;
    final separator = value.indexOf('-', 6);
    if (separator < 0) return null;
    return int.tryParse(value.substring(6, separator));
  }
}
