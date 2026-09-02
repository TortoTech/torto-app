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

  test('translation prompt carries structured book translation rules', () {
    final prompt = translationSystemPrompt('简体中文');
    expect(prompt, contains('# 翻译任务'));
    expect(prompt, contains('# 中文表达'));
    expect(prompt, contains('# 正文结构'));
    expect(prompt, contains('# 输出格式'));
    expect(prompt, contains('<cite>'));
    expect(prompt, contains('<torto-italic>'));
    expect(prompt, contains('不需要用括号附原文'));
  });

  test('translation reasoning effort defaults and round-trips', () {
    expect(
      TranslationSettings.fromJson(const {}).reasoningEffort,
      ReasoningEffort.defaultLevel,
    );
    final restored = TranslationSettings.fromJson(
      const TranslationSettings(reasoningEffort: ReasoningEffort.high).toJson(),
    );
    expect(restored.reasoningEffort, ReasoningEffort.high);
  });

  test('leading list markers are preserved deterministically', () {
    expect(preserveLeadingListMarker('Paragraph', '• 译文'), '译文');
    expect(preserveLeadingListMarker('1. Item', '2. 项目'), '1. 项目');
    expect(preserveLeadingListMarker('• Item', '• 项目'), '• 项目');
  });

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

  test('retries when translated inline markup fails validation', () async {
    var requests = 0;
    final client = OpenAiCompatibleClient(
      client: MockClient((request) async {
        requests++;
        final value = requests == 1 ? '<em>损坏' : '<em>有效</em>';
        return _jsonResponse({
          'choices': [
            {
              'message': {
                'content': jsonEncode({'0': value}),
              },
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
        TranslationBlockInput(
          blockIndex: 0,
          nodeId: 'node',
          text: '<em>Hello</em>',
        ),
      ],
      validate: (translations) {
        if (!translations.single.text.endsWith('</em>')) {
          throw const FormatException('invalid inline markup');
        }
      },
    );

    expect(requests, 2);
    expect(result.single.text, '<em>有效</em>');
    client.close();
  });

  test(
    'reasoning effort is omitted by default and sent when selected',
    () async {
      final payloads = <Map<String, dynamic>>[];
      final client = OpenAiCompatibleClient(
        client: MockClient((request) async {
          payloads.add(jsonDecode(request.body) as Map<String, dynamic>);
          return _jsonResponse({
            'choices': [
              {
                'message': {'content': '{"0":"你好"}'},
              },
            ],
          });
        }),
      );
      const blocks = [
        TranslationBlockInput(blockIndex: 0, nodeId: 'node', text: 'Hello'),
      ];

      await client.translateBlocks(
        provider: provider,
        model: 'book-model',
        targetLanguage: '简体中文',
        blocks: blocks,
      );
      await client.translateBlocks(
        provider: provider,
        model: 'book-model',
        targetLanguage: '简体中文',
        reasoningEffort: ReasoningEffort.minimal,
        blocks: blocks,
      );

      expect(payloads.first.containsKey('reasoning_effort'), isFalse);
      expect(payloads.last['reasoning_effort'], 'minimal');
      client.close();
    },
  );
}

http.Response _jsonResponse(Object body) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  200,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);
