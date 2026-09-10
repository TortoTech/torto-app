import 'package:shared_preferences/shared_preferences.dart';

import '../../core/layout/layout_types.dart';

/// Persists reader-wide presentation choices shared by every book.
class ReaderPreferencesStore {
  static const _typesettingModeKey = 'reader_typesetting_mode_v1';
  static const _darkModeKey = 'reader_dark_mode_v1';
  // Legacy global font keys retained only as a migration fallback.
  static const _latinFontKey = 'reader_latin_font_v1';
  static const _cjkFontKey = 'reader_cjk_font_v1';
  static const _cjkPrimaryFontKey = 'reader_cjk_primary_font_v2';
  static const _cjkLatinFontKey = 'reader_cjk_latin_font_v2';
  static const _otherPrimaryFontKey = 'reader_other_primary_font_v2';
  static const _otherCjkFontKey = 'reader_other_cjk_font_v2';
  static const _fontSizeKey = 'reader_font_size_v2';
  static const _fontWeightKey = 'reader_font_weight_v1';

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

  Future<ReaderTypography> loadTypography() async {
    try {
      final preferences = await _preferences;
      final defaults = const ReaderTypography();
      ReaderLatinFont latinFont(String? value, ReaderLatinFont fallback) =>
          ReaderLatinFont.values.firstWhere(
            (font) => font.name == value,
            orElse: () =>
                value == null ? fallback : ReaderLatinFont.parse(value),
          );
      ReaderCjkFont cjkFont(String? value, ReaderCjkFont fallback) =>
          ReaderCjkFont.values.firstWhere(
            (font) => font.name == value,
            orElse: () => value == null ? fallback : ReaderCjkFont.parse(value),
          );
      ReaderLatinFont? optionalLatinFont(String? value) {
        if (value == null || value == 'follow') return null;
        for (final font in ReaderLatinFont.values) {
          if (font.name == value) return font;
        }
        return ReaderLatinFont.parse(value);
      }

      ReaderCjkFont? optionalCjkFont(String? value) {
        if (value == null || value == 'follow') return null;
        for (final font in ReaderCjkFont.values) {
          if (font.name == value) return font;
        }
        return ReaderCjkFont.parse(value);
      }

      return ReaderTypography(
        cjkPrimaryFont: cjkFont(
          preferences.getString(_cjkPrimaryFontKey) ??
              preferences.getString(_cjkFontKey),
          defaults.cjkPrimaryFont,
        ),
        cjkLatinFont: optionalLatinFont(
          preferences.getString(_cjkLatinFontKey),
        ),
        otherPrimaryFont: latinFont(
          preferences.getString(_otherPrimaryFontKey) ??
              preferences.getString(_latinFontKey),
          defaults.otherPrimaryFont,
        ),
        otherCjkFont: optionalCjkFont(preferences.getString(_otherCjkFontKey)),
        fontSize: (preferences.getDouble(_fontSizeKey) ?? defaults.fontSize)
            .clamp(12, 28),
        fontWeight: (preferences.getInt(_fontWeightKey) ?? defaults.fontWeight)
            .clamp(200, 900),
      );
    } catch (_) {
      return const ReaderTypography();
    }
  }

  Future<void> saveTypography(ReaderTypography typography) async {
    final preferences = await _preferences;
    await Future.wait([
      preferences.setString(_cjkPrimaryFontKey, typography.cjkPrimaryFont.name),
      preferences.setString(
        _cjkLatinFontKey,
        typography.cjkLatinFont?.name ?? 'follow',
      ),
      preferences.setString(
        _otherPrimaryFontKey,
        typography.otherPrimaryFont.name,
      ),
      preferences.setString(
        _otherCjkFontKey,
        typography.otherCjkFont?.name ?? 'follow',
      ),
      preferences.setDouble(_fontSizeKey, typography.fontSize),
      preferences.setInt(_fontWeightKey, typography.fontWeight),
    ]);
  }
}
