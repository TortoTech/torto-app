import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/translation/translation_models.dart';
import 'ai_models.dart';

class OpenAiCompatibleClient {
  static const _maxTranslationChars = 2000;
  static const _maxAttempts = 2;

  final http.Client _client;

  OpenAiCompatibleClient({http.Client? client})
    : _client = client ?? http.Client();

  void close() => _client.close();

  Future<List<String>> fetchModels(AiProviderConfig provider) async {
    final response = await _client
        .get(_modelsUri(provider.baseUrl), headers: _headers(provider.apiKey))
        .timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AiRequestException(_httpError('Failed to load models', response));
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map || decoded['data'] is! List) {
      throw const AiRequestException('The model response is invalid.');
    }
    final models =
        <String>{
          for (final value in (decoded['data'] as List).whereType<Map>())
            if ((value['id'] as String? ?? '').trim().isNotEmpty)
              (value['id'] as String).trim(),
        }.toList()..sort(
          (left, right) => left.toLowerCase().compareTo(right.toLowerCase()),
        );
    return models;
  }

  Future<List<BlockTranslation>> translateBlocks({
    required AiProviderConfig provider,
    required String model,
    required String targetLanguage,
    required List<TranslationBlockInput> blocks,
  }) async {
    _validateProvider(provider, model);
    final output = <BlockTranslation>[];
    for (final batch in _batches(blocks)) {
      output.addAll(
        await _translateBatch(
          provider: provider,
          model: model,
          targetLanguage: targetLanguage,
          blocks: batch,
        ),
      );
    }
    return output;
  }

  Future<List<BlockTranslation>> _translateBatch({
    required AiProviderConfig provider,
    required String model,
    required String targetLanguage,
    required List<TranslationBlockInput> blocks,
  }) async {
    final input = <String, String>{
      for (var index = 0; index < blocks.length; index++)
        '$index': blocks[index].text,
    };
    Object? lastError;
    for (var attempt = 0; attempt < _maxAttempts; attempt++) {
      try {
        final response = await _client
            .post(
              _chatCompletionsUri(provider.baseUrl),
              headers: {
                ..._headers(provider.apiKey),
                'content-type': 'application/json',
              },
              body: jsonEncode({
                'model': model,
                'temperature': 0.2,
                'messages': [
                  {
                    'role': 'system',
                    'content':
                        'You are a professional book translator. Translate every value in the input JSON object into $targetLanguage. Preserve tone, proper names, paragraph meaning, and every key. '
                        'The tags <strong>, <em>, <u>, <s>, <sup>, <sub>, <noteref>, <noteback>, and <inlinefootnote> are protected inline structure: move each complete tag pair to the corresponding translated words without translating, deleting, splitting, or widening it. '
                        'Self-closing tags such as <torto-math-0/> are protected formula placeholders. Each must appear exactly once, unchanged, although it may move with sentence order. '
                        'Return only one JSON object with the same keys and translated string values.',
                  },
                  {'role': 'user', 'content': jsonEncode(input)},
                ],
              }),
            )
            .timeout(const Duration(seconds: 90));
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw AiRequestException(_httpError('Translation failed', response));
        }
        final content = _messageContent(response.body);
        final values = _translationObject(content, blocks.length);
        return [
          for (var index = 0; index < blocks.length; index++)
            BlockTranslation(
              blockIndex: blocks[index].blockIndex,
              segmentIndex: blocks[index].segmentIndex,
              text: values[index],
            ),
        ];
      } catch (error) {
        lastError = error;
      }
    }
    if (lastError is AiRequestException) throw lastError;
    throw AiRequestException('Translation failed: $lastError');
  }

  static void _validateProvider(AiProviderConfig provider, String model) {
    if (provider.baseUrl.trim().isEmpty) {
      throw const AiRequestException('Configure the AI provider URL first.');
    }
    if (provider.apiKey.trim().isEmpty) {
      throw const AiRequestException(
        'Configure the AI provider API Key first.',
      );
    }
    if (model.trim().isEmpty) {
      throw const AiRequestException('Select a translation model first.');
    }
    _chatCompletionsUri(provider.baseUrl);
  }

  static List<List<TranslationBlockInput>> _batches(
    List<TranslationBlockInput> blocks,
  ) {
    final batches = <List<TranslationBlockInput>>[];
    var current = <TranslationBlockInput>[];
    var characters = 0;
    for (final block in blocks) {
      final length = block.text.runes.length;
      if (current.isNotEmpty && characters + length > _maxTranslationChars) {
        batches.add(current);
        current = <TranslationBlockInput>[];
        characters = 0;
      }
      current.add(block);
      characters += length;
    }
    if (current.isNotEmpty) batches.add(current);
    return batches;
  }

  static List<String> _translationObject(String content, int count) {
    var candidate = content.trim();
    if (candidate.startsWith('```')) {
      candidate = candidate.replaceFirst(RegExp(r'^```(?:json)?\s*'), '');
      candidate = candidate.replaceFirst(RegExp(r'\s*```$'), '');
    }
    final start = candidate.indexOf('{');
    final end = candidate.lastIndexOf('}');
    if (start < 0 || end < start) {
      throw const FormatException('Translation did not return a JSON object.');
    }
    final decoded = jsonDecode(candidate.substring(start, end + 1));
    if (decoded is! Map) {
      throw const FormatException('Translation did not return a JSON object.');
    }
    return [
      for (var index = 0; index < count; index++)
        if (decoded['$index'] is String &&
            (decoded['$index'] as String).trim().isNotEmpty)
          decoded['$index'] as String
        else
          throw const FormatException('Translation omitted a text block.'),
    ];
  }

  static String _messageContent(String body) {
    final decoded = jsonDecode(body);
    if (decoded is! Map || decoded['choices'] is! List) {
      throw const FormatException('The AI response is invalid.');
    }
    final choices = decoded['choices'] as List;
    if (choices.isEmpty || choices.first is! Map) {
      throw const FormatException('The AI response is empty.');
    }
    final message = (choices.first as Map)['message'];
    if (message is! Map || message['content'] is! String) {
      throw const FormatException('The AI response is empty.');
    }
    return message['content'] as String;
  }

  static Map<String, String> _headers(String apiKey) => {
    'accept': 'application/json',
    if (apiKey.trim().isNotEmpty) 'authorization': 'Bearer ${apiKey.trim()}',
  };

  static Uri _modelsUri(String baseUrl) {
    var base = _normalizedBase(baseUrl);
    if (base.endsWith('/chat/completions')) {
      base = base.substring(0, base.length - '/chat/completions'.length);
    }
    if (!base.endsWith('/models')) base = '$base/models';
    return Uri.parse(base);
  }

  static Uri _chatCompletionsUri(String baseUrl) {
    var base = _normalizedBase(baseUrl);
    if (!base.endsWith('/chat/completions')) {
      if (base.endsWith('/models')) {
        base = base.substring(0, base.length - '/models'.length);
      }
      base = '$base/chat/completions';
    }
    return Uri.parse(base);
  }

  static String _normalizedBase(String value) {
    final base = value.trim().replaceFirst(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(base);
    if (uri == null ||
        !const {'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty) {
      throw const AiRequestException(
        'The AI provider URL must use HTTP or HTTPS.',
      );
    }
    return base;
  }

  static String _httpError(String prefix, http.Response response) {
    final detail = response.body.trim();
    final clipped = detail.length <= 240
        ? detail
        : '${detail.substring(0, 240)}…';
    return clipped.isEmpty
        ? '$prefix: HTTP ${response.statusCode}'
        : '$prefix: HTTP ${response.statusCode} · $clipped';
  }
}

class AiRequestException implements Exception {
  final String message;

  const AiRequestException(this.message);

  @override
  String toString() => message;
}
