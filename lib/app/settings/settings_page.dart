import 'package:flutter/material.dart';

import 'about_page.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('设置')),
    body: ListView(
      padding: const EdgeInsets.symmetric(vertical: 12),
      children: [
        ListTile(
          leading: const Icon(Icons.info_outline),
          title: const Text('关于 Torto'),
          subtitle: const Text('版本、更新与开源许可'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(
            context,
          ).push(MaterialPageRoute<void>(builder: (_) => const AboutPage())),
        ),
      ],
    ),
  );
}
