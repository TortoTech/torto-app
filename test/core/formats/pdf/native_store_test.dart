import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torto/core/formats/pdf/native_store.dart';

void main() {
  test('publication failure rolls back both previous files', () async {
    final root = await Directory.systemTemp.createTemp('native-pair-test-');
    addTearDown(() => root.delete(recursive: true));
    await File('${root.path}/native-pdf.zip').writeAsString('previous archive');
    await File(
      '${root.path}/native-pdf.json',
    ).writeAsString('previous metadata');
    final metadata = utf8.encode(
      jsonEncode({
        'content_sha256': sha256.convert(utf8.encode('new')).toString(),
      }),
    );
    await expectLater(
      withNativeStore(
        root,
        () =>
            installNativePair(root, File('${root.path}/missing.zip'), metadata),
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(
      await File('${root.path}/native-pdf.zip').readAsString(),
      'previous archive',
    );
    expect(
      await File('${root.path}/native-pdf.json').readAsString(),
      'previous metadata',
    );
  });
  test(
    'an interrupted pair is recovered before the next reader opens it',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'native-recovery-test-',
      );
      addTearDown(() => root.delete(recursive: true));
      await File('${root.path}/native-pdf.zip.previous').writeAsString('old');
      await File(
        '${root.path}/native-pdf.json.previous',
      ).writeAsString('old metadata');
      await File('${root.path}/native-pdf.zip').writeAsString('new incomplete');
      await File('${root.path}/native-publication.json').writeAsString(
        jsonEncode({'hash': '0' * 64, 'archive': true, 'metadata': true}),
      );
      await recoverNativePair(root);
      expect(await File('${root.path}/native-pdf.zip').readAsString(), 'old');
      expect(
        await File('${root.path}/native-pdf.json').readAsString(),
        'old metadata',
      );
      expect(
        await File('${root.path}/native-publication.json').exists(),
        isFalse,
      );
    },
  );
}
