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

  const AiProviderEditPage({super.key, required this.provider});

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
  late final TextEditingController _models = TextEditingController(
    text: widget.provider.models.join(', '),
  );
  bool _loadingModels = false;

  @override
  void dispose() {
    _name.dispose();
    _baseUrl.dispose();
    _apiKey.dispose();
    _models.dispose();
    super.dispose();
  }

  AiProviderConfig get _value {
    final models = _models.text
        .split(RegExp(r'[,\n]'))
        .map((model) => model.trim())
        .where((model) => model.isNotEmpty)
        .toSet()
        .toList();
    return widget.provider.copyWith(
      kind: _kind,
      name: _name.text.trim(),
      baseUrl: _baseUrl.text.trim(),
      apiKey: _apiKey.text.trim(),
      models: models.isEmpty ? const ['gpt-4o-mini'] : models,
    );
  }

  Future<void> _fetchModels() async {
    setState(() => _loadingModels = true);
    final client = OpenAiCompatibleClient();
    try {
      final models = await client.fetchModels(_value);
      if (!mounted) return;
      setState(() => _models.text = models.join(', '));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    } finally {
      client.close();
      if (mounted) setState(() => _loadingModels = false);
    }
  }

  void _selectKind(AiProviderKind? value) {
    if (value == null) return;
    final oldLabel = _kind.label;
    setState(() {
      _kind = value;
      final baseUrl = value.defaultBaseUrl;
      if (baseUrl != null) _baseUrl.text = baseUrl;
      if (_name.text.trim().isEmpty || _name.text == oldLabel) {
        _name.text = value.label;
      }
    });
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
          TextField(
            controller: _models,
            minLines: 1,
            maxLines: 4,
            decoration: InputDecoration(
              labelText: l10n.text('模型', 'Models'),
              helperText: l10n.text(
                '使用逗号分隔多个模型',
                'Separate models with commas',
              ),
              suffixIcon: _loadingModels
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : IconButton(
                      icon: const Icon(Icons.refresh),
                      tooltip: l10n.text('从接口获取模型', 'Fetch models'),
                      onPressed: _fetchModels,
                    ),
            ),
          ),
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
