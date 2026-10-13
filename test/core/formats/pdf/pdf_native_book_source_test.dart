import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torto/core/formats/pdf/pdf_native_book_source.dart';
import 'package:torto/core/formats/pdf/pdf_reflow_source.dart';
import 'package:torto/core/formats/desktop_ir_codec.dart';
import 'package:torto/core/ir/ir.dart';
import 'package:torto/core/ir/text_index.dart';
import 'package:torto/core/layout/layout_engine.dart';
import 'package:torto/core/layout/layout_types.dart';
import 'pdf_ocr_book_source_test.dart' show OriginalSource;

Map<String, dynamic> fixtureManifest({String id = 'book'}) => {
  'version': 14,
  'original': {'id': id},
  'book': {
    'id': id,
    'metadata': {
      'title': 'Native',
      'authors': [],
      'languages': ['en'],
      'layout': 'reflowable',
    },
    'cover': null,
    'sections': [
      for (var i = 0; i < 2; i++)
        {
          'id': 'pdf-native-v14-$i',
          'href': 'Text/native-$i.xhtml',
          'linear': true,
          'properties': i == 0 ? [] : ['rebook-continuation-section'],
        },
    ],
    'table_of_contents': [
      {
        'label': 'Chapter',
        'href': 'Text/native-0.xhtml#pdf-page-1',
        'children': [],
      },
    ],
  },
  'page_targets': [
    for (var p = 1; p <= 4; p++)
      'Text/native-${p <= 2 ? 0 : 1}.xhtml#pdf-page-$p',
  ],
  'resources': [],
  'stats': {'pages': 4},
};

Map<String, dynamic> fixtureSection(int i, String text) {
  final anchor = {'spine': 'pdf-native-v14-$i', 'node': 'n0', 'text_offset': 0};
  return {
    'section': {
      'id': 'pdf-native-v14-$i',
      'href': 'Text/native-$i.xhtml',
      'blocks': [
        {
          'Text': {
            'kind': 'Paragraph',
            'style': {},
            'source': {
              'start': anchor,
              'end': {...anchor, 'text_offset': text.runes.length},
            },
            'content': [
              {
                'Text': {'text': text, 'style': {}, 'link': null},
              },
            ],
          },
        },
      ],
      'anchors': [
        {'fragment': 'pdf-page-${i * 2 + 1}', 'source': anchor},
        {
          'fragment': 'pdf-page-${i * 2 + 2}',
          'source': {...anchor, 'text_offset': text.runes.length},
        },
      ],
    },
    'provenance': [],
  };
}

Future<void> writeNative(
  Directory root, {
  String text = 'First native chapter.',
  String id = 'book',
  bool unsafe = false,
}) async {
  final files = {
    'manifest.json': fixtureManifest(id: id),
    'sections/0.json': fixtureSection(0, text),
    'sections/1.json': fixtureSection(1, 'Continuation across storage chunks.'),
    if (unsafe) '../outside.json': {},
  };
  final archive = Archive();
  for (final entry in files.entries) {
    final bytes = utf8.encode(jsonEncode(entry.value));
    archive.add(ArchiveFile(entry.key, bytes.length, bytes));
  }
  await File(
    '${root.path}/native-pdf.zip',
  ).writeAsBytes(ZipEncoder().encode(archive));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(
    () async => root = await Directory.systemTemp.createTemp('torto-native-'),
  );
  tearDown(() => root.delete(recursive: true));

  test('desktop serde uses kebab-case language and hyphenation hints', () {
    final run = DesktopIrCodec().run({
      'text': 'colour',
      'link': null,
      'style': {
        'language': 'english-gb',
        'hyphenation': 'manual',
        'display_writing_system': 'latin',
      },
    });
    expect(run.language, 'en-GB');
    expect(run.style.hyphenation, HyphenationMode.manual);
    expect(run.displayWritingSystem, WritingSystem.latin);
  });

  test('native fallback images map back to their own physical page', () async {
    final second = fixtureSection(1, '');
    final block = (second['section']['blocks'] as List).single as Map;
    final sourceRange = (block['Text'] as Map)['source'];
    second['section']['blocks'] = [
      {
        'Image': {
          'href': 'resources/fallback.png',
          'alt': '',
          'style': {},
          'source': sourceRange,
        },
      },
    ];
    final fourth = fixtureSection(1, 'Fourth physical page.');
    final fourthBlock = (fourth['section']['blocks'] as List).single as Map;
    final fourthRange = fourthBlock['Text']['source'] as Map;
    (fourthRange['start'] as Map)['node'] = 'n1';
    (fourthRange['end'] as Map)['node'] = 'n1';
    (second['section']['blocks'] as List).add(fourthBlock);
    (second['section']['anchors'] as List).last['source'] =
        fourthRange['start'];
    final manifest = fixtureManifest();
    manifest['resources'] = ['resources/fallback.png'];
    final archive = Archive();
    for (final entry in {
      'manifest.json': manifest,
      'sections/0.json': fixtureSection(0, 'Prose'),
      'sections/1.json': second,
    }.entries) {
      final bytes = utf8.encode(jsonEncode(entry.value));
      archive.add(ArchiveFile(entry.key, bytes.length, bytes));
    }
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l9sAAAAASUVORK5CYII=',
    );
    archive.add(ArchiveFile('resources/fallback.png', png.length, png));
    await File(
      '${root.path}/native-pdf.zip',
    ).writeAsBytes(ZipEncoder().encode(archive));
    final native = (await loadPdfNativeBookSource(OriginalSource(), root))!;
    addTearDown(native.dispose);
    final section = await native.parseSection(0);
    final image = section.blocks.whereType<ImageBlock>().single;
    expect(native.physicalPage(0, image.source!.start, section), 2);
    expect(await native.resource(image.href), png);
  });

  test(
    'desktop IR retains source IDs and joins continuation storage chunks',
    () async {
      await writeNative(root);
      final source = (await loadPdfNativeBookSource(OriginalSource(), root))!;
      addTearDown(source.dispose);
      expect(source.book.sectionCount, 1);
      expect(
        source.book.indexOfSpine(const SpineItemId('pdf-native-v14-1')),
        0,
      );
      final section = await source.parseSection(0);
      final nodes = sectionTextNodes(section).toList();
      expect(nodes.map((n) => n.source.start.spine.value), [
        'pdf-native-v14-0',
        'pdf-native-v14-1',
      ]);
      expect(source.reflowTarget(2), 'Text/native-0.xhtml#pdf-page-3');
      expect(source.physicalPage(0, nodes.last.source.start, section), 2);
      final pages = LayoutEngine().paginate(
        section,
        const LayoutViewport(width: 360, height: 640),
        const ReaderStyle(focusMode: true),
        readingToc: source.book.toc,
      );
      expect(pages, isNotEmpty);
      for (final page in pages) {
        page.dispose();
      }
    },
  );

  test(
    'a retained source keeps its immutable generation after replacement',
    () async {
      await writeNative(root, text: 'Old native content.');
      final old = (await loadPdfNativeBookSource(OriginalSource(), root))!;
      addTearDown(old.dispose);
      await writeNative(root, text: 'New native content.');
      final current = (await loadPdfNativeBookSource(OriginalSource(), root))!;
      addTearDown(current.dispose);
      expect(old.generation.path, isNot(current.generation.path));
      expect(
        ((await old.parseSection(0)).blocks.first as TextBlock).plainText,
        'Old native content.',
      );
      expect(
        ((await current.parseSection(0)).blocks.first as TextBlock).plainText,
        'New native content.',
      );
    },
  );

  test(
    'explicit original and legacy OCR choices survive new native results',
    () async {
      await writeNative(root);
      await File('${root.path}/view-mode.json').writeAsString('"reflow"');
      expect(await loadPdfNativeBookSource(OriginalSource(), root), isNull);
      await File('${root.path}/pdf-source.json').writeAsString('"original"');
      final source = (await loadPdfNativeBookSource(OriginalSource(), root))!;
      addTearDown(source.dispose);
      expect(source.mode, PdfOcrViewMode.original);
      source.mode = PdfOcrViewMode.reflow;
      await source.saveMode();
      expect(
        jsonDecode(await File('${root.path}/pdf-source.json').readAsString()),
        'native',
      );
    },
  );

  test(
    'missing physical-page fragments are rejected before publishing native data',
    () async {
      final manifest = fixtureManifest();
      (manifest['page_targets'] as List)[0] = 'Text/native-0.xhtml#missing';
      final archive = Archive();
      for (final entry in {
        'manifest.json': manifest,
        'sections/0.json': fixtureSection(0, 'First'),
        'sections/1.json': fixtureSection(1, 'Second'),
      }.entries) {
        final bytes = utf8.encode(jsonEncode(entry.value));
        archive.add(ArchiveFile(entry.key, bytes.length, bytes));
      }
      await File(
        '${root.path}/native-pdf.zip',
      ).writeAsBytes(ZipEncoder().encode(archive));
      await expectLater(
        loadPdfNativeBookSource(OriginalSource(), root),
        throwsFormatException,
      );
      expect(await Directory('${root.path}/native').list().toList(), isEmpty);
    },
  );
  test(
    'wrong book identities and escaping archive paths are rejected before publication',
    () async {
      await writeNative(root, id: 'another');
      await expectLater(
        loadPdfNativeBookSource(OriginalSource(), root),
        throwsFormatException,
      );
      await writeNative(root, unsafe: true);
      await expectLater(
        loadPdfNativeBookSource(OriginalSource(), root),
        throwsFormatException,
      );
      final entries = await Directory('${root.path}/native').list().toList();
      expect(entries, isEmpty);
    },
  );
}
