import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:torto/app/ai/ai_models.dart';
import 'package:torto/app/ai/openai_compatible_client.dart';
import 'package:torto/app/ai/semantic_layout_service.dart';
import 'package:torto/core/ir/ir.dart'
    show TextBlock, TextBlockKind, QuoteBlock;
import 'package:torto/app/ai/formula_image_payload.dart';
import 'package:torto/app/ai/formula_image_contract.dart';
import 'package:torto/core/formats/epub_book_source.dart';
import 'package:torto/core/semantic_layout/image_formulas.dart';
import 'package:torto/core/semantic_layout/batching.dart';
import 'package:torto/core/semantic_layout/inline_semantics.dart';
import 'core/html_ir_parser_test.dart' show parseSection;
import 'semantic_layout_test.dart' show paragraphAt, chapter;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'standalone credits retain their source text when no math container is available',
    () async {
      final cache = await Directory.systemTemp.createTemp(
        'torto-credit-contract-',
      );
      addTearDown(() => cache.delete(recursive: true));
      final quoted = paragraphAt(0, 'Quoted words');
      final section = chapter([
        QuoteBlock(body: [quoted], source: quoted.source),
        paragraphAt(1, '— Author', kind: TextBlockKind.quoteAttribution),
      ]);
      final service = SemanticLayoutService(
        const AiProviderConfig(
          id: 'test',
          name: 'test',
          baseUrl: 'https://example.test/v1',
          apiKey: 'test',
        ),
        'test',
        cacheDirectory: cache,
        client: OpenAiCompatibleClient(
          client: MockClient((request) async {
            final body = jsonDecode(request.body),
                input = jsonDecode(body['messages'][1]['content']);
            expect(input['blocks'][1]['text'], '— Author');
            expect(input['blocks'][1]['math_texts'], isEmpty);
            return http.Response(
              jsonEncode({
                'choices': [
                  {
                    'message': {
                      'content': jsonEncode({
                        'groups': [
                          {
                            'kind': 'quote_attribution',
                            'quote': 0,
                            'attribution': 1,
                            'body_index': null,
                          },
                        ],
                        'citations': [],
                        'formulas': [],
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
      expect(await service.recognize(section, 'book'), hasLength(1));
    },
  );
  test(
    'GIF first frame becomes lossless PNG without modifying source bytes',
    () async {
      final frame = img.Image(width: 8, height: 4, numChannels: 4);
      for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 8; x++) {
          frame.setPixelRgba(
            x,
            y,
            x < 4 ? 255 : 0,
            y < 2 ? 255 : 0,
            0,
            x == 7 ? 0 : 255,
          );
        }
      }
      final bytes = img.encodeGif(frame),
          original = Uint8List.fromList(img.encodeGif(frame));
      final source = img.GifDecoder(bytes).decodeFrame(0)!;
      final payload = await prepareFormulaImagePayload(bytes);
      expect(payload, isNotNull);
      expect(payload!.mime, 'image/png');
      expect(payload.converted, isTrue);
      final decoded = img.decodePng(payload.bytes)!;
      expect((decoded.width, decoded.height), (source.width, source.height));
      for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 8; x++) {
          final a = source.getPixel(x, y), b = decoded.getPixel(x, y);
          expect([b.r, b.g, b.b, b.a], [a.r, a.g, a.b, a.a]);
        }
      }
      expect(bytes, original);
      expect(
        await prepareFormulaImagePayload(
          Uint8List.fromList(ascii.encode('GIF89a')),
        ),
        isNull,
      );
    },
  );
  test(
    'desktop prompt is compact and unused roles are removed per batch',
    () async {
      final full = await rootBundle.loadString('assets/ai/semantic_layout.md');
      expect(utf8.encode(full).length, lessThan(7000));
      expect(full, isNot(contains('## Examples')));
      final input = {
        'targets': {
          'classify_headings': <int>[],
          'classify_blocks': [0],
          'complete_quote_sources': <int>[],
          'classify_citations': <String>[],
        },
        'blocks': [
          {'id': 0, 'type': 'paragraph'},
        ],
      };
      final prompt = semanticWindowPrompt(full, input);
      expect(prompt, contains('## Quotations'));
      expect(prompt, contains('## Text formulas'));
      expect(prompt, isNot(contains('## Headings')));
      expect(prompt, isNot(contains('## Captions')));
      expect(prompt, isNot(contains('## Inline citations')));
      expect(prompt.length, lessThan(full.length));
      final images = await formulaImagePrompts();
      expect(images.transcribe, contains('## Transcription self-check'));
      expect(images.transcribe, isNot(contains('## Conditional review')));
      expect(images.verify, contains('## Conditional review'));
      expect(images.verify, isNot(contains('## Transcription self-check')));
    },
  );
  test(
    'desktop schemas describe exact spans nullable negatives and short typed IDs',
    () {
      final schema = semanticSchema({
        'quote',
        'quote_before',
        'quote_inline',
        'quote_attribution',
        'figure',
        'section_heading',
      });
      expect(schema['properties']['citations']['items']['type'], 'string');
      expect(
        schema['properties']['formulas']['items']['properties']['original']['minLength'],
        1,
      );
      expect(
        schema['properties']['formulas']['items']['properties']['latex']['description'],
        contains('backslash'),
      );
      final item = formulaImageSchema['properties']! as Map;
      expect(
        item['results']['items']['properties']['image_id']['type'],
        'integer',
      );
      expect(item['results']['items']['properties']['latex']['type'], [
        'string',
        'null',
      ]);
    },
  );
  test(
    'desktop protected markers and entity boundaries preserve exact source offsets',
    () {
      final section = parseSection(
        '<p>a &lt; b &amp; c <a href="notes.xhtml">protected</a></p>',
      );
      final text = mathText(section.blocks.first as TextBlock);
      expect(text.text, contains('a &lt; b &amp; c'));
      expect(text.text, contains('<protected/>'));
      final groups = resolveInlineProposals(
        section,
        [],
        [
          {'block': 0, 'paragraph': 0, 'original': 'a &lt; b', 'latex': 'a<b'},
        ],
        0,
        1,
      );
      expect(groups.single['text'], 'a < b');
      expect(groups.single['end'], 5);
    },
  );
  final path = Platform.environment['TORTO_HEARING_BOOK'];
  test(
    'current hearing-book equation 2.5 is a GIF candidate and enters the vision payload',
    () async {
      final source = await EpubBookSource.fromBytes(
        await File(path!).readAsBytes(),
      );
      addTearDown(source.dispose);
      final index = source.book.spine.indexWhere(
        (s) => s.href.endsWith('/ch02.html'),
      );
      expect(index, greaterThanOrEqualTo(0));
      final section = await source.parseSection(index);
      final candidate = formulaImageCandidates(
        section,
        0,
        section.blocks.length,
      ).singleWhere((c) => c.$2.href.endsWith('/f0044-01.gif'));
      final raw = (await source.resource(candidate.$2.href))!;
      expect(String.fromCharCodes(raw.take(3)), 'GIF');
      final prepared = await prepareFormulaImagePayload(raw);
      expect(prepared, isNotNull);
      expect(prepared!.mime, 'image/png');
      final batch = semanticBatches(
        section,
      ).singleWhere((b) => b.contains(candidate.$1));
      final output = Platform.environment['TORTO_FORMULA_EVIDENCE'];
      final cache = await Directory.systemTemp.createTemp(
        'torto-hearing-contract-',
      );
      addTearDown(() => cache.delete(recursive: true));
      final metrics = <String, dynamic>{};
      final service = SemanticLayoutService(
        const AiProviderConfig(
          id: 'test',
          name: 'test',
          baseUrl: 'https://example.test/v1',
          apiKey: 'test',
        ),
        'test',
        cacheDirectory: cache,
        client: OpenAiCompatibleClient(
          client: MockClient((request) async {
            final body = jsonDecode(request.body);
            final prompt = body['messages'][0]['content'] as String;
            final input = jsonDecode(body['messages'][1]['content']);
            metrics.addAll({
              'system_prompt_chars': prompt.length,
              'user_input_chars':
                  (body['messages'][1]['content'] as String).length,
              'schema_chars': jsonEncode(
                body['response_format']['json_schema']['schema'],
              ).length,
              'heading_targets': input['targets']['classify_headings'].length,
              'citation_targets': input['targets']['classify_citations'].length,
            });
            expect(input.containsKey('math_texts'), isFalse);
            return http.Response(
              jsonEncode({
                'choices': [
                  {
                    'message': {
                      'content': '{"groups":[],"citations":[],"formulas":[]}',
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
      await service.recognize(
        section,
        source.book.id.toString(),
        batches: [batch],
      );
      if (output != null) {
        await Directory(output).create(recursive: true);
        await File('$output/equation-2.5.png').writeAsBytes(prepared.bytes);
        await File('$output/book-repro.json').writeAsString(
          jsonEncode({
            ...metrics,
            'section': index,
            'href': section.href,
            'image': candidate.$2.href,
            'block': candidate.$1,
            'batch_start': batch.start,
            'batch_end': batch.end,
            'source_bytes': raw.length,
            'payload_bytes': prepared.bytes.length,
          }),
        );
      }
    },
    skip: path == null
        ? 'Set TORTO_HEARING_BOOK to the local user-provided EPUB'
        : false,
  );
}
