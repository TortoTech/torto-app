import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'ai_models.dart';
import 'search_capabilities.dart';

enum SearchService {
  tavily,
  brave,
  exa,
  searxng;

  String get label => switch (this) {
    tavily => 'Tavily',
    brave => 'Brave Search',
    exa => 'Exa',
    searxng => 'SearXNG',
  };
  String get defaultEndpoint => switch (this) {
    tavily => 'https://api.tavily.com/search',
    brave => 'https://api.search.brave.com/res/v1/web/search',
    exa => 'https://api.exa.ai/search',
    searxng => '',
  };
}

enum SearchMode { auto, native, external }

class SearchServiceConfig {
  final String endpoint, apiKey;
  const SearchServiceConfig({this.endpoint = '', this.apiKey = ''});
}

class AssistantSettings {
  final String providerId, model, selectionModel, _searchEndpoint, _searchKey;
  final bool webSearch, officialSearch;
  final SearchMode searchMode;
  final SearchService searchService;
  final Map<SearchService, SearchServiceConfig> services;
  final int maxToolSteps, historyTurns;
  final ReasoningEffort reasoningEffort;
  const AssistantSettings({
    this.providerId = '',
    this.model = '',
    this.webSearch = false,
    this.officialSearch = true,
    this.searchMode = SearchMode.auto,
    this.searchService = SearchService.tavily,
    String searchEndpoint = '',
    String searchKey = '',
    this.services = const {},
    this.selectionModel = '',
    this.maxToolSteps = 24,
    this.historyTurns = 10,
    this.reasoningEffort = ReasoningEffort.defaultLevel,
  }) : _searchEndpoint = searchEndpoint,
       _searchKey = searchKey;
  String get searchEndpoint =>
      services[searchService]?.endpoint ?? _searchEndpoint;
  String get searchKey => services[searchService]?.apiKey ?? _searchKey;
  String get endpoint => searchEndpoint.trim().isEmpty
      ? searchService.defaultEndpoint
      : searchEndpoint.trim();
  bool get hasExternal =>
      endpoint.isNotEmpty &&
      (searchService == SearchService.searxng || searchKey.isNotEmpty);
  Map<SearchService, SearchServiceConfig> get configurations => {
    ...services,
    searchService: SearchServiceConfig(endpoint: endpoint, apiKey: searchKey),
  };
  AiProviderConfig? provider(AiSettings settings) => settings.provider(
    providerId.isEmpty ? settings.translation.providerId : providerId,
  );
  String resolvedModel(AiSettings settings) =>
      model.isEmpty ? settings.translation.model : model;
  SearchMode resolvedMode(AiProviderConfig? provider, String model) =>
      provider == null ||
          !SearchCapabilities.supports(provider, model) ||
          (!officialSearch && searchMode == SearchMode.auto)
      ? SearchMode.external
      : searchMode == SearchMode.auto
      ? SearchMode.native
      : searchMode;
  AssistantSettings prepareModel(AiProviderConfig? provider, String model) {
    final identity = '${provider?.id}|$model';
    return identity == selectionModel
        ? this
        : copyWith(
            selectionModel: identity,
            reasoningEffort:
                SearchCapabilities.reasoningLevels(
                  provider,
                  model,
                ).contains(reasoningEffort)
                ? reasoningEffort
                : ReasoningEffort.defaultLevel,
            searchMode:
                selectionModel.isEmpty && searchMode == SearchMode.external
                ? SearchMode.external
                : provider != null &&
                      SearchCapabilities.supports(provider, model)
                ? SearchMode.native
                : SearchMode.external,
          );
  }

  AssistantSettings withService(
    SearchService service, {
    String? endpoint,
    String? apiKey,
  }) {
    final records = configurations,
        old =
            configurations[service] ??
            SearchServiceConfig(endpoint: service.defaultEndpoint);
    records[service] = SearchServiceConfig(
      endpoint: endpoint ?? old.endpoint,
      apiKey: apiKey ?? old.apiKey,
    );
    return copyWith(services: records, searchService: service);
  }

  AssistantSettings copyWith({
    String? providerId,
    String? model,
    String? selectionModel,
    bool? webSearch,
    SearchMode? searchMode,
    SearchService? searchService,
    Map<SearchService, SearchServiceConfig>? services,
    int? maxToolSteps,
    int? historyTurns,
    ReasoningEffort? reasoningEffort,
  }) => AssistantSettings(
    providerId: providerId ?? this.providerId,
    model: model ?? this.model,
    selectionModel: selectionModel ?? this.selectionModel,
    webSearch: webSearch ?? this.webSearch,
    officialSearch: officialSearch,
    searchMode: searchMode ?? this.searchMode,
    searchService: searchService ?? this.searchService,
    services: services ?? configurations,
    maxToolSteps: (maxToolSteps ?? this.maxToolSteps).clamp(1, 24),
    historyTurns: (historyTurns ?? this.historyTurns).clamp(1, 50),
    reasoningEffort: reasoningEffort ?? this.reasoningEffort,
  );
  Map<String, dynamic> toJson() => {
    'version': 2,
    'provider_id': providerId,
    'model': model,
    'web_search': webSearch,
    'official_search': officialSearch,
    'search_mode': searchMode.name,
    'search_service': searchService.name,
    'selection_model': selectionModel,
    'max_tool_steps': maxToolSteps,
    'history_turns': historyTurns,
    'reasoning_effort': reasoningEffort.name,
    'services': {
      for (final entry in configurations.entries)
        entry.key.name: {'endpoint': entry.value.endpoint},
    },
  };
  factory AssistantSettings.fromJson(
    Map json, {
    String key = '',
    Map<String, String> keys = const {},
  }) {
    final found = SearchService.values
        .where((v) => v.name == json['search_service'])
        .firstOrNull;
    final removed = json['search_service'] != null && found == null,
        selected = found ?? SearchService.tavily;
    final records = <SearchService, SearchServiceConfig>{};
    if (json['services'] is Map) {
      for (final item in (json['services'] as Map).entries) {
        final kind = SearchService.values
            .where((v) => v.name == item.key)
            .firstOrNull;
        if (kind != null && item.value is Map) {
          records[kind] = SearchServiceConfig(
            endpoint: item.value['endpoint'] as String? ?? kind.defaultEndpoint,
            apiKey: keys[kind.name] ?? '',
          );
        }
      }
    }
    if (!records.containsKey(selected)) {
      records[selected] = SearchServiceConfig(
        endpoint: removed
            ? selected.defaultEndpoint
            : json['search_endpoint'] as String? ?? selected.defaultEndpoint,
        apiKey: removed ? '' : keys[selected.name] ?? key,
      );
    }
    return AssistantSettings(
      providerId: json['provider_id'] as String? ?? '',
      model: json['model'] as String? ?? '',
      webSearch: json['web_search'] == true,
      officialSearch: json['official_search'] != false,
      searchMode:
          SearchMode.values
              .where((v) => v.name == json['search_mode'])
              .firstOrNull ??
          (json['official_search'] == false
              ? SearchMode.external
              : SearchMode.auto),
      searchService: selected,
      services: records,
      selectionModel: json['selection_model'] as String? ?? '',
      maxToolSteps: ((json['max_tool_steps'] as num?)?.toInt() ?? 24).clamp(
        1,
        24,
      ),
      historyTurns: ((json['history_turns'] as num?)?.toInt() ?? 10).clamp(
        1,
        50,
      ),
      reasoningEffort:
          ReasoningEffort.values
              .where((v) => v.name == json['reasoning_effort'])
              .firstOrNull ??
          ReasoningEffort.defaultLevel,
    );
  }
}

class AssistantSettingsStore {
  final FlutterSecureStorage secure;
  const AssistantSettingsStore({this.secure = const FlutterSecureStorage()});
  Future<AssistantSettings> load() async {
    final prefs = await SharedPreferences.getInstance(),
        keys = <String, String>{};
    for (final kind in SearchService.values) {
      try {
        keys[kind.name] =
            await secure.read(
              key: 'assistant_search_api_key_v2_${kind.name}',
            ) ??
            '';
      } catch (_) {}
    }
    try {
      final raw = prefs.getString('assistant_settings_v2');
      if (raw != null) {
        return AssistantSettings.fromJson(jsonDecode(raw) as Map, keys: keys);
      }
      final legacy = prefs.getString('assistant_settings_v1');
      if (legacy == null) return const AssistantSettings();
      final key = await secure.read(key: 'assistant_search_api_key_v1') ?? '';
      final migrated = AssistantSettings.fromJson(
        jsonDecode(legacy) as Map,
        key: key,
      );
      try {
        await save(migrated);
      } catch (_) {
        // Keep the usable legacy configuration if secure migration is unavailable.
      }
      return migrated;
    } catch (_) {
      return const AssistantSettings();
    }
  }

  Future<void> save(AssistantSettings settings) async {
    for (final entry in settings.configurations.entries) {
      final key = 'assistant_search_api_key_v2_${entry.key.name}';
      if (entry.value.apiKey.isEmpty) {
        await secure.delete(key: key);
      } else {
        await secure.write(key: key, value: entry.value.apiKey);
      }
    }
    await (await SharedPreferences.getInstance()).setString(
      'assistant_settings_v2',
      jsonEncode(settings.toJson()),
    );
  }
}
