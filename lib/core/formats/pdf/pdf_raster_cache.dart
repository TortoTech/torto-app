import 'dart:io';
import 'dart:typed_data';

/// Lossless rendered pages, keyed by content fingerprint and output dimensions.
/// The directory is private, disposable app cache; publication files are never
/// changed. Limits apply across books, not once per open reader.
class PdfRasterCache {
  final Directory directory;
  final String fingerprint;
  final int maxBytes;
  final int maxEntries;
  static final _writes = <String, Future<void>>{};
  static final _maintenance = <String, Future<void>>{};
  static int _sequence = 0;

  PdfRasterCache(
    this.directory,
    this.fingerprint, {
    this.maxBytes = 256 * 1024 * 1024,
    this.maxEntries = 128,
  }) {
    if (maxBytes < 1 || maxEntries < 1) {
      throw ArgumentError('Invalid cache budget');
    }
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(fingerprint)) {
      throw ArgumentError.value(fingerprint, 'fingerprint');
    }
  }

  File _file(int page, int dimension) {
    if (page < 0 || dimension < 1 || dimension > 2048) {
      throw ArgumentError('Invalid raster key');
    }
    return File('${directory.path}/$fingerprint-$page-$dimension.png');
  }

  Future<Uint8List?> read(int page, int dimension) async {
    final file = _file(page, dimension);
    try {
      await _writes[file.path];
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      await file.setLastModified(DateTime.now());
      return bytes;
    } on FileSystemException {
      return null;
    }
  }

  Future<void> remove(int page, int dimension) async {
    final file = _file(page, dimension);
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      /* Cache miss. */
    }
  }

  Future<void> write(int page, int dimension, Uint8List png) {
    if (png.length > maxBytes) return Future.value();
    return writePending(page, dimension, Future.value(png));
  }

  Future<void> writePending(
    int page,
    int dimension,
    Future<Uint8List?> encoded,
  ) {
    final file = _file(page, dimension);
    final existing = _writes[file.path];
    if (existing != null) return Future.wait([existing, encoded]).then((_) {});
    late final Future<void> future;
    future = () async {
      File? temporary;
      try {
        final png = await encoded;
        if (png == null || png.length > maxBytes) return;
        await directory.create(recursive: true);
        temporary = File(
          '${file.path}.part-${DateTime.now().microsecondsSinceEpoch}-${_sequence++}',
        );
        await temporary.writeAsBytes(png, flush: false);
        if (await file.exists()) await file.delete();
        await temporary.rename(file.path);
        final previous = _maintenance[directory.path] ?? Future.value();
        final cleanup = previous.then((_) => _trim());
        _maintenance[directory.path] = cleanup;
        try {
          await cleanup;
        } finally {
          if (identical(_maintenance[directory.path], cleanup)) {
            _maintenance.remove(directory.path);
          }
        }
      } on FileSystemException {
        /* Disk/full/cache eviction cannot break reading. */
      } finally {
        if (temporary != null) {
          try {
            if (await temporary.exists()) await temporary.delete();
          } on FileSystemException {
            /* Best effort. */
          }
        }
        if (identical(_writes[file.path], future)) _writes.remove(file.path);
      }
    }();
    _writes[file.path] = future;
    return future;
  }

  Future<void> flush() async {
    await Future.wait(
      _writes.entries
          .where((e) => e.key.startsWith('${directory.path}/'))
          .map((e) => e.value)
          .toList(),
    );
    await _maintenance[directory.path];
  }

  Future<void> _trim() async {
    final entries = <(File, FileStat)>[];
    await for (final entry in directory.list()) {
      if (entry is! File ||
          !RegExp(r'[a-f0-9]{64}-\d+-\d+\.png$').hasMatch(entry.path)) {
        continue;
      }
      final stat = await entry.stat();
      if (stat.type == FileSystemEntityType.file) entries.add((entry, stat));
    }
    entries.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
    var bytes = entries.fold<int>(0, (sum, entry) => sum + entry.$2.size);
    var count = entries.length;
    for (final entry in entries) {
      if (bytes <= maxBytes && count <= maxEntries) break;
      try {
        await entry.$1.delete();
      } on FileSystemException {
        /* Concurrent eviction. */
      }
      bytes -= entry.$2.size;
      count--;
    }
  }
}
