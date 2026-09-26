import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:torto/app/ai/ai_models.dart';
import 'package:torto/app/ai/openai_compatible_client.dart';
import 'package:torto/app/ai/semantic_layout_service.dart';
import 'package:torto/core/ir/ir.dart';
import 'package:torto/core/semantic_layout/semantic_layout.dart';
import 'package:torto/core/translation/translation_book_source.dart';
import 'package:torto/core/translation/translation_models.dart';
import 'core/html_ir_parser_test.dart' show parseSection;

class _Source implements BookSource {
  final Section section;
  _Source(this.section);
  @override
  Book get book => Book(
    id: 'book',
    metadata: const BookMetadata(title: 'Book'),
    spine: [SpineItem(id: section.id, index: 0, href: section.href)],
  );
  @override
  Future<Section> parseSection(int index) async => section;
  @override
  Future<Uint8List?> resource(String href) async => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'one request feeds inline semantics into translation and preserves them after composition',
    () async {
      final root = await Directory.systemTemp.createTemp('torto-p2-pipeline-');
      addTearDown(() => root.delete(recursive: true));
      final raw = parseSection(
        '<p>Value x/2 (Smith, 2020). See example.com.</p>',
        spineIndex: 0,
      );
      var calls = 0;
      final service = SemanticLayoutService(
        const AiProviderConfig(
          id: 'p',
          name: 'P',
          baseUrl: 'https://example.test/v1',
          apiKey: 'test',
        ),
        'm',
        cacheDirectory: root,
        client: OpenAiCompatibleClient(
          client: MockClient((request) async {
            calls++;
            final body = jsonDecode(request.body),
                input = jsonDecode(body['messages'][1]['content']);
            expect(
              body['response_format']['json_schema']['schema']['required'],
              containsAll(['groups', 'citations', 'formulas']),
            );
            expect(input['blocks'][0].containsKey('text'), isFalse);
            expect(
              input['blocks'][0]['math_texts'][0]['text'],
              contains('x/2'),
            );
            return http.Response(
              jsonEncode({
                'choices': [
                  {
                    'message': {
                      'content': jsonEncode({
                        'groups': [],
                        'citations': ['c0_0_0'],
                        'formulas': [
                          {
                            'block': 0,
                            'paragraph': 0,
                            'original': 'x/2',
                            'latex': r'\frac{x}{2}',
                            'before': '',
                            'after': '',
                          },
                        ],
                      }),
                    },
                  },
                ],
              }),
              200,
            );
          }),
        ),
      );
      addTearDown(service.cancel);
      final annotations = <int, (Section, List<SemanticGroup>)>{
        0: (raw, await service.recognize(raw, 'book')),
      };
      expect(annotations[0]!.$2, hasLength(2));
      expect(await service.recognize(raw, 'book'), hasLength(2));
      expect(calls, 1);
      final inputSource = SemanticLayoutBookSource(
        _Source(raw),
        annotations: annotations,
        inlineOnly: true,
      );
      final translation = TranslationBookSource(inputSource)..enabled = true;
      final display = SemanticLayoutBookSource(
        translation,
        annotations: annotations,
      );
      final node = (raw.blocks.single as TextBlock).nodeId;
      final inputs = await translation.untranslatedBlocksForNodes(0, {node});
      expect(inputs.single.text, contains('<torto-math-0/>'));
      expect(inputs.single.text, contains('<torto-protected-0/>'));
      expect(inputs.single.text, contains('<torto-protected-1/>'));
      await translation.storeBatch(0, [
        BlockTranslation(
          blockIndex: 0,
          text:
              '译文 <torto-math-0/> <torto-protected-0/>。链接 <torto-protected-1/>。',
        ),
      ]);
      final result = (await display.parseSection(0)).blocks.single as TextBlock;
      expect(
        result.inlines.whereType<MathInline>().single.latex,
        r'\frac{x}{2}',
      );
      expect(
        result.inlines
            .whereType<TextRun>()
            .where((r) => r.style.inlineCitation == 1)
            .single
            .text,
        '(Smith, 2020)',
      );
      expect(
        result.inlines
            .whereType<TextRun>()
            .where((r) => r.style.website)
            .single
            .link,
        'https://example.com',
      );
      expect(
        (raw.blocks.single as TextBlock).plainText,
        'Value x/2 (Smith, 2020). See example.com.',
      );
      annotations.clear();
      translation.invalidateBlocks(0, {0});
      final restored =
          (await display.parseSection(0)).blocks.single as TextBlock;
      expect(restored.inlines.whereType<MathInline>(), isEmpty);
      expect(restored.plainText, (raw.blocks.single as TextBlock).plainText);
    },
  );
}
