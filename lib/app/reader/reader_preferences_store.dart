import 'package:shared_preferences/shared_preferences.dart';

import '../../core/layout/layout_types.dart';

/// Persists reader-wide presentation choices shared by every book.
class ReaderPreferencesStore {
  static const _typesettingModeKey = 'reader_typesetting_mode_v1';
  static const _darkModeKey = 'reader_dark_mode_v1';

  final SharedPreferences? _injected;
  SharedPreferences? _resolved;

  ReaderPreferencesStore([SharedPreferences? preferences])
    : _injected = preferences;

  Future<SharedPreferences> get _preferences async =>
      _resolved ??= _injected ?? await SharedPreferences.getInstance();

  Future<TypesettingMode> loadTypesettingMode() async {
    try {
      return switch ((await _preferences).getString(_typesettingModeKey)) {
        'book' => TypesettingMode.book,
        _ => TypesettingMode.unified,
      };
    } catch (_) {
      // Reader startup must remain usable if platform preferences are
      // temporarily unavailable (notably in lightweight widget tests).
      return TypesettingMode.unified;
    }
  }

  Future<void> saveTypesettingMode(TypesettingMode mode) async {
    await (await _preferences).setString(_typesettingModeKey, mode.name);
  }

  Future<bool> loadDarkMode() async {
    try {
      return (await _preferences).getBool(_darkModeKey) ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> saveDarkMode(bool enabled) async {
    await (await _preferences).setBool(_darkModeKey, enabled);
  }
}
