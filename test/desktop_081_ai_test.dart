import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:torto/app/ai/ai_models.dart';
import 'package:torto/app/ai/assistant_settings.dart';
import 'package:torto/app/ai/formula_image_service.dart';
import 'package:torto/app/ai/llm_transport.dart';
import 'package:torto/app/ai/openai_compatible_client.dart';
import 'package:torto/app/ai/pdf_discovery_service.dart';
import 'package:torto/app/ai/semantic_wire.dart';
import 'package:torto/core/ir/ir.dart';
import 'package:torto/core/semantic_layout/image_formulas.dart';
import 'package:torto/core/semantic_layout/semantic_layout.dart';
import 'package:torto/core/translation/translation_markup.dart';
import 'formula_image_service_test.dart' show png, section, provider;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'compact instructions describe only supplied inputs and leave literal text intact',
    () {
      final prompt = SemanticWire.instructions('Read original images.', [
        {
          'requested_ids': [0],
          'images': [
            {'image_id': 0, 'context': 'groups literal words'},
          ],
        },
      ]);
      expect(prompt, contains('ii=image_id'));
      expect(prompt, isNot(contains('g=groups')));
      expect(prompt, isNot(contains('ok=recognized')));
      expect(
        SemanticWire.decode(
          SemanticWire.encode({'context': 'groups literal words'}),
        ),
        {'context': 'groups literal words'},
      );
    },
  );

  test(
    'text-only image recognition keeps Unicode and literal examples with cache reuse',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'torto-image-text-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final bytes = await png(0xff556677);
      var calls = 0;
      final client = OpenAiCompatibleClient(
        client: MockClient((request) async {
          calls++;
          final body = jsonDecode(request.body),
              input = SemanticWire.decode(
                jsonDecode(body['messages'][1]['content'][0]['text']),
              );
          final results = [
            {
              'image_id': input['images'][0]['image_id'],
              'status': 'recognized_text',
              'latex': null,
              'equation_number': null,
              'text': 'かな é',
              'literal': true,
            },
          ];
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'choices': [
                  {
                    'message': {
                      'content': jsonEncode({'results': results}),
                    },
                  },
                ],
              }),
            ),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      addTearDown(client.close);
      final original = section([const ImageBlock(href: 'x.png')]);
      for (var i = 0; i < 2; i++) {
        final groups = await recognizeFormulaImages(
          section: original,
          start: 0,
          end: 1,
          provider: provider,
          model: 'm',
          effort: ReasoningEffort.none,
          client: client,
          cache: directory,
          resource: (_) async => bytes,
          check: () {},
        );
        expect(validateGroups(original, groups), hasLength(1));
        final image =
            composeImageAnnotations(original, groups).blocks.single
                as ImageBlock;
        expect(image.ocrText?.text, 'かな é');
        expect(image.ocrText?.literal, isTrue);
        expect(image.href, 'x.png');
      }
      expect(calls, 1);
    },
  );

  test(
    'paired image translation preserves character examples and source image identity',
    () {
      const literal = InlineImageRun(
        image: ImageBlock(
          href: 'kana.png',
          ocrText: ImageText('かな', literal: true),
        ),
        sizeScale: 1,
      );
      const words = InlineImageRun(
        image: ImageBlock(href: 'word.png', ocrText: ImageText('Hello')),
        sizeScale: 1,
      );
      final source = [literal, words];
      expect(
        TranslationMarkupCodec.encode(source),
        '<t-img-0 keep="1">かな</t-img-0><t-img-1>Hello</t-img-1>',
      );
      final result = TranslationMarkupCodec.decode(
        '<t-img-1>你好</t-img-1><t-img-0 keep="1">かな</t-img-0>',
        source,
        language: 'zh',
        requireSizeMarkup: true,
      ).cast<InlineImageRun>();
      expect(result.first.image.href, 'word.png');
      expect(result.first.image.ocrText?.displayText, '你好');
      expect(result.last.image.ocrText?.displayText, 'かな');
      final alias = TranslationMarkupCodec.decode(
        '<t-image-0 keep="1">かな</t-image-0><torto-image-1>Hello</torto-image-1>',
        source,
        language: 'en',
        requireSizeMarkup: true,
      ).cast<InlineImageRun>();
      expect(alias.last.image.ocrText?.displayText, 'Hello');
      expect(
        () => TranslationMarkupCodec.decode(
          '<t-img-0 keep="1">カナ</t-img-0><t-img-1>你好</t-img-1>',
          source,
          language: 'zh',
          requireSizeMarkup: true,
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'PDF effort is independent and transient retries preserve the selected request',
    () async {
      final settings = AssistantSettings(
        reasoningEffort: ReasoningEffort.low,
        pdfReasoningEffort: ReasoningEffort.high,
      );
      final restored = AssistantSettings.fromJson(settings.toJson());
      expect(restored.reasoningEffort, ReasoningEffort.low);
      expect(restored.pdfReasoningEffort, ReasoningEffort.high);
      var calls = 0;
      final client = OpenAiCompatibleClient(
        client: MockClient((request) async {
          calls++;
          final body = jsonDecode(request.body);
          expect(body['reasoning_effort'], 'high');
          if (calls == 1) return http.Response('temporary', 503);
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {
                    'content': jsonEncode({
                      'action': 'finish',
                      'status': 'complete',
                      'title': 'Recovered',
                      'authors': [],
                      'entries': [],
                      'special_pages': [],
                    }),
                  },
                },
              ],
            }),
            200,
          );
        }),
      );
      addTearDown(client.close);
      final service = PdfDiscoveryService(
        client: client,
        retryDelay: Duration.zero,
      );
      final bytes = await png(0xff112233);
      final result = await service.discover(
        bookId: 'book',
        pageCount: 1,
        provider: const AiProviderConfig(
          id: 'p',
          name: 'P',
          kind: AiProviderKind.openAi,
          baseUrl: 'https://example.test/v1',
          apiKey: 'test',
        ),
        model: 'gpt-5',
        reasoningEffort: restored.pdfReasoningEffort,
        goals: {'metadata'},
        pageImage: (_) async => base64Encode(bytes),
      );
      expect(result.title, 'Recovered');
      expect(calls, 2);
    },
  );

  test('PDF authentication failures do not trigger retry', () async {
    var calls = 0;
    final client = OpenAiCompatibleClient(
      client: MockClient((request) async {
        calls++;
        return http.Response('Unauthorized', 401);
      }),
    );
    addTearDown(client.close);
    final service = PdfDiscoveryService(
      client: client,
      retryDelay: Duration.zero,
    );
    final bytes = await png(0xff112233);
    await expectLater(
      service.discover(
        bookId: 'book',
        pageCount: 1,
        provider: provider,
        model: 'm',
        goals: {'metadata'},
        pageImage: (_) async => base64Encode(bytes),
      ),
      throwsA(isA<LlmHttpException>()),
    );
    expect(calls, 1);
  });
}
