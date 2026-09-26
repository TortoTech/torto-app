import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:torto/app/ai/ai_models.dart';
import 'package:torto/app/ai/formula_image_service.dart';
import 'package:torto/app/ai/openai_compatible_client.dart';
import 'package:torto/core/ir/ir.dart';
import 'package:torto/core/semantic_layout/image_formulas.dart';

const provider = AiProviderConfig(
  id: 'p',
  name: 'P',
  baseUrl: 'https://example.test/v1',
  apiKey: 'test',
);
http.Response response(List<Map<String, dynamic>> results) => http.Response(
  jsonEncode({
    'choices': [
      {
        'message': {
          'content': jsonEncode({'results': results}),
        },
      },
    ],
  }),
  200,
);
Future<Uint8List> png(int color) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    const ui.Rect.fromLTWH(0, 0, 8, 4),
    ui.Paint()..color = ui.Color(color),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(8, 4);
  final bytes = (await image.toByteData(
    format: ui.ImageByteFormat.png,
  ))!.buffer.asUint8List();
  image.dispose();
  picture.dispose();
  return bytes;
}

Section section(List<Block> blocks) => Section(
  id: const SpineItemId('s'),
  spineIndex: 0,
  href: 's.xhtml',
  blocks: blocks,
);
Map<String, dynamic> item(
  Object id, {
  String status = 'recognized',
  String latex = r'\frac{x}{2}',
}) => {
  'image_id': id,
  'status': status,
  'latex': status == 'recognized' ? latex : null,
  'equation_number': null,
};
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'vision batches cap at five and matching ignores response order',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'torto-formula-batches-',
      );
      addTearDown(() => root.delete(recursive: true));
      final resources = {
        for (var i = 0; i < 6; i++)
          'i$i.png': await png(0xff000000 + i * 0x00202020),
      };
      final source = section([
        for (final href in resources.keys) ImageBlock(href: href),
      ]);
      final counts = <int>[];
      final client = OpenAiCompatibleClient(
        client: MockClient((request) async {
          final body = jsonDecode(request.body),
              content = body['messages'][1]['content'] as List;
          final input = jsonDecode(content.first['text']);
          final images = input['images'] as List;
          counts.add(images.length);
          expect(
            content.where((c) => c['type'] == 'image_url').length,
            images.length,
          );
          return response([
            for (final i in images.reversed) item(i['image_id']),
          ]);
        }),
      );
      addTearDown(client.close);
      final result = await recognizeFormulaImages(
        section: source,
        start: 0,
        end: 6,
        provider: provider,
        model: 'm',
        effort: ReasoningEffort.low,
        client: client,
        cache: root,
        resource: (href) async => resources[href],
        check: () {},
      );
      expect(counts, [5, 1]);
      expect(result, hasLength(6));
      await recognizeFormulaImages(
        section: source,
        start: 0,
        end: 6,
        provider: provider,
        model: 'm',
        effort: ReasoningEffort.low,
        client: client,
        cache: root,
        resource: (href) async => resources[href],
        check: () {},
      );
      expect(counts, [5, 1]);
      final rendered = composeImageAnnotations(source, result);
      expect(
        rendered.blocks.cast<ImageBlock>().every(
          (image) => image.formula?.latex == r'\frac{x}{2}',
        ),
        isTrue,
      );
      expect(
        rendered.blocks.cast<ImageBlock>().map((image) => image.href),
        resources.keys,
      );
    },
  );
  test(
    'equal bytes deduplicate and negative classification is cached',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'torto-formula-negative-',
      );
      addTearDown(() => root.delete(recursive: true));
      final bytes = await png(0xff112233),
          source = section([
            const ImageBlock(href: 'a.png'),
            const ImageBlock(href: 'b.png'),
          ]);
      var calls = 0;
      final client = OpenAiCompatibleClient(
        client: MockClient((request) async {
          calls++;
          final body = jsonDecode(request.body);
          final images =
              jsonDecode(body['messages'][1]['content'][0]['text'])['images']
                  as List;
          expect(images, hasLength(1));
          return response([
            item(images.single['image_id'], status: 'not_formula', latex: ''),
          ]);
        }),
      );
      addTearDown(client.close);
      for (var i = 0; i < 2; i++) {
        expect(
          await recognizeFormulaImages(
            section: source,
            start: 0,
            end: 2,
            provider: provider,
            model: 'm',
            effort: ReasoningEffort.defaultLevel,
            client: client,
            cache: root,
            resource: (_) async => bytes,
            check: () {},
          ),
          isEmpty,
        );
      }
      expect(calls, 1);
    },
  );
  test(
    'only locally invalid transcriptions enter conditional review',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'torto-formula-review-',
      );
      addTearDown(() => root.delete(recursive: true));
      final resources = {
        'a.png': await png(0xff112233),
        'b.png': await png(0xff223344),
      };
      final source = section([
        for (final href in resources.keys) ImageBlock(href: href),
      ]);
      var calls = 0;
      int? failed;
      final client = OpenAiCompatibleClient(
        client: MockClient((request) async {
          calls++;
          final body = jsonDecode(request.body);
          final images =
              jsonDecode(body['messages'][1]['content'][0]['text'])['images']
                  as List;
          if (calls == 1) {
            failed = images.last['image_id'];
            return response([
              item(images.first['image_id']),
              item(failed!, latex: r'\unknown{x}'),
            ]);
          }
          expect(images, hasLength(1));
          expect(images.single['image_id'], failed);
          expect(images.single['local_validation_error'], isNotNull);
          return response([item(failed!, latex: 'x^2')]);
        }),
      );
      addTearDown(client.close);
      final results = await recognizeFormulaImages(
        section: source,
        start: 0,
        end: 2,
        provider: provider,
        model: 'm',
        effort: ReasoningEffort.defaultLevel,
        client: client,
        cache: root,
        resource: (href) async => resources[href],
        check: () {},
      );
      expect(calls, 2);
      expect(
        results.map((g) => g['latex']),
        containsAll([r'\frac{x}{2}', 'x^2']),
      );
    },
  );
  test('failed review retains originals and remains retryable', () async {
    final root = await Directory.systemTemp.createTemp('torto-formula-failed-');
    addTearDown(() => root.delete(recursive: true));
    final bytes = await png(0xff123456),
        source = section([const ImageBlock(href: 'x.png')]);
    var calls = 0;
    final client = OpenAiCompatibleClient(
      client: MockClient((request) async {
        calls++;
        final body = jsonDecode(request.body);
        final images =
            jsonDecode(body['messages'][1]['content'][0]['text'])['images']
                as List;
        return response([
          item(images.single['image_id'], latex: r'\unknown{x}'),
        ]);
      }),
    );
    addTearDown(client.close);
    for (var i = 0; i < 2; i++) {
      final groups = await recognizeFormulaImages(
        section: source,
        start: 0,
        end: 1,
        provider: provider,
        model: 'm',
        effort: ReasoningEffort.defaultLevel,
        client: client,
        cache: root,
        resource: (_) async => bytes,
        check: () {},
      );
      expect(groups.single['latex'], '');
      expect(
        (composeImageAnnotations(source, groups).blocks.single as ImageBlock)
            .formula,
        isNull,
      );
    }
    expect(calls, 4);
    expect(await root.list().length, 0);
  });
  test('cancelled image replies cannot publish disk cache', () async {
    final root = await Directory.systemTemp.createTemp('torto-formula-cancel-');
    addTearDown(() => root.delete(recursive: true));
    final bytes = await png(0xff112233),
        requested = Completer<int>(),
        reply = Completer<http.Response>();
    var cancelled = false;
    final client = OpenAiCompatibleClient(
      client: MockClient((request) {
        final body = jsonDecode(request.body);
        requested.complete(
          jsonDecode(
            body['messages'][1]['content'][0]['text'],
          )['images'][0]['image_id'],
        );
        return reply.future;
      }),
    );
    addTearDown(client.close);
    final future = recognizeFormulaImages(
      section: section([const ImageBlock(href: 'a.png')]),
      start: 0,
      end: 1,
      provider: provider,
      model: 'm',
      effort: ReasoningEffort.defaultLevel,
      client: client,
      cache: root,
      resource: (_) async => bytes,
      check: () {
        if (cancelled) throw StateError('cancelled');
      },
    );
    final expectation = expectLater(future, throwsStateError);
    final id = await requested.future;
    cancelled = true;
    reply.complete(response([item(id)]));
    await expectation;
    expect(await root.list().length, 0);
  });
}
