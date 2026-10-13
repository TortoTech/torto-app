import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torto/core/ir/ir.dart' hide TextStyle;
import 'package:torto/core/layout/layout_engine.dart';
import 'package:torto/core/layout/layout_types.dart';
import 'package:torto/core/render/page_painter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final mono = File('C:/Windows/Fonts/consola.ttf');
    final font = await mono.exists()
        ? ByteData.sublistView(await mono.readAsBytes())
        : await rootBundle.load('assets/fonts/Literata-opsz-wght.ttf');
    await (FontLoader('monospace')..addFont(Future.value(font))).load();
    await (FontLoader(
      'Literata',
    )..addFont(rootBundle.load('assets/fonts/Literata-opsz-wght.ttf'))).load();
    await (FontLoader(
      'LXGW WenKai GB Screen',
    )..addFont(rootBundle.load('assets/fonts/LXGWWenKaiGBScreen.ttf'))).load();
  });
  for (final dark in [false, true]) {
    test(
      'chapter grouping and OCR prose render with real fonts in ${dark ? 'dark' : 'light'} mode',
      () async {
        SourceRange source(String node, int length) => SourceRange(
          start: SourceAnchor(
            spine: const SpineItemId('s'),
            node: node,
            textOffset: 0,
          ),
          end: SourceAnchor(
            spine: const SpineItemId('s'),
            node: node,
            textOffset: length,
          ),
        );
        final section = Section(
          id: const SpineItemId('s'),
          spineIndex: 0,
          href: 'chapter',
          blocks: [
            TextBlock(
              nodeId: 'number',
              source: source('number', 1),
              kind: TextBlockKind.heading,
              headingLevel: 1,
              headingOrdinal: true,
              inlines: const [TextRun('1')],
            ),
            TextBlock(
              nodeId: 'title',
              source: source('title', 6),
              kind: TextBlockKind.heading,
              headingLevel: 1,
              inlines: const [TextRun('从图片到正文')],
            ),
            ImageBlock(
              href: 'text.png',
              source: source('image', 0),
              ocrText: const ImageText(
                '图片中的文字现在可以像正文一样阅读、选择、复制和搜索。原图仍可通过双击查看，原有的位置和笔记锚点保持稳定。\nA faithful transcript can wrap with the reading font and preserve its original image anchor.',
              ),
            ),
            ImageBlock(
              href: 'code.png',
              source: source('code', 0),
              ocrText: const ImageText(
                '<a href="https://example.test">\n  Literal code stays unchanged.\n</a>',
                literal: true,
              ),
            ),
          ],
        );
        final pages = LayoutEngine().paginate(
          section,
          const LayoutViewport(width: 360, height: 640),
          ReaderStyle(
            baseFontSize: 19,
            writingSystem: WritingSystem.cjk,
            foreground: dark ? 0xffe6e6e6 : 0xff222222,
          ),
        );
        addTearDown(() {
          for (final p in pages) {
            p.dispose();
          }
        });
        expect(pages, hasLength(1));
        final recorder = ui.PictureRecorder(), canvas = Canvas(recorder);
        PagePainter(
          page: pages.single,
          imageResolver: (_) => null,
          background: dark ? const Color(0xff171717) : const Color(0xfffaf8f3),
        ).paint(canvas, const Size(360, 640));
        final picture = recorder.endRecording(),
            image = await picture.toImage(360, 640);
        try {
          final bytes = (await image.toByteData(
            format: ui.ImageByteFormat.png,
          ))!;
          final output = File(
            '../output/torto-app-081-complete/reading-${dark ? 'dark' : 'light'}.png',
          );
          await output.parent.create(recursive: true);
          await output.writeAsBytes(
            bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
          );
        } finally {
          image.dispose();
          picture.dispose();
        }
      },
    );
  }
}
