import 'dart:async';
import 'dart:convert';

import 'package:characters/characters.dart';
import 'package:http/http.dart' as http;

import '../../core/translation/translation_models.dart';
import 'ai_models.dart';
import 'llm_transport.dart';
import 'translation_glossary.dart';
import 'semantic_wire.dart';

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
- 不要直译，按$targetLanguage语言习惯翻译。
- 保留 <t-size scale="...">...</t-size> 字号标签及其数值，翻译标签内文字，不得删除、复制或修改字号。
- 忠实保留原文语气、事实、专名所指与段落结构。

# 中文表达（目标语言为中文时）
- 人名、地名、书名、机构名、专业术语等外文专名，显示译名即可，不需要用括号附原文。
- 尽量不保留破折号句式，仅当用于话语中断作用时才保留。

# 正文结构
- 每个 JSON 值都是独立正文块。原文开头没有项目符号、编号或列表标记时，译文绝对不得新增；原文有列表标记时保持相同类型。
- <strong>、<em>、<i>、<cite>、<t-italic>、<u>、<s>、<sup>、<sub>、<noteback> 及其闭合标签是行内结构标记。必须把完整标签移动到译文中语义对应的词语或句子周围，不得翻译、删除、拆分或把样式扩展到标签范围之外。
- Preserve each <t-note-N/> footnote reference and <t-web-N/> website exactly once, attached to its corresponding claim. Never translate, expand or renumber these source identities. Keep literal websites unchanged.
- Translate contents of <inlinefootnote id="N">...</inlinefootnote> and <citation id="N">...</citation>, preserving each group and its ID exactly once. Keep bibliographic names and years accurate; never invent or merge IDs. Untagged paragraphs must not acquire citation tags. Numeric paragraph JSON keys are not citation IDs.
- <t-math-0/>、<t-math-1/> 等自闭合标签是不可修改的公式占位符。可以随语序移动到对应位置，但每个占位符必须原样保留且恰好出现一次，绝不能翻译、展开、删除、重复、重编号或改写其中的公式。
$fixedPageSection
# 输出格式
- Return one JSON object with exactly the requested paragraph keys, each mapped to its translated string. Optional glossary metadata is g; never add another paragraph key.''';
}

const translationResponseSchema = <String, dynamic>{
  'type': 'object',
  'properties': {
    'g': {
      'type': 'array',
      'items': {
        'type': 'object',
        'properties': {
          's': {'type': 'string'},
          't': {'type': 'string'},
        },
        'required': ['s', 't'],
        'additionalProperties': false,
      },
    },
  },
  'patternProperties': {
    r'^[0-9]+$': {'type': 'string', 'minLength': 1},
  },
  'additionalProperties': false,
};

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
  Future<Map<String, dynamic>> recognizeLayout({
    required AiProviderConfig provider,
    required String model,
    required String prompt,
    required Map<String, dynamic> input,
    required Map<String, dynamic> schema,
    List<Map<String, dynamic>> images = const [],
    String schemaName = 'ebook_semantic_groups',
    int? maxTokens,
    ReasoningEffort reasoningEffort = ReasoningEffort.defaultLevel,
    bool compact = false,
  }) async {
    final content = await LlmTransport(_client).generate(
      provider: provider,
      model: model,
      system: compact ? SemanticWire.instructions(prompt) : prompt,
      input: compact ? SemanticWire.convert(input) : input,
      images: images,
      schema: compact ? SemanticWire.schema(schema) : schema,
      schemaName: schemaName,
      maxTokens: maxTokens,
      effort: reasoningEffort,
    );
    final result = decodeLlmObject(content);
    return compact ? SemanticWire.convert(result, decode: true) : result;
  }

  static const _maxTranslationChars = 2000;
  static const _maxAttempts = 2;

  final http.Client _client;

  OpenAiCompatibleClient({http.Client? client})
    : _client = client ?? http.Client();

  void close() => _client.close();

  Future<List<String>> fetchModels(AiProviderConfig provider) async {
    return LlmTransport(_client).models(provider);
  }

  Future<List<BlockTranslation>> translateBlocks({
    required AiProviderConfig provider,
    required String model,
    required String targetLanguage,
    required List<TranslationBlockInput> blocks,
    ReasoningEffort reasoningEffort = ReasoningEffort.defaultLevel,
    TranslationGlossary? glossary,
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
          glossary: glossary,
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
    TranslationGlossary? glossary,
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
        final context = glossary == null ? '' : await glossary.prompt(blocks);
        final content = await LlmTransport(_client).generate(
          provider: provider,
          model: model,
          system:
              translationSystemPrompt(targetLanguage) +
              (glossary == null
                  ? '\nTerminology extraction is disabled.'
                  : TranslationGlossary.instructions),
          input:
              '${jsonEncode(input)}${context.isEmpty ? '' : '\n$context'}${lastError == null ? '' : '\nPrevious response failed validation: $lastError. Translate the original input again; preserve only existing source identities.'}',
          schema: translationResponseSchema,
          schemaName: 'translation',
          effort: reasoningEffort,
        );
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
        if (glossary != null) {
          await glossary.merge(content, blocks, translations);
        }
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
    if (provider.kind.requiresApiKey && provider.apiKey.trim().isEmpty) {
      throw const AiRequestException(
        'Configure the AI provider API Key first.',
      );
    }
    if (model.trim().isEmpty) {
      throw const AiRequestException('Select a translation model first.');
    }
    LlmTransport.endpoint(provider.baseUrl);
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
    final decoded = decodeLlmObject(content);
    if (decoded.keys.any(
      (key) => key != 'g' && !List.generate(count, (i) => '$i').contains(key),
    )) {
      throw const FormatException(
        'Translation returned an unrequested text block.',
      );
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
}

class AiRequestException implements Exception {
  final String message;

  const AiRequestException(this.message);

  @override
  String toString() => message;
}
