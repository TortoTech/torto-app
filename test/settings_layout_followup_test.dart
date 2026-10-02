import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:torto/l10n/app_localizations.dart';
import 'package:torto/app/settings/translation_settings_page.dart';
import 'package:torto/app/settings/assistant_settings_page.dart';

void main() {
  Future<void> mount(WidgetTester tester, Widget page) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: const [AppLocalizations.delegate],
        home: page,
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('translation model is a heading and expert toggle is last', (
    tester,
  ) async {
    await mount(tester, const TranslationSettingsPage());
    final title = tester.widget<Text>(find.text('Translation model'));
    expect(
      title.style,
      Theme.of(
        tester.element(find.text('Translation model')),
      ).textTheme.titleSmall,
    );
    expect(
      tester.getTopLeft(find.text('Expert translation')).dy,
      greaterThan(
        tester.getTopLeft(find.text('Translate table of contents')).dy,
      ),
    );
    expect(find.textContaining('When translation is enabled'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('web search follows history turns', (tester) async {
    await mount(tester, const AssistantSettingsPage());
    expect(
      tester.getTopLeft(find.text('Web search')).dy,
      greaterThan(tester.getTopLeft(find.text('History turns')).dy),
    );
    expect(tester.takeException(), isNull);
  });
}
