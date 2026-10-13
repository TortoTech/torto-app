import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:torto/app/reader/chat_page.dart';

void main() {
  for (final dark in [false, true]) {
    testWidgets(
      'embedded chat fits a narrow ${dark ? 'dark' : 'light'} keyboard viewport',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        tester.view.physicalSize = const Size(360, 740);
        tester.view.devicePixelRatio = 1;
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetViewInsets);
        var closed = false;
        await tester.pumpWidget(
          MaterialApp(
            theme: dark ? ThemeData.dark() : ThemeData.light(),
            home: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: SizedBox(
                  height: 220,
                  child: ChatPage(
                    bookId: 'book',
                    title: 'Book',
                    excerpt: 'Current reading',
                    blockId: 'n0',
                    file: 'book.epub',
                    onClose: () => closed = true,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byIcon(Icons.add_photo_alternate_outlined), findsOneWidget);
        await tester.tap(find.byIcon(Icons.close));
        expect(closed, isTrue);
      },
    );
  }
}
