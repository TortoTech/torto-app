import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../library/library_store.dart';
import '../progress_store.dart';
import 'derived_data_store.dart';
import 'sync_models.dart';
import 'sync_store.dart';
import 'webdav_client.dart';

class SyncProgress {
  final String label;
  final double? fraction;

  const SyncProgress(this.label, [this.fraction]);
}

class SyncEngine {
  final LibraryStore libraryStore;
  final ProgressStore progressStore;
  final SyncStore syncStore;
  final WebDavClient webdav;
  final CloudSettings settings;
  final void Function(SyncProgress progress)? onProgress;

  SyncEngine({
    required this.libraryStore,
    required this.progressStore,
    required this.syncStore,
    required this.webdav,
    required this.settings,
    this.onProgress,
  });

  Future<SyncReport> sync({bool readingOnly = false}) async {
    _validateDeviceId(settings.deviceId);
    if (settings.deviceName.trim().isEmpty) {
      throw const WebDavException('The sync device name is invalid.');
    }
    final localProgress = await progressStore.all();
    for (final locator in localProgress.values) {
      await syncStore.adoptLocalProgress(locator);
    }
    final pending = <String>[];
    for (final id in await syncStore.readingBookIds()) {
      final payload = await _readingPayload(id);
      final revision = jsonEncode(payload);
      if (await webdav.cacheGet('reading:$id') != revision) pending.add(id);
    }
    if (readingOnly && pending.isEmpty) return const SyncReport();
    onProgress?.call(const SyncProgress('Preparing sync…'));
    await webdav.ensureLayout();
    if (!readingOnly || await webdav.cacheGet('protocol:verified') != '1') {
      await _ensureProtocol();
      await webdav.cacheSet('protocol:verified', '1');
    }

    var uploaded = 0;
    var downloaded = 0;
    var mergedProgress = 0;
    var mergedAnnotations = 0;
    var downloadedDerivedData = 0;
    // Flush small reading changes before scanning or transferring book/OCR data.
    for (final bookId in pending) {
      _validateBookId(bookId);
      onProgress?.call(const SyncProgress('Syncing reading changes…'));
      await webdav.ensureBookCollections(bookId);
      final revision = await _publishBookState(bookId);
      final result = await _mergeRemoteState(bookId);
      mergedProgress += result.progress;
      mergedAnnotations += result.annotations;
      await webdav.cacheSet('reading:$bookId', revision);
    }
    if (readingOnly) {
      return SyncReport(
        mergedProgress: mergedProgress,
        mergedAnnotations: mergedAnnotations,
      );
    }
    var localBooks = await libraryStore.list();
    final pendingUploads = <LibraryBook>[];

    var checkedBooks = 0;
    onProgress?.call(const SyncProgress('Checking library…', 0));
    await _forEachBook(localBooks, (book) async {
      _validateBookId(book.id);
      await syncStore.setMembership(book.id, true);
      if (!await _remoteBookExists(book)) pendingUploads.add(book);
      onProgress?.call(
        SyncProgress('Checking library…', ++checkedBooks / localBooks.length),
      );
    });
    final uploadTotal = pendingUploads.fold<int>(
      0,
      (sum, book) => sum + book.sizeBytes,
    );
    var uploadCompleted = 0;
    for (final book in pendingUploads) {
      if (await _uploadBook(
        book,
        onBytes: (sent) => onProgress?.call(
          SyncProgress(
            'Uploading books…',
            uploadTotal == 0 ? null : (uploadCompleted + sent) / uploadTotal,
          ),
        ),
      )) {
        uploaded++;
      }
      uploadCompleted += book.sizeBytes;
      onProgress?.call(
        SyncProgress(
          'Uploading books…',
          uploadTotal == 0 ? 1 : uploadCompleted / uploadTotal,
        ),
      );
    }
    await _publishLibrary();

    onProgress?.call(const SyncProgress('Discovering remote books…'));
    final remoteIds = await _discoverRemoteBooks();
    final localIds = localBooks.map((book) => book.id).toSet();
    final allBookIds = <String>{...remoteIds, ...localIds};
    for (final bookId in remoteIds) {
      if (localIds.contains(bookId)) continue;
      final membership = await syncStore.membership(bookId);
      if (membership?.present == false) continue;
      onProgress?.call(const SyncProgress('Downloading books…'));
      final installed = await _downloadBook(bookId);
      if (installed) {
        downloaded++;
        await syncStore.setMembership(bookId, true);
      }
    }
    if (downloaded > 0) {
      localBooks = await libraryStore.list();
      await _publishLibrary();
    }

    // Remote reading changes also precede potentially large derived downloads.
    await _forEachBook(allBookIds, (bookId) async {
      if (pending.contains(bookId)) return;
      onProgress?.call(const SyncProgress('Syncing reading progress…'));
      final files = await webdav.listJsonFiles('state/$bookId/devices/');
      if (!files.contains('${settings.deviceId}.json')) {
        await webdav.invalidatePublished(
          'state/$bookId/devices/${settings.deviceId}.json',
        );
      }
      final revision = await _publishBookState(bookId);
      final result = await _mergeRemoteState(bookId, files: files);
      mergedProgress += result.progress;
      mergedAnnotations += result.annotations;
      await webdav.cacheSet('reading:$bookId', revision);
    });

    final derivedStore = DerivedDataStore.fromBooksDirectory(
      await libraryStore.booksDirectory(),
    );
    onProgress?.call(const SyncProgress('Checking PDF data…'));
    await _forEachBook(allBookIds, (bookId) async {
      final derivedChanges = await derivedStore.syncRemoteBook(
        webdav,
        bookId,
        onProgress: (received, total) => onProgress?.call(
          SyncProgress(
            'Downloading PDF OCR data...',
            total == 0 ? null : received / total,
          ),
        ),
      );
      downloadedDerivedData += derivedChanges;
    }, concurrency: 2);

    onProgress?.call(const SyncProgress('Sync complete', 1));
    return SyncReport(
      uploadedBooks: uploaded,
      downloadedBooks: downloaded,
      mergedProgress: mergedProgress,
      mergedAnnotations: mergedAnnotations,
      downloadedDerivedData: downloadedDerivedData,
    );
  }

  // Bound network and file activity. On error, stop scheduling new books and
  // drain already-started work before the controller closes the HTTP client.
  static Future<void> _forEachBook<T>(
    Iterable<T> books,
    Future<void> Function(T) action, {
    int concurrency = 4,
  }) async {
    final iterator = books.iterator;
    var failed = false;
    await Future.wait(
      List.generate(concurrency, (_) async {
        while (!failed && iterator.moveNext()) {
          final book = iterator.current;
          try {
            await action(book);
          } catch (_) {
            failed = true;
            rethrow;
          }
        }
      }),
    );
  }

  Future<void> _ensureProtocol() async {
    const path = 'protocol.json';
    final existing = await webdav.getJsonOptional(path);
    if (existing != null) {
      if (existing['version'] != syncProtocolVersion ||
          existing['protocol'] != syncProtocolName) {
        throw const WebDavException(
          'The WebDAV sync protocol is incompatible.',
        );
      }
      return;
    }
    final created = await webdav.putImmutableBytes(
      path,
      utf8.encode(
        const JsonEncoder.withIndent('  ').convert({
          'version': syncProtocolVersion,
          'protocol': syncProtocolName,
        }),
      ),
      contentType: 'application/json',
    );
    if (!created) {
      final winner = await webdav.getJsonOptional(path);
      if (winner == null ||
          winner['version'] != syncProtocolVersion ||
          winner['protocol'] != syncProtocolName) {
        throw const WebDavException(
          'The WebDAV sync protocol is incompatible.',
        );
      }
    }
  }

  Future<bool> _remoteBookExists(LibraryBook book) async {
    final manifestPath = 'books/${book.id}/manifest.json';
    final existing = await webdav.getJsonOptional(manifestPath);
    if (existing != null) {
      _validateManifest(existing, book.id);
      if ((existing['content_length'] as num).toInt() != book.sizeBytes) {
        throw const WebDavException('Remote book size does not match its ID.');
      }
      await _applyRemoteMetadata(book, existing);
      return true;
    }
    return false;
  }

  Future<bool> _uploadBook(
    LibraryBook book, {
    void Function(int sent)? onBytes,
  }) async {
    final manifestPath = 'books/${book.id}/manifest.json';
    final digest = await sha256.bind(book.file.openRead()).first;
    if (digest.toString() != book.id) {
      throw const WebDavException('A local book changed while it was syncing.');
    }
    await webdav.ensureBookCollections(book.id);
    final extension = _storageExtension(book.file.path);
    final contentPath = 'books/${book.id}/content.$extension';
    final uploaded = await webdav.putImmutableFile(
      contentPath,
      book.file,
      onProgress: onBytes,
    );
    String? coverPath;
    final cover = book.coverBytes;
    if (cover != null && cover.isNotEmpty) {
      coverPath = 'books/${book.id}/cover.bin';
      await webdav.putImmutableBytes(coverPath, cover);
    }
    await webdav.putImmutableBytes(
      manifestPath,
      utf8.encode(
        const JsonEncoder.withIndent('  ').convert({
          'version': syncProtocolVersion,
          'book_id': book.id,
          'title': book.title,
          'authors': book.authors,
          'file_name': _baseName(book.file.path),
          'content_path': contentPath,
          'content_sha256': book.id,
          'content_length': book.sizeBytes,
          'cover_path': coverPath,
          'added_at': book.addedAt,
        }),
      ),
      contentType: 'application/json',
    );
    return uploaded;
  }

  Future<void> _publishLibrary() async {
    final files = await webdav.listJsonFiles('library/devices/');
    final path = 'library/devices/${settings.deviceId}.json';
    if (!files.contains('${settings.deviceId}.json')) {
      await webdav.invalidatePublished(path);
    }
    final entries = await syncStore.memberships();
    final timestamp = await syncStore.tick();
    await webdav.putMutableJson(path, {
      'version': syncProtocolVersion,
      'device_id': settings.deviceId,
      'device_name': settings.deviceName,
      'updated_at': timestamp.toJson(),
      'books': [
        for (final entry in entries)
          {
            'book_id': entry.bookId,
            'present': entry.present,
            'changed_at': entry.changedAt.toJson(),
          },
      ],
    });
  }

  Future<Set<String>> _discoverRemoteBooks() async {
    final result = <String>{};
    for (final file in await webdav.listJsonFiles('library/devices/')) {
      final library = await webdav.getJsonOptional('library/devices/$file');
      if (library == null) continue;
      final deviceId = library['device_id'];
      final deviceName = library['device_name'];
      final updatedAt = library['updated_at'];
      final books = library['books'];
      if (library['version'] != syncProtocolVersion ||
          deviceId is! String ||
          deviceId.trim().isEmpty ||
          deviceName is! String ||
          updatedAt is! Map ||
          books is! List) {
        throw const WebDavException('Remote device library is invalid.');
      }
      HybridTimestamp.fromJson(Map<String, dynamic>.from(updatedAt));
      for (final item in books) {
        if (item is! Map) {
          throw const WebDavException('Remote device library is invalid.');
        }
        final entry = Map<String, dynamic>.from(item);
        final id = entry['book_id'];
        final present = entry['present'];
        final changedAt = entry['changed_at'];
        if (id is! String || present is! bool || changedAt is! Map) {
          throw const WebDavException('Remote device library is invalid.');
        }
        _validateBookId(id);
        HybridTimestamp.fromJson(Map<String, dynamic>.from(changedAt));
        if (present) result.add(id);
      }
    }
    return result;
  }

  Future<bool> _downloadBook(String bookId) async {
    final manifest = await webdav.getJsonOptional(
      'books/$bookId/manifest.json',
    );
    if (manifest == null) return false;
    _validateManifest(manifest, bookId);
    final fileName = manifest['file_name'] as String;
    final contentPath = manifest['content_path'] as String;
    final expectedLength = (manifest['content_length'] as num).toInt();
    final booksDir = await libraryStore.booksDirectory();
    final cacheDir = Directory(
      '${booksDir.parent.path}${Platform.pathSeparator}sync-downloads-v1',
    );
    final partial = File(
      '${cacheDir.path}${Platform.pathSeparator}$bookId.part',
    );
    await webdav.downloadToFile(
      contentPath,
      partial,
      expectedLength,
      onProgress: (received, total) => onProgress?.call(
        SyncProgress(
          'Downloading books…',
          total == 0 ? null : received / total,
        ),
      ),
    );
    final digest = await sha256.bind(partial.openRead()).first;
    if (digest.toString() != bookId) {
      await partial.delete();
      throw const WebDavException('Downloaded book checksum failed.');
    }
    final coverBytes = await _downloadRemoteCover(manifest);
    await libraryStore.installDownloaded(
      partial,
      bookId,
      fileName,
      remoteTitle: manifest['title'] as String,
      remoteAuthors: List<String>.from(manifest['authors'] as List),
      remoteCoverBytes: coverBytes,
      remoteAddedAt: manifest['added_at'] as int,
    );
    return true;
  }

  Future<void> _applyRemoteMetadata(
    LibraryBook book,
    Map<String, dynamic> manifest,
  ) async {
    final coverBytes = book.coverBytes == null
        ? await _downloadRemoteCover(manifest)
        : null;
    await libraryStore.applyRemoteMetadata(
      book,
      remoteTitle: manifest['title'] as String,
      remoteAuthors: List<String>.from(manifest['authors'] as List),
      remoteCoverBytes: coverBytes,
      remoteAddedAt: manifest['added_at'] as int,
    );
  }

  Future<Uint8List?> _downloadRemoteCover(Map<String, dynamic> manifest) async {
    final coverPath = manifest['cover_path'] as String?;
    if (coverPath == null) return null;
    final cover = await webdav.getOptional(coverPath);
    if (cover == null) {
      throw const WebDavException('Remote book cover is missing.');
    }
    return cover.bytes;
  }

  Future<_MergeCounts> _mergeRemoteState(
    String bookId, {
    List<String>? files,
  }) async {
    var mergedProgress = 0;
    var mergedAnnotations = 0;
    for (final file
        in files ?? await webdav.listJsonFiles('state/$bookId/devices/')) {
      if (file == '${settings.deviceId}.json') continue;
      final path = 'state/$bookId/devices/$file';
      final object = await webdav.getOptional(path);
      if (object == null) continue;
      final digest = sha256.convert(object.bytes).toString();
      final appliedKey = 'applied:$path';
      if (await webdav.cacheGet(appliedKey) == digest) continue;
      final state = jsonDecode(utf8.decode(object.bytes));
      if (state is! Map<String, dynamic>) {
        throw const WebDavException('Remote reading state is invalid.');
      }
      final stateDeviceId = state['device_id'];
      final stateUpdatedAt = state['updated_at'];
      final rawProgress = state['progress'];
      final rawAnnotations = state['annotations'];
      if (state['version'] != syncProtocolVersion ||
          state['book_id'] != bookId ||
          stateDeviceId is! String ||
          stateDeviceId.trim().isEmpty ||
          stateUpdatedAt is! Map ||
          (rawProgress != null && rawProgress is! Map) ||
          rawAnnotations is! List) {
        throw const WebDavException('Remote reading state is invalid.');
      }
      HybridTimestamp.fromJson(Map<String, dynamic>.from(stateUpdatedAt));
      if (rawProgress is Map) {
        StoredProgress? incoming;
        try {
          incoming = StoredProgress.fromJson(
            Map<String, dynamic>.from(rawProgress),
          );
        } on FormatException {
          // Discard progress written by the pre-desktop-compatible app.
        } on TypeError {
          // Discard structurally invalid legacy progress.
        }
        if (incoming != null && incoming.locator.publicationId != bookId) {
          incoming = null;
        }
        if (incoming != null && await syncStore.mergeProgress(incoming)) {
          await progressStore.save(
            incoming.locator,
            activityTimeMs: incoming.updatedAt.wallTimeMs,
          );
          mergedProgress++;
        }
      }
      final annotations = <AnnotationState>[];
      for (final raw in rawAnnotations) {
        if (raw is! Map) {
          throw const WebDavException('Remote annotation is invalid.');
        }
        annotations.add(
          AnnotationState.fromJson(Map<String, dynamic>.from(raw)),
        );
      }
      if (annotations.any((annotation) => annotation.bookId != bookId)) {
        throw const WebDavException(
          'Remote annotation belongs to a different book.',
        );
      }
      mergedAnnotations += await syncStore.mergeAnnotations(annotations);
      await webdav.cacheSet(appliedKey, digest);
    }
    return _MergeCounts(mergedProgress, mergedAnnotations);
  }

  Future<Map<String, Object?>> _readingPayload(String bookId) async {
    final progress = await syncStore.progress(bookId);
    final localProgress = progress?.updatedAt.deviceId == settings.deviceId
        ? progress
        : null;
    final annotations = await syncStore.annotationsForDeviceBook(bookId);
    return {
      'version': syncProtocolVersion,
      'device_id': settings.deviceId,
      'book_id': bookId,
      'progress': localProgress?.toJson(),
      'annotations': annotations
          .map((annotation) => annotation.toJson())
          .toList(growable: false),
    };
  }

  Future<String> _publishBookState(String bookId) async {
    final payload = await _readingPayload(bookId);
    final revision = jsonEncode(payload);
    final timestamp = await syncStore.tick();
    await webdav.putMutableJson(
      'state/$bookId/devices/${settings.deviceId}.json',
      {...payload, 'updated_at': timestamp.toJson()},
    );
    return revision;
  }

  static void _validateBookId(String value) {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
      throw const WebDavException('A book has an invalid content ID.');
    }
  }

  static void _validateDeviceId(String value) {
    if (!RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
    ).hasMatch(value)) {
      throw const WebDavException('The sync device ID is invalid.');
    }
  }

  static void _validateManifest(Map<String, dynamic> manifest, String id) {
    _validateBookId(id);
    if (manifest['version'] != syncProtocolVersion ||
        manifest['book_id'] != id ||
        manifest['content_sha256'] != id) {
      throw const WebDavException('Remote book manifest is invalid.');
    }
    final contentPath = manifest['content_path'];
    final fileName = manifest['file_name'];
    final length = manifest['content_length'];
    final title = manifest['title'];
    final authors = manifest['authors'];
    final addedAt = manifest['added_at'];
    if (contentPath is! String ||
        !RegExp(
          '^books/$id/content\\.[A-Za-z0-9]+'
          r'$',
        ).hasMatch(contentPath) ||
        fileName is! String ||
        title is! String ||
        authors is! List ||
        authors.any((author) => author is! String) ||
        addedAt is! int ||
        addedAt < 0 ||
        length is! num ||
        length.toInt() < 0) {
      throw const WebDavException(
        'Remote book manifest contains invalid data.',
      );
    }
    final cover = manifest['cover_path'];
    if (cover != null && cover != 'books/$id/cover.bin') {
      throw const WebDavException('Remote book cover path is invalid.');
    }
  }

  static String _storageExtension(String path) {
    final name = _baseName(path);
    final dot = name.lastIndexOf('.');
    final extension = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
    if (!RegExp(r'^[a-z0-9]+$').hasMatch(extension)) {
      throw const WebDavException('Book extension is invalid.');
    }
    return extension;
  }

  static String _baseName(String path) {
    final normalized = path.replaceAll('\\', '/');
    return normalized.substring(normalized.lastIndexOf('/') + 1);
  }
}

class _MergeCounts {
  final int progress;
  final int annotations;

  const _MergeCounts(this.progress, this.annotations);
}
