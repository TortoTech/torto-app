import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_math_fork/flutter_math.dart' as fm;
import 'package:torto/app/reader/footnote_sheet.dart';
import 'package:torto/app/reader/reader_controller.dart';
import 'package:torto/core/ir/ir.dart' as ir;
import 'package:torto/core/layout/layout_types.dart';
import 'package:torto/core/layout/layout_engine.dart';
import 'core/html_ir_parser_test.dart' show parseSection;

void main() {
  testWidgets('plain popup URLs become clickable icons with measured wrapping', (
    tester,
  ) async {
    await (FontLoader(
      'Literata',
    )..addFont(rootBundle.load('assets/fonts/Literata-opsz-wght.ttf'))).load();
    final calls = <MethodCall>[];
    String? copiedUrl;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copiedUrl = call.arguments['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    const channel = MethodChannel('plugins.flutter.io/url_launcher');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      return true;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    for (final scale in [1.0, 1.7]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: SizedBox(
                width: 280,
                child: ReaderFootnoteSheet(
                  text:
                      'See https://example.com/a(b), and more reading information. '
                      'The remaining explanation wraps across lines.\r\n'
                      'Also example.org/path. Mail reader@example.net stays text.',
                  foreground: Colors.black,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.language), findsNWidgets(2));
      final tooltips = tester.widgetList<Tooltip>(find.byType(Tooltip));
      expect(tooltips.map((t) => t.message), [
        'https://example.com/a(b)',
        'https://example.org/path',
      ]);
      expect(
        find.textContaining('reader@example.net', findRichText: true),
        findsOneWidget,
      );
      final first = find.byIcon(Icons.language).first;
      await tester.tap(first);
      await tester.pump();
      expect(calls.last.arguments['url'], 'https://example.com/a(b)');
      await tester.longPress(first);
      await tester.pump();
      expect(copiedUrl, 'https://example.com/a(b)');
      for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
        final text = rich.text.toPlainText();
        if (!text.contains('\ufffc')) continue;
        final render = tester.renderObject<RenderParagraph>(
          find.byWidget(rich),
        );
        var offset = 0;
        for (final grapheme in text.characters) {
          if (grapheme.trim().isNotEmpty) {
            final boxes = render.getBoxesForSelection(
              TextSelection(
                baseOffset: offset,
                extentOffset: offset + grapheme.length,
              ),
            );
            for (final box in boxes) {
              expect(
                box.right,
                lessThanOrEqualTo(render.size.width + 1),
                reason: 'scale=$scale character=$grapheme',
              );
            }
          }
          offset += grapheme.length;
        }
      }
      expect(tester.takeException(), isNull);
    }
  });

  test(
    'body, quotes, tables and captions preserve webpage links in every layout',
    () {
      final section = parseSection('''
      <p>Read example.com and <a href="https://publisher.dev/source">Publisher</a>.</p>
      <blockquote><p>More at example.net.</p></blockquote>
      <table><tr><td>Data at example.org.</td></tr></table>
      <figure><img src="cover.png" width="100" height="50"/>
        <figcaption>Figure 1: See example.edu.</figcaption></figure>
    ''');
      for (final mode in TypesettingMode.values) {
        for (final strategy in LineBreakStrategy.values) {
          for (final focus in [false, true]) {
            final pages = LayoutEngine().paginate(
              section,
              const LayoutViewport(width: 360, height: 700),
              ReaderStyle(
                typesettingMode: mode,
                lineBreakStrategy: strategy,
                focusMode: focus,
              ),
            );
            final links = [
              for (final page in pages)
                for (final item in page.items)
                  ...switch (item) {
                    TextPlacement(:final links) ||
                    TableCellPlacement(:final links) => links,
                    _ => <TextLinkRange>[],
                  },
            ];
            if (mode == TypesettingMode.unified) {
              expect(
                links.where((l) => l.websiteIcon).map((l) => l.href).toSet(),
                {
                  'https://example.com',
                  'https://publisher.dev/source',
                  'https://example.net',
                  'https://example.org',
                  'https://example.edu',
                },
                reason: 'mode=$mode strategy=$strategy focus=$focus',
              );
            } else {
              expect(links.where((l) => l.websiteIcon), isEmpty);
              expect(
                links.map((l) => l.href),
                contains('https://publisher.dev/source'),
              );
            }
            for (final page in pages) {
              page.dispose();
            }
          }
        }
      }
    },
  );

  testWidgets('expanded citations and authored links retain URLs beside math', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 280,
            child: ReaderFootnoteSheet(
              text: '',
              foreground: Colors.black,
              entries: const [
                ReaderFootnote(
                  marker: '[1]',
                  footnoteNumber: 1,
                  text: 'Read the source.',
                  inlines: [
                    ir.TextRun('['),
                    ir.TextRun('1] '),
                    ir.TextRun('Publisher', link: 'https://example.com/source'),
                    ir.TextRun(' and '),
                    ir.MathInline(r'x^2'),
                    ir.TextRun(' see example.org.'),
                  ],
                ),
                ReaderFootnote(
                  marker: '[2]',
                  citationOrdinal: 2,
                  text: '(Research at example.net, 2020)',
                ),
                ReaderFootnote(
                  marker: '[3]',
                  citationOrdinal: 3,
                  text: 'Styled citation',
                  inlines: [
                    ir.TextRun(
                      'Details at example.edu.',
                      style: ir.TextStyle(inlineCitation: 3),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.language), findsNWidgets(4));
    expect(find.byType(fm.Math), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(find.textContaining('[1]', findRichText: true), findsNothing);
    expect(
      tester.widgetList<Tooltip>(find.byType(Tooltip)).map((t) => t.message),
      [
        'https://example.com/source',
        'https://example.org',
        'https://example.net',
        'https://example.edu',
      ],
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('book mode retains URL text and unified fallback retains icons', (
    tester,
  ) async {
    for (final mode in TypesettingMode.values) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReaderFootnoteSheet(
              text: 'مرحبا https://example.com/path',
              foreground: Colors.black,
              typesettingMode: mode,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      if (mode == TypesettingMode.unified) {
        expect(find.byIcon(Icons.language), findsOneWidget);
      } else {
        expect(find.byIcon(Icons.language), findsNothing);
        expect(
          find.textContaining('https://example.com/path', findRichText: true),
          findsOneWidget,
        );
      }
      expect(tester.takeException(), isNull);
    }
  });
}
