import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app/home/home_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Color(0xFFFAF8F3),
      statusBarIconBrightness: Brightness.dark,
      statusBarBrightness: Brightness.light,
      systemNavigationBarColor: Color(0xFFFAF8F3),
      systemNavigationBarDividerColor: Color(0xFFFAF8F3),
      systemNavigationBarIconBrightness: Brightness.dark,
      systemStatusBarContrastEnforced: false,
      systemNavigationBarContrastEnforced: false,
    ),
  );
  runApp(const TortoApp());
}

class TortoApp extends StatelessWidget {
  const TortoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Torto',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.brown),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}
