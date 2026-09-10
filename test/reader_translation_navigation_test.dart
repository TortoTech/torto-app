import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:torto/app/ai/ai_models.dart';
import 'package:torto/app/ai/ai_settings_store.dart';
import 'package:torto/app/ai/openai_compatible_client.dart';
import 'package:torto/app/progress_store.dart';
import 'package:torto/app/reader/reader_controller.dart';
import 'package:torto/core/layout/layout_types.dart';
import 'package:torto/core/translation/translation_models.dart';

class _Settings extends AiSettingsStore {
  @override
  Future<AiSettings> load() async => const AiSettings(
    providers: [
      AiProviderConfig(
        id: 'provider-1',
        name: 'Test',
        baseUrl: 'https://example.invalid/v1',
        apiKey: 'test',
      ),
    ],
    translation: TranslationSettings(translateToc: false),
  );
}

class _DelayedClient extends OpenAiCompatibleClient {
  final releaseFirst = Completer<void>();
  final requests = <String>[];
  @override
  Future<List<BlockTranslation>> translateBlocks({
    required AiProviderConfig provider,
    required String model,
    required String targetLanguage,
    required List<TranslationBlockInput> blocks,
    ReasoningEffort reasoningEffort = ReasoningEffort.defaultLevel,
    FutureOr<void> Function(List<BlockTranslation>)? validate,
  }) async {
    requests.add(blocks.map((block) => block.text).join(' '));
    if (requests.length == 1) await releaseFirst.future;
    throw StateError('Simulated request failure');
  }
}

void main() {
  test(
    'chapter entered during an in-flight request is translated without another turn',
    () async {
      SharedPreferences.setMockInitialValues({});
      final directory = await Directory.systemTemp.createTemp(
        'torto-translation-navigation-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final archive = Archive();
      void add(String name, String contents) {
        final bytes = utf8.encode(contents);
        archive.addFile(ArchiveFile(name, bytes.length, bytes));
      }

      add('mimetype', 'application/epub+zip');
      add(
        'META-INF/container.xml',
        '<container><rootfiles><rootfile full-path="book.opf"/></rootfiles></container>',
      );
      add(
        'book.opf',
        '''<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">navigation-test</dc:identifier><dc:title>Test</dc:title><dc:language>en</dc:language></metadata><manifest><item id="a" href="a.xhtml" media-type="application/xhtml+xml"/><item id="b" href="b.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="a"/><itemref idref="b"/></spine></package>''',
      );
      add('a.xhtml', '<html><body><p>First chapter.</p></body></html>');
      add('b.xhtml', '<html><body><p>Second chapter.</p></body></html>');
      final file = File('${directory.path}/book.epub');
      await file.writeAsBytes(ZipEncoder().encode(archive));
      final client = _DelayedClient();
      final controller = ReaderController(
        progressStore: ProgressStore(await SharedPreferences.getInstance()),
        aiSettingsStore: _Settings(),
        translationClient: client,
      );
      addTearDown(controller.dispose);
      await controller.open(
        file,
        const LayoutViewport(width: 400, height: 700),
        const ReaderStyle(),
      );
      expect(await controller.toggleTranslation(), isTrue);
      for (var i = 0; i < 100 && client.requests.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(client.requests.single, contains('First chapter'));
      await controller.nextPage();
      expect(controller.sectionIndex, 1);
      client.releaseFirst.complete();
      for (var i = 0; i < 100 && client.requests.length < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(client.requests, hasLength(2));
      expect(client.requests.last, contains('Second chapter'));
    },
  );
}
