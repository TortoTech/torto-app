import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_math_fork/flutter_math.dart' as fm;
import 'package:torto/app/reader/footnote_sheet.dart';
import 'package:torto/app/reader/reader_controller.dart';
import 'package:torto/core/ir/ir.dart' as ir;

void main() {
  testWidgets(
    'reference popup fits a narrow screen, renders note math and dismisses outside',
    (tester) async {
      tester.view.physicalSize = const Size(280, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => showReaderFootnoteSheet(
                    context,
                    text: '',
                    background: const Color(0xff17191d),
                    foreground: Colors.white,
                    entries: const [
                      ReaderFootnote(
                        marker: '*',
                        text: 'A formula in a note.',
                        inlines: [
                          ir.TextRun('A formula '),
                          ir.MathInline(r'\frac{a+b+c+d+e+f}{x+y+z}'),
                          ir.TextRun(' in a note.'),
                        ],
                      ),
                      ReaderFootnote(
                        marker: '[1]',
                        text: 'Smith, 2020. A bibliographic reference.',
                        citationOrdinal: 1,
                      ),
                    ],
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.byType(fm.Math), findsOneWidget);
      expect(find.text('[1]'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.byType(ReaderFootnoteSheet), findsNothing);
    },
  );
}
