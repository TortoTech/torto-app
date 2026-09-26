import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:torto/app/ai/ai_models.dart';
import 'package:torto/app/ai/openai_compatible_client.dart';
import 'package:torto/app/ai/semantic_layout_service.dart';
import 'package:torto/core/ir/ir.dart';
import 'package:torto/core/semantic_layout/batching.dart';
import 'semantic_layout_test.dart' show chapter, paragraphAt;

const provider = AiProviderConfig(
  id: 'p',
  name: 'P',
  baseUrl: 'https://example.test/v1',
  models: ['m'],
  apiKey: 'test',
);
http.Response result(List<Object?> groups) => http.Response(
  jsonEncode({
    'choices': [
      {
        'message': {
          'content': jsonEncode({'groups': groups}),
        },
      },
    ],
  }),
  200,
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'reasoning settings migrate and persist independently of translation',
    () {
      expect(
        SemanticLayoutSettings.fromJson({}).reasoningEffort,
        ReasoningEffort.defaultLevel,
      );
      const settings = SemanticLayoutSettings(
        enabled: true,
        providerId: 'p',
        model: 'm',
        reasoningEffort: ReasoningEffort.high,
      );
      expect(
        SemanticLayoutSettings.fromJson(settings.toJson()).reasoningEffort,
        ReasoningEffort.high,
      );
    },
  );
  test(
    'batch cache survives demand changes and isolates reasoning settings and content',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'torto-layout-batches-',
      );
      addTearDown(() => root.delete(recursive: true));
      var calls = 0;
      SemanticLayoutService service(ReasoningEffort effort) {
        final service = SemanticLayoutService(
          provider,
          'm',
          reasoningEffort: effort,
          cacheDirectory: root,
          client: OpenAiCompatibleClient(
            client: MockClient((request) async {
              calls++;
              final body = jsonDecode(request.body);
              if (effort == ReasoningEffort.defaultLevel) {
                expect(body.containsKey('reasoning_effort'), isFalse);
              } else {
                expect(body['reasoning_effort'], effort.label);
              }
              return result([]);
            }),
          ),
        );
        addTearDown(service.cancel);
        return service;
      }

      final original = chapter([
        paragraphAt(0, 'First', kind: TextBlockKind.heading),
        paragraphAt(1, 'a' * 3000),
        paragraphAt(2, 'b' * 3000),
      ]);
      final plan = semanticBatches(original);
      final normal = service(ReasoningEffort.defaultLevel);
      await normal.recognize(original, 'book', batches: [plan.last]);
      expect(calls, 1);
      await normal.recognize(
        original,
        'book',
        batches: [plan.first, plan.last],
      );
      expect(calls, 2);
      await service(
        ReasoningEffort.low,
      ).recognize(original, 'book', batches: [plan.last]);
      expect(calls, 3);
      final edited = chapter([
        paragraphAt(0, 'First', kind: TextBlockKind.heading),
        paragraphAt(1, 'a' * 3000),
        paragraphAt(2, 'c' * 3000),
      ]);
      await normal.recognize(edited, 'book', batches: [plan.last]);
      expect(calls, 4);
    },
  );
  test(
    'redundant authored headings do not retry but invalid output never becomes an empty cache',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'torto-layout-invalid-',
      );
      addTearDown(() => root.delete(recursive: true));
      var calls = 0;
      final service = SemanticLayoutService(
        provider,
        'm',
        cacheDirectory: root,
        client: OpenAiCompatibleClient(
          client: MockClient((request) async {
            calls++;
            return result([
              {'kind': 'section_heading', 'block': calls == 1 ? 0 : 999},
            ]);
          }),
        ),
      );
      addTearDown(service.cancel);
      final original = chapter([
        paragraphAt(0, 'Existing', kind: TextBlockKind.heading),
        paragraphAt(1, 'Plain prose'),
      ]);
      expect(await service.recognize(original, 'first'), isEmpty);
      expect(calls, 1);
      await expectLater(
        service.recognize(original, 'second'),
        throwsFormatException,
      );
      expect(calls, 3);
      await expectLater(
        service.recognize(original, 'second'),
        throwsFormatException,
      );
      expect(calls, 5);
      expect(await root.list().length, 1);
    },
  );
  test(
    'read-only context cannot be promoted into target annotations',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'torto-layout-context-',
      );
      addTearDown(() => root.delete(recursive: true));
      final original = chapter([
        paragraphAt(0, 'First'),
        paragraphAt(1, 'body ' * 1000),
      ]);
      final plan = semanticBatches(original);
      var calls = 0;
      final service = SemanticLayoutService(
        provider,
        'm',
        cacheDirectory: root,
        client: OpenAiCompatibleClient(
          client: MockClient((request) async {
            calls++;
            return result([
              {'kind': 'section_heading', 'block': 0},
            ]);
          }),
        ),
      );
      addTearDown(service.cancel);
      await expectLater(
        service.recognize(original, 'book', batches: [plan.last]),
        throwsFormatException,
      );
      expect(calls, 2);
    },
  );
}
