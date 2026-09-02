import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:torto/app/ai/ai_models.dart';
import 'package:torto/app/ai/openai_compatible_client.dart';
import 'package:torto/app/settings/ai_providers_page.dart';

void main() {
  testWidgets('provider editor auto-loads models and supports multi-select', (
    tester,
  ) async {
    var requests = 0;
    final client = OpenAiCompatibleClient(
      client: MockClient((request) async {
        requests++;
        expect(request.url.toString(), 'https://example.com/v1/models');
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'data': [
                {'id': 'model-a'},
                {'id': 'model-b'},
              ],
            }),
          ),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    addTearDown(client.close);

    await tester.pumpWidget(
      MaterialApp(
        home: AiProviderEditPage(
          provider: const AiProviderConfig(
            id: 'provider',
            name: 'Provider',
            baseUrl: 'https://example.com/v1',
            apiKey: 'secret',
            models: ['book-model'],
          ),
          client: client,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(requests, 1);

    await tester.tap(find.byType(InputDecorator).last);
    await tester.pumpAndSettle();
    expect(find.text('model-a'), findsOneWidget);
    expect(find.text('model-b'), findsOneWidget);

    await tester.tap(find.text('model-a'));
    await tester.pump();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已选择 2 个模型'), findsOneWidget);
  });
}
