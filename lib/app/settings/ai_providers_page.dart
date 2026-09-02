import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../ai/ai_models.dart';
import '../ai/ai_settings_store.dart';
import '../ai/openai_compatible_client.dart';

class AiProvidersPage extends StatefulWidget {
  final AiSettingsStore? store;

  const AiProvidersPage({super.key, this.store});

  @override
  State<AiProvidersPage> createState() => _AiProvidersPageState();
}

class _AiProvidersPageState extends State<AiProvidersPage> {
  late final AiSettingsStore _store = widget.store ?? AiSettingsStore();
  AiSettings? _settings;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final settings = await _store.load();
    if (mounted) setState(() => _settings = settings);
  }

  Future<void> _edit(int index) async {
    final settings = _settings!;
    final provider = await Navigator.of(context).push<AiProviderConfig>(
      MaterialPageRoute(
        builder: (_) => AiProviderEditPage(provider: settings.providers[index]),
      ),
    );
    if (provider == null) return;
    final providers = [...settings.providers]..[index] = provider;
    final next = settings.copyWith(providers: providers).normalized();
    await _store.save(next);
    if (mounted) setState(() => _settings = next);
  }

  Future<void> _add() async {
    final settings = _settings!;
    var suffix = settings.providers.length + 1;
    while (settings.providers.any(
      (provider) => provider.id == 'provider-$suffix',
    )) {
      suffix++;
    }
    final provider = await Navigator.of(context).push<AiProviderConfig>(
      MaterialPageRoute(
        builder: (_) => AiProviderEditPage(
          provider: AiProviderConfig(
            id: 'provider-$suffix',
            name: 'Custom $suffix',
          ),
        ),
      ),
    );
    if (provider == null) return;
    final next = settings
        .copyWith(providers: [...settings.providers, provider])
        .normalized();
    await _store.save(next);
    if (mounted) setState(() => _settings = next);
  }

  Future<void> _remove(int index) async {
    final settings = _settings!;
    if (settings.providers.length <= 1) return;
    final provider = settings.providers[index];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.text('删除 AI 提供商？', 'Remove AI provider?')),
        content: Text(provider.name),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.text('取消', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.text('删除', 'Remove')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final providers = [...settings.providers]..removeAt(index);
    final next = settings.copyWith(providers: providers).normalized();
    await _store.deleteProviderSecret(provider.id);
    await _store.save(next);
    if (mounted) setState(() => _settings = next);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final settings = _settings;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.text('AI 提供商', 'AI providers')),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: l10n.text('添加提供商', 'Add provider'),
            onPressed: settings == null ? null : _add,
          ),
        ],
      ),
      body: settings == null
          ? const Center(child: CircularProgressIndicator())
          : ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 12),
              itemCount: settings.providers.length,
              separatorBuilder: (_, _) => const Divider(indent: 72),
              itemBuilder: (context, index) {
                final provider = settings.providers[index];
                return ListTile(
                  leading: const Icon(Icons.dns_outlined),
                  title: Text(provider.name),
                  subtitle: Text(
                    '${provider.kind.label} · ${provider.models.length} ${l10n.text('个模型', 'models')}',
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (settings.providers.length > 1)
                        IconButton(
                          icon: const Icon(Icons.delete_outline),
                          tooltip: l10n.text('删除', 'Remove'),
                          onPressed: () => _remove(index),
                        ),
                      const Icon(Icons.chevron_right),
                    ],
                  ),
                  onTap: () => _edit(index),
                );
              },
            ),
    );
  }
}

class AiProviderEditPage extends StatefulWidget {
  final AiProviderConfig provider;
  final OpenAiCompatibleClient? client;

  const AiProviderEditPage({super.key, required this.provider, this.client});

  @override
  State<AiProviderEditPage> createState() => _AiProviderEditPageState();
}

class _AiProviderEditPageState extends State<AiProviderEditPage> {
  late AiProviderKind _kind = widget.provider.kind;
  late final TextEditingController _name = TextEditingController(
    text: widget.provider.name,
  );
  late final TextEditingController _baseUrl = TextEditingController(
    text: widget.provider.baseUrl,
  );
  late final TextEditingController _apiKey = TextEditingController(
    text: widget.provider.apiKey,
  );
  late final OpenAiCompatibleClient _client =
      widget.client ?? OpenAiCompatibleClient();
  late final bool _ownsClient = widget.client == null;
  late final List<String> _selectedModels = [...widget.provider.models];
  List<String> _availableModels = const [];
  bool _loadingModels = false;
  String? _modelsError;
  Timer? _modelFetchDebounce;
  int _modelFetchGeneration = 0;

  @override
  void initState() {
    super.initState();
    _baseUrl.addListener(_onProviderEndpointChanged);
    _apiKey.addListener(_onProviderEndpointChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scheduleModelFetch(immediate: true);
    });
  }

  @override
  void dispose() {
    _modelFetchDebounce?.cancel();
    _baseUrl.removeListener(_onProviderEndpointChanged);
    _apiKey.removeListener(_onProviderEndpointChanged);
    _name.dispose();
    _baseUrl.dispose();
    _apiKey.dispose();
    if (_ownsClient) _client.close();
    super.dispose();
  }

  AiProviderConfig get _value {
    final models = _selectedModels.toSet().toList()
      ..sort(
        (left, right) => left.toLowerCase().compareTo(right.toLowerCase()),
      );
    return widget.provider.copyWith(
      kind: _kind,
      name: _name.text.trim(),
      baseUrl: _baseUrl.text.trim(),
      apiKey: _apiKey.text.trim(),
      models: models.isEmpty ? const ['gpt-4o-mini'] : models,
    );
  }

  void _onProviderEndpointChanged() => _scheduleModelFetch();

  void _scheduleModelFetch({bool immediate = false}) {
    _modelFetchDebounce?.cancel();
    final generation = ++_modelFetchGeneration;
    final hasUrl = _baseUrl.text.trim().isNotEmpty;
    setState(() {
      _modelsError = null;
      _availableModels = const [];
      if (!hasUrl) {
        _loadingModels = false;
      }
    });
    if (!hasUrl) return;
    if (immediate) {
      unawaited(_fetchModels(generation));
    } else {
      _modelFetchDebounce = Timer(
        const Duration(milliseconds: 500),
        () => unawaited(_fetchModels(generation)),
      );
    }
  }

  void _refreshModels() {
    _modelFetchDebounce?.cancel();
    final generation = ++_modelFetchGeneration;
    unawaited(_fetchModels(generation));
  }

  Future<void> _fetchModels(int generation) async {
    if (_baseUrl.text.trim().isEmpty) return;
    if (mounted) {
      setState(() {
        _loadingModels = true;
        _modelsError = null;
      });
    }
    try {
      final models = await _client.fetchModels(_value);
      if (!mounted || generation != _modelFetchGeneration) return;
      setState(() => _availableModels = models);
    } catch (error) {
      if (!mounted || generation != _modelFetchGeneration) return;
      setState(() => _modelsError = error.toString());
    } finally {
      if (mounted && generation == _modelFetchGeneration) {
        setState(() => _loadingModels = false);
      }
    }
  }

  void _selectKind(AiProviderKind? value) {
    if (value == null) return;
    final oldLabel = _kind.label;
    final baseUrl = value.defaultBaseUrl;
    setState(() {
      _kind = value;
      if (_name.text.trim().isEmpty || _name.text == oldLabel) {
        _name.text = value.label;
      }
    });
    if (baseUrl != null && _baseUrl.text != baseUrl) {
      _baseUrl.text = baseUrl;
    } else {
      _scheduleModelFetch();
    }
  }

  List<String> get _modelOptions {
    final values = <String>{..._availableModels, ..._selectedModels}.toList();
    values.sort(
      (left, right) => left.toLowerCase().compareTo(right.toLowerCase()),
    );
    return values;
  }

  Future<void> _showModelSelector() async {
    final l10n = context.l10n;
    final search = TextEditingController();
    final custom = TextEditingController();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) {
          final query = search.text.trim().toLowerCase();
          final options = _modelOptions
              .where((model) => model.toLowerCase().contains(query))
              .toList(growable: false);

          void update(VoidCallback change) {
            if (!mounted) return;
            setState(change);
            setSheetState(() {});
          }

          void addCustomModel() {
            final model = custom.text.trim();
            if (model.isEmpty) return;
            update(() {
              if (!_availableModels.contains(model)) {
                _availableModels = [..._availableModels, model];
              }
              if (!_selectedModels.contains(model)) {
                _selectedModels.add(model);
              }
              custom.clear();
            });
          }

          return DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.72,
            minChildSize: 0.45,
            maxChildSize: 0.92,
            builder: (context, scrollController) => SafeArea(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            l10n.text('选择模型', 'Select models'),
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(sheetContext),
                          child: Text(l10n.text('完成', 'Done')),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: TextField(
                      controller: search,
                      decoration: InputDecoration(
                        prefixIcon: const Icon(Icons.search),
                        hintText: l10n.text('搜索模型', 'Search models'),
                      ),
                      onChanged: (_) => setSheetState(() {}),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: custom,
                            decoration: InputDecoration(
                              hintText: l10n.text(
                                '手动添加模型 ID',
                                'Add a model ID manually',
                              ),
                            ),
                            onSubmitted: (_) => addCustomModel(),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.add),
                          tooltip: l10n.text('添加模型', 'Add model'),
                          onPressed: addCustomModel,
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: options.isEmpty
                        ? Center(
                            child: Text(
                              l10n.text('没有匹配的模型', 'No matching models'),
                            ),
                          )
                        : ListView.builder(
                            controller: scrollController,
                            itemCount: options.length,
                            itemBuilder: (context, index) {
                              final model = options[index];
                              final selected = _selectedModels.contains(model);
                              return CheckboxListTile(
                                value: selected,
                                title: Text(model),
                                controlAffinity:
                                    ListTileControlAffinity.leading,
                                onChanged:
                                    selected && _selectedModels.length == 1
                                    ? null
                                    : (_) => update(() {
                                        selected
                                            ? _selectedModels.remove(model)
                                            : _selectedModels.add(model);
                                      }),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    search.dispose();
    custom.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.text('编辑 AI 提供商', 'Edit AI provider')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, _value),
            child: Text(l10n.text('保存', 'Save')),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          DropdownButtonFormField<AiProviderKind>(
            initialValue: _kind,
            decoration: InputDecoration(
              labelText: l10n.text('提供商', 'Provider'),
            ),
            items: [
              for (final kind in AiProviderKind.values)
                DropdownMenuItem(value: kind, child: Text(kind.label)),
            ],
            onChanged: _selectKind,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            decoration: InputDecoration(labelText: l10n.text('名称', 'Name')),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _baseUrl,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'Base URL',
              hintText: 'https://api.openai.com/v1',
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _apiKey,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(labelText: 'API Key'),
          ),
          const SizedBox(height: 16),
          InkWell(
            borderRadius: BorderRadius.circular(4),
            onTap: _showModelSelector,
            child: InputDecorator(
              decoration: InputDecoration(
                labelText: l10n.text('模型', 'Models'),
                suffixIcon: _loadingModels
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : IconButton(
                        icon: const Icon(Icons.refresh),
                        tooltip: l10n.text('刷新模型', 'Refresh models'),
                        onPressed: _baseUrl.text.trim().isEmpty
                            ? null
                            : _refreshModels,
                      ),
              ),
              child: Text(
                _selectedModels.length == 1
                    ? _selectedModels.single
                    : l10n.text(
                        '已选择 ${_selectedModels.length} 个模型',
                        '${_selectedModels.length} models selected',
                      ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          if (_modelsError != null) ...[
            const SizedBox(height: 8),
            Text(
              _modelsError!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ],
          const SizedBox(height: 20),
          Text(
            l10n.text(
              '仅支持 OpenAI 兼容协议。API Key 只保存在本机安全存储中。',
              'Only OpenAI-compatible APIs are supported. The API Key stays in secure storage on this device.',
            ),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
