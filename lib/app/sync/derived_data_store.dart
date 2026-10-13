import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../../core/ir/ir.dart';
import '../../core/formats/pdf/native_store.dart';
import 'webdav_client.dart';

class DerivedBookMetadata {
  final String title;
  final List<String> authors;

  const DerivedBookMetadata({this.title = '', this.authors = const []});
}

/// Local cache for regenerable desktop-derived data. The cache is consumed by
/// the shelf, generated PDF TOC, and PDF OCR reflow reader. Large OCR archives
/// remain on disk rather than in the sync database.
class DerivedDataStore {
  static const _maxOcrBytes = 768 * 1024 * 1024;

  final Directory root;

  DerivedDataStore.fromBooksDirectory(Directory booksDirectory)
    : root = Directory(
        '${booksDirectory.parent.path}${Platform.pathSeparator}derived-sync-v1',
      );

  Directory _bookDirectory(String bookId) =>
      Directory('${root.path}${Platform.pathSeparator}$bookId');

  Future<void> savePdfDiscovery(
    String bookId, {
    required String title,
    required List<String> authors,
    required List<Map<String, dynamic>> entries,
    required List<Map<String, dynamic>> specialPages,
  }) async {
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(bookId)) {
      throw const FormatException('Invalid book identity');
    }
    final directory = _bookDirectory(bookId);
    await directory.create(recursive: true);
    final file = File(
      '${directory.path}${Platform.pathSeparator}metadata.json',
    );
    Map<String, dynamic> stored = {};
    try {
      stored = Map<String, dynamic>.from(
        jsonDecode(await file.readAsString()) as Map,
      );
    } catch (_) {}
    final value = {
      ...stored,
      'version': 1,
      'book_id': bookId,
      if (title.isNotEmpty || authors.isNotEmpty)
        'metadata': {
          'version': 1,
          'book_id': bookId,
          'metadata': {'title': title, 'authors': authors},
        },
      if (entries.isNotEmpty || specialPages.isNotEmpty)
        'toc': {
          if (stored['toc'] is Map) ...(stored['toc'] as Map),
          'version': 1,
          'book_id': bookId,
          'verified_pages': true,
          'page_mapping_revision': 2,
          'entries': entries.isNotEmpty
              ? entries
              : (stored['toc'] is Map ? stored['toc']['entries'] ?? [] : []),
          'special_pages': specialPages,
        },
    };
    await _writeAtomicIfChanged(file, utf8.encode(jsonEncode(value)));
  }

  Future<int> syncRemoteBook(
    WebDavClient webdav,
    String bookId, {
    void Function(int received, int total)? onProgress,
  }) async {
    var changed = 0;
    final directory = _bookDirectory(bookId);
    await directory.create(recursive: true);

    final metadata = await webdav.getOptional('derived/$bookId/metadata.json');
    if (metadata != null) {
      _validateMetadata(bookId, metadata.bytes);
      if (await _writeAtomicIfChanged(
        File('${directory.path}${Platform.pathSeparator}metadata.json'),
        metadata.bytes,
      )) {
        changed++;
      }
    }

    changed += await _syncArchive(webdav, bookId, 'ocr', directory, onProgress);
    changed += await _syncArchive(
      webdav,
      bookId,
      'native-pdf',
      directory,
      onProgress,
    );
    return changed;
  }

  Future<int> _syncArchive(
    WebDavClient webdav,
    String bookId,
    String kind,
    Directory directory,
    void Function(int, int)? onProgress,
  ) async {
    final manifestObject = await webdav.getOptional(
      'derived/$bookId/$kind.json',
    );
    if (kind == 'native-pdf') {
      final file = File('${directory.path}/$kind.json');
      Map<String, dynamic>? pending;
      try {
        pending = Map<String, dynamic>.from(
          jsonDecode(await file.readAsString()) as Map,
        );
      } catch (_) {}
      if (pending?['pending_upload'] == true) {
        final remote = manifestObject == null
            ? null
            : jsonDecode(utf8.decode(manifestObject.bytes)) as Map;
        final hash = remote?['content_sha256'];
        if (hash == pending!['content_sha256']) {
          await _acknowledgeNative(directory, pending);
          return 0;
        }
        if (hash != pending['base_content_sha256']) {
          throw const WebDavException(
            'The cloud has a different PDF generation. Your local generation was preserved.',
          );
        }
        final archive = File('${directory.path}/$kind.zip');
        final upload = await archive.copy(
          '${directory.path}/native-upload-${DateTime.now().microsecondsSinceEpoch}.zip',
        );
        try {
          final length = _validateOcrManifest(bookId, pending);
          if (await upload.length() != length ||
              (await sha256.bind(upload.openRead()).first).toString() !=
                  pending['content_sha256']) {
            throw const WebDavException(
              'Local PDF generation checksum failed.',
            );
          }
          final published = Map<String, dynamic>.of(pending)
            ..remove('pending_upload')
            ..remove('base_content_sha256');
          await webdav.publishDerivedArchive(
            'derived/$bookId/$kind.zip',
            upload,
            'derived/$bookId/$kind.json',
            published,
            manifestObject,
          );
          await _acknowledgeNative(directory, pending);
          return 1;
        } finally {
          if (await upload.exists()) await upload.delete();
        }
      }
    }
    if (manifestObject == null) return 0;
    final manifest = jsonDecode(utf8.decode(manifestObject.bytes));
    if (manifest is! Map<String, dynamic>) {
      throw const WebDavException('PDF OCR manifest is invalid.');
    }
    final length = _validateOcrManifest(bookId, manifest);
    final expectedHash = manifest['content_sha256'] as String;
    final archive = File('${directory.path}${Platform.pathSeparator}$kind.zip');
    final localManifest = File(
      '${directory.path}${Platform.pathSeparator}$kind.json',
    );
    if (await archive.exists() && await localManifest.exists()) {
      try {
        final cached = jsonDecode(await localManifest.readAsString());
        if (cached is Map &&
            cached['content_sha256'] == expectedHash &&
            await archive.length() == length) {
          return 0;
        }
      } catch (_) {
        // Replace an incomplete or corrupt cache below.
      }
    }

    final partial = File(
      '${directory.path}${Platform.pathSeparator}$kind.zip.part',
    );
    await webdav.downloadToFile(
      'derived/$bookId/$kind.zip',
      partial,
      length,
      onProgress: onProgress,
    );
    final digest = await sha256.bind(partial.openRead()).first;
    if (digest.toString() != expectedHash) {
      await partial.delete();
      throw const WebDavException('PDF OCR archive checksum failed.');
    }
    if (kind == 'native-pdf') {
      return withNativeStore(directory, () async {
        Map? latest;
        try {
          latest = jsonDecode(await localManifest.readAsString()) as Map;
        } catch (_) {}
        if (latest?['pending_upload'] == true) {
          await partial.delete();
          return 0;
        }
        await installNativePair(directory, partial, manifestObject.bytes);
        return 1;
      });
    }
    if (await archive.exists()) await archive.delete();
    await partial.rename(archive.path);
    await _writeAtomic(localManifest, manifestObject.bytes);
    return 1;
  }

  Future<void> _acknowledgeNative(
    Directory directory,
    Map<String, dynamic> published,
  ) => withNativeStore(directory, () async {
    final file = File('${directory.path}/native-pdf.json');
    final latest = Map<String, dynamic>.from(
      jsonDecode(await file.readAsString()) as Map,
    );
    if (latest['content_sha256'] == published['content_sha256']) {
      latest.remove('pending_upload');
      latest.remove('base_content_sha256');
    } else if (latest['pending_upload'] == true &&
        latest['base_content_sha256'] == published['base_content_sha256']) {
      // Regeneration during an upload retains its archive and queues against
      // the generation just published, rather than losing the new phone work.
      latest['base_content_sha256'] = published['content_sha256'];
    } else {
      return;
    }
    await _writeAtomic(file, utf8.encode(jsonEncode(latest)));
  });

  Future<DerivedBookMetadata?> metadata(String bookId) async {
    final file = File(
      '${_bookDirectory(bookId).path}${Platform.pathSeparator}metadata.json',
    );
    if (!await file.exists()) return null;
    try {
      final outer = jsonDecode(await file.readAsString());
      if (outer is! Map ||
          outer['version'] != 1 ||
          outer['book_id'] != bookId) {
        return null;
      }
      final stored = outer['metadata'];
      if (stored is! Map ||
          stored['version'] != 1 ||
          stored['book_id'] != bookId) {
        return null;
      }
      final value = stored['metadata'];
      if (value is! Map) return null;
      final title = (value['title'] as String? ?? '').trim();
      final authors = <String>[
        if (value['authors'] is List)
          for (final author in (value['authors'] as List).whereType<String>())
            if (author.trim().isNotEmpty) author.trim(),
      ];
      return DerivedBookMetadata(title: title, authors: authors);
    } catch (_) {
      return null;
    }
  }

  Future<List<TocEntry>> generatedToc(String bookId, Book book) async {
    final file = File(
      '${_bookDirectory(bookId).path}${Platform.pathSeparator}metadata.json',
    );
    if (!await file.exists()) return const [];
    try {
      final outer = jsonDecode(await file.readAsString());
      if (outer is! Map || outer['book_id'] != bookId) return const [];
      final toc = outer['toc'];
      if (toc is! Map ||
          toc['version'] != 1 ||
          toc['book_id'] != bookId ||
          toc['verified_pages'] != true ||
          toc['page_mapping_revision'] != 2 ||
          toc['entries'] is! List) {
        return const [];
      }
      final roots = <_MutableToc>[];
      final stack = <_MutableToc>[];
      for (final raw in (toc['entries'] as List).whereType<Map>()) {
        final title = (raw['title'] as String? ?? '').trim();
        final page = (raw['physical_page'] as num?)?.toInt();
        if (title.isEmpty || page == null || page <= 0) continue;
        final index = page - 1;
        if (index >= book.spine.length) continue;
        final depth = ((raw['depth'] as num?)?.toInt() ?? 0).clamp(0, 64);
        while (stack.isNotEmpty && stack.last.depth >= depth) {
          stack.removeLast();
        }
        final node = _MutableToc(
          depth: depth,
          label: title,
          href: book.spine[index].href,
          spineIndex: index,
        );
        if (stack.isEmpty) {
          roots.add(node);
        } else {
          stack.last.children.add(node);
        }
        stack.add(node);
      }
      return roots.map((node) => node.freeze()).toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  static void _validateMetadata(String bookId, List<int> bytes) {
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map || value['version'] != 1 || value['book_id'] != bookId) {
      throw const WebDavException('Generated book metadata is invalid.');
    }
    for (final key in ['toc', 'metadata']) {
      final child = value[key];
      if (child != null &&
          (child is! Map ||
              child['version'] != 1 ||
              child['book_id'] != bookId)) {
        throw const WebDavException('Generated book metadata is invalid.');
      }
    }
  }

  static int _validateOcrManifest(
    String bookId,
    Map<String, dynamic> manifest,
  ) {
    final hash = manifest['content_sha256'];
    final length = (manifest['content_length'] as num?)?.toInt();
    if (manifest['version'] != 1 ||
        manifest['book_id'] != bookId ||
        hash is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash) ||
        length == null ||
        length < 0 ||
        length > _maxOcrBytes) {
      throw const WebDavException('PDF OCR manifest is invalid.');
    }
    return length;
  }

  static Future<void> _writeAtomic(File target, List<int> bytes) async {
    await target.parent.create(recursive: true);
    final temporary = File('${target.path}.part');
    await temporary.writeAsBytes(bytes, flush: true);
    if (await target.exists()) await target.delete();
    await temporary.rename(target.path);
  }

  static Future<bool> _writeAtomicIfChanged(
    File target,
    List<int> bytes,
  ) async {
    if (await target.exists()) {
      final existing = await target.readAsBytes();
      if (existing.length == bytes.length) {
        var equal = true;
        for (var index = 0; index < bytes.length; index++) {
          if (existing[index] != bytes[index]) {
            equal = false;
            break;
          }
        }
        if (equal) return false;
      }
    }
    await _writeAtomic(target, bytes);
    return true;
  }
}

class _MutableToc {
  final int depth;
  final String label;
  final String href;
  final int spineIndex;
  final List<_MutableToc> children = [];

  _MutableToc({
    required this.depth,
    required this.label,
    required this.href,
    required this.spineIndex,
  });

  TocEntry freeze() => TocEntry(
    label: label,
    href: href,
    spineIndex: spineIndex,
    children: children.map((child) => child.freeze()).toList(growable: false),
  );
}
