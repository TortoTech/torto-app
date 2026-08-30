import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import 'app_preferences.dart';

class SystemSettingsPage extends StatelessWidget {
  final AppPreferencesController controller;

  const SystemSettingsPage({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.text('系统', 'System'))),
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.symmetric(vertical: 12),
          children: [
            ListTile(
              leading: const Icon(Icons.palette_outlined),
              title: Text(l10n.text('主题', 'Theme')),
              trailing: DropdownButton<AppThemePreference>(
                value: controller.theme,
                onChanged: (value) {
                  if (value != null) controller.setTheme(value);
                },
                items: [
                  DropdownMenuItem(
                    value: AppThemePreference.system,
                    child: Text(l10n.text('跟随系统', 'Follow system')),
                  ),
                  DropdownMenuItem(
                    value: AppThemePreference.light,
                    child: Text(l10n.text('浅色', 'Light')),
                  ),
                  DropdownMenuItem(
                    value: AppThemePreference.dark,
                    child: Text(l10n.text('深色', 'Dark')),
                  ),
                ],
              ),
            ),
            const Divider(indent: 72),
            ListTile(
              leading: const Icon(Icons.language_outlined),
              title: Text(l10n.text('界面语言', 'Interface language')),
              trailing: DropdownButton<AppLanguagePreference>(
                value: controller.language,
                onChanged: (value) {
                  if (value != null) controller.setLanguage(value);
                },
                items: [
                  DropdownMenuItem(
                    value: AppLanguagePreference.system,
                    child: Text(l10n.text('跟随系统', 'Follow system')),
                  ),
                  const DropdownMenuItem(
                    value: AppLanguagePreference.simplifiedChinese,
                    child: Text('简体中文'),
                  ),
                  const DropdownMenuItem(
                    value: AppLanguagePreference.english,
                    child: Text('English'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
