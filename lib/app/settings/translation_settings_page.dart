import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/translation/translation_models.dart';
import '../../l10n/app_localizations.dart';
import '../ai/ai_models.dart';
import '../ai/ai_settings_store.dart';

class TranslationSettingsPage extends StatefulWidget {
  final AiSettingsStore? store;

  const TranslationSettingsPage({super.key, this.store});

  @override
  State<TranslationSettingsPage> createState() =>
      _TranslationSettingsPageState();
}

class _TranslationSettingsPageState extends State<TranslationSettingsPage> {
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

  Future<void> _save() async {
    final settings = _settings;
    if (settings == null) return;
    await _store.save(settings);
    if (mounted) Navigator.pop(context);
  }

  void _update(TranslationSettings value) {
    setState(() => _settings = _settings!.copyWith(translation: value));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final settings = _settings;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.text('翻译', 'Translation')),
        actions: [
          TextButton(
            onPressed: settings == null ? null : _save,
            child: Text(l10n.text('保存', 'Save')),
          ),
        ],
      ),
      body: settings == null
          ? const Center(child: CircularProgressIndicator())
          : _content(context, settings),
    );
  }

  Widget _content(BuildContext context, AiSettings settings) {
    final l10n = context.l10n;
    final translation = settings.translation;
    final options = <String, String>{
      for (final provider in settings.providers)
        for (final model in provider.models)
          '${provider.id}\u0000$model': '${provider.name} · $model',
    };
    String? selected = '${translation.providerId}\u0000${translation.model}';
    if (!options.containsKey(selected)) selected = options.keys.firstOrNull;
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 12),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
          child: Text(
            l10n.text('翻译模型', 'Translation model'),
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: DropdownButtonFormField<String>(
            isExpanded: true,
            initialValue: selected,
            items: [
              for (final entry in options.entries)
                DropdownMenuItem(value: entry.key, child: Text(entry.value)),
            ],
            onChanged: (value) {
              if (value == null) return;
              final parts = value.split('\u0000');
              _update(
                translation.copyWith(providerId: parts[0], model: parts[1]),
              );
            },
          ),
        ),
        const Divider(indent: 16, endIndent: 16),
        ListTile(
          title: Text(l10n.text('思考等级', 'Reasoning effort')),
          trailing: DropdownButton<ReasoningEffort>(
            value: translation.reasoningEffort,
            items: [
              for (final effort in ReasoningEffort.values)
                DropdownMenuItem(
                  value: effort,
                  child: Text(
                    effort == ReasoningEffort.defaultLevel
                        ? l10n.text('默认', 'default')
                        : effort.label,
                  ),
                ),
            ],
            onChanged: (value) {
              if (value != null) {
                _update(translation.copyWith(reasoningEffort: value));
              }
            },
          ),
        ),
        ListTile(
          title: Text(l10n.text('翻译为', 'Translate to')),
          trailing: DropdownButton<TranslationTarget>(
            value: translation.target,
            items: [
              DropdownMenuItem(
                value: TranslationTarget.system,
                child: Text(l10n.text('跟随系统', 'Follow system')),
              ),
              const DropdownMenuItem(
                value: TranslationTarget.simplifiedChinese,
                child: Text('简体中文'),
              ),
              const DropdownMenuItem(
                value: TranslationTarget.english,
                child: Text('English'),
              ),
            ],
            onChanged: (value) {
              if (value != null) _update(translation.copyWith(target: value));
            },
          ),
        ),
        SwitchListTile(
          title: Text(l10n.text('显示原文', 'Show original text')),
          subtitle: Text(
            l10n.text('开启后使用双语对照', 'Use bilingual layout when enabled'),
          ),
          value: translation.mode == TranslationMode.bilingual,
          onChanged: (value) => _update(
            translation.copyWith(
              mode: value ? TranslationMode.bilingual : TranslationMode.replace,
            ),
          ),
        ),
        SwitchListTile(
          title: Text(l10n.text('翻译目录', 'Translate table of contents')),
          value: translation.translateToc,
          onChanged: (value) =>
              _update(translation.copyWith(translateToc: value)),
        ),
        SwitchListTile(
          title: Text(l10n.text('专家翻译', 'Expert translation')),
          subtitle: Text(
            l10n.text(
              '按书籍和语言记忆术语，保持后续译文一致',
              'Remember terminology per book and language for consistent translations',
            ),
          ),
          value: translation.expertTranslation,
          onChanged: (value) =>
              _update(translation.copyWith(expertTranslation: value)),
        ),
      ],
    );
  }
}
