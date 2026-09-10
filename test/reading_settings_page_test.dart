import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:torto/app/reader/reader_preferences_store.dart';
import 'package:torto/app/settings/reading_settings_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'typesetting page exposes language profiles without expert toggles',
    (tester) async {
      final preferences = await SharedPreferences.getInstance();
      await tester.binding.setSurfaceSize(const Size(412, 915));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        MaterialApp(
          home: ReadingSettingsPage(store: ReaderPreferencesStore(preferences)),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('排版'), findsOneWidget);
      expect(find.text('中日韩书籍'), findsOneWidget);
      expect(find.text('其他语言书籍'), findsOneWidget);
      expect(find.text('字号'), findsOneWidget);
      expect(find.text('最小字号'), findsNothing);
      expect(find.text('光学字号'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
