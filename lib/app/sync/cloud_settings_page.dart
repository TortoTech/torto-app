import 'package:flutter/material.dart';

import 'cloud_sync_controller.dart';
import 'sync_models.dart';

class CloudSettingsPage extends StatefulWidget {
  final CloudSyncController controller;

  const CloudSettingsPage({super.key, required this.controller});

  @override
  State<CloudSettingsPage> createState() => _CloudSettingsPageState();
}

class _CloudSettingsPageState extends State<CloudSettingsPage> {
  late bool _enabled;
  late CloudProvider _provider;
  late final TextEditingController _url;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late final TextEditingController _deviceName;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final settings = widget.controller.settings;
    _enabled = settings.enabled;
    _provider = settings.provider;
    _url = TextEditingController(text: settings.baseUrl);
    _username = TextEditingController(text: settings.username);
    _password = TextEditingController(text: widget.controller.password);
    _deviceName = TextEditingController(text: settings.deviceName);
  }

  @override
  void dispose() {
    _url.dispose();
    _username.dispose();
    _password.dispose();
    _deviceName.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final settings = widget.controller.settings.copyWith(
      enabled: _enabled,
      provider: _provider,
      baseUrl: _url.text.trim(),
      username: _username.text.trim(),
      deviceName: _deviceName.text.trim(),
    );
    if (_enabled &&
        (settings.effectiveBaseUrl.isEmpty ||
            settings.username.isEmpty ||
            _password.text.isEmpty)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Complete the WebDAV settings.')),
      );
      return;
    }
    setState(() => _saving = true);
    await widget.controller.saveConfiguration(settings, _password.text);
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Cloud sync')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Enable cloud sync'),
            subtitle: const Text(
              'Sync books and reading progress with WebDAV.',
            ),
            value: _enabled,
            onChanged: (value) => setState(() => _enabled = value),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<CloudProvider>(
            initialValue: _provider,
            decoration: const InputDecoration(
              labelText: 'Cloud provider',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final provider in CloudProvider.values)
                DropdownMenuItem(value: provider, child: Text(provider.label)),
            ],
            onChanged: (value) {
              if (value != null) setState(() => _provider = value);
            },
          ),
          if (_provider == CloudProvider.custom) ...[
            const SizedBox(height: 16),
            TextField(
              controller: _url,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'WebDAV URL',
                hintText: 'https://dav.example.com/path',
                border: OutlineInputBorder(),
              ),
            ),
          ],
          const SizedBox(height: 16),
          TextField(
            controller: _username,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Username',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _password,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: 'App password',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _deviceName,
            decoration: const InputDecoration(
              labelText: 'Device name',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'The password is stored in the system credential store. Torto uploads book files and reading progress only after you enable sync.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Save'),
          ),
        ],
      ),
    );
  }
}
