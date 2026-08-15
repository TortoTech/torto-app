import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../core/ir/ir.dart';

/// SharedPreferences-backed persistence for reading positions ([LocatorV1]).
///
/// Keys are `progress:<publicationId>`; values are the locator's JSON form.
/// Pass a [SharedPreferences] instance for tests, or let it lazily resolve
/// the default instance.
class ProgressStore {
  static const String _keyPrefix = 'progress:';

  final SharedPreferences? _injected;
  SharedPreferences? _resolved;

  ProgressStore([SharedPreferences? prefs]) : _injected = prefs;

  Future<SharedPreferences> get _prefs async =>
      _resolved ??= _injected ?? await SharedPreferences.getInstance();

  /// Returns the saved locator for [publicationId], or null when absent or
  /// unreadable (corrupt payloads are ignored rather than fatal).
  Future<LocatorV1?> load(String publicationId) async {
    final prefs = await _prefs;
    final raw = prefs.getString('$_keyPrefix$publicationId');
    if (raw == null) return null;
    try {
      return LocatorV1.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> save(LocatorV1 locator) async {
    final prefs = await _prefs;
    await prefs.setString(
      '$_keyPrefix${locator.publicationId}',
      jsonEncode(locator.toJson()),
    );
  }
}
