import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/formats/formats.dart';
import '../../core/formats/pdf/pdf_cover.dart';
import '../sync/derived_data_store.dart';

/// One imported book on disk.
class LibraryBook {
  /// Lowercase SHA-256 of the exact imported bytes (the cross-device ID).
  final String id;
  final File file;

  /// Display title from package metadata, with the file name as fallback.
  final String title;

  final List<String> authors;
  final List<String> languages;
  final Uint8List? coverBytes;
  final int sizeBytes;
  final int addedAt;

  const LibraryBook({
    this.id = '',
    required this.file,
    required this.title,
    this.authors = const [],
    this.languages = const [],
    this.coverBytes,
    required this.sizeBytes,
    this.addedAt = 0,
  });
}

/// On-disk library: book files (EPUB, FB2/FBZ, CBZ) under
/// `<app documents>/books/`.
///
/// Pass [booksDir] in tests to avoid touching path_provider.
class LibraryStore {
  static const _metadataVersion = 2;

  final Directory? _overrideDir;
  Directory? _dir;

  LibraryStore({Directory? booksDir}) : _overrideDir = booksDir;

  Future<Directory> _booksDir() async {
    final cached = _dir;
    if (cached != null) return cached;
    final override = _overrideDir;
    if (override != null) return _dir = override;
    final docs = await getApplicationDocumentsDirectory();
    return _dir = Directory('${docs.path}${Platform.pathSeparator}books');
  }

  Future<Directory> booksDirectory() => _booksDir();

  /// Lists imported books, sorted by title. A missing directory (fresh
  /// install) yields an empty library.
  Future<List<LibraryBook>> list() async {
    final dir = await _booksDir();
    if (!await dir.exists()) return const [];
    final books = <LibraryBook>[];
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      if (!hasSupportedBookExtension(entity.path)) continue;
      books.add(await _readBook(entity));
    }
    books.sort(
      (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
    );
    return books;
  }

  /// Opens the platform file picker and copies the chosen file into the
  /// library directory. Returns the imported file, or null when the user
  /// cancelled. Name collisions get a `-1`, `-2`, … suffix.
  Future<File?> import() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      // `zip` admits `.fb2.zip`; other zips are rejected by name below.
      allowedExtensions: [...supportedBookExtensions, 'zip'],
    );
    if (files.isEmpty) return null;
    final picked = files.first;
    final bytes = await picked.readAsBytes();

    final name = picked.name.isEmpty ? 'book' : picked.name;
    if (!hasSupportedBookExtension(name)) {
      // A plain .zip is not a book (FBZ must be named *.fb2.zip).
      throw FormatException('不支持的电子书格式: $name');
    }

    final dir = await _booksDir();
    await dir.create(recursive: true);

    final dot = name.lastIndexOf('.');
    final base = dot > 0 ? name.substring(0, dot) : name;
    final ext = dot > 0 ? name.substring(dot) : '';

    var candidate = File('${dir.path}${Platform.pathSeparator}$name');
    var suffix = 1;
    while (await candidate.exists()) {
      candidate = File('${dir.path}${Platform.pathSeparator}$base-$suffix$ext');
      suffix++;
    }
    await candidate.writeAsBytes(bytes, flush: true);
    await _readBook(candidate, bytes: bytes, forceRefresh: true);
    return candidate;
  }

  /// Removes [file] from the library. Missing files are ignored.
  Future<void> delete(File file) async {
    if (await file.exists()) await file.delete();
    final metadata = _metadataFile(file);
    if (await metadata.exists()) await metadata.delete();
    final cover = _coverFile(file);
    if (await cover.exists()) await cover.delete();
  }

  /// Atomically installs a fully downloaded and verified remote book.
  Future<File> installDownloaded(
    File downloaded,
    String contentId,
    String remoteFileName, {
    String remoteTitle = '',
    List<String> remoteAuthors = const [],
    Uint8List? remoteCoverBytes,
    int? remoteAddedAt,
  }) async {
    final dir = await _booksDir();
    await dir.create(recursive: true);
    final safeName = _baseName(remoteFileName).trim();
    final format = BookFormat.fromFileName(safeName);
    if (safeName.isEmpty ||
        format == null ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(contentId)) {
      throw const FormatException('Remote book has an unsupported file name.');
    }
    final target = File(
      '${dir.path}${Platform.pathSeparator}$contentId.${format.name}',
    );
    if (await target.exists()) {
      final existingDigest = await sha256.bind(target.openRead()).first;
      if (existingDigest.toString() == contentId) {
        if (await downloaded.exists()) await downloaded.delete();
        await _readBook(
          target,
          forceRefresh: true,
          sourceFileName: safeName,
          preferredTitle: remoteTitle,
          preferredAuthors: remoteAuthors,
          preferredCoverBytes: remoteCoverBytes,
          preferredAddedAt: remoteAddedAt,
        );
        return target;
      }
      await delete(target);
    }
    await downloaded.rename(target.path);
    await _readBook(
      target,
      forceRefresh: true,
      sourceFileName: safeName,
      preferredTitle: remoteTitle,
      preferredAuthors: remoteAuthors,
      preferredCoverBytes: remoteCoverBytes,
      preferredAddedAt: remoteAddedAt,
    );
    return target;
  }

  /// Applies authoritative manifest metadata without reopening large books.
  Future<void> applyRemoteMetadata(
    LibraryBook book, {
    String remoteTitle = '',
    List<String> remoteAuthors = const [],
    Uint8List? remoteCoverBytes,
    int? remoteAddedAt,
  }) async {
    final stat = await book.file.stat();
    final title = remoteTitle.trim().isEmpty ? book.title : remoteTitle.trim();
    final normalizedAuthors = _normalizedValues(remoteAuthors);
    final authors = normalizedAuthors.isEmpty
        ? book.authors
        : normalizedAuthors;
    final coverBytes = remoteCoverBytes != null && remoteCoverBytes.isNotEmpty
        ? remoteCoverBytes
        : book.coverBytes;
    await _writeBookCache(
      file: book.file,
      sizeBytes: stat.size,
      modifiedMillis: stat.modified.millisecondsSinceEpoch,
      id: book.id,
      title: title,
      authors: authors,
      languages: book.languages,
      coverBytes: coverBytes,
      addedAt: remoteAddedAt ?? book.addedAt,
    );
  }

  Future<LibraryBook> _readBook(
    File file, {
    Uint8List? bytes,
    bool forceRefresh = false,
    String? sourceFileName,
    String preferredTitle = '',
    List<String> preferredAuthors = const [],
    Uint8List? preferredCoverBytes,
    int? preferredAddedAt,
  }) async {
    final stat = await file.stat();
    final sizeBytes = stat.size;
    final modifiedMillis = stat.modified.millisecondsSinceEpoch;
    if (!forceRefresh) {
      final cached = await _readCachedBook(
        file,
        sizeBytes: sizeBytes,
        modifiedMillis: modifiedMillis,
      );
      if (cached != null) {
        if (cached.coverBytes == null &&
            BookFormat.fromFileName(file.path) == BookFormat.pdf) {
          final generatedCover = await renderPdfCover(file.path);
          if (generatedCover != null && generatedCover.isNotEmpty) {
            await applyRemoteMetadata(cached, remoteCoverBytes: generatedCover);
            return LibraryBook(
              id: cached.id,
              file: cached.file,
              title: cached.title,
              authors: cached.authors,
              languages: cached.languages,
              coverBytes: generatedCover,
              sizeBytes: cached.sizeBytes,
              addedAt: cached.addedAt,
            );
          }
        }
        return cached;
      }
    }

    final content = bytes ?? await file.readAsBytes();
    var id = sha256.convert(content).toString();
    var title = titleOf(sourceFileName ?? file.path);
    var authors = const <String>[];
    var languages = const <String>[];
    Uint8List? coverBytes;
    try {
      final source = await openBook(
        content,
        sourceFileName ?? _baseName(file.path),
        filePath: file.path,
        titleHint: preferredTitle,
        publicationIdHint: id,
      );
      final metadata = source.book.metadata;
      id = source.book.id;
      final packageTitle = metadata.title.trim();
      if (packageTitle.isNotEmpty) title = packageTitle;
      authors = _normalizedValues(metadata.authors);
      languages = _normalizedValues(metadata.languages);
      final coverHref = source.book.coverHref;
      if (coverHref != null) coverBytes = await source.resource(coverHref);
    } catch (_) {
      // A damaged book remains visible and openable by file name. Cache the
      // fallback until its size or modification time changes.
    }
    if (preferredTitle.trim().isNotEmpty) title = preferredTitle.trim();
    final normalizedPreferredAuthors = _normalizedValues(preferredAuthors);
    if (normalizedPreferredAuthors.isNotEmpty) {
      authors = normalizedPreferredAuthors;
    }
    if (preferredCoverBytes != null && preferredCoverBytes.isNotEmpty) {
      coverBytes = preferredCoverBytes;
    }
    if ((coverBytes == null || coverBytes.isEmpty) &&
        BookFormat.fromFileName(sourceFileName ?? file.path) ==
            BookFormat.pdf) {
      coverBytes = await renderPdfCover(file.path);
    }
    final addedAt = preferredAddedAt ?? stat.changed.millisecondsSinceEpoch;
    await _writeBookCache(
      file: file,
      sizeBytes: sizeBytes,
      modifiedMillis: modifiedMillis,
      id: id,
      title: title,
      authors: authors,
      languages: languages,
      coverBytes: coverBytes,
      addedAt: addedAt,
    );
    return _withDerivedMetadata(
      LibraryBook(
        id: id,
        file: file,
        title: title,
        authors: authors,
        languages: languages,
        coverBytes: coverBytes,
        sizeBytes: sizeBytes,
        addedAt: addedAt,
      ),
    );
  }

  Future<void> _writeBookCache({
    required File file,
    required int sizeBytes,
    required int modifiedMillis,
    required String id,
    required String title,
    required List<String> authors,
    required List<String> languages,
    required Uint8List? coverBytes,
    required int addedAt,
  }) async {
    final coverFile = _coverFile(file);
    final storedCover = coverBytes != null && coverBytes.isNotEmpty
        ? coverBytes
        : null;
    if (storedCover != null) {
      await coverFile.writeAsBytes(storedCover, flush: true);
    } else if (await coverFile.exists()) {
      await coverFile.delete();
    }
    await _metadataFile(file).writeAsString(
      jsonEncode({
        'version': _metadataVersion,
        'sizeBytes': sizeBytes,
        'modifiedMillis': modifiedMillis,
        'id': id,
        'addedAt': addedAt,
        'title': title,
        'authors': authors,
        'languages': languages,
        'hasCover': storedCover != null,
      }),
      flush: true,
    );
  }

  Future<LibraryBook?> _readCachedBook(
    File file, {
    required int sizeBytes,
    required int modifiedMillis,
  }) async {
    try {
      final decoded = jsonDecode(await _metadataFile(file).readAsString());
      if (decoded is! Map<String, dynamic> ||
          decoded['version'] != _metadataVersion ||
          decoded['sizeBytes'] != sizeBytes ||
          decoded['modifiedMillis'] != modifiedMillis) {
        return null;
      }
      final title = decoded['title'];
      if (title is! String || title.trim().isEmpty) return null;
      final authors = _stringList(decoded['authors']);
      final languages = _stringList(decoded['languages']);
      Uint8List? coverBytes;
      if (decoded['hasCover'] == true) {
        final coverFile = _coverFile(file);
        if (!await coverFile.exists()) return null;
        coverBytes = await coverFile.readAsBytes();
      }
      return await _withDerivedMetadata(
        LibraryBook(
          id: decoded['id'] as String,
          file: file,
          title: title,
          authors: authors,
          languages: languages,
          coverBytes: coverBytes,
          sizeBytes: sizeBytes,
          addedAt: decoded['addedAt'] as int? ?? modifiedMillis,
        ),
      );
    } catch (_) {
      return null;
    }
  }

  Future<LibraryBook> _withDerivedMetadata(LibraryBook book) async {
    final derived = await DerivedDataStore.fromBooksDirectory(
      await _booksDir(),
    ).metadata(book.id);
    if (derived == null || (derived.title.isEmpty && derived.authors.isEmpty)) {
      return book;
    }
    return LibraryBook(
      id: book.id,
      file: book.file,
      title: derived.title.isEmpty ? book.title : derived.title,
      authors: derived.authors.isEmpty ? book.authors : derived.authors,
      languages: book.languages,
      coverBytes: book.coverBytes,
      sizeBytes: book.sizeBytes,
      addedAt: book.addedAt,
    );
  }

  static List<String> _stringList(Object? value) => value is List
      ? _normalizedValues(value.whereType<String>())
      : const <String>[];

  static List<String> _normalizedValues(Iterable<String> values) {
    final normalized = <String>[];
    for (final value in values) {
      final text = value.trim();
      if (text.isNotEmpty && !normalized.contains(text)) normalized.add(text);
    }
    return List.unmodifiable(normalized);
  }

  static File _metadataFile(File file) => File('${file.path}.metadata.json');

  static File _coverFile(File file) => File('${file.path}.cover');

  /// File name without extension, used as the display title.
  static String titleOf(String path) {
    final normalized = path.replaceAll('\\', '/');
    var name = normalized.substring(normalized.lastIndexOf('/') + 1);
    if (name.toLowerCase().endsWith('.fb2.zip')) {
      return name.substring(0, name.length - '.fb2.zip'.length);
    }
    final dot = name.lastIndexOf('.');
    if (dot > 0) name = name.substring(0, dot);
    return name;
  }

  static String _baseName(String path) {
    final normalized = path.replaceAll('\\', '/');
    return normalized.substring(normalized.lastIndexOf('/') + 1);
  }
}
