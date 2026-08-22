import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../../core/ir/ir.dart';
import 'webdav_client.dart';

class DerivedBookMetadata {
  final String title;
  final List<String> authors;

  const DerivedBookMetadata({this.title = '', this.authors = const []});
}

/// Local cache for regenerable desktop-derived data. The cache is consumed by
/// the shelf and generated PDF TOC today; OCR archives are retained for the
/// mobile OCR renderer without placing them in the sync database.
class DerivedDataStore {
  static const _maxOcrBytes = 768 * 1024 * 1024;

  final Directory root;

  DerivedDataStore.fromBooksDirectory(Directory booksDirectory)
    : root = Directory(
        '${booksDirectory.parent.path}${Platform.pathSeparator}derived-sync-v1',
      );

  Directory _bookDirectory(String bookId) =>
      Directory('${root.path}${Platform.pathSeparator}$bookId');

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

    final manifestObject = await webdav.getOptional('derived/$bookId/ocr.json');
    if (manifestObject == null) return changed;
    final manifest = jsonDecode(utf8.decode(manifestObject.bytes));
    if (manifest is! Map<String, dynamic>) {
      throw const WebDavException('PDF OCR manifest is invalid.');
    }
    final length = _validateOcrManifest(bookId, manifest);
    final expectedHash = manifest['content_sha256'] as String;
    final archive = File('${directory.path}${Platform.pathSeparator}ocr.zip');
    final localManifest = File(
      '${directory.path}${Platform.pathSeparator}ocr.json',
    );
    if (await archive.exists() && await localManifest.exists()) {
      try {
        final cached = jsonDecode(await localManifest.readAsString());
        if (cached is Map &&
            cached['content_sha256'] == expectedHash &&
            await archive.length() == length) {
          return changed;
        }
      } catch (_) {
        // Replace an incomplete or corrupt cache below.
      }
    }

    final partial = File(
      '${directory.path}${Platform.pathSeparator}ocr.zip.part',
    );
    await webdav.downloadToFile(
      'derived/$bookId/ocr.zip',
      partial,
      length,
      onProgress: onProgress,
    );
    final digest = await sha256.bind(partial.openRead()).first;
    if (digest.toString() != expectedHash) {
      await partial.delete();
      throw const WebDavException('PDF OCR archive checksum failed.');
    }
    if (await archive.exists()) await archive.delete();
    await partial.rename(archive.path);
    await _writeAtomic(localManifest, manifestObject.bytes);
    return changed + 1;
  }

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
