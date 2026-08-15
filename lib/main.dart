import 'package:flutter/material.dart';

import 'app/library/library_page.dart';

void main() {
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
      home: const LibraryPage(),
    );
  }
}
