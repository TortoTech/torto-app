import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../ai/ai_models.dart';
import '../ai/ai_settings_store.dart';

class SemanticLayoutSettingsPage extends StatefulWidget {
  final AiSettingsStore? store;
  const SemanticLayoutSettingsPage({super.key, this.store});
  @override
  State<SemanticLayoutSettingsPage> createState() =>
      _SemanticLayoutSettingsPageState();
}

class _SemanticLayoutSettingsPageState
    extends State<SemanticLayoutSettingsPage> {
  late final store = widget.store ?? AiSettingsStore();
  AiSettings? settings;
  bool enabled = false, saving = false;
  String providerId = '', model = '';
  ReasoningEffort reasoningEffort = ReasoningEffort.none;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final value = await store.load();
    if (mounted) {
      setState(() {
        settings = value;
        enabled = value.semanticLayout.enabled;
        providerId = value.semanticLayout.providerId;
        model = value.semanticLayout.model;
        reasoningEffort = value.semanticLayout.reasoningEffort;
      });
    }
  }

  Future<void> _save() async {
    setState(() => saving = true);
    try {
      // Merge against the latest provider settings instead of restoring a stale snapshot.
      final latest = await store.load();
      await store.save(
        latest.copyWith(
          semanticLayout: SemanticLayoutSettings(
            enabled: enabled,
            providerId: providerId,
            model: model,
            reasoningEffort: reasoningEffort,
          ),
        ),
      );
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        setState(() => saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.l10n.text('保存失败，请重试', 'Could not save. Try again.'),
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final options = <String, String>{
      for (final p in settings?.providers ?? <AiProviderConfig>[])
        for (final m in p.models) '${p.id}\u0000$m': '${p.name} · $m',
    };
    final selected = '$providerId\u0000$model';
    final valid = options.containsKey(selected);
    return Scaffold(
      appBar: AppBar(
        title: Text(l.text('AI 排版', 'AI layout')),
        actions: [
          TextButton(
            onPressed: settings == null || saving ? null : _save,
            child: Text(l.text('保存', 'Save')),
          ),
        ],
      ),
      body: settings == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                SwitchListTile(
                  title: Text(l.text('启用 AI 排版', 'Enable AI layout')),
                  subtitle: Text(
                    l.text(
                      '自动识别引用、图注、小节标题和公式',
                      'Recognize quotations, captions, section headings and formulas',
                    ),
                  ),
                  value: enabled,
                  onChanged: saving ? null : (v) => setState(() => enabled = v),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: DropdownButtonFormField<String>(
                    isExpanded: true,
                    initialValue: valid ? selected : null,
                    decoration: InputDecoration(
                      labelText: l.text('独立选择排版模型', 'Layout model'),
                    ),
                    items: options.entries
                        .map(
                          (e) => DropdownMenuItem(
                            value: e.key,
                            child: Text(
                              e.value,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: saving
                        ? null
                        : (v) {
                            if (v == null) return;
                            final parts = v.split('\u0000');
                            setState(() {
                              providerId = parts.first;
                              model = parts.last;
                            });
                          },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: DropdownButtonFormField<ReasoningEffort>(
                    initialValue: reasoningEffort,
                    decoration: InputDecoration(
                      labelText: l.text('思考等级', 'Reasoning effort'),
                    ),
                    items: [
                      for (final effort in ReasoningEffort.values)
                        DropdownMenuItem(
                          value: effort,
                          child: Text(
                            effort == ReasoningEffort.defaultLevel
                                ? l.text('默认', 'Default')
                                : effort.label,
                          ),
                        ),
                    ],
                    onChanged: saving
                        ? null
                        : (value) {
                            if (value != null) {
                              setState(() => reasoningEffort = value);
                            }
                          },
                  ),
                ),
                if (!valid)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      l.text(
                        '请先在 AI 服务中添加模型并在这里选择。模型失效时排版会暂停，不会自动切换。',
                        'Add a model in AI services and select it here. An unavailable model pauses recognition without switching providers.',
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
