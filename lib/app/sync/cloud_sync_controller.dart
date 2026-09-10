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

  Future<SyncReport> sync({bool force = false}) {
    final running = _inFlight;
    if (running != null) return running;
    if (!settings.enabled && !force) {
      return Future.value(const SyncReport());
    }
    final future = _runSync();
    _inFlight = future;
    return future.whenComplete(() => _inFlight = null);
  }

  Future<SyncReport> _runSync() async {
    status = CloudSyncStatus.syncing;
    errorMessage = null;
    progress = const SyncProgress('Connecting…');
    notifyListeners();
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
      );
      final report = await SyncEngine(
        libraryStore: libraryStore,
        progressStore: progressStore,
        syncStore: syncStore,
        webdav: client,
        settings: settings,
        onProgress: (value) {
          progress = value;
          notifyListeners();
        },
      ).sync();
      progress = const SyncProgress('Syncing reading statistics…');
      notifyListeners();
      final statistics = await ReadingStatisticsStore.instance();
      await statistics.registerBooks(await libraryStore.list());
      await statistics.sync(client);
      status = CloudSyncStatus.success;
      progress = const SyncProgress('Sync complete', 1);
      notifyListeners();
      return report;
    } catch (error, stackTrace) {
      debugPrint('Cloud sync failed: $error\n$stackTrace');
      status = CloudSyncStatus.error;
      errorMessage = error.toString();
      progress = null;
      notifyListeners();
      rethrow;
    } finally {
      client?.close();
    }
  }

  Future<void> markBookRemoved(String bookId) async {
    if (bookId.isEmpty) return;
    await syncStore.setMembership(bookId, false);
  }

  @override
  void dispose() {
    unawaited(syncStore.close());
    super.dispose();
  }
}
