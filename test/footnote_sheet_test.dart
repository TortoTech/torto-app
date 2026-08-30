import 'package:flutter/material.dart';
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
