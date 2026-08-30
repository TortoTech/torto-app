import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ai_models.dart';

class AiSettingsStore {
  static const _settingsKey = 'ai_settings_v1';
  static const _apiKeyPrefix = 'ai_provider_api_key_v1_';

  final SharedPreferences? _injectedPreferences;
  final FlutterSecureStorage _secureStorage;
  SharedPreferences? _preferences;

  AiSettingsStore({
    SharedPreferences? preferences,
    FlutterSecureStorage? secureStorage,
  }) : _injectedPreferences = preferences,
       _secureStorage = secureStorage ?? const FlutterSecureStorage();

  Future<SharedPreferences> get _prefs async => _preferences ??=
      _injectedPreferences ?? await SharedPreferences.getInstance();

  Future<AiSettings> load() async {
    AiSettings settings;
    try {
      final raw = (await _prefs).getString(_settingsKey);
      settings = raw == null
          ? AiSettings.defaults()
          : AiSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      settings = AiSettings.defaults();
    }
    final providers = <AiProviderConfig>[];
    for (final provider in settings.providers) {
      String apiKey = '';
      try {
        apiKey =
            await _secureStorage.read(key: '$_apiKeyPrefix${provider.id}') ??
            '';
      } catch (_) {
        // A locked keystore should leave the provider visibly unconfigured.
      }
      providers.add(provider.copyWith(apiKey: apiKey));
    }
    return settings.copyWith(providers: providers).normalized();
  }

  Future<void> save(AiSettings settings) async {
    final normalized = settings.normalized();
    await (await _prefs).setString(
      _settingsKey,
      jsonEncode(normalized.toJson()),
    );
    for (final provider in normalized.providers) {
      final key = '$_apiKeyPrefix${provider.id}';
      if (provider.apiKey.isEmpty) {
        await _secureStorage.delete(key: key);
      } else {
        await _secureStorage.write(key: key, value: provider.apiKey);
      }
    }
  }

  Future<void> deleteProviderSecret(String providerId) =>
      _secureStorage.delete(key: '$_apiKeyPrefix$providerId');
}
