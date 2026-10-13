import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:torto/app/reader/reader_preferences_store.dart';
import 'package:torto/app/reader/footnote_sheet.dart';
import 'package:torto/app/reader/reader_controller.dart';
import 'package:torto/app/reader/media_reference_preview.dart';
import 'package:torto/app/reader/media_preview.dart';
import 'package:torto/core/ir/ir.dart' as ir;
import 'package:torto/core/layout/layout_engine.dart';
import 'package:torto/core/layout/layout_types.dart';
import 'package:torto/core/semantic_layout/media_references.dart';
import 'package:torto/l10n/app_localizations.dart';
import 'core/html_ir_parser_test.dart' show parseSection;

class _MediaSource extends ir.BookSource {
  final List<List<ir.Block>> blocks;
  _MediaSource(this.blocks);
  @override
  ir.Book get book => ir.Book(
    id: 'book',
    metadata: const ir.BookMetadata(),
    spine: [
      for (var i = 0; i < blocks.length; i++)
        ir.SpineItem(id: ir.SpineItemId('$i'), index: i, href: '$i.xhtml'),
    ],
  );
  @override
  Future<ir.Section> parseSection(int index) async => ir.Section(
    id: ir.SpineItemId('$index'),
    spineIndex: index,
    href: '$index.xhtml',
    blocks: blocks[index],
  );
  @override
  Future<Uint8List?> resource(String href) async => null;
}

void main() {
  test(
    'inline image previews use painted geometry without treating ruby as an image',
    () {
      final section = parseSection(
        '<p>See <img src="glyph.png" width="18" height="20"/> now.</p>',
      );
      final pages = LayoutEngine().paginate(
        section,
        const LayoutViewport(width: 360, height: 640),
        const ReaderStyle(),
        imageSizeResolver: (_) => const Size(18, 20),
      );
      final item = pages.first.items.whereType<TextPlacement>().first;
      final image = item.inlineImages.single;
      final box = item.paragraph.getBoxesForRange(image.start, image.end).first;
      final point = Offset(
        item.x + (box.left + box.right) / 2,
        item.y -
            item.sliceTop +
            box.top +
            image.paintOffsetY +
            image.height / 2,
      );
      expect(
        readerImagePreviewTarget(pages.first, point)?.href,
        'OPS/text/glyph.png',
      );
      expect(readerImagePreviewTarget(pages.first, const Offset(0, 0)), isNull);
      for (final page in pages) {
        page.dispose();
      }
    },
  );

  test(
    'media preview prefers a local match and rejects ambiguous chapters',
    () async {
      ir.FigureBlock figure(String href) => ir.FigureBlock(
        images: [ir.ImageBlock(href: href)],
        captions: [
          ir.TextBlock(
            kind: ir.TextBlockKind.caption,
            inlines: const [ir.TextRun('Figure 2. Caption')],
          ),
        ],
      );
      final a = figure('a.png'), b = figure('b.png'), c = figure('c.png');
      const key = 'torto-media:figure/2';
      expect(
        (await findMediaReference(
          _MediaSource([
            [a],
            [b],
          ]),
          0,
          key,
        ))!.single,
        same(a),
      );
      expect(
        await findMediaReference(
          _MediaSource([
            [a, b],
            [c],
          ]),
          0,
          key,
        ),
        isNull,
      );
      expect(
        await findMediaReference(
          _MediaSource([
            [],
            [a],
            [b],
          ]),
          0,
          key,
        ),
        isNull,
      );
      expect(
        (await findMediaReference(
          _MediaSource([
            [],
            [a],
          ]),
          0,
          key,
        ))!.single,
        same(a),
      );
    },
  );
  test(
    'media references normalize multilingual numbers and cross style boundaries',
    () {
      final refs = MediaReferences.references(
        'See Figures ２.１a, ２.２ and ２.３, 表十二。',
      );
      expect(refs.map((r) => r.href), [
        'torto-media:figure/2.1a',
        'torto-media:figure/2.2',
        'torto-media:figure/2.3',
        'torto-media:table/12',
      ]);
      const source = [
        ir.TextRun('See Fig.', style: ir.TextStyle(bold: true)),
        ir.TextRun(' 2 for details.'),
      ];
      final linked = MediaReferences.link(source).cast<ir.TextRun>();
      expect(linked.map((r) => r.text).join(), 'See Fig. 2 for details.');
      expect(
        linked.where((r) => r.link != null).map((r) => r.link),
        everyElement('torto-media:figure/2'),
      );
      expect(linked.first.style.bold, isTrue);
      expect(MediaReferences.references('configuration2'), isEmpty);
    },
  );
  test('ambiguous captions do not select an arbitrary figure', () {
    ir.FigureBlock figure(String href) => ir.FigureBlock(
      images: [ir.ImageBlock(href: href)],
      captions: [
        ir.TextBlock(
          kind: ir.TextBlockKind.caption,
          inlines: const [ir.TextRun('Figure 2. Caption')],
        ),
      ],
    );
    final a = figure('a.png'), b = figure('b.png');
    ir.Section section(List<ir.Block> blocks) => ir.Section(
      id: const ir.SpineItemId('s'),
      spineIndex: 0,
      href: 's.xhtml',
      blocks: blocks,
    );
    expect(mediaBlocks(section([a]), 'torto-media:figure/2')!.single, same(a));
    expect(mediaBlocks(section([a, b]), 'torto-media:figure/2'), isNull);
  });
  test(
    'focus style persists and unknown legacy choices have a stable default',
    () async {
      SharedPreferences.setMockInitialValues({
        'reader_focus_style_v1': 'unknown',
      });
      final store = ReaderPreferencesStore(
        await SharedPreferences.getInstance(),
      );
      expect(await store.loadFocusStyle(), FocusStyle.dimSurroundings);
      await store.saveFocusStyle(FocusStyle.highlight);
      expect(await store.loadFocusStyle(), FocusStyle.highlight);
    },
  );
  testWidgets(
    'footnotes cycle in both directions and media references open from popup text',
    (tester) async {
      String? opened;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: const [AppLocalizations.delegate],
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showReaderFootnoteSheet(
                  context,
                  text: 'First',
                  background: Colors.white,
                  foreground: Colors.black,
                  blockNavigation: true,
                  entries: const [
                    ReaderFootnote(
                      marker: '1',
                      footnoteNumber: 1,
                      text: 'First note.',
                    ),
                    ReaderFootnote(
                      marker: '2',
                      footnoteNumber: 2,
                      text: 'See Figure 2.',
                    ),
                  ],
                  onMediaReference: (href) async {
                    opened = href;
                  },
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('footnote-previous')));
      await tester.pumpAndSettle();
      expect(find.text('2 / 2'), findsOneWidget);
      await tester.tap(find.text('Figure 2'));
      await tester.pump();
      expect(opened, 'torto-media:figure/2');
      await tester.tap(find.byKey(const Key('footnote-next')));
      await tester.pumpAndSettle();
      expect(find.text('1 / 2'), findsOneWidget);
      expect(find.byKey(const Key('footnote-copy')), findsOneWidget);
    },
  );
}
