import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'sync_models.dart';

class CloudSettingsStore {
  static const _settingsKey = 'cloud_sync_settings_v1';
  static const _passwordKey = 'cloud_sync_password_v1';

  final SharedPreferences? _injectedPreferences;
  final FlutterSecureStorage _secureStorage;
  SharedPreferences? _preferences;

  CloudSettingsStore({
    SharedPreferences? preferences,
    FlutterSecureStorage? secureStorage,
  }) : _injectedPreferences = preferences,
       _secureStorage = secureStorage ?? const FlutterSecureStorage();

  Future<SharedPreferences> get _prefs async => _preferences ??=
      _injectedPreferences ?? await SharedPreferences.getInstance();

  Future<CloudSettings> load() async {
    final raw = (await _prefs).getString(_settingsKey);
    CloudSettings settings;
    try {
      settings = raw == null
          ? const CloudSettings()
          : CloudSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      settings = const CloudSettings();
    }
    if (settings.deviceId.isEmpty || settings.deviceName.isEmpty) {
      settings = settings.copyWith(
        deviceId: settings.deviceId.isEmpty
            ? const Uuid().v4()
            : settings.deviceId,
        deviceName: settings.deviceName.isEmpty
            ? '${Platform.operatingSystem} mobile'
            : settings.deviceName,
      );
      await saveSettings(settings);
    }
    return settings;
  }

  Future<void> saveSettings(CloudSettings settings) async {
    await (await _prefs).setString(_settingsKey, jsonEncode(settings.toJson()));
  }

  Future<String> loadPassword() async =>
      await _secureStorage.read(key: _passwordKey) ?? '';

  Future<void> savePassword(String password) async {
    if (password.isEmpty) {
      await _secureStorage.delete(key: _passwordKey);
    } else {
      await _secureStorage.write(key: _passwordKey, value: password);
    }
  }
}
