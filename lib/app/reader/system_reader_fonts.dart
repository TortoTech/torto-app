import 'dart:io';
import 'package:flutter/services.dart';
import 'package:xml/xml.dart';

/// Android's installed font configuration, including OEM font families.
/// Only selected families are registered with Flutter.
class SystemReaderFonts {
  static final instance = SystemReaderFonts();
  final Map<String, List<String>> _files = {};
  final Set<String> cjk = {};
  final Set<String> _loaded = {};
  Future<void>? _scan;
  Future<void> scan() =>
      Platform.isAndroid ? _scan ??= _discover() : Future<void>.value();
  List<String> get families => _files.keys.toList()..sort();

  Future<void> _discover() async {
    if (!Platform.isAndroid) return;
    for (final config in [
      '/system/etc/fonts.xml',
      '/product/etc/fonts_customization.xml',
      '/vendor/etc/fonts.xml',
    ]) {
      try {
        final file = File(config);
        if (!await file.exists()) continue;
        final xml = XmlDocument.parse(await file.readAsString());
        for (final family in xml.findAllElements('family')) {
          final paths = <String>[];
          for (final font in family.findElements('font')) {
            final filename = font.children
                .whereType<XmlText>()
                .map((text) => text.value)
                .join()
                .trim();
            if (filename.isEmpty || filename.contains('..')) continue;
            // FontLoader cannot select a nonzero TTC face. Do not advertise
            // those faces under a name that would render another face.
            if ((int.tryParse(font.getAttribute('index') ?? '0') ?? 0) != 0) {
              continue;
            }
            for (final root in [
              '/system/fonts',
              '/product/fonts',
              '/vendor/fonts',
            ]) {
              final path = '$root/$filename';
              if (await File(path).exists()) {
                paths.add(path);
                break;
              }
            }
          }
          if (paths.isEmpty) continue;
          final name =
              family.getAttribute('name') ??
              paths.first
                  .split('/')
                  .last
                  .replaceAll(RegExp(r'\.(ttf|otf|ttc)$'), '');
          if (name.toLowerCase().contains('emoji')) continue;
          _files.putIfAbsent(name, () => paths);
          final language = family.getAttribute('lang') ?? '';
          if (RegExp(r'zh|ja|ko|Hans|Hant|Jpan|Kore').hasMatch(language)) {
            cjk.add(name);
          }
        }
      } catch (_) {
        // A missing or OEM-specific configuration does not block reading.
      }
    }
  }

  Future<void> load(Iterable<String> families) async {
    await scan();
    for (final name in families.toSet()) {
      if (_loaded.contains(name)) continue;
      final paths = _files[name];
      if (paths == null) continue;
      final loader = FontLoader(name);
      try {
        for (final path in paths) {
          loader.addFont(
            File(
              path,
            ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
          );
        }
        await loader.load();
        _loaded.add(name);
      } catch (_) {
        // Flutter's fallback remains available if an OEM file cannot load.
      }
    }
  }
}
