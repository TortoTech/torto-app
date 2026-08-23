import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../update/app_update_service.dart';

const _appIconAsset = 'android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png';
final _repositoryUri = Uri.parse('https://github.com/TortoTech/torto-app');

class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  late final Future<PackageInfo> _packageInfo = PackageInfo.fromPlatform();
  final AppUpdateService _updateService = AppUpdateService();
  AppUpdateInfo? _updateInfo;
  Object? _updateError;
  bool _checking = false;

  @override
  void dispose() {
    _updateService.dispose();
    super.dispose();
  }

  Future<void> _checkForUpdates() async {
    if (_checking) return;
    setState(() {
      _checking = true;
      _updateError = null;
    });
    try {
      final packageInfo = await _packageInfo;
      final updateInfo = await _updateService.check(
        currentVersion: packageInfo.version,
      );
      if (!mounted) return;
      setState(() => _updateInfo = updateInfo);
    } catch (error) {
      if (!mounted) return;
      setState(() => _updateError = error);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _openUri(Uri uri) async {
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('无法打开链接。')));
    }
  }

  Future<void> _showLicenses() async {
    String? version;
    try {
      final info = await _packageInfo;
      version = _displayVersion(info);
    } catch (_) {
      // The license page remains useful when package metadata is unavailable.
    }
    if (!mounted) return;
    showLicensePage(
      context: context,
      applicationName: 'Torto',
      applicationVersion: version,
      applicationIcon: Image.asset(_appIconAsset, width: 48, height: 48),
    );
  }

  String get _updateStatus {
    if (_checking) return '正在连接 GitHub Releases…';
    if (_updateError != null) return '检查失败，点击重试';
    final updateInfo = _updateInfo;
    if (updateInfo == null) return '从 GitHub Releases 检查新版本';
    if (!updateInfo.hasRelease) return '尚未发布正式版本';
    if (updateInfo.updateAvailable) {
      return '发现新版本 v${updateInfo.latestVersion}';
    }
    return '已是最新版本';
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final updateInfo = _updateInfo;
    final updatePage = updateInfo?.updateAvailable == true
        ? updateInfo?.releasePage
        : null;
    final canOpenUpdate = updatePage != null;
    return Scaffold(
      appBar: AppBar(title: const Text('关于')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
        children: [
          Center(
            child: Column(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: Image.asset(_appIconAsset, width: 88, height: 88),
                ),
                const SizedBox(height: 16),
                Text(
                  'Torto',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                FutureBuilder<PackageInfo>(
                  future: _packageInfo,
                  builder: (context, snapshot) => Text(
                    snapshot.hasData
                        ? _displayVersion(snapshot.data!)
                        : '版本信息加载中',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '专注阅读体验的开源电子书阅读器',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.system_update_outlined),
                  title: const Text('检查更新'),
                  subtitle: Text(_updateStatus),
                  trailing: _checking
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : canOpenUpdate
                      ? const Text('下载')
                      : const Icon(Icons.chevron_right),
                  onTap: _checking
                      ? null
                      : canOpenUpdate
                      ? () => _openUri(updatePage)
                      : _checkForUpdates,
                ),
                const Divider(height: 1, indent: 56),
                ListTile(
                  leading: const Icon(Icons.code),
                  title: const Text('GitHub'),
                  subtitle: const Text('源代码、问题反馈与版本发布'),
                  trailing: const Icon(Icons.open_in_new),
                  onTap: () => _openUri(_repositoryUri),
                ),
                const Divider(height: 1, indent: 56),
                ListTile(
                  leading: const Icon(Icons.description_outlined),
                  title: const Text('开源许可'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _showLicenses,
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Text(
            '© ${DateTime.now().year} TortoTech',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

String _displayVersion(PackageInfo info) {
  final build = info.buildNumber.trim();
  return build.isEmpty ? '版本 ${info.version}' : '版本 ${info.version} ($build)';
}
