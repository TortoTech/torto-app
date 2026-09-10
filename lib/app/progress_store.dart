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
  static const String _activityKeyPrefix = 'progress_activity:';

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
      final json = jsonDecode(raw) as Map<String, dynamic>;
      // Older local anchors used a different node/whitespace contract. Keep
      // their chapter and fractional position instead of trusting a stale node.
      if (json['source_revision'] != 3) json.remove('source');
      return LocatorV1.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  Future<void> save(LocatorV1 locator, {int? activityTimeMs}) async {
    final prefs = await _prefs;
    await prefs.setString(
      '$_keyPrefix${locator.publicationId}',
      jsonEncode({...locator.toJson(), 'source_revision': 3}),
    );
    await markActivity(locator.publicationId, activityTimeMs: activityTimeMs);
  }

  Future<void> markActivity(String publicationId, {int? activityTimeMs}) async {
    if (publicationId.isEmpty) return;
    final prefs = await _prefs;
    final key = '$_activityKeyPrefix$publicationId';
    final next = activityTimeMs ?? DateTime.now().millisecondsSinceEpoch;
    final current = prefs.getInt(key) ?? 0;
    if (next > current) await prefs.setInt(key, next);
  }

  Future<Map<String, int>> activityTimes() async {
    final prefs = await _prefs;
    final result = <String, int>{};
    for (final key in prefs.getKeys()) {
      if (!key.startsWith(_activityKeyPrefix)) continue;
      final value = prefs.getInt(key);
      if (value != null && value >= 0) {
        result[key.substring(_activityKeyPrefix.length)] = value;
      }
    }
    return result;
  }

  Future<Map<String, LocatorV1>> all() async {
    final prefs = await _prefs;
    final result = <String, LocatorV1>{};
    for (final key in prefs.getKeys()) {
      if (!key.startsWith(_keyPrefix)) continue;
      final raw = prefs.getString(key);
      if (raw == null) continue;
      try {
        final json = jsonDecode(raw) as Map<String, dynamic>;
        if (json['source_revision'] != 3) json.remove('source');
        final locator = LocatorV1.fromJson(json);
        result[locator.publicationId] = locator;
      } catch (_) {
        // Ignore a single damaged entry without losing the remaining books.
      }
    }
    return result;
  }
}
