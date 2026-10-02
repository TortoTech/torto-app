import 'dart:convert';
import 'package:http/http.dart' as http;
import 'ai_models.dart';

class LlmHttpException extends StateError {
  final int status;
  final String detail;
  LlmHttpException(this.status, this.detail)
    : super('AI HTTP $status: $detail');
}

/// Provider-specific wire protocols; callers keep their original task system
/// instructions through structured-output fallback and JSON recovery.
class LlmTransport {
  final http.Client client;
  const LlmTransport(this.client);

  Future<String> generate({
    required AiProviderConfig provider,
    required String model,
    required String system,
    required Object input,
    List<Map<String, dynamic>> images = const [],
    Map<String, dynamic>? schema,
    String schemaName = 'result',
    int? maxTokens,
    ReasoningEffort effort = ReasoningEffort.defaultLevel,
    bool webSearch = false,
    void Function(String text)? onPartial,
  }) async {
    if (provider.baseUrl.trim().isEmpty ||
        model.trim().isEmpty ||
        provider.kind.requiresApiKey && provider.apiKey.trim().isEmpty) {
      throw StateError('Configure the AI provider, API key and model first.');
    }
    final base = endpoint(provider.baseUrl);
    final kind = provider.kind;
    final text = input is String ? input : jsonEncode(input);
    final jsonSystem = schema == null
        ? system
        : '$system\nReturn one JSON object matching this schema: ${jsonEncode(schema)}';
    var format =
        schema != null &&
            !const {
              AiProviderKind.custom,
              AiProviderKind.deepSeek,
              AiProviderKind.moonshot,
              AiProviderKind.miniMax,
            }.contains(kind)
        ? 2
        : kind == AiProviderKind.custom
        ? 0
        : 1;
    for (var attempt = 0; attempt < 3; attempt++) {
      final headers = <String, String>{'content-type': 'application/json'};
      if (provider.apiKey.isNotEmpty) {
        headers['authorization'] = 'Bearer ${provider.apiKey}';
      }
      late String path;
      late Map<String, dynamic> body;
      if ((kind == AiProviderKind.openAi || kind == AiProviderKind.xai) &&
          webSearch) {
        path =
            '${base.replaceFirst(RegExp(r'/chat/completions$'), '')}/responses';
        body = {
          'model': model,
          'instructions': system,
          'input': images.isEmpty
              ? text
              : [
                  {
                    'role': 'user',
                    'content': [
                      {'type': 'input_text', 'text': text},
                      for (final image in images)
                        {
                          'type': 'input_image',
                          'image_url': (image['image_url'] as Map)['url'],
                        },
                    ],
                  },
                ],
          'store': false,
          'max_output_tokens': maxTokens ?? 8192,
          'max_tool_calls': 3,
          'tools': [
            {
              'type': 'web_search',
              if (kind == AiProviderKind.openAi) 'search_context_size': 'low',
            },
          ],
          if (effort.apiValue != null)
            'reasoning': {
              'effort':
                  kind == AiProviderKind.openAi && effort == ReasoningEffort.max
                  ? 'xhigh'
                  : effort.apiValue,
            },
        };
      } else if (kind == AiProviderKind.anthropic) {
        path = '${base.replaceFirst(RegExp(r'/v1$'), '')}/v1/messages';
        headers.remove('authorization');
        headers['x-api-key'] = provider.apiKey;
        headers['anthropic-version'] = '2023-06-01';
        body = {
          'model': model,
          'max_tokens':
              (maxTokens ?? 8192) +
              (effort != ReasoningEffort.defaultLevel &&
                      effort != ReasoningEffort.none
                  ? 8192
                  : 0),
          if (effort != ReasoningEffort.defaultLevel)
            'thinking': effort == ReasoningEffort.none
                ? {'type': 'disabled'}
                : {
                    'type': 'enabled',
                    'budget_tokens': switch (effort) {
                      ReasoningEffort.minimal => 1024,
                      ReasoningEffort.low => 2048,
                      ReasoningEffort.medium => 4096,
                      _ => 8192,
                    },
                  },
          'system': jsonSystem,
          'messages': [
            {
              'role': 'user',
              'content': [
                {'type': 'text', 'text': text},
                for (final image in images) _anthropicImage(image),
              ],
            },
          ],
          if (webSearch)
            'tools': [
              {
                'type': 'web_search_20250305',
                'name': 'web_search',
                'max_uses': 3,
              },
            ],
          if (schema != null &&
              format > 0 &&
              (effort == ReasoningEffort.defaultLevel ||
                  effort == ReasoningEffort.none)) ...{
            'tools': [
              {
                'name': schemaName,
                'description': 'Return the task result',
                'input_schema': schema,
              },
            ],
            'tool_choice': {'type': 'tool', 'name': schemaName},
          },
        };
      } else if (kind == AiProviderKind.gemini) {
        path =
            '${base.replaceFirst(RegExp(r'/v1beta$'), '')}/v1beta/models/${Uri.encodeComponent(model.replaceFirst('models/', ''))}:generateContent';
        headers.remove('authorization');
        headers['x-goog-api-key'] = provider.apiKey;
        body = {
          'systemInstruction': {
            'parts': [
              {'text': jsonSystem},
            ],
          },
          'contents': [
            {
              'role': 'user',
              'parts': [
                {'text': text},
                for (final image in images) _geminiImage(image),
              ],
            },
          ],
          'generationConfig': {
            'maxOutputTokens': ?maxTokens,
            if (schema != null && format > 0) ...{
              'responseMimeType': 'application/json',
              if (format > 1) 'responseJsonSchema': schema,
            },
            if (effort != ReasoningEffort.defaultLevel &&
                model.contains('gemini-3'))
              'thinkingConfig': {
                'thinkingLevel':
                    const {
                      ReasoningEffort.none,
                      ReasoningEffort.minimal,
                      ReasoningEffort.low,
                    }.contains(effort)
                    ? 'low'
                    : 'high',
              },
            if (effort != ReasoningEffort.defaultLevel && model.contains('2.5'))
              'thinkingConfig': {
                // Pro cannot disable thinking; use its minimum allowed budget.
                'thinkingBudget': switch (effort) {
                  ReasoningEffort.none => model.contains('pro') ? 128 : 0,
                  ReasoningEffort.minimal => 1024,
                  ReasoningEffort.low => 2048,
                  ReasoningEffort.medium => 4096,
                  _ => 8192,
                },
              },
          },
          if (webSearch)
            'tools': [
              {'google_search': {}},
            ],
        };
      } else if (kind == AiProviderKind.ollama) {
        path = '${base.replaceFirst(RegExp(r'/(api|v1)$'), '')}/api/chat';
        body = {
          'model': model,
          'stream': false,
          'messages': [
            {'role': 'system', 'content': jsonSystem},
            {
              'role': 'user',
              'content': text,
              if (images.isNotEmpty)
                'images': images.map((image) => _imageData(image).$2).toList(),
            },
          ],
          if (schema != null && format > 0) 'format': schema,
          if (effort != ReasoningEffort.defaultLevel)
            'think': effort != ReasoningEffort.none,
          'options': {'num_predict': ?maxTokens},
        };
      } else {
        path = base.endsWith('/chat/completions')
            ? base
            : '$base/chat/completions';
        body = {
          'model': model,
          (RegExp(r'^(?:gpt-[56]|o[134])').hasMatch(model)
                  ? 'max_completion_tokens'
                  : 'max_tokens'):
              ?maxTokens,
          'messages': [
            {'role': 'system', 'content': schema == null ? system : jsonSystem},
            {
              'role': 'user',
              'content': images.isEmpty
                  ? text
                  : [
                      {'type': 'text', 'text': text},
                      ...images,
                    ],
            },
          ],
          if (schema != null && format > 0)
            'response_format': format == 2
                ? {
                    'type': 'json_schema',
                    'json_schema': {
                      'name': schemaName,
                      'strict': true,
                      'schema': schema,
                    },
                  }
                : {'type': 'json_object'},
          if (webSearch && kind == AiProviderKind.openRouter)
            'tools': [
              {
                'type': 'openrouter:web_search',
                'parameters': {
                  'engine': 'auto',
                  'max_uses': 3,
                  'max_results': 5,
                  'max_total_results': 15,
                },
              },
            ],
          if (webSearch && kind == AiProviderKind.zai)
            'tools': [
              {
                'type': 'web_search',
                'web_search': {
                  'enable': true,
                  'search_result': true,
                  'count': 5,
                },
              },
            ],
          if (kind == AiProviderKind.xai && effort.apiValue != null)
            'reasoning': {'effort': effort.apiValue},
          if ((kind == AiProviderKind.deepSeek ||
                  kind == AiProviderKind.moonshot) &&
              effort != ReasoningEffort.defaultLevel)
            'thinking': {
              'type': effort == ReasoningEffort.none ? 'disabled' : 'enabled',
            },
          if (kind == AiProviderKind.deepSeek &&
              effort != ReasoningEffort.defaultLevel &&
              effort != ReasoningEffort.none)
            'reasoning_effort': effort == ReasoningEffort.max
                ? 'max'
                : const {
                    ReasoningEffort.minimal,
                    ReasoningEffort.low,
                  }.contains(effort)
                ? 'low'
                : 'high',
          if (!const {
                AiProviderKind.deepSeek,
                AiProviderKind.moonshot,
                AiProviderKind.miniMax,
                AiProviderKind.xai,
              }.contains(kind) &&
              !(kind == AiProviderKind.openAi && model.startsWith('gpt-4')) &&
              effort.apiValue != null)
            'reasoning_effort':
                kind == AiProviderKind.openAi && effort == ReasoningEffort.max
                ? 'xhigh'
                : effort.apiValue,
        };
      }
      if (onPartial != null && schema == null) {
        if (kind == AiProviderKind.gemini) {
          path =
              '${path.replaceFirst(':generateContent', ':streamGenerateContent')}?alt=sse';
        } else {
          body['stream'] = true;
        }
        final request = http.Request('POST', Uri.parse(path))
          ..headers.addAll(headers)
          ..body = jsonEncode(body);
        final response = await client
            .send(request)
            .timeout(const Duration(seconds: 90));
        if (response.statusCode < 200 || response.statusCode >= 300) {
          final bytes = <int>[];
          await for (final chunk in response.stream) {
            bytes.addAll(chunk.take(8192 - bytes.length));
            if (bytes.length >= 8192) break;
          }
          throw LlmHttpException(
            response.statusCode,
            _safeError(
              utf8.decode(bytes, allowMalformed: true),
              provider.apiKey,
            ),
          );
        }
        return _readStream(
          response,
          kind,
          onPartial,
        ).timeout(const Duration(seconds: 90));
      }
      final response = await client
          .post(Uri.parse(path), headers: headers, body: jsonEncode(body))
          .timeout(const Duration(seconds: 90));
      if (response.statusCode >= 200 && response.statusCode < 300) {
        final result = jsonDecode(response.body) as Map;
        if ((kind == AiProviderKind.openAi || kind == AiProviderKind.xai) &&
            webSearch) {
          final output = StringBuffer();
          for (final item
              in (result['output'] as List? ?? []).whereType<Map>()) {
            if (item['type'] != 'message') continue;
            for (final part
                in (item['content'] as List? ?? []).whereType<Map>()) {
              var text = part['text'] as String? ?? '';
              final citations =
                  (part['annotations'] as List? ?? [])
                      .whereType<Map>()
                      .where(
                        (c) =>
                            c['type'] == 'url_citation' &&
                            c['start_index'] is int &&
                            c['end_index'] is int,
                      )
                      .toList()
                    ..sort(
                      (a, b) => (b['start_index'] as int).compareTo(
                        a['start_index'] as int,
                      ),
                    );
              for (final citation in citations) {
                final start = citation['start_index'] as int,
                    end = citation['end_index'] as int;
                final url = citation['url'] as String? ?? '';
                if (start >= 0 &&
                    end > start &&
                    end <= text.length &&
                    safeSourceUrl(url)) {
                  text = text.replaceRange(
                    start,
                    end,
                    '[${text.substring(start, end).replaceAll('[', '').replaceAll(']', '')}](<$url>)',
                  );
                }
              }
              output.write(text);
            }
          }
          final answer = output.toString();
          return answer +
              sourceLinks(
                _collectSources(
                  result,
                ).where((source) => !answer.contains(source['url'] as String)),
              );
        }
        if (kind == AiProviderKind.anthropic) {
          for (final part
              in (result['content'] as List? ?? []).whereType<Map>()) {
            if (part['type'] == 'tool_use' && part['name'] == schemaName) {
              return jsonEncode(part['input']);
            }
          }
          return (result['content'] as List? ?? [])
              .whereType<Map>()
              .where((part) => part['type'] == 'text')
              .map(
                (part) =>
                    '${part['text'] ?? ''}${sourceLinks((part['citations'] as List? ?? []).whereType<Map>())}',
              )
              .join();
        }
        if (kind == AiProviderKind.gemini) {
          final candidates = result['candidates'] as List? ?? [];
          if (candidates.isEmpty) {
            throw const FormatException('AI returned no content');
          }
          final candidate = candidates.first as Map;
          return (((candidate['content']['parts'] as List)
                  .whereType<Map>()
                  .where((part) => part['thought'] != true)
                  .map((part) => part['text'] ?? '')
                  .join()) +
              sourceLinks(
                ((candidate['groundingMetadata'] as Map?)?['groundingChunks']
                            as List? ??
                        [])
                    .whereType<Map>()
                    .map((chunk) => chunk['web'])
                    .whereType<Map>(),
              ));
        }
        if (kind == AiProviderKind.ollama) {
          return result['message']['content'] as String;
        }
        final choices = result['choices'] as List? ?? [];
        if (choices.isEmpty) {
          throw const FormatException('AI returned no content');
        }
        final message = (choices.first as Map)['message'] as Map;
        if (message['content'] is String) {
          return (message['content'] as String) +
              sourceLinks(_collectSources(result));
        }
        if (message['content'] is List) {
          return (message['content'] as List)
              .whereType<Map>()
              .where((part) => part['type'] == 'text')
              .map((part) => part['text'] ?? '')
              .join();
        }
        throw const FormatException('AI returned no text');
      }
      // Only unsupported structured-output errors permit protocol fallback.
      // Authentication, rate limiting and other task failures are not retried.
      final detail = response.body.toLowerCase();
      if (schema != null &&
          format > 0 &&
          const {400, 422}.contains(response.statusCode) &&
          RegExp(
            r'response.?format|json.?schema|structured|tool.?choice|input.?schema|responsejsonschema|responsemimetype',
          ).hasMatch(detail)) {
        format--;
        continue;
      }
      throw LlmHttpException(
        response.statusCode,
        _safeError(response.body, provider.apiKey),
      );
    }
    throw StateError('AI structured output unavailable');
  }

  static String _safeError(String message, String key) {
    final text = key.isEmpty ? message : message.replaceAll(key, '[redacted]');
    return text.substring(0, text.length.clamp(0, 2000));
  }

  static List<Map> _collectSources(dynamic value, [int depth = 0]) {
    if (depth > 24) return [];
    final found = <Map>[];
    if (value is Map) {
      final url = value['url'] ?? value['uri'] ?? value['link'];
      if (url is String && safeSourceUrl(url)) {
        found.add({
          'url': url,
          'title': value['title'] ?? value['name'] ?? url,
        });
      }
      for (final entry in value.entries) {
        if (!const {
          'arguments',
          'input',
          'messages',
          'chat_history',
        }.contains(entry.key)) {
          found.addAll(_collectSources(entry.value, depth + 1));
        }
      }
    } else if (value is List) {
      for (final item in value) {
        found.addAll(_collectSources(item, depth + 1));
        if (found.length >= 30) break;
      }
    }
    return found.take(30).toList();
  }

  Future<List<String>> models(AiProviderConfig provider) async {
    var base = endpoint(provider.baseUrl);
    final headers = <String, String>{};
    final kind = provider.kind;
    String path;
    if (kind == AiProviderKind.anthropic) {
      path = '${base.replaceFirst(RegExp(r'/v1$'), '')}/v1/models';
      headers.addAll({
        'x-api-key': provider.apiKey,
        'anthropic-version': '2023-06-01',
      });
    } else if (kind == AiProviderKind.gemini) {
      path = '${base.replaceFirst(RegExp(r'/v1beta$'), '')}/v1beta/models';
      headers['x-goog-api-key'] = provider.apiKey;
    } else if (kind == AiProviderKind.ollama) {
      path = '${base.replaceFirst(RegExp(r'/(api|v1)$'), '')}/api/tags';
    } else {
      base = base.replaceFirst(RegExp(r'/chat/completions$'), '');
      path = '$base/models';
      if (provider.apiKey.isNotEmpty) {
        headers['authorization'] = 'Bearer ${provider.apiKey}';
      }
    }
    final models = <String>{};
    final cursors = <String>{};
    String? cursor;
    for (var page = 0; page < 32; page++) {
      final uri = Uri.parse(path).replace(
        queryParameters: cursor == null
            ? null
            : {
                kind == AiProviderKind.gemini ? 'pageToken' : 'after_id':
                    cursor,
              },
      );
      final response = await client
          .get(uri, headers: headers)
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        throw StateError('Models HTTP ${response.statusCode}');
      }
      final data = jsonDecode(response.body) as Map;
      final entries =
          data[kind == AiProviderKind.gemini || kind == AiProviderKind.ollama
              ? 'models'
              : 'data'];
      if (entries is! List) throw const FormatException('Invalid model list');
      for (final entry in entries.whereType<Map>()) {
        final id =
            entry[kind == AiProviderKind.gemini || kind == AiProviderKind.ollama
                ? 'name'
                : 'id'];
        if (id is String && id.isNotEmpty) {
          models.add(id.replaceFirst(RegExp(r'^models/'), ''));
        }
      }
      cursor = kind == AiProviderKind.gemini
          ? data['nextPageToken'] as String?
          : kind == AiProviderKind.anthropic && data['has_more'] == true
          ? data['last_id'] as String?
          : null;
      if (cursor == null || cursor.isEmpty || !cursors.add(cursor)) break;
    }
    return models.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  Future<String> _readStream(
    http.StreamedResponse response,
    AiProviderKind kind,
    void Function(String) onPartial,
  ) async {
    final text = StringBuffer(), pending = StringBuffer();
    final sources = <Map>[];
    void collectSources(dynamic data) {
      for (final source in _collectSources(data)) {
        if (sources.length >= 30) break;
        if (!sources.any((old) => old['url'] == source['url'])) {
          sources.add(source);
        }
      }
    }

    final clock = Stopwatch()..start();
    var published = false;
    Map? completed;
    void event(String value) {
      if (value.trim().isEmpty || value.trim() == '[DONE]') return;
      final data = jsonDecode(value) as Map;
      collectSources(data);
      if (data['error'] != null ||
          const {'error', 'response.failed'}.contains(data['type'])) {
        throw StateError('AI streaming failed');
      }
      if (kind == AiProviderKind.anthropic) {
        final delta = data['delta'] as Map?;
        if (delta?['type'] == 'text_delta') text.write(delta?['text'] ?? '');
        if (delta?['citation'] is Map) collectSources(delta!['citation']);
        if (data['type'] == 'content_block_start' &&
            data['content_block'] is Map &&
            data['content_block']['type'] == 'text') {
          text.write(data['content_block']['text'] ?? '');
        }
        if (data['content'] is List) {
          for (final part in (data['content'] as List).whereType<Map>()) {
            if (part['type'] == 'text') text.write(part['text'] ?? '');
          }
        }
      } else if (kind == AiProviderKind.gemini) {
        for (final candidate
            in (data['candidates'] as List? ?? []).whereType<Map>()) {
          for (final part
              in ((candidate['content'] as Map?)?['parts'] as List? ?? [])
                  .whereType<Map>()) {
            if (part['thought'] != true) text.write(part['text'] ?? '');
          }
          collectSources(
            ((candidate['groundingMetadata'] as Map?)?['groundingChunks']
                        as List? ??
                    [])
                .whereType<Map>()
                .map((chunk) => chunk['web'])
                .whereType<Map>(),
          );
        }
      } else if (kind == AiProviderKind.ollama) {
        text.write((data['message'] as Map?)?['content'] ?? '');
      } else if (data['type'] == 'response.output_text.delta') {
        text.write(data['delta'] ?? '');
      } else if (data['type'] == 'response.completed') {
        completed = data['response'] as Map?;
      } else if (data['output'] is List) {
        completed = data;
      } else {
        for (final choice
            in (data['choices'] as List? ?? []).whereType<Map>()) {
          text.write(
            (choice['delta'] as Map?)?['content'] ??
                (choice['message'] as Map?)?['content'] ??
                '',
          );
        }
      }
      if (text.isNotEmpty && (!published || clock.elapsedMilliseconds >= 40)) {
        onPartial(text.toString());
        published = true;
        clock.reset();
      }
    }

    await for (final line
        in response.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      if (line.length > 1024 * 1024 || text.length > 200000) {
        throw const FormatException('AI stream too large');
      }
      if (line.startsWith('data:')) {
        if (line.substring(5).trim() == '[DONE]') break;
        pending.writeln(line.substring(5).trimLeft());
      } else if (line.isEmpty && pending.isNotEmpty) {
        event(pending.toString());
        pending.clear();
      } else if (line.startsWith('{')) {
        // Ollama uses JSONL; tolerate providers that return a whole JSON body
        // even when streaming was requested.
        event(line);
      }
    }
    if (pending.isNotEmpty) event(pending.toString());
    var answer = text.toString();
    if (completed != null) {
      final parts = <String>[];
      for (final output
          in (completed!['output'] as List? ?? []).whereType<Map>()) {
        if (output['type'] != 'message') continue;
        for (final part
            in (output['content'] as List? ?? []).whereType<Map>()) {
          var content = part['text'] as String? ?? '';
          final annotations =
              (part['annotations'] as List? ?? []).whereType<Map>().toList()
                ..sort(
                  (a, b) => ((b['start_index'] as int?) ?? 0).compareTo(
                    (a['start_index'] as int?) ?? 0,
                  ),
                );
          for (final citation in annotations) {
            final start = citation['start_index'],
                end = citation['end_index'],
                url = citation['url'];
            if (start is int &&
                end is int &&
                start >= 0 &&
                end > start &&
                end <= content.length &&
                url is String &&
                safeSourceUrl(url)) {
              content = content.replaceRange(
                start,
                end,
                '[${content.substring(start, end).replaceAll('[', '').replaceAll(']', '')}](<$url>)',
              );
            }
          }
          parts.add(content);
        }
      }
      if (parts.isNotEmpty) answer = parts.join();
    }
    answer += sourceLinks(
      sources.where(
        (source) =>
            !answer.contains((source['url'] ?? source['uri'] ?? '') as String),
      ),
    );
    if (answer.trim().isEmpty) throw const FormatException('Empty AI stream');
    onPartial(answer);
    return answer;
  }

  static String endpoint(String value) {
    final base = value.trim().replaceFirst(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(base);
    if (uri == null ||
        !const {'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException('Invalid AI provider URL');
    }
    return base;
  }

  static bool safeSourceUrl(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        !RegExp(r'[\s<>]').hasMatch(value) &&
        const {'https', 'http'}.contains(uri.scheme) &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty;
  }

  static String sourceLinks(Iterable<Map> sources) => sources
      .where(
        (source) =>
            (source['url'] ?? source['uri']) is String &&
            safeSourceUrl((source['url'] ?? source['uri']) as String),
      )
      .map((source) {
        final url = source['url'] ?? source['uri'];
        final title = (source['title'] ?? url)
            .toString()
            .replaceAll('[', '')
            .replaceAll(']', '');
        return '\n[$title](<$url>)';
      })
      .toSet()
      .join();

  static (String, String) _imageData(Map image) {
    final url = image['image_url']['url'] as String;
    final match = RegExp(
      r'^data:([^;]+);base64,(.+)$',
      dotAll: true,
    ).firstMatch(url);
    if (match == null) {
      throw const FormatException('Expected encoded image data');
    }
    return (match[1]!, match[2]!);
  }

  static Map<String, dynamic> _anthropicImage(Map image) {
    final (mime, data) = _imageData(image);
    return {
      'type': 'image',
      'source': {'type': 'base64', 'media_type': mime, 'data': data},
    };
  }

  static Map<String, dynamic> _geminiImage(Map image) {
    final (mime, data) = _imageData(image);
    return {
      'inlineData': {'mimeType': mime, 'data': data},
    };
  }
}

/// Recover fences/preamble and trailing commas without rewriting string data.
Map<String, dynamic> decodeLlmObject(String content) {
  final start = content.indexOf('{');
  final end = content.lastIndexOf('}');
  if (start < 0 || end < start) {
    throw const FormatException('Expected JSON object');
  }
  final text = content.substring(start, end + 1);
  try {
    return Map<String, dynamic>.from(jsonDecode(text) as Map);
  } on FormatException {
    final repaired = StringBuffer();
    var quoted = false, escaped = false;
    for (var i = 0; i < text.length; i++) {
      final c = text[i];
      if (!quoted && c == ',') {
        var next = i + 1;
        while (next < text.length && text[next].trim().isEmpty) {
          next++;
        }
        if (next < text.length && (text[next] == '}' || text[next] == ']')) {
          continue;
        }
      }
      repaired.write(c);
      if (escaped) {
        escaped = false;
        continue;
      }
      if (quoted && c == '\\') {
        escaped = true;
        continue;
      }
      if (c == '"') quoted = !quoted;
    }
    return Map<String, dynamic>.from(jsonDecode(repaired.toString()) as Map);
  }
}
