import 'dart:convert';

import 'package:http/http.dart' as http;

enum UpdateSource { automatic, github, gitee }

class AppUpdateInfo {
  final String currentVersion;
  final String? latestVersion;
  final Uri? releasePage;

  const AppUpdateInfo({
    required this.currentVersion,
    required this.latestVersion,
    required this.releasePage,
  });

  bool get hasRelease => latestVersion != null && releasePage != null;

  bool get updateAvailable =>
      latestVersion != null &&
      compareReleaseVersions(currentVersion, latestVersion!) < 0;
}

class AppUpdateService {
  static final latestReleaseEndpoint = Uri.parse(
    'https://api.github.com/repos/TortoTech/torto-app/releases/latest',
  );

  final http.Client _client;
  final bool _ownsClient;
  final Uri endpoint;

  AppUpdateService({http.Client? client, Uri? endpoint})
    : _client = client ?? http.Client(),
      _ownsClient = client == null,
      endpoint = endpoint ?? latestReleaseEndpoint;

  Future<AppUpdateInfo> check({
    required String currentVersion,
    UpdateSource source = UpdateSource.github,
  }) async {
    if (source == UpdateSource.github) return _github(currentVersion);
    if (source == UpdateSource.gitee) return _gitee(currentVersion);
    final results = await Future.wait([
      _github(
        currentVersion,
      ).then<AppUpdateInfo?>((value) => value).catchError((Object _) => null),
      _gitee(
        currentVersion,
      ).then<AppUpdateInfo?>((value) => value).catchError((Object _) => null),
    ]);
    final available =
        results.whereType<AppUpdateInfo>().where((v) => v.hasRelease).toList()
          ..sort(
            (a, b) =>
                compareReleaseVersions(b.latestVersion!, a.latestVersion!),
          );
    if (available.isNotEmpty) return available.first;
    if (results.any((v) => v != null)) {
      return AppUpdateInfo(
        currentVersion: currentVersion,
        latestVersion: null,
        releasePage: null,
      );
    }
    throw const AppUpdateException('Update sources are unavailable.');
  }

  Future<AppUpdateInfo> _gitee(String currentVersion) async {
    final response = await _client
        .get(
          Uri.parse(
            'https://gitee.com/api/v5/repos/TortoTech/torto-app/releases/latest',
          ),
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode == 404) {
      return AppUpdateInfo(
        currentVersion: currentVersion,
        latestVersion: null,
        releasePage: null,
      );
    }
    if (response.statusCode != 200) {
      throw const AppUpdateException('Gitee update source is unavailable.');
    }
    final release = jsonDecode(response.body) as Map;
    final tag = release['tag_name'];
    if (tag is! String ||
        !RegExp(r'^v\d+\.\d+\.\d+$').hasMatch(tag) ||
        release['prerelease'] == true ||
        release['draft'] == true) {
      throw const AppUpdateException('Invalid Gitee release.');
    }
    final manifestResponse = await _client
        .get(
          Uri.parse(
            'https://gitee.com/TortoTech/torto-app/releases/download/$tag/torto-update.json',
          ),
        )
        .timeout(const Duration(seconds: 15));
    if (manifestResponse.statusCode != 200) {
      throw const AppUpdateException('Gitee release mirroring is incomplete.');
    }
    final manifest = jsonDecode(manifestResponse.body) as Map;
    final asset = manifest['asset'];
    final name = 'Torto-${tag.substring(1)}-android-arm64-v8a.apk';
    if (manifest['tag'] != tag ||
        manifest['version'] != tag.substring(1) ||
        asset is! Map ||
        asset['name'] != name ||
        asset['size'] is! int ||
        asset['size'] <= 0 ||
        asset['sha256'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(asset['sha256'])) {
      throw const AppUpdateException('Gitee release verification failed.');
    }
    final files = release['assets'];
    if (files is! List ||
        !files.whereType<Map>().any((file) {
          final url = Uri.tryParse(
            file['browser_download_url'] as String? ?? '',
          );
          return file['name'] == name &&
              url != null &&
              url.scheme == 'https' &&
              url.host == 'gitee.com' &&
              url.userInfo.isEmpty &&
              url.path == '/TortoTech/torto-app/releases/download/$tag/$name';
        })) {
      throw const AppUpdateException(
        'Gitee release is missing the Android APK.',
      );
    }
    return AppUpdateInfo(
      currentVersion: currentVersion,
      latestVersion: tag.substring(1),
      releasePage: Uri.parse(
        'https://gitee.com/TortoTech/torto-app/releases/tag/$tag',
      ),
    );
  }

  Future<AppUpdateInfo> _github(String currentVersion) async {
    final response = await _client
        .get(
          endpoint,
          headers: const {
            'Accept': 'application/vnd.github+json',
            'X-GitHub-Api-Version': '2026-03-10',
            'User-Agent': 'Torto-Android',
          },
        )
        .timeout(const Duration(seconds: 15));

    if (response.statusCode == 404) {
      return AppUpdateInfo(
        currentVersion: currentVersion,
        latestVersion: null,
        releasePage: null,
      );
    }
    if (response.statusCode != 200) {
      throw AppUpdateException(
        'GitHub returned HTTP ${response.statusCode} while checking updates.',
      );
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const AppUpdateException('GitHub returned an invalid release.');
    }
    final tag = decoded['tag_name'];
    final releaseUrl = decoded['html_url'];
    if (tag is! String || releaseUrl is! String) {
      throw const AppUpdateException('The latest release is missing metadata.');
    }

    final latestVersion = _normalizeVersion(tag);
    final releasePage = Uri.tryParse(releaseUrl);
    if (releasePage == null || !releasePage.hasScheme) {
      throw const AppUpdateException('The latest release URL is invalid.');
    }
    // Validate both values before exposing the result to the UI.
    compareReleaseVersions(currentVersion, latestVersion);

    return AppUpdateInfo(
      currentVersion: currentVersion,
      latestVersion: latestVersion,
      releasePage: releasePage,
    );
  }

  void dispose() {
    if (_ownsClient) _client.close();
  }
}

class AppUpdateException implements Exception {
  final String message;

  const AppUpdateException(this.message);

  @override
  String toString() => message;
}

int compareReleaseVersions(String left, String right) {
  final leftParts = _versionParts(left);
  final rightParts = _versionParts(right);
  final length = leftParts.length > rightParts.length
      ? leftParts.length
      : rightParts.length;
  for (var index = 0; index < length; index++) {
    final leftPart = index < leftParts.length ? leftParts[index] : 0;
    final rightPart = index < rightParts.length ? rightParts[index] : 0;
    final comparison = leftPart.compareTo(rightPart);
    if (comparison != 0) return comparison;
  }
  return 0;
}

List<int> _versionParts(String version) {
  final normalized = _normalizeVersion(
    version,
  ).split('+').first.split('-').first;
  final parts = normalized.split('.');
  if (parts.isEmpty) throw FormatException('Invalid version: $version');
  return parts
      .map((part) {
        final value = int.tryParse(part);
        if (value == null || value < 0) {
          throw FormatException('Invalid version: $version');
        }
        return value;
      })
      .toList(growable: false);
}

String _normalizeVersion(String version) {
  final trimmed = version.trim();
  final normalized = trimmed.startsWith('v') || trimmed.startsWith('V')
      ? trimmed.substring(1)
      : trimmed;
  if (normalized.isEmpty) throw FormatException('Invalid version: $version');
  return normalized;
}
