import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torto/app/reader/footnote_sheet.dart';
import 'package:torto/core/linebreak/english_hyphenator.dart';

class _RecordingHyphenator implements ParagraphHyphenator {
  String? text;
  String? publicationLanguage;
  List<HyphenationSpan> spans = const [];

  @override
  Set<int> breakOpportunities({
    required String text,
    required List<HyphenationSpan> spans,
    required String? publicationLanguage,
  }) {
    this.text = text;
    this.spans = spans;
    this.publicationLanguage = publicationLanguage;
    return const {};
  }
}

void main() {
  testWidgets(
    'mixed footnotes keep measured widths with real fonts and text scaling',
    (tester) async {
      final latin = FontLoader('Literata')
        ..addFont(rootBundle.load('assets/fonts/Literata-opsz-wght.ttf'));
      final cjk = FontLoader('LXGW WenKai GB Screen')
        ..addFont(rootBundle.load('assets/fonts/LXGWWenKaiGBScreen.ttf'));
      await latin.load();
      await cjk.load();
      const text =
          '比较心理学家哈里·哈洛（Harry Harlow）进行了一项实验，研究了语言与行为之间的关系。Office affinity and efficient scientific observations help explain this relationship.';
      for (final width in [280.0, 380.0]) {
        for (final scale in [1.0, 1.4]) {
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: MediaQuery(
                  data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                  child: SizedBox(
                    width: width,
                    child: OptimizedJustifiedText(
                      text,
                      style: const TextStyle(
                        fontFamily: 'Literata',
                        fontFamilyFallback: ['LXGW WenKai GB Screen'],
                        fontSize: 17,
                        height: 1.55,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pump();
          final widget = tester
              .widgetList<Text>(
                find.descendant(
                  of: find.byType(OptimizedJustifiedText),
                  matching: find.byType(Text),
                ),
              )
              .single;
          expect(widget.textSpan, isNotNull);
          final painter = TextPainter(
            text: widget.textSpan,
            textDirection: TextDirection.ltr,
            textScaler: TextScaler.linear(scale),
          )..layout(maxWidth: 1000000);
          final metrics = painter.computeLineMetrics();
          expect(metrics.length, greaterThan(1));
          for (final line in metrics.take(metrics.length - 1)) {
            expect(
              line.width,
              closeTo(width, 2),
              reason: 'width=$width scale=$scale',
            );
          }
          expect(metrics.last.width, lessThanOrEqualTo(width + 1));
          painter.dispose();
        }
      }
    },
  );
  testWidgets('footnote bottom sheet fills the window width', (tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showReaderFootnoteSheet(
                context,
                text: '一段脚注正文。',
                background: const Color(0xFFFAF8F3),
                foreground: Colors.black,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(tester.getSize(find.byType(BottomSheet)).width, closeTo(420, 0.1));
    expect(find.byType(OptimizedJustifiedText), findsOneWidget);
  });

  testWidgets('footnote text uses optimized explicit line breaks', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 180,
            child: OptimizedJustifiedText(
              '系统思考帮助我们理解复杂世界中的结构、反馈、延迟以及行为之间的关系。',
              style: TextStyle(fontSize: 17, height: 1.55),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final optimized = tester
        .widgetList<Text>(
          find.descendant(
            of: find.byType(OptimizedJustifiedText),
            matching: find.byType(Text),
          ),
        )
        .where((widget) => widget.textSpan != null)
        .single;
    expect(optimized.textSpan!.toPlainText(), contains('\n'));
  });

  testWidgets('footnote optimizer uses publication-aware hyphenation', (
    tester,
  ) async {
    final hyphenator = _RecordingHyphenator();
    const text =
        'Hyphenation opportunities improve narrow footnote paragraphs on mobile screens.';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 180,
            child: OptimizedJustifiedText(
              text,
              style: const TextStyle(fontSize: 17, height: 1.55),
              publicationLanguage: 'en-GB',
              hyphenator: hyphenator,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(hyphenator.text, text);
    expect(hyphenator.publicationLanguage, 'en-GB');
    expect(hyphenator.spans, hasLength(1));
    expect(hyphenator.spans.single.start, 0);
    expect(hyphenator.spans.single.end, text.length);
  });
}
