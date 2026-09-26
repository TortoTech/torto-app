import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Bounded, best-effort local diagnostics. Callers pass metadata, never content.
class ReaderDiagnostics {
  static final instance = ReaderDiagnostics();
  ReaderDiagnostics({this.maxBytes = 1024 * 1024});
  final int maxBytes;
  Directory? _directory;
  Future<void> _tail = Future.value();
  int _pending = 0;

  Future<void> initialize(Directory directory) async {
    await directory.create(recursive: true);
    _directory = directory;
  }

  void event(String name, [Map<String, Object?> fields = const {}]) {
    final directory = _directory;
    if (directory == null || _pending >= 128) return;
    final line =
        '${jsonEncode({'time': DateTime.now().toUtc().toIso8601String(), 'event': name, ...fields})}\n';
    if (line.length > 8192) return;
    _pending++;
    _tail = _tail
        .then((_) async {
          final file = File('${directory.path}/reader.log');
          if (await file.exists() &&
              await file.length() + utf8.encode(line).length > maxBytes) {
            final oldest = File('${directory.path}/reader.2.log');
            if (await oldest.exists()) await oldest.delete();
            final previous = File('${directory.path}/reader.1.log');
            if (await previous.exists()) await previous.rename(oldest.path);
            await file.rename(previous.path);
          }
          await file.writeAsString(line, mode: FileMode.append);
        })
        .catchError((Object _) {})
        .whenComplete(() => _pending--);
  }

  Future<T> measure<T>(
    String name,
    Future<T> Function() action, [
    Map<String, Object?> fields = const {},
  ]) async {
    final watch = Stopwatch()..start();
    event('$name.start', fields);
    try {
      final result = await action();
      event('$name.complete', {
        ...fields,
        'elapsed_ms': watch.elapsedMilliseconds,
      });
      return result;
    } catch (error) {
      // Exception messages can contain book text, URLs or provider credentials.
      event('$name.failed', {
        ...fields,
        'elapsed_ms': watch.elapsedMilliseconds,
        'type': error.runtimeType.toString(),
      });
      rethrow;
    }
  }

  Future<String> export() async {
    await _tail;
    final directory = _directory;
    if (directory == null) return '';
    final buffer = StringBuffer();
    for (final name in ['reader.2.log', 'reader.1.log', 'reader.log']) {
      final file = File('${directory.path}/$name');
      if (await file.exists()) buffer.write(await file.readAsString());
    }
    final traces = await directory
        .list()
        .where(
          (entry) =>
              entry is File && RegExp(r'anr-[0-9]+\.txt$').hasMatch(entry.path),
        )
        .toList();
    traces.sort((a, b) => a.path.compareTo(b.path));
    for (final entry in traces.take(3)) {
      buffer.writeln('\n--- Android ANR trace (up to 128 KiB) ---');
      buffer.write(
        utf8.decode(await (entry as File).readAsBytes(), allowMalformed: true),
      );
    }
    return buffer.toString();
  }
}
