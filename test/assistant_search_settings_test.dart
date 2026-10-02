import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:torto/app/ai/assistant_settings.dart';
import 'package:torto/app/ai/chat_assistant.dart';
import 'package:torto/app/settings/assistant_settings_page.dart';

void main() {
  test('removed services do not leak their endpoint or key to Tavily', () {
    for (final name in ['custom', 'serper']) {
      final settings = AssistantSettings.fromJson({
        'search_service': name,
        'search_endpoint': 'https://old.test/search',
      }, key: 'old-key');
      expect(settings.searchService, SearchService.tavily);
      expect(settings.endpoint, SearchService.tavily.defaultEndpoint);
      expect(settings.searchKey, isEmpty);
    }
  });

  test(
    'Exa requests highlights and normalizes them into bounded snippets',
    () async {
      final client = MockClient((request) async {
        expect(request.url.toString(), SearchService.exa.defaultEndpoint);
        expect(request.method, 'POST');
        expect(request.headers['x-api-key'], 'exa-key');
        expect(jsonDecode(request.body), {
          'query': 'evidence',
          'numResults': 5,
          'contents': {'highlights': true},
        });
        return http.Response(
          jsonEncode({
            'results': [
              {
                'title': 'Evidence',
                'url': 'https://example.test',
                'highlights': ['First', 'Second'],
              },
            ],
          }),
          200,
        );
      });
      final result = await WebSearchService(client).search(
        'evidence',
        const AssistantSettings(
          searchService: SearchService.exa,
          searchKey: 'exa-key',
        ),
      );
      expect(result.single['content'], 'First\nSecond');
      client.close();
    },
  );

  test('SearXNG uses JSON GET without mandatory credentials', () async {
    final client = MockClient((request) async {
      expect(request.method, 'GET');
      expect(request.headers['authorization'], isNull);
      expect(request.url.queryParameters, {
        'language': 'en',
        'q': 'evidence',
        'format': 'json',
      });
      return http.Response(
        '{"results":[{"title":"Evidence","url":"https://example.test","content":"Fact"}]}',
        200,
      );
    });
    final result = await WebSearchService(client).search(
      'evidence',
      const AssistantSettings(
        searchService: SearchService.searxng,
        searchEndpoint: 'https://searx.test/search?language=en',
      ),
    );
    expect(result.single['content'], 'Fact');
    client.close();
  });

  testWidgets(
    'provider changes restore independent addresses and credentials',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      await tester.pumpWidget(const MaterialApp(home: AssistantSettingsPage()));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      TextField endpoint() =>
          tester.widget<TextField>(find.byType(TextField).first);
      expect(endpoint().controller!.text, SearchService.tavily.defaultEndpoint);
      Finder dropdown() => find.byWidgetPredicate(
        (w) =>
            w is DropdownButtonFormField<String> &&
            w.key.toString().contains('search-mode-'),
      );
      await tester.ensureVisible(dropdown());
      await tester.tap(dropdown());
      await tester.pumpAndSettle();
      expect(find.text('Serper'), findsNothing);
      expect(find.text('Custom'), findsNothing);
      await tester.tap(find.text('Exa').last);
      await tester.pumpAndSettle();
      expect(endpoint().controller!.text, SearchService.exa.defaultEndpoint);
      await tester.enterText(find.byType(TextField).last, 'temporary-key');
      await tester.tap(dropdown());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Brave Search').last);
      await tester.pumpAndSettle();
      expect(endpoint().controller!.text, SearchService.brave.defaultEndpoint);
      expect(
        tester.widget<TextField>(find.byType(TextField).last).controller!.text,
        isEmpty,
      );
      await tester.tap(dropdown());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Exa').last);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField).last).controller!.text,
        'temporary-key',
      );
    },
  );
}
