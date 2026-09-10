import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:torto/app/home/home_page.dart';

void main() {
  testWidgets('bottom navigation reaches settings and about', (tester) async {
    PackageInfo.setMockInitialValues(
      appName: 'Torto',
      packageName: 'com.example.torto',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );

    await tester.pumpWidget(
      const MaterialApp(home: HomePage(library: Text('Shelf content'))),
    );

    expect(find.text('Shelf content'), findsOneWidget);
    await tester.tap(find.text('我'));
    await tester.pumpAndSettle();
    expect(find.text('设置'), findsOneWidget);

    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(find.text('关于 Torto'), findsOneWidget);

    final about = find.byIcon(Icons.info_outline);
    await tester.ensureVisible(about);
    await tester.pumpAndSettle();
    await tester.tap(about);
    await tester.pumpAndSettle();
    expect(find.text('Torto'), findsOneWidget);
    expect(find.text('版本 1.0.0 (1)'), findsOneWidget);
    expect(find.text('检查更新'), findsOneWidget);
  });
}
