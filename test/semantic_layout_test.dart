import 'package:torto/app/ai/semantic_wire.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:torto/core/ir/ir.dart';
import 'package:torto/core/semantic_layout/semantic_layout.dart';
import 'package:torto/app/ai/ai_models.dart';
import 'package:torto/app/ai/openai_compatible_client.dart';
import 'package:torto/app/ai/semantic_layout_service.dart';

const spine = SpineItemId('chapter');

class TestSource implements BookSource {
  final Section section;
  TestSource(this.section);
  @override
  final book = const Book(
    id: 'book',
    metadata: BookMetadata(title: 'Book'),
    spine: [SpineItem(id: spine, index: 0, href: 'chapter.xhtml')],
  );
  @override
  Future<Section> parseSection(int index) async => section;
  @override
  Future<Uint8List?> resource(String href) async => null;
}

TextBlock paragraphAt(
  int id,
  String text, {
  TextBlockKind kind = TextBlockKind.paragraph,
}) => TextBlock(
  kind: kind,
  nodeId: 'n$id',
  inlines: [TextRun(text)],
  source: SourceRange(
    start: SourceAnchor(spine: spine, node: 'n$id', textOffset: 0),
    end: SourceAnchor(
      spine: spine,
      node: 'n$id',
      textOffset: text.runes.length,
    ),
  ),
);
Section chapter(List<Block> blocks) =>
    Section(id: spine, spineIndex: 0, href: 'chapter.xhtml', blocks: blocks);
Map<String, dynamic> quote({
  String kind = 'quote',
  List<int> body = const [1],
  int attribution = 2,
}) => {
  'kind': kind,
  'body': body,
  'attribution': attribution,
  'alignment': 'center',
};
String flatten(Section s) => s.blocks
    .expand(
      (b) => switch (b) {
        TextBlock b => [b.plainText],
        QuoteBlock b => [
          ...b.body.map((t) => t.plainText),
          if (b.attribution != null) b.attribution!.plainText,
        ],
        FigureBlock b => b.captions.map((t) => t.plainText),
        _ => <String>[],
      },
    )
    .join('|');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'overlay composes in worker, reuses output and clears cleanly',
    () async {
      final original = chapter([
        paragraphAt(0, 'Words'),
        paragraphAt(1, '— Author'),
      ]);
      final overlay = SemanticLayoutBookSource(TestSource(original));
      overlay.annotations[0] = (
        original,
        validateGroups(original, [
          quote(body: [0], attribution: 1),
        ]),
      );
      final first = await overlay.parseSection(0);
      expect(first.blocks.single, isA<QuoteBlock>());
      expect(await overlay.parseSection(0), same(first));
      overlay.annotations.clear();
      expect(await overlay.parseSection(0), same(original));
    },
  );
  test('cancelled requests cannot populate the persistent cache', () async {
    final dir = await Directory.systemTemp.createTemp('torto-layout-cancel');
    addTearDown(() => dir.delete(recursive: true));
    final requested = Completer<void>();
    final response = Completer<http.Response>();
    final client = OpenAiCompatibleClient(
      client: MockClient((request) {
        requested.complete();
        return response.future;
      }),
    );
    final service = SemanticLayoutService(
      const AiProviderConfig(
        id: 'p',
        name: 'P',
        kind: AiProviderKind.openAi,
        baseUrl: 'https://example.test/v1',
        apiKey: 'test',
      ),
      'm',
      client: client,
      cacheDirectory: dir,
    );
    final result = service.recognize(
      chapter([paragraphAt(0, 'Words')]),
      'book',
    );
    final expectation = expectLater(result, throwsStateError);
    await requested.future;
    service.cancel();
    response.complete(
      http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {'content': '{"groups":[]}'},
            },
          ],
        }),
        200,
      ),
    );
    await expectation;
    expect(await dir.list().toList(), isEmpty);
  });
  test(
    'provider failure is not cached as an empty successful chapter',
    () async {
      final dir = await Directory.systemTemp.createTemp('torto-layout-fail');
      addTearDown(() => dir.delete(recursive: true));
      var requests = 0;
      final client = OpenAiCompatibleClient(
        client: MockClient((request) async {
          requests++;
          return http.Response('private provider detail', 503);
        }),
      );
      final service = SemanticLayoutService(
        const AiProviderConfig(
          id: 'p',
          name: 'P',
          kind: AiProviderKind.openAi,
          baseUrl: 'https://example.test/v1',
          apiKey: 'test',
        ),
        'm',
        client: client,
        cacheDirectory: dir,
      );
      addTearDown(service.cancel);
      final section = chapter([paragraphAt(0, 'Words')]);
      await expectLater(service.recognize(section, 'book'), throwsStateError);
      await expectLater(service.recognize(section, 'book'), throwsStateError);
      expect(requests, 2);
      expect(await dir.list().toList(), isEmpty);
    },
  );
  test(
    'settings default off, preserve unavailable selection without fallback',
    () {
      final old = AiSettings.fromJson({
        'providers': [
          {
            'id': 'p',
            'name': 'P',
            'models': ['m'],
          },
        ],
      });
      expect(old.semanticLayout.enabled, false);
      final settings = old.copyWith(
        semanticLayout: const SemanticLayoutSettings(
          enabled: true,
          providerId: 'deleted',
          model: 'gone',
        ),
      );
      final restored = AiSettings.fromJson(settings.toJson());
      expect(restored.semanticLayout.providerId, 'deleted');
      expect(restored.semanticLayout.model, 'gone');
    },
  );
  test(
    'quote composition preserves surrounding text, anchors, original styles',
    () {
      final section = chapter([
        paragraphAt(0, 'Before'),
        paragraphAt(1, 'Quoted words'),
        paragraphAt(2, '— Author'),
        paragraphAt(3, 'After'),
      ]);
      final groups = validateGroups(section, [quote()]);
      expect(groups.length, 1);
      final output = composeSemanticLayout(section, section, groups);
      expect(flatten(output), flatten(section));
      final q = output.blocks[1] as QuoteBlock;
      expect(
        q.body.single.source!.start,
        (section.blocks[1] as TextBlock).source!.start,
      );
      expect(q.body.single.style.semanticAlignment, BlockAlign.center);
      expect(q.body.single.style.authoredAlignment, null);
      expect(output.anchors, same(section.anchors));
    },
  );
  test(
    'reject missing credit, invalid IDs, overlap, rewritten fields and protected blocks',
    () {
      final section = chapter([
        paragraphAt(0, 'Before'),
        paragraphAt(1, 'Quotation'),
        paragraphAt(2, 'I was walking.'),
        paragraphAt(3, 'Heading', kind: TextBlockKind.heading),
      ]);
      expect(
        validateGroups(section, [
          quote(),
          quote(body: [-1]),
          quote(body: [3]),
          {...quote(), 'style': 'red'},
        ]),
        isEmpty,
      );
      final valid = chapter([paragraphAt(0, 'Q'), paragraphAt(1, '— Author')]);
      expect(
        validateGroups(valid, [
          quote(body: [0], attribution: 1),
          quote(body: [0], attribution: 1),
        ]).length,
        1,
      );
    },
  );
  test('preceding introduction remains in place', () {
    final section = chapter([
      paragraphAt(0, 'Jane writes:'),
      paragraphAt(1, 'Quoted words'),
      paragraphAt(2, 'After'),
    ]);
    final output = composeSemanticLayout(
      section,
      section,
      validateGroups(section, [quote(kind: 'quote_before', attribution: 0)]),
    );
    expect(output.blocks.first, same(section.blocks.first));
    expect(output.blocks[1], isA<QuoteBlock>());
    expect(flatten(output), flatten(section));
    expect(introducesQuote('Someone says:'), false);
  });
  test(
    'inline credit splitting preserves Unicode scalar offsets and links',
    () {
      final original = paragraphAt(0, '😀 text — Author');
      final b = copyText(
        original,
        inlines: [
          const TextRun('😀 text ', link: 'chapter.xhtml#x'),
          const TextRun('— Author', style: TextStyle(italic: true)),
        ],
      );
      final pair = splitCredit(b, '— Author')!;
      expect(pair.$1.source!.end.textOffset, 7);
      expect(pair.$2.source!.start.textOffset, 7);
      expect((pair.$1.inlines.first as TextRun).link, 'chapter.xhtml#x');
      expect((pair.$2.inlines.first as TextRun).style.italic, true);
      expect(splitCredit(b, 'Author'), null);
      expect(splitCredit(b, '— Invented'), null);
      final translated = TextBlock(
        nodeId: 'n0@translation',
        inlines: const [TextRun('译文 — Author')],
        source: b.source,
      );
      expect(splitCredit(translated, '— Author'), null);
    },
  );
  test(
    'bilingual companions grouped by source, not translated block indices',
    () {
      final original = chapter([
        paragraphAt(0, 'Before'),
        paragraphAt(1, 'Quote'),
        paragraphAt(2, '— Author'),
      ]);
      final displayed = chapter([
        for (final b in original.blocks.cast<TextBlock>()) ...[
          b,
          copyText(b, inlines: [TextRun('译${b.plainText}')]),
        ],
      ]);
      final output = composeSemanticLayout(
        original,
        displayed,
        validateGroups(original, [quote()]),
      );
      expect(flatten(output), flatten(displayed));
      expect((output.blocks.last as QuoteBlock).body.length, 3);
    },
  );
  test(
    'figures protect already captioned image runs and preserve caption order',
    () {
      final image = ImageBlock(
        href: 'x.png',
        source: paragraphAt(0, '').source,
      );
      final section = chapter([image, paragraphAt(1, 'Figure 1')]);
      final group = {
        'kind': 'figure',
        'images': [0],
        'captions': [1],
      };
      final output = composeSemanticLayout(
        section,
        section,
        validateGroups(section, [group]),
      );
      expect((output.blocks.single as FigureBlock).images.single, same(image));
      final protected = chapter([
        image,
        paragraphAt(1, 'Figure 1', kind: TextBlockKind.caption),
      ]);
      expect(validateGroups(protected, [group]), isEmpty);
    },
  );
  test('existing quote last body attribution is moved without losing text', () {
    final q = QuoteBlock(
      body: [paragraphAt(0, 'Words'), paragraphAt(1, '— Author')],
      source: paragraphAt(0, 'Words').source,
    );
    final section = chapter([q]);
    final group = {
      'kind': 'quote_attribution',
      'quote': 0,
      'attribution': null,
      'body_index': 1,
    };
    final output = composeSemanticLayout(
      section,
      section,
      validateGroups(section, [group]),
    );
    expect(
      (output.blocks.single as QuoteBlock).attribution!.plainText,
      '— Author',
    );
    expect(flatten(output), flatten(section));
  });
  test(
    'service sends strict schema, retries invalid groups, caches complete result',
    () async {
      final dir = await Directory.systemTemp.createTemp('torto-layout-test');
      addTearDown(() => dir.delete(recursive: true));
      var requests = 0;
      const provider = AiProviderConfig(
        id: 'p',
        name: 'P',
        kind: AiProviderKind.openAi,
        baseUrl: 'https://example.test/v1',
        models: ['m'],
        apiKey: 'test',
      );
      final client = OpenAiCompatibleClient(
        client: MockClient((request) async {
          requests++;
          final body = jsonDecode(request.body) as Map;
          expect(body['response_format']['json_schema']['strict'], true);
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {
                    'content': jsonEncode({
                      'groups': requests == 1
                          ? [
                              quote(body: [99], attribution: 100),
                            ]
                          : [
                              quote(body: [0], attribution: 1),
                            ],
                    }),
                  },
                },
              ],
            }),
            200,
          );
        }),
      );
      final service = SemanticLayoutService(
        provider,
        'm',
        client: client,
        cacheDirectory: dir,
      );
      addTearDown(service.cancel);
      final section = chapter([
        paragraphAt(0, 'Words'),
        paragraphAt(1, '— Author'),
      ]);
      expect((await service.recognize(section, 'book')).length, 1);
      expect(requests, 2);
      expect((await service.recognize(section, 'book')).length, 1);
      expect(requests, 2);
    },
  );
  test(
    'numbered headings share one request without an independent review',
    () async {
      final dir = await Directory.systemTemp.createTemp('torto-layout-test');
      addTearDown(() => dir.delete(recursive: true));
      var requests = 0;
      const provider = AiProviderConfig(
        id: 'p',
        name: 'P',
        kind: AiProviderKind.openAi,
        baseUrl: 'https://example.test/v1',
        apiKey: 'test',
      );
      final client = OpenAiCompatibleClient(
        client: MockClient((request) async {
          final body = jsonDecode(request.body);
          final input = SemanticWire.decode(jsonDecode(body['messages'][1]['content']));
          requests++;
          expect(input['review_only'], isNull);
          expect(input['quotes_enabled'], isTrue);
          expect(input['captions_enabled'], isTrue);
          final groups = [
            {'kind': 'section_heading', 'block': 1},
            {'block': 1, 'kind': 'section_heading'},
          ];
          return http.Response(
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
        }),
      );
      final service = SemanticLayoutService(
        provider,
        'm',
        client: client,
        cacheDirectory: dir,
      );
      addTearDown(service.cancel);
      expect(
        await service.recognize(
          chapter([
            paragraphAt(0, 'Before'),
            paragraphAt(1, '1. How reading develops'),
            paragraphAt(2, 'continues'),
          ]),
          'book',
        ),
        hasLength(1),
      );
      expect(requests, 1);
    },
  );
}
