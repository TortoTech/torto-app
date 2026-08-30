import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:torto/app/ai/ai_models.dart';
import 'package:torto/app/ai/openai_compatible_client.dart';
import 'package:torto/core/translation/translation_models.dart';

void main() {
  const provider = AiProviderConfig(
    id: 'test',
    name: 'Test',
    baseUrl: 'https://example.com/v1/',
    apiKey: 'secret',
    models: ['book-model'],
  );

  test('loads and sorts models from an OpenAI-compatible endpoint', () async {
    final client = OpenAiCompatibleClient(
      client: MockClient((request) async {
        expect(request.url.toString(), 'https://example.com/v1/models');
        expect(request.headers['authorization'], 'Bearer secret');
        return _jsonResponse({
          'data': [
            {'id': 'z-model'},
            {'id': 'A-model'},
          ],
        });
      }),
    );

    expect(await client.fetchModels(provider), ['A-model', 'z-model']);
    client.close();
  });

  test(
    'batches long translations and maps response keys to source ids',
    () async {
      var requests = 0;
      final client = OpenAiCompatibleClient(
        client: MockClient((request) async {
          requests++;
          expect(
            request.url.toString(),
            'https://example.com/v1/chat/completions',
          );
          final payload = jsonDecode(request.body) as Map<String, dynamic>;
          expect(payload['model'], 'book-model');
          final messages = payload['messages'] as List<dynamic>;
          final input =
              jsonDecode(
                    (messages[1] as Map<String, dynamic>)['content'] as String,
                  )
                  as Map<String, dynamic>;
          final translated = {
            for (final entry in input.entries) entry.key: '译文-${entry.value}',
          };
          return _jsonResponse({
            'choices': [
              {
                'message': {'content': jsonEncode(translated)},
              },
            ],
          });
        }),
      );
      final blocks = [
        TranslationBlockInput(blockIndex: 4, nodeId: 'one', text: 'a' * 1200),
        TranslationBlockInput(
          blockIndex: 9,
          segmentIndex: 2,
          nodeId: 'two',
          text: 'b' * 1200,
        ),
      ];

      final result = await client.translateBlocks(
        provider: provider,
        model: 'book-model',
        targetLanguage: '简体中文',
        blocks: blocks,
      );

      expect(requests, 2);
      expect(result.map((value) => value.blockIndex), [4, 9]);
      expect(result.last.segmentIndex, 2);
      expect(result.first.text, startsWith('译文-'));
      client.close();
    },
  );

  test('retries one failed translation request', () async {
    var requests = 0;
    final client = OpenAiCompatibleClient(
      client: MockClient((request) async {
        requests++;
        if (requests == 1) {
          return http.Response('{"error":{"message":"temporary"}}', 500);
        }
        return _jsonResponse({
          'choices': [
            {
              'message': {'content': '{"0":"你好"}'},
            },
          ],
        });
      }),
    );

    final result = await client.translateBlocks(
      provider: provider,
      model: 'book-model',
      targetLanguage: '简体中文',
      blocks: const [
        TranslationBlockInput(blockIndex: 7, nodeId: 'node', text: 'Hello'),
      ],
    );

    expect(requests, 2);
    expect(result.single.text, '你好');
    client.close();
  });
}

http.Response _jsonResponse(Object body) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  200,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);
