import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'ai_models.dart';

/// Desktop provider/model matrix; configuration is distinct from transient failures.
class SearchCapabilities {
  static List<ReasoningEffort> reasoningLevels(
    AiProviderConfig? provider,
    String model,
  ) {
    const d = ReasoningEffort.defaultLevel,
        n = ReasoningEffort.none,
        l = ReasoningEffort.low,
        m = ReasoningEffort.medium,
        h = ReasoningEffort.high,
        x = ReasoningEffort.max;
    return switch (provider?.kind) {
      AiProviderKind.miniMax => [d],
      AiProviderKind.deepSeek => [d, n, l, h, x],
      AiProviderKind.ollama || AiProviderKind.moonshot => [d, n, h],
      AiProviderKind.gemini when model.contains('gemini-3') => [d, l, h],
      AiProviderKind.gemini when model.contains('pro') => [d, l, m, h],
      AiProviderKind.openAi when model.startsWith('gpt-4') => [d],
      _ => ReasoningEffort.values,
    };
  }

  static bool supports(AiProviderConfig provider, String model) {
    final m = model.trim().split('/').last.toLowerCase();
    if (m.isEmpty) return false;
    return switch (provider.kind) {
      AiProviderKind.openAi =>
        !(m.startsWith('gpt-4o') ||
            m == 'gpt-4' ||
            m.startsWith('gpt-4-') ||
            m.startsWith('gpt-4-turbo') ||
            m.startsWith('gpt-3') ||
            m.startsWith('o1') ||
            m.startsWith('o3-mini')),
      AiProviderKind.gemini => m.startsWith('gemini-3'),
      AiProviderKind.anthropic ||
      AiProviderKind.xai ||
      AiProviderKind.openRouter ||
      AiProviderKind.zai ||
      AiProviderKind.moonshot ||
      AiProviderKind.mistral => true,
      _ => false,
    };
  }

  static final Map<String, DateTime> _unsupported = {};
  static String _key(AiProviderConfig provider, String model) => sha256
      .convert(
        utf8.encode(
          jsonEncode([
            provider.kind.name,
            provider.baseUrl,
            provider.apiKey,
            model,
          ]),
        ),
      )
      .toString();
  static bool unavailable(AiProviderConfig provider, String model) {
    final time = _unsupported[_key(provider, model)];
    return time != null &&
        DateTime.now().difference(time) < const Duration(hours: 1);
  }

  static void remember(AiProviderConfig provider, String model) {
    if (_unsupported.length >= 256) _unsupported.clear();
    _unsupported[_key(provider, model)] = DateTime.now();
  }

  static bool capabilityError(int status, String message) {
    if (const {401, 403, 429}.contains(status) ||
        RegExp(
          r'timeout|timed out|unauthorized|invalid api key',
          caseSensitive: false,
        ).hasMatch(message)) {
      return false;
    }
    if (status == 404 || status == 405) return true;
    return RegExp(
          r'unsupported|not supported|does not support|not enabled|invalid tool|unknown tool|not available',
          caseSensitive: false,
        ).hasMatch(message) &&
        RegExp(
          r'web_search|google.?search|grounding|builtin_function|search tool|search is not enabled|tools are not supported|does not support tools',
          caseSensitive: false,
        ).hasMatch(message);
  }
}
