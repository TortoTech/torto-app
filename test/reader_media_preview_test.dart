import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torto/app/reader/media_preview.dart';
import 'package:torto/app/reader/footnote_sheet.dart';
import 'package:torto/app/reader/reader_controller.dart';
import 'package:torto/core/render/page_painter.dart';

void main() {
  testWidgets(
    'wide previews fit safe-area bounds without a clipped zoom frame',
    (tester) async {
      tester.view.physicalSize = const Size(360, 700);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(left: 24, right: 38);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPadding);
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawRect(
        const Rect.fromLTWH(0, 0, 1000, 100),
        Paint()..color = Colors.red,
      );
      final picture = recorder.endRecording(),
          image = await picture.toImage(1000, 100);
      addTearDown(image.dispose);
      addTearDown(picture.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () =>
                    showReaderImagePreview(context, Future.value(image)),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      final rect = tester.getRect(
        find.byKey(const Key('reader-image-preview')),
      );
      expect(rect.left, greaterThanOrEqualTo(44));
      expect(rect.right, lessThanOrEqualTo(302));
      expect(rect.width / rect.height, closeTo(10, 0.001));
      expect(
        tester
            .widget<InteractiveViewer>(find.byType(InteractiveViewer))
            .clipBehavior,
        Clip.none,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'image preview uses only a dimming overlay, keeps taps inside, dismisses outside',
    (tester) async {
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawRect(
        const Rect.fromLTWH(0, 0, 300, 100),
        Paint()..color = Colors.red,
      );
      final picture = recorder.endRecording(),
          image = await picture.toImage(300, 100);
      addTearDown(image.dispose);
      addTearDown(picture.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () =>
                    showReaderImagePreview(context, Future.value(image)),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byIcon(Icons.close), findsNothing);
      expect(find.byType(InteractiveViewer), findsOneWidget);
      await tester.tap(find.byKey(const Key('reader-image-preview')));
      await tester.pumpAndSettle();
      expect(find.byType(RawImage), findsOneWidget);
      await tester.tapAt(const Offset(50, 50));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('reader-image-preview')), findsNothing);
    },
  );
  testWidgets(
    'formula preview is white even in a dark reader, with no buttons',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () =>
                    showReaderFormulaPreview(context, r'\frac{x}{y}'),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ColoredBox>(find.byKey(const Key('reader-formula-preview')))
            .color,
        Colors.white,
      );
      expect(find.byType(Dialog), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byIcon(Icons.close), findsNothing);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('reader-formula-preview')), findsNothing);
    },
  );
  for (final background in [Colors.white, const Color(0xff17191d)]) {
    testWidgets(
      'reference markers use body marker color and center within first line for $background',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showReaderFootnoteSheet(
                    context,
                    text: '',
                    background: background,
                    foreground: background == Colors.white
                        ? Colors.black
                        : Colors.white,
                    entries: [
                      ReaderFootnote(
                        marker: '[1]',
                        text: '(Smith (Ed.), 2020)',
                        citationOrdinal: 1,
                      ),
                      ReaderFootnote(
                        marker: '*',
                        text:
                            'Long note with multiple lines and more text. ' *
                            10,
                      ),
                    ],
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        final marker = tester.widget<Text>(find.text('[1]'));
        expect(marker.style!.color, footnoteIconColor(background));
        final markerBox = find
            .ancestor(of: find.text('[1]'), matching: find.byType(SizedBox))
            .first;
        expect(
          tester.getCenter(find.text('[1]')).dy,
          tester.getCenter(markerBox).dy,
        );
        expect(
          find.textContaining('(Smith (Ed.), 2020)', findRichText: true),
          findsNothing,
        );
        expect(
          find.textContaining('Smith (Ed.), 2020', findRichText: true),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
  test(
    'only outer citation parentheses are hidden; original source and regular notes remain exact',
    () {
      for (final text in [
        ' ( Smith (Ed.), 2020 ) ',
        '（Smith, 2020）',
        '[Smith, 2020]',
        '［Smith, 2020］',
      ]) {
        final note = ReaderFootnote(
          marker: '[1]',
          text: text,
          citationOrdinal: 1,
        );
        expect(note.popupText.startsWith(RegExp(r'[\(（\[［]')), false);
        expect(note.text, text);
      }
      const normal = ReaderFootnote(
        marker: '1',
        text: '(A parenthesized note.)',
      );
      expect(normal.popupText, normal.text);
    },
  );
}
