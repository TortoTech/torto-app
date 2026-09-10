import 'package:flutter/material.dart';
import '../statistics/statistics_page.dart';

import '../../l10n/app_localizations.dart';
import '../settings/settings_page.dart';
import '../sync/cloud_sync_controller.dart';

class ProfilePage extends StatelessWidget {
  final bool active;
  final CloudSyncController? cloudSyncController;

  const ProfilePage({super.key, this.cloudSyncController, this.active = true});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.text('我', 'Me'))),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 12),
        children: [
          StatisticsSummaryCard(active: active),
          ListTile(
            leading: const Icon(Icons.settings_outlined),
            title: Text(l10n.text('设置', 'Settings')),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) =>
                    SettingsPage(cloudSyncController: cloudSyncController),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
