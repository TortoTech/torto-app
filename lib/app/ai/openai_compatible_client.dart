import 'dart:async';
import 'dart:convert';

import 'package:characters/characters.dart';
import 'package:http/http.dart' as http;

import '../../core/translation/translation_models.dart';
import 'ai_models.dart';

String translationSystemPrompt(
  String targetLanguage, {
  String fixedPageHint = '',
}) {
  final fixedPageSection = fixedPageHint.trim().isEmpty
      ? ''
      : '\n# PDF 文字层\n- ${fixedPageHint.trim()}\n';
  return '''你是一名专业图书翻译。

# 翻译任务
- 把输入 JSON 对象中的每个值翻译为$targetLanguage。
- 忠实保留原文语气、事实、专名所指与段落结构。

# 中文表达（目标语言为中文时）
- 人名、地名、书名、机构名、专业术语等外文专名，显示译名即可，不需要用括号附原文。
- 尽量不保留破折号句式，仅当用于话语中断作用时才保留。

# 正文结构
- 每个 JSON 值都是独立正文块。原文开头没有项目符号、编号或列表标记时，译文绝对不得新增；原文有列表标记时保持相同类型。
- <strong>、<em>、<i>、<cite>、<torto-italic>、<u>、<s>、<sup>、<sub>、<noteref>、<noteback>、<inlinefootnote> 及其闭合标签是行内结构标记。必须把完整标签移动到译文中语义对应的词语或句子周围，不得翻译、删除、拆分或把样式扩展到标签范围之外。
- <torto-math-0/>、<torto-math-1/> 等自闭合标签是不可修改的公式占位符。可以随语序移动到对应位置，但每个占位符必须原样保留且恰好出现一次，绝不能翻译、展开、删除、重复、重编号或改写其中的公式。
$fixedPageSection
# 输出格式
- 只返回一个 JSON 对象，保留完全相同的键；每个值只能是对应译文字符串。''';
}

String preserveLeadingListMarker(String source, String translation) {
  final sourceMarker = _leadingListMarker(source);
  final translationMarker = _leadingListMarker(translation);
  if (sourceMarker == null && translationMarker != null) {
    return translation.substring(translationMarker.$2).trimLeft();
  }
  if (sourceMarker != null &&
      translationMarker != null &&
      sourceMarker.$1 != translationMarker.$1) {
    return '${sourceMarker.$1} '
        '${translation.substring(translationMarker.$2).trimLeft()}';
  }
  return translation;
}

(String, int)? _leadingListMarker(String text) {
  final trimmed = text.trimLeft();
  final leadingUnits = text.length - trimmed.length;
  if (trimmed.isEmpty) return null;
  final first = trimmed.characters.first;
  if (const {'•', '·', '●', '○', '▪', '‣', '◦', '∙'}.contains(first)) {
    return (first, leadingUnits + first.length);
  }
  if (const {'-', '*', '+'}.contains(first) &&
      trimmed.substring(first.length).characters.firstOrNull?.trim().isEmpty ==
          true) {
    return (first, leadingUnits + first.length);
  }
  final token = trimmed.split(RegExp(r'\s')).first;
  final body = token.replaceFirst(RegExp(r'(?:\.|、|\)|）)$'), '');
  if (body.isEmpty ||
      body.runes.length > 6 ||
      !RegExp(r'^[A-Za-z0-9]+$').hasMatch(body) ||
      body.length == token.length) {
    return null;
  }
  return (token, leadingUnits + token.length);
}

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
    ReasoningEffort reasoningEffort = ReasoningEffort.defaultLevel,
    FutureOr<void> Function(List<BlockTranslation> translations)? validate,
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
          reasoningEffort: reasoningEffort,
          validate: validate,
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
    required ReasoningEffort reasoningEffort,
    required FutureOr<void> Function(List<BlockTranslation> translations)?
    validate,
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
                'reasoning_effort': ?reasoningEffort.apiValue,
                'messages': [
                  {
                    'role': 'system',
                    'content': translationSystemPrompt(targetLanguage),
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
        final translations = [
          for (var index = 0; index < blocks.length; index++)
            BlockTranslation(
              blockIndex: blocks[index].blockIndex,
              segmentIndex: blocks[index].segmentIndex,
              text: preserveLeadingListMarker(
                blocks[index].text,
                values[index],
              ),
            ),
        ];
        await validate?.call(translations);
        return translations;
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
