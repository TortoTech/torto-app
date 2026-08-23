import 'dart:convert';

import 'package:http/http.dart' as http;

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

  Future<AppUpdateInfo> check({required String currentVersion}) async {
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
