import 'package:torto/app/ai/semantic_wire.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:torto/app/ai/ai_models.dart';
import 'package:torto/app/ai/ai_settings_store.dart';
import 'package:torto/app/ai/openai_compatible_client.dart';
import 'package:torto/app/ai/semantic_layout_service.dart';
import 'package:torto/app/progress_store.dart';
import 'package:torto/app/reader/reader_controller.dart';
import 'package:torto/core/layout/layout_types.dart';

const provider = AiProviderConfig(
  id: 'p',
  name: 'Test',
  baseUrl: 'https://example.test/v1',
  models: ['m'],
  apiKey: 'test',
);

class _Settings extends AiSettingsStore {
  @override
  Future<AiSettings> load() async => const AiSettings(
    providers: [provider],
    translation: TranslationSettings(
      providerId: 'p',
      model: 'm',
      translateToc: false,
    ),
    semanticLayout: SemanticLayoutSettings(
      enabled: true,
      providerId: 'p',
      model: 'm',
      reasoningEffort: ReasoningEffort.low,
    ),
  );
}

class _Service extends SemanticLayoutService {
  bool cancelled = false;
  _Service(
    super.provider,
    super.model, {
    required super.client,
    required super.cacheDirectory,
    required super.reasoningEffort,
  });
  @override
  void cancel() {
    cancelled = true;
    super.cancel();
  }
}

http.Response response(Object result) => http.Response(
  jsonEncode({
    'choices': [
      {
        'message': {'content': jsonEncode(result)},
      },
    ],
  }),
  200,
);
Future<void> until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for reader state');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Future<File> fixture(Directory root) async {
  final archive = Archive();
  void add(String name, String value) =>
      archive.addFile(ArchiveFile.string(name, value));
  add('mimetype', 'application/epub+zip');
  add(
    'META-INF/container.xml',
    '<container><rootfiles><rootfile full-path="book.opf"/></rootfiles></container>',
  );
  add(
    'book.opf',
    '<package><metadata><title>Scheduling</title></metadata><manifest><item id="s" href="s.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="s"/></spine></package>',
  );
  add(
    's.xhtml',
    '<html><body><h2 id="first">First</h2><p>How reading develops</p><p>${'A readable paragraph. ' * 160}</p><p>${'Another paragraph. ' * 160}</p><h2 id="second" style="page-break-before:always">Second</h2><p>A short final paragraph.</p></body></html>',
  );
  final file = File('${root.path}/fixture.epub');
  await file.writeAsBytes(ZipEncoder().encodeBytes(archive));
  return file;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'same subsection keeps in-flight work; navigation preempts and rejects late cache writes',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'torto-reader-semantic-',
      );
      addTearDown(() => root.delete(recursive: true));
      SharedPreferences.setMockInitialValues({});
      final services = <_Service>[];
      final requests = <Map>[];
      final replies = <Completer<http.Response>>[];
      final controller = ReaderController(
        progressStore: ProgressStore(await SharedPreferences.getInstance()),
        aiSettingsStore: _Settings(),
        semanticServiceFactory: (provider, model, effort) {
          final service = _Service(
            provider,
            model,
            reasoningEffort: effort,
            cacheDirectory: Directory('${root.path}/cache'),
            client: OpenAiCompatibleClient(
              client: MockClient((request) {
                final body = jsonDecode(request.body);
                expect(body['reasoning_effort'], 'low');
                requests.add(SemanticWire.decode(jsonDecode(body['messages'][1]['content'])) as Map);
                final reply = Completer<http.Response>();
                replies.add(reply);
                return reply.future;
              }),
            ),
          );
          services.add(service);
          return service;
        },
      );
      addTearDown(controller.dispose);
      await controller.open(
        await fixture(root),
        const LayoutViewport(width: 320, height: 480),
        const ReaderStyle(baseFontSize: 16),
      );
      await until(() => requests.length == 1);
      final first = requests.single;
      await controller.nextPage();
      await Future<void>.delayed(const Duration(milliseconds: 450));
      expect(requests, hasLength(1));
      expect(services.first.cancelled, false);
      await controller.goToHref('s.xhtml#second');
      await until(() => requests.length == 2);
      expect(services.first.cancelled, true);
      expect(
        requests.last['target_start'],
        greaterThan(first['target_start'] as int),
      );
      replies.first.complete(response({'groups': []}));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(await Directory('${root.path}/cache').exists(), false);
      replies.last.complete(response({'groups': []}));
      await until(() => !controller.semanticLayoutRunning);
      final anchor = controller.currentPage?.firstAnchor;
      expect(anchor, isNotNull);
      expect(controller.sectionIndex, 0);
      expect(await Directory('${root.path}/cache').list().length, 1);
      await controller.goToHref('s.xhtml#first');
      await until(() => requests.length == 3);
      controller.setReaderVisible(false);
      replies.last.complete(response({'groups': []}));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(await Directory('${root.path}/cache').list().length, 1);
    },
  );

  test('visible translation waits for recognition and then resumes', () async {
    final root = await Directory.systemTemp.createTemp('torto-reader-barrier-');
    addTearDown(() => root.delete(recursive: true));
    SharedPreferences.setMockInitialValues({});
    final requested = Completer<void>();
    final recognition = Completer<http.Response>();
    var translations = 0;
    final releaseTranslation = Completer<void>();
    final translation = OpenAiCompatibleClient(
      client: MockClient((request) async {
        translations++;
        await releaseTranslation.future;
        final body = jsonDecode(request.body);
        final input = SemanticWire.decode(jsonDecode(body['messages'][1]['content'])) as Map;
        return response(
          input.map((key, value) => MapEntry(key, 'Translated text.')),
        );
      }),
    );
    addTearDown(translation.close);
    var first = true;
    final controller = ReaderController(
      progressStore: ProgressStore(await SharedPreferences.getInstance()),
      aiSettingsStore: _Settings(),
      translationClient: translation,
      semanticServiceFactory: (p, m, e) => SemanticLayoutService(
        p,
        m,
        cacheDirectory: Directory('${root.path}/cache'),
        client: OpenAiCompatibleClient(
          client: MockClient((request) {
            if (first) {
              first = false;
              requested.complete();
              return recognition.future;
            }
            return Future.value(response({'groups': []}));
          }),
        ),
      ),
    );
    addTearDown(controller.dispose);
    await controller.open(
      await fixture(root),
      const LayoutViewport(width: 320, height: 480),
      const ReaderStyle(baseFontSize: 16),
    );
    await requested.future.timeout(const Duration(seconds: 10));
    expect(await controller.toggleTranslation(), true);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(translations, 0);
    final previousPage = controller.currentPage;
    recognition.complete(
      response({
        'groups': [
          {'kind': 'section_heading', 'block': 1},
        ],
      }),
    );
    await until(() => translations > 0);
    await Future<void>.delayed(const Duration(milliseconds: 350));
    expect(controller.currentPage, same(previousPage));
    releaseTranslation.complete();
    await until(() => !identical(controller.currentPage, previousPage));
    await until(() => !controller.semanticLayoutRunning);
    expect(controller.translationError, isNull);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final completedTranslations = translations;
    final completedPage = controller.currentPage;
    await controller.reloadSemanticLayout();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(translations, completedTranslations);
    expect(controller.currentPage, same(completedPage));
    controller.setReaderVisible(false);
  });
}
