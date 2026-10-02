import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:torto/app/ai/ai_models.dart';
import 'package:torto/app/ai/assistant_settings.dart';
import 'package:torto/app/ai/chat_assistant.dart';
import 'package:torto/app/ai/llm_transport.dart';
import 'package:torto/app/ai/openai_compatible_client.dart';
import 'package:torto/app/ai/pdf_discovery_service.dart';
import 'package:torto/app/ai/translation_glossary.dart';
import 'package:torto/app/update/app_update_service.dart';
import 'package:torto/core/translation/translation_models.dart';

http.Response answer(Object value) => http.Response(
  jsonEncode({
    'choices': [
      {
        'message': {'content': value is String ? value : jsonEncode(value)},
      },
    ],
  }),
  200,
);
const provider = AiProviderConfig(
  id: 'p',
  name: 'P',
  baseUrl: 'https://example.test/v1',
  apiKey: 'test',
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('reasoning defaults respect model capability limits', () async {
    for (final entry in [
      (AiProviderKind.gemini, 'gemini-2.5-pro', {'thinkingBudget': 128}),
      (AiProviderKind.gemini, 'gemini-2.5-flash', {'thinkingBudget': 0}),
      (AiProviderKind.gemini, 'gemini-3-pro-preview', {'thinkingLevel': 'low'}),
      (AiProviderKind.openAi, 'gpt-4.1', null),
      (AiProviderKind.miniMax, 'MiniMax-M2', null),
      (AiProviderKind.moonshot, 'kimi-k2.5', {'type': 'disabled'}),
    ]) {
      final client = MockClient((request) async {
        final body = jsonDecode(request.body);
        if (entry.$1 == AiProviderKind.gemini) {
          expect(body['generationConfig']['thinkingConfig'], entry.$3);
          return http.Response(
            jsonEncode({
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {'text': 'OK'},
                    ],
                  },
                },
              ],
            }),
            200,
          );
        }
        expect(body['reasoning_effort'], isNull);
        expect(body['thinking'], entry.$3);
        return answer('OK');
      });
      expect(
        await LlmTransport(client).generate(
          provider: provider.copyWith(kind: entry.$1),
          model: entry.$2,
          system: 'Task',
          input: 'Question',
          effort: ReasoningEffort.none,
        ),
        'OK',
      );
      client.close();
    }
  });
  test(
    'real SSE deltas stream progressively and final citations stay linked',
    () async {
      final client = MockClient((request) async {
        expect(jsonDecode(request.body)['stream'], true);
        final events = [
          {'type': 'response.output_text.delta', 'delta': 'Hello'},
          {'type': 'response.output_text.delta', 'delta': ' world.'},
          {
            'type': 'response.completed',
            'response': {
              'output': [
                {
                  'type': 'message',
                  'content': [
                    {
                      'type': 'output_text',
                      'text': 'Hello world.',
                      'annotations': [
                        {
                          'type': 'url_citation',
                          'start_index': 0,
                          'end_index': 5,
                          'url': 'https://example.test/hello',
                        },
                      ],
                    },
                  ],
                },
              ],
            },
          },
        ];
        return http.Response(
          '${events.map((event) => 'data: ${jsonEncode(event)}\n\n').join()}data: [DONE]\n\n',
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      });
      final updates = <String>[];
      final result = await LlmTransport(client).generate(
        provider: provider.copyWith(kind: AiProviderKind.openAi),
        model: 'm',
        system: 'Task',
        input: 'Question',
        webSearch: true,
        onPartial: updates.add,
      );
      expect(updates.first, 'Hello');
      expect(updates.last, '[Hello](<https://example.test/hello>) world.');
      expect(result, updates.last);
      client.close();
    },
  );
  test(
    'schema fallback keeps original instructions and recovers only outside strings',
    () async {
      var calls = 0;
      final client = MockClient((request) async {
        final body = jsonDecode(request.body);
        expect(body['messages'][0]['content'], contains('Original task'));
        if (++calls == 1) {
          return http.Response('unsupported response_format json_schema', 400);
        }
        expect(body['response_format']['type'], 'json_object');
        return answer('```json\n{"value":"text, }",}\n```');
      });
      final content = await LlmTransport(client).generate(
        provider: provider.copyWith(kind: AiProviderKind.openAi),
        model: 'm',
        system: 'Original task',
        input: {},
        schema: {'type': 'object'},
      );
      expect(decodeLlmObject(content)['value'], 'text, }');
      expect(calls, 2);
      client.close();
    },
  );
  test(
    'custom JSON uses the prompt; new models stay empty and layout reasoning defaults off',
    () async {
      final client = MockClient((request) async {
        expect(jsonDecode(request.body)['response_format'], isNull);
        return answer({'ok': true});
      });
      expect(
        decodeLlmObject(
          await LlmTransport(client).generate(
            provider: provider,
            model: 'm',
            system: 'Task',
            input: {},
            schema: {'type': 'object'},
          ),
        )['ok'],
        true,
      );
      expect(
        AiSettings.defaults().normalized().providers.single.models,
        isEmpty,
      );
      expect(
        SemanticLayoutSettings.fromJson({}).reasoningEffort,
        ReasoningEffort.none,
      );
      expect(AiProviderKind.values, hasLength(15));
      client.close();
    },
  );
  for (final kind in [
    AiProviderKind.anthropic,
    AiProviderKind.gemini,
    AiProviderKind.ollama,
  ]) {
    test(
      '$kind uses its native transport and retains system instructions',
      () async {
        final client = MockClient((request) async {
          final body = jsonDecode(request.body);
          if (kind == AiProviderKind.anthropic) {
            expect(request.headers['x-api-key'], 'test');
            expect(body['system'], contains('Task'));
            return http.Response(
              jsonEncode({
                'content': [
                  {
                    'type': 'tool_use',
                    'name': 'result',
                    'input': {'ok': true},
                  },
                ],
              }),
              200,
            );
          }
          if (kind == AiProviderKind.gemini) {
            expect(request.headers['x-goog-api-key'], 'test');
            expect(
              body['systemInstruction']['parts'][0]['text'],
              contains('Task'),
            );
            return http.Response(
              jsonEncode({
                'candidates': [
                  {
                    'content': {
                      'parts': [
                        {'text': '{"ok":true}'},
                      ],
                    },
                  },
                ],
              }),
              200,
            );
          }
          expect(body['format'], isA<Map>());
          return http.Response(
            jsonEncode({
              'message': {'content': '{"ok":true}'},
            }),
            200,
          );
        });
        expect(
          decodeLlmObject(
            await LlmTransport(client).generate(
              provider: provider.copyWith(kind: kind),
              model: 'm',
              system: 'Task',
              input: {},
              schema: {'type': 'object'},
            ),
          )['ok'],
          true,
        );
        client.close();
      },
    );
  }
  test(
    'glossary survives reopening, rejects invented/conflicting terms and isolates book/language',
    () async {
      const blocks = [
        TranslationBlockInput(
          blockIndex: 0,
          nodeId: 'n0',
          text: 'The spectral centroid is useful.',
        ),
      ];
      const translated = [BlockTranslation(blockIndex: 0, text: '频谱质心很有用。')];
      const glossary = TranslationGlossary('book', 'zh');
      await glossary.merge(
        '{"g":[{"s":"spectral centroid","t":"频谱质心"},{"s":"invented","t":"虚构"}]}',
        blocks,
        translated,
      );
      expect(
        await const TranslationGlossary('book', 'zh').prompt(blocks),
        contains('"s":"spectral centroid"'),
      );
      await glossary.merge(
        '{"g":[{"s":"spectral centroid","t":"很有用"}]}',
        blocks,
        translated,
      );
      expect(await glossary.prompt(blocks), isNot(contains('"t":"很有用"')));
      expect(
        await const TranslationGlossary('other', 'zh').prompt(blocks),
        isNot(contains('"s":"spectral centroid"')),
      );
      expect(
        await const TranslationGlossary('book', 'en').prompt(blocks),
        isNot(contains('"s":"spectral centroid"')),
      );
      await glossary.merge('{"g":"invalid"}', blocks, translated);
    },
  );
  test(
    'PDF inspection verifies real destination images and retains a draft',
    () async {
      final seen = <int>[];
      var calls = 0;
      final service = PdfDiscoveryService(
        client: OpenAiCompatibleClient(
          client: MockClient((request) async {
            if (++calls == 1) {
              return answer({
                'title': 'Book',
                'authors': ['Author'],
                'inspect_pages': [],
                'entries': [
                  {'title': 'Chapter', 'physical_page': 6, 'depth': 0},
                ],
                'special_pages': [],
              });
            }
            final input = jsonDecode(
              (jsonDecode(request.body)['messages'][1]['content']
                  as List)[0]['text'],
            );
            expect(input['physical_pages'], [6]);
            return answer({
              'targets': [
                {'title': 'Chapter', 'physical_page': 6, 'verified': true},
              ],
            });
          }),
        ),
      );
      final result = await service.discover(
        bookId: 'book',
        pageCount: 8,
        provider: provider,
        model: 'm',
        pageImage: (page) async {
          seen.add(page);
          return 'cG5n';
        },
      );
      expect(seen, [1, 2, 3, 4, 6]);
      expect(result.entries, hasLength(1));
      expect(
        (await SharedPreferences.getInstance()).getString(
          'pdf_discovery_draft_v1_book',
        ),
        contains('Chapter'),
      );
      service.cancel();
    },
  );
  test('PDF rejects out-of-range destinations', () async {
    final service = PdfDiscoveryService(
      client: OpenAiCompatibleClient(
        client: MockClient(
          (_) async => answer({
            'title': '',
            'authors': [],
            'inspect_pages': [],
            'special_pages': [],
            'entries': [
              {'title': 'Invented', 'physical_page': 999, 'depth': 0},
            ],
          }),
        ),
      ),
    );
    await expectLater(
      service.discover(
        bookId: 'bad',
        pageCount: 5,
        provider: provider,
        model: 'm',
        pageImage: (_) async => 'cG5n',
      ),
      throwsFormatException,
    );
    service.cancel();
  });
  test(
    'chat runs bounded third-party search and exposes clickable sources',
    () async {
      var calls = 0, searches = 0;
      final assistant = ChatAssistant(
        client: MockClient((request) async {
          if (request.url.host == 'search.test') {
            searches++;
            return http.Response(
              '{"results":[{"title":"Evidence","url":"https://example.test/evidence","content":"Fact"}]}',
              200,
            );
          }
          return answer(
            ++calls == 1
                ? {'action': 'search_web', 'query': 'question', 'answer': ''}
                : {
                    'action': 'answer',
                    'query': '',
                    'answer': 'Supported answer.',
                  },
          );
        }),
      );
      final result = await assistant.answer(
        provider: provider,
        model: 'm',
        title: 'Book',
        context: 'Text',
        history: [],
        settings: const AssistantSettings(
          webSearch: true,
          searchService: SearchService.tavily,
          searchEndpoint: 'https://search.test/query',
          searchKey: 'test',
        ),
      );
      expect(searches, 1);
      expect(calls, 2);
      expect(result, contains('[Evidence](<https://example.test/evidence>)'));
      assistant.cancel();
    },
  );
  test('disabled web search cannot cause tool network calls', () async {
    var calls = 0;
    final assistant = ChatAssistant(
      client: MockClient((_) async {
        calls++;
        return answer({'action': 'search_web', 'query': 'query', 'answer': ''});
      }),
    );
    await expectLater(
      assistant.answer(
        provider: provider,
        model: 'm',
        settings: const AssistantSettings(),
        history: [],
        title: '',
        context: '',
      ),
      throwsFormatException,
    );
    expect(calls, 1);
    assistant.cancel();
  });
  test(
    'official OpenAI search uses Responses and links citations inline',
    () async {
      final client = MockClient((request) async {
        expect(request.url.path, '/v1/responses');
        expect(jsonDecode(request.body)['tools'][0]['type'], 'web_search');
        return http.Response(
          jsonEncode({
            'output': [
              {
                'type': 'message',
                'content': [
                  {
                    'type': 'output_text',
                    'text': 'Fact.',
                    'annotations': [
                      {
                        'type': 'url_citation',
                        'start_index': 0,
                        'end_index': 4,
                        'url': 'https://example.test/fact',
                      },
                    ],
                  },
                ],
              },
            ],
          }),
          200,
        );
      });
      expect(
        await LlmTransport(client).generate(
          provider: provider.copyWith(kind: AiProviderKind.openAi),
          model: 'm',
          system: 'Task',
          input: 'Question',
          webSearch: true,
        ),
        '[Fact](<https://example.test/fact>).',
      );
      client.close();
    },
  );
  test('automatic updates require a complete Android Gitee mirror', () async {
    final service = AppUpdateService(
      client: MockClient((request) async {
        if (request.url.host == 'api.github.com') {
          return http.Response('Unavailable', 503);
        }
        if (request.url.path.endsWith('torto-update.json')) {
          return http.Response(
            jsonEncode({
              'tag': 'v0.7.1',
              'version': '0.7.1',
              'asset': {
                'name': 'Torto-0.7.1-android-arm64-v8a.apk',
                'size': 123,
                'sha256': 'a' * 64,
              },
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'tag_name': 'v0.7.1',
            'assets': [
              {
                'name': 'Torto-0.7.1-android-arm64-v8a.apk',
                'browser_download_url':
                    'https://gitee.com/TortoTech/torto-app/releases/download/v0.7.1/Torto-0.7.1-android-arm64-v8a.apk',
              },
            ],
          }),
          200,
        );
      }),
    );
    final result = await service.check(
      currentVersion: '0.6.2',
      source: UpdateSource.automatic,
    );
    expect(result.updateAvailable, true);
    expect(result.releasePage!.host, 'gitee.com');
    service.dispose();
  });
}
