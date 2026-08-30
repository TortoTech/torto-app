import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppThemePreference { system, light, dark }

enum AppLanguagePreference { system, simplifiedChinese, english }

class AppPreferencesController extends ChangeNotifier {
  static const _themeKey = 'app_theme_v1';
  static const _languageKey = 'app_language_v1';

  final SharedPreferences? _injectedPreferences;
  SharedPreferences? _preferences;

  AppThemePreference theme = AppThemePreference.system;
  AppLanguagePreference language = AppLanguagePreference.system;

  AppPreferencesController({SharedPreferences? preferences})
    : _injectedPreferences = preferences;

  Future<SharedPreferences> get _prefs async => _preferences ??=
      _injectedPreferences ?? await SharedPreferences.getInstance();

  ThemeMode get themeMode => switch (theme) {
    AppThemePreference.system => ThemeMode.system,
    AppThemePreference.light => ThemeMode.light,
    AppThemePreference.dark => ThemeMode.dark,
  };

  Locale? get locale => switch (language) {
    AppLanguagePreference.system => null,
    AppLanguagePreference.simplifiedChinese => const Locale('zh', 'CN'),
    AppLanguagePreference.english => const Locale('en'),
  };

  Future<void> load() async {
    try {
      final preferences = await _prefs;
      theme = switch (preferences.getString(_themeKey)) {
        'light' => AppThemePreference.light,
        'dark' => AppThemePreference.dark,
        _ => AppThemePreference.system,
      };
      language = switch (preferences.getString(_languageKey)) {
        'zh-CN' => AppLanguagePreference.simplifiedChinese,
        'en' => AppLanguagePreference.english,
        _ => AppLanguagePreference.system,
      };
      notifyListeners();
    } catch (_) {
      // Platform preferences must never prevent the app from starting.
    }
  }

  Future<void> setTheme(AppThemePreference value) async {
    if (theme == value) return;
    theme = value;
    notifyListeners();
    await (await _prefs).setString(_themeKey, switch (value) {
      AppThemePreference.system => 'system',
      AppThemePreference.light => 'light',
      AppThemePreference.dark => 'dark',
    });
  }

  Future<void> setLanguage(AppLanguagePreference value) async {
    if (language == value) return;
    language = value;
    notifyListeners();
    await (await _prefs).setString(_languageKey, switch (value) {
      AppLanguagePreference.system => 'system',
      AppLanguagePreference.simplifiedChinese => 'zh-CN',
      AppLanguagePreference.english => 'en',
    });
  }
}

class AppPreferencesScope extends InheritedNotifier<AppPreferencesController> {
  const AppPreferencesScope({
    super.key,
    required AppPreferencesController controller,
    required super.child,
  }) : super(notifier: controller);

  static AppPreferencesController of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<AppPreferencesScope>()!
      .notifier!;

  static AppPreferencesController? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<AppPreferencesScope>()
      ?.notifier;
}
