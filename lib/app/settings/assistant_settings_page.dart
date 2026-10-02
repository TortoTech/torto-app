import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../ai/ai_models.dart';
import '../ai/ai_settings_store.dart';
import '../ai/assistant_settings.dart';
import '../ai/search_capabilities.dart';

class AssistantSettingsPage extends StatefulWidget {
  const AssistantSettingsPage({super.key});
  @override
  State<AssistantSettingsPage> createState() => _AssistantSettingsPageState();
}

class _AssistantSettingsPageState extends State<AssistantSettingsPage> {
  final _store = const AssistantSettingsStore();
  AiSettings? _ai;
  AssistantSettings? _settings;
  final _endpoint = TextEditingController(), _key = TextEditingController();
  bool _saving = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final ai = await AiSettingsStore().load(), settings = await _store.load();
    if (!mounted) return;
    _endpoint.text = settings.endpoint;
    _key.text = settings.searchKey;
    setState(() {
      _ai = ai;
      _settings = settings.prepareModel(
        settings.provider(ai),
        settings.resolvedModel(ai),
      );
    });
  }

  @override
  void dispose() {
    _endpoint.dispose();
    _key.dispose();
    super.dispose();
  }

  void _stash() {
    _settings = _settings!.withService(
      _settings!.searchService,
      endpoint: _endpoint.text.trim(),
      apiKey: _key.text.trim(),
    );
  }

  void _update(Map<String, dynamic> changes) => setState(() {
    _stash();
    _settings = _settings!.copyWith(
      providerId: changes['provider_id'],
      model: changes['model'],
      webSearch: changes['web_search'],
    );
    _settings = _settings!.prepareModel(
      _settings!.provider(_ai!),
      _settings!.resolvedModel(_ai!),
    );
  });
  void _selectSearch(String value) => setState(() {
    _stash();
    if (value == 'official') {
      _settings = _settings!.copyWith(searchMode: SearchMode.native);
    } else {
      _settings = _settings!
          .withService(SearchService.values.byName(value))
          .copyWith(searchMode: SearchMode.external);
    }
    _endpoint.text = _settings!.endpoint;
    _key.text = _settings!.searchKey;
  });
  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      _stash();
      await _store.save(_settings!);
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.l10n.text('保存失败，请重试', 'Save failed. Try again.'),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n, settings = _settings, ai = _ai;
    final models = <String, String>{
      if (ai != null)
        for (final p in ai.providers)
          for (final m in p.models) '${p.id}|$m': '${p.name} · $m',
    };
    final chosen = settings == null || ai == null
        ? ''
        : '${settings.provider(ai)?.id}|${settings.resolvedModel(ai)}';
    return Scaffold(
      appBar: AppBar(
        title: Text(l.text('阅读助手', 'Reading assistant')),
        actions: [
          TextButton(
            onPressed: settings == null || _saving ? null : _save,
            child: Text(l.text('保存', 'Save')),
          ),
        ],
      ),
      body: settings == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                DropdownButtonFormField<String>(
                  initialValue: models.containsKey(chosen) ? chosen : null,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: l.text(
                      '对话 / PDF 识别模型',
                      'Chat / PDF discovery model',
                    ),
                  ),
                  items: [
                    for (final entry in models.entries)
                      DropdownMenuItem(
                        value: entry.key,
                        child: Text(
                          entry.value,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    final split = value.indexOf('|');
                    _update({
                      'provider_id': value.substring(0, split),
                      'model': value.substring(split + 1),
                    });
                  },
                ),
                DropdownButtonFormField<ReasoningEffort>(
                  key: ValueKey('assistant-effort-$chosen'),
                  initialValue: settings.reasoningEffort,
                  decoration: InputDecoration(
                    labelText: l.text('思考等级', 'Reasoning effort'),
                  ),
                  items: [
                    for (final effort in SearchCapabilities.reasoningLevels(
                      settings.provider(ai!),
                      settings.resolvedModel(ai),
                    ))
                      DropdownMenuItem(
                        value: effort,
                        child: Text(effort.label),
                      ),
                  ],
                  onChanged: (effort) {
                    if (effort != null) {
                      setState(
                        () => _settings = _settings!.copyWith(
                          reasoningEffort: effort,
                        ),
                      );
                    }
                  },
                ),
                ListTile(
                  title: Text(l.text('工具调用轮数', 'Tool call steps')),
                  subtitle: Slider(
                    min: 1,
                    max: 24,
                    divisions: 23,
                    value: settings.maxToolSteps.toDouble(),
                    label: settings.maxToolSteps.toString(),
                    onChanged: (v) => setState(
                      () => _settings = _settings!.copyWith(
                        maxToolSteps: v.round(),
                      ),
                    ),
                  ),
                ),
                ListTile(
                  title: Text(l.text('历史记录轮数', 'History turns')),
                  subtitle: Slider(
                    min: 1,
                    max: 50,
                    divisions: 49,
                    value: settings.historyTurns.toDouble(),
                    label: settings.historyTurns.toString(),
                    onChanged: (v) => setState(
                      () => _settings = _settings!.copyWith(
                        historyTurns: v.round(),
                      ),
                    ),
                  ),
                ),
                SwitchListTile(
                  title: Text(l.text('联网搜索', 'Web search')),
                  value: settings.webSearch,
                  onChanged: (v) => _update({'web_search': v}),
                ),
                if (settings.webSearch) ...[
                  DropdownButtonFormField<String>(
                    key: ValueKey(
                      'search-mode-$chosen-${settings.resolvedMode(settings.provider(ai), settings.resolvedModel(ai)).name}-${settings.searchService.name}',
                    ),
                    initialValue:
                        settings.resolvedMode(
                              settings.provider(ai),
                              settings.resolvedModel(ai),
                            ) ==
                            SearchMode.native
                        ? 'official'
                        : settings.searchService.name,
                    decoration: InputDecoration(
                      labelText: l.text('搜索提供商', 'Search provider'),
                    ),
                    items: [
                      if (settings.provider(ai) case final provider?
                          when SearchCapabilities.supports(
                            provider,
                            settings.resolvedModel(ai),
                          ))
                        DropdownMenuItem(
                          value: 'official',
                          child: Text(l.text('官方服务', 'Official service')),
                        ),
                      for (final kind in SearchService.values)
                        DropdownMenuItem(
                          value: kind.name,
                          child: Text(kind.label),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) _selectSearch(value);
                    },
                  ),
                  if (settings.resolvedMode(
                        settings.provider(ai),
                        settings.resolvedModel(ai),
                      ) ==
                      SearchMode.external) ...[
                    const SizedBox(height: 16),
                    TextField(
                      controller: _endpoint,
                      decoration: InputDecoration(
                        labelText: l.text('搜索服务地址', 'Search endpoint'),
                        helperText:
                            settings.searchService == SearchService.searxng
                            ? l.text(
                                '填写支持 JSON 的 SearXNG 实例',
                                'Enter a SearXNG endpoint with JSON enabled',
                              )
                            : null,
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _key,
                      obscureText: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: const InputDecoration(
                        labelText: 'Search API key',
                      ),
                    ),
                  ],
                ],
                const SizedBox(height: 16),
              ],
            ),
    );
  }
}
