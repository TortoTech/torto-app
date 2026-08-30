import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../sync/cloud_settings_page.dart';
import '../sync/cloud_sync_controller.dart';
import 'about_page.dart';
import 'ai_providers_page.dart';
import 'app_preferences.dart';
import 'system_settings_page.dart';
import 'translation_settings_page.dart';

class SettingsPage extends StatelessWidget {
  final CloudSyncController? cloudSyncController;

  const SettingsPage({super.key, this.cloudSyncController});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.text('设置', 'Settings'))),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 12),
        children: [
          _section(context, l10n.text('通用', 'General')),
          ListTile(
            leading: const Icon(Icons.tune_outlined),
            title: Text(l10n.text('系统', 'System')),
            subtitle: Text(
              l10n.text('主题与界面语言', 'Theme and interface language'),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _openSystem(context),
          ),
          _section(context, l10n.text('智能功能', 'Intelligence')),
          ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: Text(l10n.text('AI 提供商', 'AI providers')),
            subtitle: const Text('OpenAI-compatible API'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const AiProvidersPage()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.translate),
            title: Text(l10n.text('翻译', 'Translation')),
            subtitle: Text(
              l10n.text('模型、目标语言与显示方式', 'Model, language and display mode'),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const TranslationSettingsPage(),
              ),
            ),
          ),
          _section(context, l10n.text('数据', 'Data')),
          ListTile(
            leading: const Icon(Icons.cloud_outlined),
            title: Text(l10n.text('云同步', 'Cloud sync')),
            subtitle: Text(
              cloudSyncController == null
                  ? l10n.text('云同步服务暂不可用', 'Cloud sync is unavailable')
                  : l10n.text(
                      'WebDAV 书籍与阅读进度',
                      'WebDAV books and reading progress',
                    ),
            ),
            trailing: const Icon(Icons.chevron_right),
            enabled: cloudSyncController != null,
            onTap: cloudSyncController == null
                ? null
                : () => _openCloud(context, cloudSyncController!),
          ),
          _section(context, l10n.text('其他', 'Other')),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: Text(l10n.text('关于 Torto', 'About Torto')),
            subtitle: Text(
              l10n.text('版本、更新与开源许可', 'Version, updates and licenses'),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(
              context,
            ).push(MaterialPageRoute<void>(builder: (_) => const AboutPage())),
          ),
        ],
      ),
    );
  }

  static Widget _section(BuildContext context, String label) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
    child: Text(
      label,
      style: Theme.of(context).textTheme.labelLarge?.copyWith(
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );

  static Future<void> _openSystem(BuildContext context) async {
    final inherited = AppPreferencesScope.maybeOf(context);
    final controller = inherited ?? AppPreferencesController();
    if (inherited == null) await controller.load();
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SystemSettingsPage(controller: controller),
      ),
    );
    if (inherited == null) controller.dispose();
  }

  static Future<void> _openCloud(
    BuildContext context,
    CloudSyncController controller,
  ) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => CloudSettingsPage(controller: controller),
      ),
    );
    if (saved != true || !controller.settings.enabled) return;
    try {
      await controller.sync();
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }
}
