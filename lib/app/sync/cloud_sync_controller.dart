import 'dart:async';
import '../statistics/statistics_store.dart';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../library/library_store.dart';
import '../progress_store.dart';
import 'cloud_settings_store.dart';
import 'sync_engine.dart';
import 'sync_models.dart';
import 'sync_store.dart';
import 'webdav_client.dart';

enum CloudSyncStatus { idle, syncing, success, error }

class CloudSyncController extends ChangeNotifier {
  final LibraryStore libraryStore;
  final ProgressStore progressStore;
  final CloudSettingsStore settingsStore;
  final SyncStore syncStore;

  CloudSettings settings;
  String password;
  CloudSyncStatus status = CloudSyncStatus.idle;
  SyncProgress? progress;
  String? errorMessage;
  Future<SyncReport>? _inFlight;
  Future<SyncReport>? _queued;
  bool _queuedFull = false, _queuedForce = false;
  bool _disposed = false;
  String? _lastFullAccount;
  DateTime? _retryAfter;
  bool _retryFull = false;
  String get _account =>
      '${settings.effectiveBaseUrl}\n${settings.username}\n${settings.cstCloudCompatibility}';

  CloudSyncController._({
    required this.libraryStore,
    required this.progressStore,
    required this.settingsStore,
    required this.syncStore,
    required this.settings,
    required this.password,
  });

  static Future<CloudSyncController> create({
    required LibraryStore libraryStore,
    required ProgressStore progressStore,
    CloudSettingsStore? settingsStore,
  }) async {
    final store = settingsStore ?? CloudSettingsStore();
    final settings = await store.load();
    return CloudSyncController._(
      libraryStore: libraryStore,
      progressStore: progressStore,
      settingsStore: store,
      syncStore: await SyncStore.open(settings.deviceId),
      settings: settings,
      password: await store.loadPassword(),
    );
  }

  Future<void> saveConfiguration(
    CloudSettings nextSettings,
    String nextPassword,
  ) async {
    settings = nextSettings;
    password = nextPassword;
    await settingsStore.saveSettings(nextSettings);
    await settingsStore.savePassword(nextPassword);
    notifyListeners();
  }

  Future<SyncReport> sync({bool force = false, bool readingOnly = false}) {
    if (_disposed) return Future.value(const SyncReport());
    if (!force &&
        _retryAfter != null &&
        DateTime.now().isBefore(_retryAfter!)) {
      return Future.value(const SyncReport());
    }
    final running = _inFlight;
    if (running != null) {
      _queuedFull |= !readingOnly;
      _queuedForce |= force;
      return _queued ??= running.catchError((_) => const SyncReport()).then((
        _,
      ) {
        final full = _queuedFull, forced = _queuedForce;
        _queuedFull = _queuedForce = false;
        _queued = null;
        return sync(force: forced, readingOnly: !full);
      });
    }
    if (!settings.enabled && !force) {
      return Future.value(const SyncReport());
    }
    final light =
        readingOnly &&
        !_retryFull &&
        !force &&
        _lastFullAccount == _account;
    return _inFlight = _runSync(
      readingOnly: light,
      force: force,
    ).whenComplete(() => _inFlight = null);
  }

  Future<SyncReport> _runSync({
    required bool readingOnly,
    required bool force,
  }) async {
    final account = _account;
    final watch = Stopwatch()..start();
    var stage = 'Connecting';
    var stageStarted = 0;
    void traceStage(String next) {
      if (next == stage) return;
      debugPrint(
        'TortoSync stage=$stage elapsed_ms=${watch.elapsedMilliseconds - stageStarted}',
      );
      stage = next;
      stageStarted = watch.elapsedMilliseconds;
    }

    final settings = this.settings;
    final password = this.password;
    if (!readingOnly) {
      status = CloudSyncStatus.syncing;
      errorMessage = null;
      progress = const SyncProgress('Connecting…');
      notifyListeners();
    }
    WebDavClient? client;
    try {
      if (settings.effectiveBaseUrl.isEmpty ||
          settings.username.trim().isEmpty ||
          password.isEmpty) {
        throw const WebDavException('Complete the cloud sync settings first.');
      }
      final package = await PackageInfo.fromPlatform();
      client = WebDavClient(
        baseUrl: settings.effectiveBaseUrl,
        username: settings.username.trim(),
        password: password,
        cstCloudCompatibility: settings.cstCloudCompatibility,
        userAgent: 'Torto/${package.version} Zotero/7.0',
        cacheStore: syncStore,
      );
      final report = await SyncEngine(
        libraryStore: libraryStore,
        progressStore: progressStore,
        syncStore: syncStore,
        webdav: client,
        settings: settings,
        onProgress: (value) {
          traceStage(value.label);
          status = CloudSyncStatus.syncing;
          errorMessage = null;
          progress = value;
          notifyListeners();
        },
      ).sync(readingOnly: readingOnly);
      if (!readingOnly) {
        traceStage('Reading statistics');
        progress = const SyncProgress('Syncing reading statistics…');
        notifyListeners();
        final statistics = await ReadingStatisticsStore.instance();
        await statistics.registerBooks(await libraryStore.list());
        final last =
            int.tryParse(await client.cacheGet('statistics:last') ?? '') ?? 0;
        if (force ||
            DateTime.now().millisecondsSinceEpoch - last >= 10 * 60 * 1000) {
          await statistics.sync(client);
          await client.cacheSet(
            'statistics:last',
            '${DateTime.now().millisecondsSinceEpoch}',
          );
        }
        _lastFullAccount = account;
      }
      status = CloudSyncStatus.success;
      _retryAfter = null;
      _retryFull = false;
      progress = const SyncProgress('Sync complete', 1);
      notifyListeners();
      return report;
    } catch (error, stackTrace) {
      _retryAfter = DateTime.now().add(const Duration(seconds: 30));
      _retryFull |= !readingOnly;
      debugPrint('Cloud sync failed: $error\n$stackTrace');
      status = CloudSyncStatus.error;
      errorMessage = error.toString();
      progress = null;
      notifyListeners();
      rethrow;
    } finally {
      traceStage('Finished');
      debugPrint(
        'TortoSync mode=${readingOnly ? "reading" : "full"} status=${status.name} elapsed_ms=${watch.elapsedMilliseconds} requests=${client?.requestCounts} request_ms=${client?.requestMilliseconds}',
      );
      client?.close();
    }
  }

  Future<void> markBookRemoved(String bookId) async {
    if (bookId.isEmpty) return;
    await syncStore.setMembership(bookId, false);
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    final running = _inFlight;
    unawaited(() async {
      try {
        await running;
      } catch (_) {
        /* Already reported by the sync caller. */
      }
      await syncStore.close();
    }());
    super.dispose();
  }
}
