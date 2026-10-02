import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:path_provider/path_provider.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'core/diagnostics.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app/home/home_page.dart';
import 'app/reader/reader_book_benchmark.dart';
import 'app/settings/app_preferences.dart';
import 'l10n/app_localizations.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      statusBarBrightness: Brightness.light,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
      systemNavigationBarIconBrightness: Brightness.dark,
      systemStatusBarContrastEnforced: false,
      systemNavigationBarContrastEnforced: false,
    ),
  );
  unawaited(_initializeDiagnostics());
  final original = FlutterError.onError;
  FlutterError.onError = (details) {
    ReaderDiagnostics.instance.event('flutter.error', {
      'type': details.exception.runtimeType.toString(),
    });
    original?.call(details);
  };
  ui.PlatformDispatcher.instance.onError = (error, stack) {
    ReaderDiagnostics.instance.event('async.error', {
      'type': error.runtimeType.toString(),
    });
    return false;
  };
  runApp(const TortoApp());
  if (benchmarkBookTitle.isNotEmpty) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(runRequestedBookBenchmark());
    });
  }
}

class TortoApp extends StatefulWidget {
  final AppPreferencesController? preferencesController;

  const TortoApp({super.key, this.preferencesController});

  @override
  State<TortoApp> createState() => _TortoAppState();
}

class _TortoAppState extends State<TortoApp> {
  late final AppPreferencesController _preferences =
      widget.preferencesController ?? AppPreferencesController();
  late final bool _ownsPreferences = widget.preferencesController == null;

  @override
  void initState() {
    super.initState();
    _preferences.load();
  }

  @override
  void dispose() {
    if (_ownsPreferences) _preferences.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppPreferencesScope(
    controller: _preferences,
    child: ListenableBuilder(
      listenable: _preferences,
      builder: (context, _) => MaterialApp(
        title: 'Torto',
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        themeMode: _preferences.themeMode,
        locale: _preferences.locale,
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        builder: (context, child) {
          final dark = Theme.of(context).brightness == Brightness.dark;
          return AnnotatedRegion<SystemUiOverlayStyle>(
            value: SystemUiOverlayStyle(
              statusBarColor: Colors.transparent,
              statusBarIconBrightness: dark
                  ? Brightness.light
                  : Brightness.dark,
              statusBarBrightness: dark ? Brightness.dark : Brightness.light,
              systemNavigationBarColor: Colors.transparent,
              systemNavigationBarDividerColor: Colors.transparent,
              systemNavigationBarIconBrightness: dark
                  ? Brightness.light
                  : Brightness.dark,
              systemStatusBarContrastEnforced: false,
              systemNavigationBarContrastEnforced: false,
            ),
            child: child ?? const SizedBox.shrink(),
          );
        },
        home: const HomePage(),
      ),
    ),
  );

  static ThemeData _theme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF7B6751),
      brightness: brightness,
    );
    return ThemeData(
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: dark
          ? const Color(0xFF121212)
          : const Color(0xFFFAF8F3),
      appBarTheme: AppBarTheme(
        backgroundColor: dark
            ? const Color(0xFF1C1C1C)
            : const Color(0xFFFAF8F3),
        surfaceTintColor: Colors.transparent,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: dark
            ? const Color(0xFF1C1C1C)
            : const Color(0xFFFAF8F3),
      ),
      useMaterial3: true,
    );
  }
}

Future<void> _initializeDiagnostics() async {
  try {
    final root = await getApplicationSupportDirectory();
    await ReaderDiagnostics.instance.initialize(
      Directory('${root.path}/diagnostics'),
    );
    final info = await PackageInfo.fromPlatform();
    ReaderDiagnostics.instance.event('app.start', {
      'version': info.version,
      'build': info.buildNumber,
    });
    WidgetsBinding.instance.addTimingsCallback((timings) {
      for (final timing in timings) {
        if (timing.totalSpan.inMilliseconds >= 100) {
          ReaderDiagnostics.instance.event('frame.slow', {
            'build_ms': timing.buildDuration.inMilliseconds,
            'raster_ms': timing.rasterDuration.inMilliseconds,
            'total_ms': timing.totalSpan.inMilliseconds,
          });
        }
      }
    });
    if (Platform.isAndroid) {
      try {
        final exits = await const MethodChannel(
          'torto/diagnostics',
        ).invokeListMethod<Object?>('exitInfo');
        for (final exit in exits ?? const []) {
          if (exit is Map) {
            ReaderDiagnostics.instance.event(
              'android.exit',
              exit.map((key, value) => MapEntry(key.toString(), value)),
            );
          }
        }
      } catch (_) {}
    }
    var last = DateTime.now();
    Timer.periodic(const Duration(seconds: 1), (_) {
      final now = DateTime.now();
      final elapsed = now.difference(last).inMilliseconds;
      last = now;
      if (elapsed > 1500 &&
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        ReaderDiagnostics.instance.event('event_loop.delay', {
          'elapsed_ms': elapsed,
        });
      }
    });
  } catch (_) {
    /* Diagnostics must never prevent startup. */
  }
}
