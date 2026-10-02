import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:torto/app/reader/chat_page.dart';
import 'package:torto/app/reader/reader_page.dart';
import 'package:torto/core/layout/layout_engine.dart';
import 'package:torto/core/layout/layout_types.dart';
import 'package:torto/app/settings/assistant_settings_page.dart';
import 'core/html_ir_parser_test.dart' show parseSection;
import 'reader_focus_gesture_test.dart' show FocusController;

Future<void> capture(WidgetTester tester, String name) async {
  final boundary = tester.firstRenderObject<RenderRepaintBoundary>(
    find.byKey(const Key('capture')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('../output/torto-app-071/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(data!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

void main() {
  setUpAll(() async {
    await (FontLoader(
      'Literata',
    )..addFont(rootBundle.load('assets/fonts/Literata-opsz-wght.ttf'))).load();
    await (FontLoader(
      'LXGW WenKai GB Screen',
    )..addFont(rootBundle.load('assets/fonts/LXGWWenKaiGBScreen.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  for (final dark in [false, true]) {
    testWidgets(
      'focus titles retain normal emphasis on a narrow ${dark ? 'dark' : 'light'} screen',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          'reader_focus_mode_v1': true,
          'reader_dark_mode_v1': dark,
        });
        tester.view.physicalSize = const Size(360, 740);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final section = parseSection(
          '<h1>阅读小节</h1><p>这是当前激活的正文段落，标题保持正常显示，不参与激活。</p><p>${'后续正文可以上下滚动阅读。' * 20}</p>',
        );
        final pages = LayoutEngine().paginate(
          section,
          const LayoutViewport(width: 360, height: 740),
          ReaderStyle(
            focusMode: true,
            baseFontSize: 20,
            foreground: dark ? 0xffe6e6e6 : 0xff222222,
          ),
        );
        final controller = FocusController(pages);
        await tester.pumpWidget(
          RepaintBoundary(
            key: const Key('capture'),
            child: MaterialApp(
              theme: (dark ? ThemeData.dark() : ThemeData.light()).copyWith(
                textTheme: (dark ? ThemeData.dark() : ThemeData.light())
                    .textTheme
                    .apply(fontFamily: 'LXGW WenKai GB Screen'),
              ),
              home: ReaderPage(
                file: File('focus.epub'),
                controller: controller,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(controller.currentPages, hasLength(1));
        expect(tester.takeException(), isNull);
        await capture(tester, dark ? 'focus-dark' : 'focus-light');
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
        for (final page in pages) {
          page.dispose();
        }
      },
    );
  }
  testWidgets(
    'chat citations are selectable links and settings fit narrow screens',
    (tester) async {
      final key =
          'assistant_chat_v1_${sha256.convert(utf8.encode(jsonEncode(['book', 'n1'])))}';
      SharedPreferences.setMockInitialValues({
        key: jsonEncode([
          {'role': 'user', 'content': '这段内容是什么意思？'},
          {
            'role': 'assistant',
            'content': '可以结合上下文理解这一观点。\n[相关资料](https://example.test/source)',
          },
        ]),
      });
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        RepaintBoundary(
          key: const Key('capture'),
          child: MaterialApp(
            theme: ThemeData.dark().copyWith(
              textTheme: ThemeData.dark().textTheme.apply(
                fontFamily: 'LXGW WenKai GB Screen',
              ),
            ),
            home: const ChatPage(
              bookId: 'book',
              title: '阅读示例',
              excerpt: '当前正文',
              blockId: 'n1',
              file: 'book.epub',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AssistantText), findsNWidgets(2));
      expect(tester.takeException(), isNull);
      await capture(tester, 'chat-dark');
      await tester.pumpWidget(
        RepaintBoundary(
          key: const Key('capture'),
          child: MaterialApp(
            theme: ThemeData(fontFamily: 'LXGW WenKai GB Screen'),
            home: const AssistantSettingsPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await capture(tester, 'assistant-settings-light');
      await tester.pumpWidget(const SizedBox());
    },
  );
}
