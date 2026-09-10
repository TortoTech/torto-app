import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:torto/app/reader/reader_preferences_store.dart';
import 'package:torto/core/ir/ir.dart';
import 'package:torto/core/layout/layout_types.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('discovered system font selections survive reload', () async {
    final store = ReaderPreferencesStore(await SharedPreferences.getInstance());
    const value = ReaderTypography(
      otherPrimaryFont: ReaderLatinFont.system('oem-sans'),
      cjkPrimaryFont: ReaderCjkFont.system('NotoSansCJK-Regular'),
    );
    await store.saveTypography(value);
    expect(await store.loadTypography(), value);
  });

  test(
    'typesetting defaults to unified and persists follow-book mode',
    () async {
      final preferences = await SharedPreferences.getInstance();
      final store = ReaderPreferencesStore(preferences);

      expect(await store.loadTypesettingMode(), TypesettingMode.unified);
      await store.saveTypesettingMode(TypesettingMode.book);

      final reloaded = ReaderPreferencesStore(preferences);
      expect(await reloaded.loadTypesettingMode(), TypesettingMode.book);
    },
  );

  test('reading typography defaults to bundled Literata and LXGW', () async {
    final store = ReaderPreferencesStore(await SharedPreferences.getInstance());

    expect(
      await store.loadTypography(),
      const ReaderTypography(
        cjkPrimaryFont: ReaderCjkFont.lxgwWenKai,
        otherPrimaryFont: ReaderLatinFont.literata,
        fontSize: 20,
        fontWeight: 400,
      ),
    );
  });

  test('reading typography persists every configurable field', () async {
    final preferences = await SharedPreferences.getInstance();
    final store = ReaderPreferencesStore(preferences);
    const typography = ReaderTypography(
      cjkPrimaryFont: ReaderCjkFont.systemSerif,
      cjkLatinFont: ReaderLatinFont.systemSansSerif,
      otherPrimaryFont: ReaderLatinFont.systemSerif,
      otherCjkFont: ReaderCjkFont.systemSansSerif,
      fontSize: 24,
      fontWeight: 550,
    );

    await store.saveTypography(typography);

    expect(
      await ReaderPreferencesStore(preferences).loadTypography(),
      typography,
    );
  });

  test('language profiles inherit their companion fonts by default', () {
    const typography = ReaderTypography(
      cjkPrimaryFont: ReaderCjkFont.systemSerif,
      otherPrimaryFont: ReaderLatinFont.systemSansSerif,
    );

    expect(
      typography.latinFontFor(WritingSystem.cjk),
      ReaderLatinFont.systemSansSerif,
    );
    expect(typography.cjkFontFor(WritingSystem.cjk), ReaderCjkFont.systemSerif);
    expect(
      typography.latinFontFor(WritingSystem.latin),
      ReaderLatinFont.systemSansSerif,
    );
    expect(
      typography.cjkFontFor(WritingSystem.other),
      ReaderCjkFont.systemSerif,
    );
  });

  test('legacy global font choices migrate into the two profiles', () async {
    SharedPreferences.setMockInitialValues({
      'reader_latin_font_v1': ReaderLatinFont.systemSansSerif.name,
      'reader_cjk_font_v1': ReaderCjkFont.systemSerif.name,
    });
    final store = ReaderPreferencesStore(await SharedPreferences.getInstance());

    final typography = await store.loadTypography();

    expect(typography.otherPrimaryFont, ReaderLatinFont.systemSansSerif);
    expect(typography.cjkPrimaryFont, ReaderCjkFont.systemSerif);
    expect(typography.cjkLatinFont, isNull);
    expect(typography.otherCjkFont, isNull);
  });
}
