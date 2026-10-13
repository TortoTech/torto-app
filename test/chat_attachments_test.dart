import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:torto/app/ai/chat_attachments.dart';
import 'package:torto/app/ai/chat_assistant.dart';
import 'package:torto/app/ai/assistant_settings.dart';
import 'ai_071_sync_test.dart' show provider, answer;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late dynamic png;
  setUp(() async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawRect(
      const ui.Rect.fromLTWH(0, 0, 8, 8),
      ui.Paint()..color = const ui.Color(0xff2468aa),
    );
    final picture = recorder.endRecording(),
        image = await picture.toImage(8, 8);
    try {
      final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      png = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } finally {
      picture.dispose();
      image.dispose();
    }
  });
  test(
    'normalized image history persists hashes and can replay multimodal evidence',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'chat-attachment-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final store = ChatAttachments(directory);
      final saved = await store.save(png, '图片.png');
      expect(
        await store.save(png, 'again.png'),
        containsPair('hash', saved['hash']),
      );
      final messages = <Map<String, String>>[
        {
          'role': 'user',
          'content': '',
          'attachments': jsonEncode([saved]),
        },
      ];
      final loaded = ChatAttachments.decode(
        jsonDecode(jsonEncode(messages))[0]['attachments'],
      );
      expect(loaded.single['name'], '图片.png');
      final images = await store.evidence(messages);
      expect(
        images.single['image_url']['url'],
        startsWith('data:image/png;base64,'),
      );
      expect(messages.single['image_labels'], contains('turn 0'));
      expect(messages.single.containsKey('attachments'), isFalse);
      await File(
        '${directory.path}/${saved['hash']}.png',
      ).writeAsString('corrupt');
      await expectLater(store.read(saved), throwsFormatException);
    },
  );
  test(
    'old images stay in history while each request prioritizes eight latest images',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'chat-budget-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final store = ChatAttachments(directory),
          saved = await store.save(png, 'image.png');
      final messages = [
        for (var i = 0; i < 9; i++)
          {
            'role': 'user',
            'content': '$i',
            'attachments': jsonEncode([saved]),
          },
      ];
      final images = await store.evidence(messages);
      expect(images, hasLength(8));
      expect(messages.last['image_labels'], contains('image 1: turn 8'));
      expect(
        messages.first['image_labels'],
        contains('omitted from this request'),
      );
    },
  );
  test('attachment path traversal is rejected before disk access', () async {
    final store = ChatAttachments(Directory.systemTemp);
    await expectLater(
      store.read({'hash': '../outside'}),
      throwsFormatException,
    );
  });
  test(
    'images survive assistant tool rounds and progress contains tool names',
    () async {
      var calls = 0;
      final progress = <String>[];
      final assistant = ChatAssistant(
        client: MockClient((request) async {
          final body = jsonDecode(request.body),
              content = body['messages'][1]['content'] as List;
          expect(content.where((c) => c['type'] == 'image_url'), hasLength(1));
          return ++calls == 1
              ? answer({
                  'action': 'getCurrentContext',
                  'query': '',
                  'answer': '',
                  'arguments': '{}',
                })
              : answer({
                  'action': 'answer',
                  'query': '',
                  'answer': 'I can see the attached image.',
                });
        }),
      );
      addTearDown(assistant.cancel);
      final result = await assistant.answer(
        provider: provider,
        model: 'vision',
        settings: const AssistantSettings(),
        history: [
          {
            'role': 'user',
            'content': 'Explain the image',
            'image_labels': '[image 1: turn 0]',
          },
        ],
        title: 'Book',
        context: '',
        images: [
          {
            'type': 'image_url',
            'image_url': {'url': 'data:image/png;base64,${base64Encode(png)}'},
          },
        ],
        onToolProgress: progress.add,
        bookTool: (_, _) async => {'text': 'Context'},
      );
      expect(result, contains('attached image'));
      expect(calls, 2);
      expect(progress, ['→ getCurrentContext', '✓ getCurrentContext']);
    },
  );
}
