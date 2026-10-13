import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';

final _writers = <String, Future<void>>{};
Future<T> withNativeStore<T>(
  Directory root,
  Future<T> Function() operation,
) async {
  var key = root.absolute.path.replaceAll('\\', '/');
  if (Platform.isWindows) key = key.toLowerCase();
  final previous = _writers[key], done = Completer<void>();
  _writers[key] = done.future;
  try {
    await previous;
    return await operation();
  } finally {
    done.complete();
    if (identical(_writers[key], done.future)) _writers.remove(key);
  }
}

Future<void> recoverNativePair(Directory root) async {
  final journal = File('${root.path}/native-publication.json');
  if (!await journal.exists()) return;
  final state = jsonDecode(await journal.readAsString()) as Map;
  if (state['hash'] is! String ||
      !RegExp(r'^[a-f0-9]{64}$').hasMatch(state['hash'] as String) ||
      state['archive'] is! bool ||
      state['metadata'] is! bool) {
    throw const FormatException('Invalid native PDF publication journal');
  }
  final zip = File('${root.path}/native-pdf.zip'),
      metadata = File('${root.path}/native-pdf.json');
  var complete = false;
  try {
    complete =
        (jsonDecode(await metadata.readAsString()) as Map)['content_sha256'] ==
            state['hash'] &&
        (await sha256.bind(zip.openRead()).first).toString() == state['hash'];
  } catch (_) {}
  for (final (target, existed) in [
    (zip, state['archive'] == true),
    (metadata, state['metadata'] == true),
  ]) {
    final backup = File('${target.path}.previous');
    if (complete) {
      if (await backup.exists()) await backup.delete();
    } else if (await backup.exists()) {
      if (await target.exists()) await target.delete();
      await backup.rename(target.path);
    } else if (!existed && await target.exists()) {
      await target.delete();
    }
  }
  await journal.delete();
}

/// Called under withNativeStore. Journaled pair publication survives errors
/// and interruption without treating a partial archive as a new generation.
Future<void> installNativePair(
  Directory root,
  File archive,
  List<int> metadataBytes,
) async {
  await recoverNativePair(root);
  final destination = File('${root.path}/native-pdf.zip'),
      metadata = File('${root.path}/native-pdf.json');
  final pending = File('${root.path}/native-pdf.json.part');
  await pending.writeAsBytes(metadataBytes, flush: true);
  final journal = File('${root.path}/native-publication.json');
  final value = jsonDecode(utf8.decode(metadataBytes)) as Map;
  await journal.writeAsString(
    jsonEncode({
      'hash': value['content_sha256'],
      'archive': await destination.exists(),
      'metadata': await metadata.exists(),
    }),
    flush: true,
  );
  try {
    for (final target in [destination, metadata]) {
      final backup = File('${target.path}.previous');
      if (await backup.exists()) await backup.delete();
      if (await target.exists()) await target.rename(backup.path);
    }
    await archive.rename(destination.path);
    await pending.rename(metadata.path);
  } catch (_) {
    await recoverNativePair(root);
    rethrow;
  }
  // Both files are installed; leave the journal recoverable if cleanup fails.
  for (final target in [destination, metadata]) {
    final backup = File('${target.path}.previous');
    if (await backup.exists()) await backup.delete();
  }
  await journal.delete();
}
