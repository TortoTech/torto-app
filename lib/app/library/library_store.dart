import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

/// One imported book on disk.
class LibraryBook {
  final File file;

  /// Display title: the file name without its extension.
  final String title;

  final int sizeBytes;

  const LibraryBook({
    required this.file,
    required this.title,
    required this.sizeBytes,
  });
}

/// On-disk library: EPUB files under `<app documents>/books/`.
///
/// Pass [booksDir] in tests to avoid touching path_provider.
class LibraryStore {
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
      books.add(LibraryBook(
        file: entity,
        title: titleOf(entity.path),
        sizeBytes: await entity.length(),
      ));
    }
    books.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    return books;
  }

  /// Opens the platform file picker (EPUB only) and copies the chosen file
  /// into the library directory. Returns the imported file, or null when the
  /// user cancelled. Name collisions get a `-1`, `-2`, … suffix.
  Future<File?> import() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['epub'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return null;
    final picked = result.files.first;
    var bytes = picked.bytes;
    if (bytes == null && picked.path != null) {
      bytes = await File(picked.path!).readAsBytes();
    }
    if (bytes == null) return null;

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
      candidate = File(
          '${dir.path}${Platform.pathSeparator}$base-$suffix$ext');
      suffix++;
    }
    await candidate.writeAsBytes(bytes, flush: true);
    return candidate;
  }

  /// Removes [file] from the library. Missing files are ignored.
  Future<void> delete(File file) async {
    if (await file.exists()) await file.delete();
  }

  /// File name without extension, used as the display title.
  static String titleOf(String path) {
    final normalized = path.replaceAll('\\', '/');
    var name = normalized.substring(normalized.lastIndexOf('/') + 1);
    final dot = name.lastIndexOf('.');
    if (dot > 0) name = name.substring(0, dot);
    return name;
  }
}
