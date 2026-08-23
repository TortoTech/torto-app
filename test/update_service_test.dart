import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:torto/app/update/app_update_service.dart';

void main() {
  test('detects a newer GitHub release', () async {
    final client = MockClient(
      (_) async => http.Response(
        '{"tag_name":"v1.2.0","html_url":"https://github.com/TortoTech/torto-app/releases/tag/v1.2.0"}',
        200,
      ),
    );
    final service = AppUpdateService(client: client);

    final result = await service.check(currentVersion: '1.1.9');

    expect(result.latestVersion, '1.2.0');
    expect(result.updateAvailable, isTrue);
    expect(result.releasePage.toString(), contains('/releases/tag/v1.2.0'));
  });

  test('treats a missing GitHub release as no published version', () async {
    final service = AppUpdateService(
      client: MockClient((_) async => http.Response('Not Found', 404)),
    );

    final result = await service.check(currentVersion: '1.0.0');

    expect(result.hasRelease, isFalse);
    expect(result.updateAvailable, isFalse);
  });

  test('compares numeric release versions', () {
    expect(compareReleaseVersions('1.10.0', '1.9.9'), greaterThan(0));
    expect(compareReleaseVersions('v1.0.0+2', '1.0'), 0);
    expect(compareReleaseVersions('1.0.0', '1.0.1'), lessThan(0));
  });
}
