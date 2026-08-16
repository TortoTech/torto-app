import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/epub/epub_book_source.dart';

/// One imported book on disk.
class LibraryBook {
  final File file;

  /// Display title from package metadata, with the file name as fallback.
  final String title;

  final List<String> authors;
  final List<String> languages;
  final Uint8List? coverBytes;
  final int sizeBytes;

  const LibraryBook({
    required this.file,
    required this.title,
    this.authors = const [],
    this.languages = const [],
    this.coverBytes,
    required this.sizeBytes,
  });
}

/// On-disk library: EPUB files under `<app documents>/books/`.
///
/// Pass [booksDir] in tests to avoid touching path_provider.
class LibraryStore {
  static const _metadataVersion = 1;

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

  /// Lists imported books, sorted by title. A missing directory (fresh
  /// install) yields an empty library.
  Future<List<LibraryBook>> list() async {
    final dir = await _booksDir();
    if (!await dir.exists()) return const [];
    final books = <LibraryBook>[];
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      if (!entity.path.toLowerCase().endsWith('.epub')) continue;
      books.add(await _readBook(entity));
    }
    books.sort(
      (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
    );
    return books;
  }

  /// Opens the platform file picker (EPUB only) and copies the chosen file
  /// into the library directory. Returns the imported file, or null when the
  /// user cancelled. Name collisions get a `-1`, `-2`, … suffix.
  Future<File?> import() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['epub'],
    );
    if (files.isEmpty) return null;
    final picked = files.first;
    final bytes = await picked.readAsBytes();

    final dir = await _booksDir();
    await dir.create(recursive: true);

    var name = picked.name.isEmpty ? 'book.epub' : picked.name;
    if (!name.toLowerCase().endsWith('.epub')) name = '$name.epub';
    final dot = name.lastIndexOf('.');
    final base = dot > 0 ? name.substring(0, dot) : name;
    final ext = dot > 0 ? name.substring(dot) : '.epub';

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

  Future<LibraryBook> _readBook(
    File file, {
    Uint8List? bytes,
    bool forceRefresh = false,
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
      if (cached != null) return cached;
    }

    var title = titleOf(file.path);
    var authors = const <String>[];
    var languages = const <String>[];
    Uint8List? coverBytes;
    try {
      final source = await EpubBookSource.fromBytes(
        bytes ?? await file.readAsBytes(),
      );
      final metadata = source.book.metadata;
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

    final coverFile = _coverFile(file);
    if (coverBytes != null && coverBytes.isNotEmpty) {
      await coverFile.writeAsBytes(coverBytes, flush: true);
    } else {
      coverBytes = null;
      if (await coverFile.exists()) await coverFile.delete();
    }
    await _metadataFile(file).writeAsString(
      jsonEncode({
        'version': _metadataVersion,
        'sizeBytes': sizeBytes,
        'modifiedMillis': modifiedMillis,
        'title': title,
        'authors': authors,
        'languages': languages,
        'hasCover': coverBytes != null,
      }),
      flush: true,
    );
    return LibraryBook(
      file: file,
      title: title,
      authors: authors,
      languages: languages,
      coverBytes: coverBytes,
      sizeBytes: sizeBytes,
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
      return LibraryBook(
        file: file,
        title: title,
        authors: authors,
        languages: languages,
        coverBytes: coverBytes,
        sizeBytes: sizeBytes,
      );
    } catch (_) {
      return null;
    }
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
    final dot = name.lastIndexOf('.');
    if (dot > 0) name = name.substring(0, dot);
    return name;
  }
}
