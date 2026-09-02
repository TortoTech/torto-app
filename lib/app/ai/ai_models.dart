import '../../core/translation/translation_models.dart';

enum AiProviderKind { custom, openAi, deepSeek, openRouter, siliconFlow }

extension AiProviderKindDetails on AiProviderKind {
  String get label => switch (this) {
    AiProviderKind.custom => 'Custom',
    AiProviderKind.openAi => 'OpenAI',
    AiProviderKind.deepSeek => 'DeepSeek',
    AiProviderKind.openRouter => 'OpenRouter',
    AiProviderKind.siliconFlow => 'SiliconFlow',
  };

  String? get defaultBaseUrl => switch (this) {
    AiProviderKind.custom => null,
    AiProviderKind.openAi => 'https://api.openai.com/v1',
    AiProviderKind.deepSeek => 'https://api.deepseek.com',
    AiProviderKind.openRouter => 'https://openrouter.ai/api/v1',
    AiProviderKind.siliconFlow => 'https://api.siliconflow.cn/v1',
  };
}

class AiProviderConfig {
  final String id;
  final AiProviderKind kind;
  final String name;
  final String baseUrl;
  final List<String> models;
  final String apiKey;

  const AiProviderConfig({
    required this.id,
    this.kind = AiProviderKind.custom,
    required this.name,
    this.baseUrl = '',
    this.models = const ['gpt-4o-mini'],
    this.apiKey = '',
  });

  AiProviderConfig copyWith({
    String? id,
    AiProviderKind? kind,
    String? name,
    String? baseUrl,
    List<String>? models,
    String? apiKey,
  }) => AiProviderConfig(
    id: id ?? this.id,
    kind: kind ?? this.kind,
    name: name ?? this.name,
    baseUrl: baseUrl ?? this.baseUrl,
    models: models ?? this.models,
    apiKey: apiKey ?? this.apiKey,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind.name,
    'name': name,
    'base_url': baseUrl,
    'models': models,
  };

  factory AiProviderConfig.fromJson(Map<String, dynamic> json) {
    final kindName = json['kind'] as String? ?? '';
    final kind = AiProviderKind.values.firstWhere(
      (candidate) => candidate.name == kindName,
      orElse: () => AiProviderKind.custom,
    );
    final models = <String>[
      if (json['models'] is List)
        for (final value in (json['models'] as List).whereType<String>())
          if (value.trim().isNotEmpty) value.trim(),
    ];
    return AiProviderConfig(
      id: json['id'] as String? ?? '',
      kind: kind,
      name: json['name'] as String? ?? kind.label,
      baseUrl: json['base_url'] as String? ?? kind.defaultBaseUrl ?? '',
      models: models.isEmpty ? const ['gpt-4o-mini'] : models,
    );
  }
}

enum TranslationTarget { system, simplifiedChinese, english }

enum ReasoningEffort { defaultLevel, none, minimal, low, medium, high }

extension ReasoningEffortDetails on ReasoningEffort {
  String get label => switch (this) {
    ReasoningEffort.defaultLevel => 'default',
    ReasoningEffort.none => 'none',
    ReasoningEffort.minimal => 'minimal',
    ReasoningEffort.low => 'low',
    ReasoningEffort.medium => 'medium',
    ReasoningEffort.high => 'high',
  };

  String? get apiValue => switch (this) {
    ReasoningEffort.defaultLevel => null,
    _ => label,
  };
}

class TranslationSettings {
  final String providerId;
  final String model;
  final TranslationTarget target;
  final TranslationMode mode;
  final bool translateToc;
  final ReasoningEffort reasoningEffort;

  const TranslationSettings({
    this.providerId = 'provider-1',
    this.model = 'gpt-4o-mini',
    this.target = TranslationTarget.system,
    this.mode = TranslationMode.replace,
    this.translateToc = true,
    this.reasoningEffort = ReasoningEffort.defaultLevel,
  });

  TranslationSettings copyWith({
    String? providerId,
    String? model,
    TranslationTarget? target,
    TranslationMode? mode,
    bool? translateToc,
    ReasoningEffort? reasoningEffort,
  }) => TranslationSettings(
    providerId: providerId ?? this.providerId,
    model: model ?? this.model,
    target: target ?? this.target,
    mode: mode ?? this.mode,
    translateToc: translateToc ?? this.translateToc,
    reasoningEffort: reasoningEffort ?? this.reasoningEffort,
  );

  Map<String, dynamic> toJson() => {
    'provider_id': providerId,
    'model': model,
    'target': target.name,
    'mode': mode.name,
    'translate_toc': translateToc,
    'reasoning_effort': reasoningEffort.label,
  };

  factory TranslationSettings.fromJson(Map<String, dynamic> json) =>
      TranslationSettings(
        providerId: json['provider_id'] as String? ?? 'provider-1',
        model: json['model'] as String? ?? 'gpt-4o-mini',
        target: TranslationTarget.values.firstWhere(
          (candidate) => candidate.name == json['target'],
          orElse: () => TranslationTarget.system,
        ),
        mode: TranslationMode.values.firstWhere(
          (candidate) => candidate.name == json['mode'],
          orElse: () => TranslationMode.replace,
        ),
        translateToc: json['translate_toc'] as bool? ?? true,
        reasoningEffort: ReasoningEffort.values.firstWhere(
          (candidate) => candidate.label == json['reasoning_effort'],
          orElse: () => ReasoningEffort.defaultLevel,
        ),
      );
}

class AiSettings {
  final List<AiProviderConfig> providers;
  final TranslationSettings translation;

  const AiSettings({required this.providers, required this.translation});

  factory AiSettings.defaults() => const AiSettings(
    providers: [AiProviderConfig(id: 'provider-1', name: 'Custom')],
    translation: TranslationSettings(),
  );

  AiSettings copyWith({
    List<AiProviderConfig>? providers,
    TranslationSettings? translation,
  }) => AiSettings(
    providers: providers ?? this.providers,
    translation: translation ?? this.translation,
  );

  AiProviderConfig? provider(String id) {
    for (final provider in providers) {
      if (provider.id == id) return provider;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
    'version': 2,
    'providers': providers.map((provider) => provider.toJson()).toList(),
    'translation': translation.toJson(),
  };

  factory AiSettings.fromJson(Map<String, dynamic> json) {
    final providers = <AiProviderConfig>[
      if (json['providers'] is List)
        for (final value in (json['providers'] as List).whereType<Map>())
          AiProviderConfig.fromJson(Map<String, dynamic>.from(value)),
    ];
    final translation = json['translation'] is Map
        ? TranslationSettings.fromJson(
            Map<String, dynamic>.from(json['translation'] as Map),
          )
        : const TranslationSettings();
    return AiSettings(
      providers: providers.isEmpty
          ? AiSettings.defaults().providers
          : providers,
      translation: translation,
    ).normalized();
  }

  AiSettings normalized() {
    final normalizedProviders = <AiProviderConfig>[];
    final ids = <String>{};
    for (var index = 0; index < providers.length; index++) {
      final provider = providers[index];
      var id = provider.id.trim().isEmpty
          ? 'provider-${index + 1}'
          : provider.id;
      while (!ids.add(id)) {
        id = '$id-';
      }
      final models =
          provider.models
              .map((model) => model.trim())
              .where((model) => model.isNotEmpty)
              .toSet()
              .toList()
            ..sort();
      normalizedProviders.add(
        provider.copyWith(
          id: id,
          name: provider.name.trim().isEmpty
              ? provider.kind.label
              : provider.name.trim(),
          baseUrl: provider.baseUrl.trim(),
          models: models.isEmpty ? const ['gpt-4o-mini'] : models,
        ),
      );
    }
    final selected =
        normalizedProviders.any(
          (provider) => provider.id == translation.providerId,
        )
        ? translation.providerId
        : normalizedProviders.first.id;
    final provider = normalizedProviders.firstWhere(
      (candidate) => candidate.id == selected,
    );
    final model = provider.models.contains(translation.model)
        ? translation.model
        : provider.models.first;
    return AiSettings(
      providers: normalizedProviders,
      translation: translation.copyWith(providerId: selected, model: model),
    );
  }
}

String resolvedTranslationTarget(
  TranslationTarget target,
  String systemLanguageCode,
) => switch (target) {
  TranslationTarget.system =>
    systemLanguageCode.toLowerCase() == 'zh' ? '简体中文' : 'English',
  TranslationTarget.simplifiedChinese => '简体中文',
  TranslationTarget.english => 'English',
};
