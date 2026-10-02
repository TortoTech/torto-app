import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart' hide TextStyle;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_math_fork/flutter_math.dart' as fm;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:torto/app/ai/ai_models.dart';
import 'package:torto/app/ai/llm_transport.dart';
import 'package:torto/app/ai/official_rest_search.dart';
import 'package:torto/app/ai/assistant_settings.dart';
import 'package:torto/app/ai/chat_assistant.dart';
import 'package:torto/app/ai/openai_compatible_client.dart';
import 'package:torto/app/ai/search_capabilities.dart';
import 'package:torto/app/ai/semantic_wire.dart';
import 'package:torto/app/ai/semantic_layout_contract.dart';
import 'package:torto/core/translation/translation_models.dart';
import 'package:torto/app/reader/assistant_rich_text.dart';
import 'package:torto/core/ir/ir.dart';
import 'package:torto/core/semantic_layout/inline_semantics.dart';
import 'package:torto/core/translation/translation_markup.dart';
import 'package:torto/app/ai/pdf_discovery_service.dart';

http.Response reply(Object data) => http.Response(
  jsonEncode({
    'choices': [
      {
        'message': {'content': jsonEncode(data)},
      },
    ],
  }),
  200,
);
AiProviderConfig provider(AiProviderKind kind, [String id = 'p']) =>
    AiProviderConfig(
      id: id,
      name: id,
      kind: kind,
      baseUrl: 'https://example.test/v1',
      apiKey: 'secret',
    );
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'capture actual full request sizes for the same semantic window',
    () async {
      final sizes = <int>[];
      final client = OpenAiCompatibleClient(
        client: MockClient((request) async {
          sizes.add(request.bodyBytes.length);
          return reply({'groups': [], 'citations': [], 'formulas': []});
        }),
      );
      final input = {
        'target_start': 0,
        'target_end_exclusive': 40,
        'quotes_enabled': true,
        'captions_enabled': true,
        'blocks': [
          for (var i = 0; i < 40; i++)
            {
              'id': i,
              'type': 'text',
              'text': 'Source paragraph $i. No text may be rewritten.',
              'math_texts': [],
              'attribution_eligible': false,
              'style': {'bold_ratio': 0.0, 'italic_ratio': 0.0},
            },
        ],
      };
      final prompt = await File('assets/ai/semantic_layout.md').readAsString();
      for (final compact in [false, true]) {
        await client.recognizeLayout(
          provider: provider(AiProviderKind.custom),
          model: 'm',
          prompt: prompt,
          input: input,
          schema: semanticSchema({'quote', 'caption'}),
          compact: compact,
        );
      }
      // Full captured HTTP body: includes prompt, input, schema and transport metadata.
      // ignore: avoid_print
      print(
        'semantic_request_bytes long=${sizes[0]} compact=${sizes[1]} blocks=40',
      );
      expect(sizes.length, 2);
      client.close();
    },
  );
  test(
    'translation rejects extra paragraph keys and sends concrete validation feedback on retry',
    () async {
      var calls = 0;
      final client = OpenAiCompatibleClient(
        client: MockClient((request) async {
          final body = jsonDecode(request.body);
          expect(body['response_format']['json_schema']['name'], 'translation');
          if (++calls == 1) return reply({'0': 'draft', '1': 'unrequested'});
          expect(
            body['messages'][1]['content'],
            contains('unrequested text block'),
          );
          return reply({'0': 'verified', 'g': []});
        }),
      );
      final result = await client.translateBlocks(
        provider: provider(AiProviderKind.openAi),
        model: 'gpt-5',
        targetLanguage: 'en',
        blocks: [
          const TranslationBlockInput(
            blockIndex: 0,
            nodeId: 'source-0',
            text: 'source',
          ),
        ],
      );
      expect(result.single.text, 'verified');
      expect(calls, 2);
      client.close();
    },
  );
  for (final kind in [
    AiProviderKind.anthropic,
    AiProviderKind.gemini,
    AiProviderKind.xai,
    AiProviderKind.openRouter,
    AiProviderKind.zai,
  ]) {
    test(
      '$kind official search request retains provider protocol and sources',
      () async {
        final client = MockClient((request) async {
          final body = jsonDecode(request.body);
          if (kind == AiProviderKind.anthropic) {
            expect(body['tools'].first['type'], 'web_search_20250305');
            expect(body['thinking']['budget_tokens'], 2048);
            return http.Response(
              jsonEncode({
                'content': [
                  {
                    'type': 'text',
                    'text': 'answer',
                    'citations': [
                      {'url': 'https://source.test', 'title': 'Source'},
                    ],
                  },
                ],
              }),
              200,
            );
          }
          if (kind == AiProviderKind.gemini) {
            expect(body['tools'].first['google_search'], {});
            return http.Response(
              jsonEncode({
                'candidates': [
                  {
                    'content': {
                      'parts': [
                        {'text': 'answer'},
                      ],
                    },
                    'groundingMetadata': {
                      'groundingChunks': [
                        {
                          'web': {
                            'uri': 'https://source.test',
                            'title': 'Source',
                          },
                        },
                      ],
                    },
                  },
                ],
              }),
              200,
            );
          }
          if (kind == AiProviderKind.xai) {
            expect(request.url.path, '/v1/responses');
            expect(body['reasoning'], {'effort': 'low'});
            expect(body['input'].first['content'].last['type'], 'input_image');
            return http.Response(
              jsonEncode({
                'output': [
                  {
                    'type': 'message',
                    'content': [
                      {
                        'type': 'output_text',
                        'text': 'answer',
                        'annotations': [
                          {
                            'type': 'url_citation',
                            'url': 'https://source.test',
                            'title': 'Source',
                          },
                        ],
                      },
                    ],
                  },
                ],
              }),
              200,
            );
          }
          expect(
            body['tools'].first['type'],
            kind == AiProviderKind.openRouter
                ? 'openrouter:web_search'
                : 'web_search',
          );
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {
                    'content': 'answer',
                    'annotations': [
                      {'url': 'https://source.test', 'title': 'Source'},
                    ],
                  },
                },
              ],
            }),
            200,
          );
        });
        final result = await LlmTransport(client).generate(
          provider: provider(kind),
          model: kind == AiProviderKind.gemini ? 'gemini-3-pro' : 'm',
          system: 'retain instructions',
          input: 'query',
          webSearch: true,
          effort: ReasoningEffort.low,
          images: [
            {
              'type': 'image_url',
              'image_url': {'url': 'data:image/png;base64,cG5n'},
            },
          ],
        );
        expect(result, contains('https://source.test'));
        client.close();
      },
    );
  }
  for (final kind in [AiProviderKind.moonshot, AiProviderKind.mistral]) {
    test(
      '$kind official REST uses desktop endpoint and actual sources',
      () async {
        final client = MockClient((request) async {
          final body = jsonDecode(request.body);
          expect(
            request.url.path,
            kind == AiProviderKind.moonshot
                ? '/v1/tools/search'
                : '/v1/conversations',
          );
          expect(
            body[kind == AiProviderKind.moonshot ? 'text_query' : 'model'],
            kind == AiProviderKind.moonshot ? 'query' : 'm',
          );
          return http.Response(
            '{"search_results":[{"url":"https://source.test","title":"Source","snippet":"Fact"}]}',
            200,
          );
        });
        expect(
          (await OfficialRestSearch(
            client,
          ).search(provider(kind), 'm', 'query')).single['content'],
          'Fact',
        );
        client.close();
      },
    );
  }
  test(
    'compact wire preserves source text, IDs, TeX and unrelated enum strings',
    () {
      final input = {
        'groups': [
          {
            'kind': 'quote',
            'body': [1, 2],
          },
        ],
        'blocks': [
          {'id': 'body', 'text': 'kind 引用 \\alpha <t-math-0/>', 'alt': 'quote'},
        ],
      };
      final encoded = SemanticWire.encode(input);
      expect(encoded['g'][0]['k'], SemanticWire.enums['quote']);
      expect(encoded['bs'][0]['i'], 'body');
      expect(encoded['bs'][0]['at'], 'quote');
      expect(SemanticWire.decode(encoded), input);
      expect(
        utf8.encode(jsonEncode(encoded)).length,
        lessThan(utf8.encode(jsonEncode(input)).length),
      );
      expect(
        SemanticWire.prompt('groups body `groups` `body`'),
        'groups body `g` `d`',
      );
      expect(
        () => SemanticWire.decode({'groups': [], 'g': []}),
        throwsFormatException,
      );
    },
  );
  test(
    'actual multimodal request and schema use compact fields; response restores them',
    () async {
      final client = OpenAiCompatibleClient(
        client: MockClient((request) async {
          final body = jsonDecode(request.body),
              input = jsonDecode(body['messages'][1]['content'][0]['text']);
          expect(input, {
            'bs': [
              {'i': 'quote', 't': 'source'},
            ],
          });
          expect(body['response_format']['json_schema']['schema']['required'], [
            'g',
          ]);
          expect(
            body['messages'][1]['content'][1]['image_url']['url'],
            'data:image/png;base64,cG5n',
          );
          return reply({
            'g': [
              {
                'k': SemanticWire.enums['quote'],
                'd': [0],
              },
            ],
          });
        }),
      );
      final result = await client.recognizeLayout(
        provider: provider(AiProviderKind.openAi),
        model: 'gpt-5',
        prompt: '`groups`',
        input: {
          'blocks': [
            {'id': 'quote', 'text': 'source'},
          ],
        },
        images: [
          {
            'type': 'image_url',
            'image_url': {'url': 'data:image/png;base64,cG5n'},
          },
        ],
        schema: {
          'type': 'object',
          'properties': {
            'groups': {'type': 'array'},
          },
          'required': ['groups'],
        },
        compact: true,
      );
      expect(result['groups'][0], {
        'kind': 'quote',
        'body': [0],
      });
      client.close();
    },
  );
  test('each search service restores its own endpoint and secret', () async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    var settings = const AssistantSettings().withService(
      SearchService.exa,
      endpoint: 'https://exa.test',
      apiKey: 'exa-secret',
    );
    settings = settings
        .withService(SearchService.brave, apiKey: 'brave-secret')
        .withService(SearchService.exa);
    expect(settings.endpoint, 'https://exa.test');
    expect(settings.searchKey, 'exa-secret');
    await const AssistantSettingsStore().save(settings);
    final loaded = await const AssistantSettingsStore().load();
    expect(loaded.withService(SearchService.brave).searchKey, 'brave-secret');
    expect(jsonEncode(loaded.toJson()), isNot(contains('secret')));
  });
  test(
    'v1 external configuration survives migration and model preparation',
    () async {
      SharedPreferences.setMockInitialValues({
        'assistant_settings_v1': jsonEncode({
          'official_search': false,
          'search_service': 'exa',
          'search_endpoint': 'https://exa.test',
        }),
      });
      FlutterSecureStorage.setMockInitialValues({
        'assistant_search_api_key_v1': 'legacy-secret',
      });
      final loaded = (await const AssistantSettingsStore().load()).prepareModel(
        provider(AiProviderKind.openAi),
        'gpt-5',
      );
      expect(loaded.searchKey, 'legacy-secret');
      expect(loaded.searchMode, SearchMode.external);
      expect(
        loaded
            .prepareModel(provider(AiProviderKind.openAi), 'gpt-4o')
            .resolvedMode(provider(AiProviderKind.openAi), 'gpt-4o'),
        SearchMode.external,
      );
    },
  );
  test('official model matrix and thinking controls match desktop', () {
    for (final kind in [
      AiProviderKind.openAi,
      AiProviderKind.anthropic,
      AiProviderKind.gemini,
      AiProviderKind.xai,
      AiProviderKind.openRouter,
      AiProviderKind.zai,
      AiProviderKind.moonshot,
      AiProviderKind.mistral,
    ]) {
      expect(
        SearchCapabilities.supports(
          provider(kind),
          kind == AiProviderKind.gemini ? 'gemini-3-pro' : 'gpt-5',
        ),
        true,
      );
    }
    expect(
      SearchCapabilities.supports(provider(AiProviderKind.openAi), 'gpt-4o'),
      false,
    );
    expect(
      SearchCapabilities.supports(
        provider(AiProviderKind.gemini),
        'gemini-2.5-pro',
      ),
      false,
    );
    expect(
      SearchCapabilities.supports(provider(AiProviderKind.custom), 'gpt-5'),
      false,
    );
    expect(
      SearchCapabilities.reasoningLevels(provider(AiProviderKind.miniMax), 'm'),
      [ReasoningEffort.defaultLevel],
    );
    expect(
      SearchCapabilities.reasoningLevels(
        provider(AiProviderKind.gemini),
        'gemini-3-pro',
      ),
      isNot(contains(ReasoningEffort.none)),
    );
  });
  for (final status in [401, 403, 429, 500]) {
    test('HTTP $status does not trigger capability fallback', () {
      expect(
        SearchCapabilities.capabilityError(
          status,
          status == 500 ? 'request timed out' : 'web_search unsupported',
        ),
        false,
      );
    });
  }
  test('unsupported search is remembered by model and credentials', () {
    final p = provider(AiProviderKind.xai, 'cache');
    expect(
      SearchCapabilities.capabilityError(400, 'web_search tool not supported'),
      true,
    );
    SearchCapabilities.remember(p, 'm');
    expect(SearchCapabilities.unavailable(p, 'm'), true);
    expect(SearchCapabilities.unavailable(p, 'other'), false);
  });
  test(
    'capability failure retries through only the configured external service',
    () async {
      var searches = 0, plans = 0;
      final assistant = ChatAssistant(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/responses')) {
            return http.Response('{"error":"web_search not supported"}', 400);
          }
          if (request.url.host == 'api.exa.ai') {
            searches++;
            return http.Response(
              '{"results":[{"url":"https://source.test","title":"Evidence","highlights":["fact"]}]}',
              200,
            );
          }
          plans++;
          if (plans == 1) return reply({'action': 'answer', 'answer': 'first'});
          if (plans == 2) {
            return reply({'action': 'search_web', 'query': 'evidence'});
          }
          return reply({'action': 'answer', 'answer': 'verified'});
        }),
      );
      final result = await assistant.answer(
        provider: provider(AiProviderKind.openAi, 'fallback'),
        model: 'gpt-5',
        settings: const AssistantSettings(
          webSearch: true,
          searchService: SearchService.exa,
          searchKey: 'exa-key',
        ),
        history: [
          {'role': 'user', 'content': 'verify'},
        ],
        title: 'book',
        context: '',
      );
      expect(searches, 1);
      expect(result, contains('https://source.test'));
      assistant.cancel();
    },
  );
  test(
    'short translation identities round-trip and missing notes fail; old caches still read',
    () {
      const original = <Inline>[
        TextRun('text', style: TextStyle(keywordSizeScale: 1.2)),
        TextRun('[1]', style: TextStyle(inlineCitation: 1)),
        TextRun('1', style: TextStyle(linkRole: LinkRole.footnoteReference)),
        TextRun('https://example.test', style: TextStyle(website: true)),
        MathInline('x'),
      ];
      final encoded = TranslationMarkupCodec.encode(original);
      expect(encoded, contains('<citation id="1">'));
      expect(encoded, contains('<t-note-0/>'));
      final decoded = TranslationMarkupCodec.decode(
        encoded,
        original,
        language: 'zh',
        requireSizeMarkup: true,
      );
      expect(
        decoded.whereType<TextRun>().map((r) => r.text).join(),
        'text[1]1https://example.test',
      );
      expect(
        () => TranslationMarkupCodec.decode(
          encoded.replaceAll('<t-note-0/>', ''),
          original,
          language: 'zh',
          requireSizeMarkup: true,
        ),
        throwsFormatException,
      );
      expect(
        TranslationMarkupCodec.decode('<torto-math-0/>', [
          const MathInline('x'),
        ], language: 'zh').single,
        isA<MathInline>(),
      );
    },
  );
  for (final text in ['(Émile, 2020, pages 12–14)', '（王小明，2020，页 12）', '［1］']) {
    test(
      'Unicode citation $text',
      () => expect(
        localCitation({'text': text, 'before': '参见：', 'after': ''}),
        true,
      ),
    );
  }
  test('SVG rejects remote, scripted and HTML payloads', () {
    expect(safeAssistantSvg('<svg><rect width="10" height="10"/></svg>'), true);
    for (final svg in [
      '<svg onload="bad()"/>',
      '<svg><script>bad()</script></svg>',
      '<svg><foreignObject/></svg>',
      '<svg><use href="https://bad.test"/></svg>',
    ]) {
      expect(safeAssistantSvg(svg), false);
    }
  });
  testWidgets('answers render Markdown, inline formulas and book references', (
    tester,
  ) async {
    Uri? opened;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AssistantRichText(
            '**Proof** \\(x^2\\) [Page](torto://page?unit=2)',
            onBookReference: (uri) => opened = uri,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(fm.Math), findsOneWidget);
    tester.widget<MarkdownBody>(find.byType(MarkdownBody)).onTapLink!(
      'Page',
      'torto://page?unit=2',
      '',
    );
    expect(opened?.queryParameters['unit'], '2');
  });
  test(
    'PDF tool loop reads text, merges draft and reports partial status',
    () async {
      SharedPreferences.setMockInitialValues({});
      var calls = 0;
      final service = PdfDiscoveryService(
        client: OpenAiCompatibleClient(
          client: MockClient((request) async {
            calls++;
            if (calls == 1) return reply({'action': 'get_text', 'page': 2});
            if (calls == 2) {
              expect(request.body, contains('real text'));
              return reply({
                'action': 'update_draft',
                'title': 'Observed',
                'authors': ['Author'],
                'entries': [],
              });
            }
            return reply({'action': 'finish', 'status': 'partial'});
          }),
        ),
      );
      final result = await service.discover(
        bookId: 'tools',
        pageCount: 3,
        provider: provider(AiProviderKind.custom),
        model: 'm',
        pageImage: (_) async => 'cG5n',
        pageText: (_) async => 'real text',
      );
      expect(result.title, 'Observed');
      expect(result.status, 'partial');
      expect(calls, 3);
      service.cancel();
    },
  );
}
