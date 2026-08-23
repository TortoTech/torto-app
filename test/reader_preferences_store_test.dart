import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:torto/app/reader/reader_preferences_store.dart';
import 'package:torto/core/layout/layout_types.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

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
}
