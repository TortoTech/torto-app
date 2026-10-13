import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:pdf_document/pdf_document.dart' as pdf;
import 'package:pdf_graphics/pdf_graphics.dart' as graphics;
import '../../ir/ir.dart';
import 'pdf_book_source.dart';
import 'pdf_provenance.dart';
import 'native_store.dart';

/// Native extraction runs off the UI thread. Visual fallback uses the same
/// portable recording/raster pipeline as the original-page reader.
class PdfNativeGenerator {
  Isolate? _worker;
  ReceivePort? _port;
  Completer<Object?>? _result;
  bool _cancelled = false;
  void cancel() {
    _cancelled = true;
    _worker?.kill(priority: Isolate.immediate);
    _port?.close();
    final result = _result;
    if (result != null && !result.isCompleted) {
      result.completeError(StateError('Cancelled'));
    }
  }

  void _check() {
    if (_cancelled) throw StateError('Cancelled');
  }

  Future<Object?> _run(
    void Function((SendPort, Map<String, dynamic>)) entry,
    Map<String, dynamic> args,
    void Function(int, int)? progress,
  ) async {
    _check();
    final port = _port = ReceivePort();
    final completion = _result = Completer<Object?>();
    final subscription = port.listen((value) {
      if (value is List && value.first == 'progress') {
        progress?.call(value[1] as int, value[2] as int);
      } else if (value is List && value.first == 'done') {
        if (!completion.isCompleted) completion.complete(value[1]);
      } else if (!completion.isCompleted) {
        completion.completeError(StateError('PDF conversion failed: $value'));
      }
    });
    try {
      _worker = await Isolate.spawn(entry, (
        port.sendPort,
        args,
      ), onError: port.sendPort);
      if (_cancelled) _worker?.kill(priority: Isolate.immediate);
      return await completion.future.timeout(const Duration(hours: 1));
    } finally {
      _worker?.kill(priority: Isolate.immediate);
      _worker = null;
      await subscription.cancel();
      port.close();
      _port = null;
      _result = null;
    }
  }

  Future<Map<String, dynamic>> generate({
    required File file,
    required PdfBookSource original,
    required Directory root,
    void Function(int, int)? onProgress,
  }) async {
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(original.book.id)) {
      throw const FormatException('Invalid book identity');
    }
    _check();
    await root.create(recursive: true);
    final jobs = await Directory(
      '${root.path}/native-jobs',
    ).create(recursive: true);
    final staging = await jobs.createTemp('generation-');
    try {
      final book = _book(original.book);
      final result =
          await _run(_extractNative, {
                'file': file.path,
                'root': staging.path,
                'book': book,
                'expected_sha256': original.contentSha256,
              }, onProgress)
              as Map;
      var outputBytes = result['bytes'] as int;
      _check();
      for (final page in (result['fallback'] as List).cast<int>()) {
        final href = (await original.parseSection(
          page,
        )).blocks.whereType<ImageBlock>().single.href;
        final bytes = await original.resource(href);
        _check();
        if (bytes == null || bytes.length > 64 * 1024 * 1024) {
          throw StateError('Could not preserve PDF page ${page + 1}');
        }
        outputBytes += bytes.length;
        if (outputBytes > 760 * 1024 * 1024) {
          throw const FormatException(
            'Native PDF archive exceeds storage budget',
          );
        }
        await File(
          '${staging.path}/resources/page-$page.png',
        ).writeAsBytes(bytes, flush: true);
        onProgress?.call(page + 1, original.pageCount);
        await Future<void>.delayed(Duration.zero);
      }
      final digest =
          await _run(_packNative, {'root': staging.path}, null) as String;
      _check();
      await withNativeStore(root, () async {
        _check();
        await recoverNativePair(root);
        String? base;
        try {
          final previous =
              jsonDecode(
                    await File('${root.path}/native-pdf.json').readAsString(),
                  )
                  as Map;
          base =
              (previous['pending_upload'] == true
                      ? previous['base_content_sha256']
                      : previous['content_sha256'])
                  as String?;
        } catch (_) {}
        final archive = File('${staging.path}/native-pdf.zip');
        final metadata = {
          'version': 1,
          'book_id': original.book.id,
          'content_sha256': digest,
          'content_length': await archive.length(),
          'source_ir_version': 14,
          'producer': 'torto-app',
          'pending_upload': true,
          'base_content_sha256': base,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        };
        _check();
        await installNativePair(
          root,
          archive,
          utf8.encode(jsonEncode(metadata)),
        );
      });
      return Map<String, dynamic>.from(result['stats'] as Map);
    } finally {
      if (await staging.exists()) await staging.delete(recursive: true);
    }
  }
}

Map<String, dynamic> _url(String href) {
  final parts = href.split('#');
  return {
    'path': parts.first,
    if (parts.length > 1) 'fragment': parts.skip(1).join('#'),
  };
}

Map<String, dynamic> _book(Book book) => {
  'id': book.id,
  'metadata': {
    'title': book.metadata.title,
    'authors': book.metadata.authors,
    'languages': book.metadata.languages,
    'layout': 'reflowable',
  },
  'cover': null,
  'sections': [
    for (final spine in book.spine)
      {
        'id': spine.id.value,
        'href': _url(spine.href),
        'media_type': 'application/xhtml+xml',
        'linear': true,
        'properties': [],
      },
  ],
  'table_of_contents': _toc(book.toc),
};
List<Map<String, dynamic>> _toc(List<TocEntry> entries) => [
  for (final entry in entries)
    {
      'label': entry.label,
      'href': _url(entry.href),
      'children': _toc(entry.children),
    },
];
Map<String, dynamic> _anchor(String spine, String node, int offset) => {
  'spine': spine,
  'node': node,
  'text_offset': offset,
};
Map<String, dynamic> _range(String spine, String node, int start, int end) => {
  'start': _anchor(spine, node, start),
  'end': _anchor(spine, node, end),
};
const _style = {
  'align': 'Start',
  'margin_before': 0,
  'margin_after': 0,
  'indent': 0,
  'line_height': 1.5,
};
const _runStyle = {
  'bold': false,
  'italic': false,
  'underline': false,
  'size_scale': 1,
  'color': {'red': 0, 'green': 0, 'blue': 0, 'alpha': 255},
};

void _extractNative((SendPort, Map<String, dynamic>) args) {
  final port = args.$1, options = args.$2;
  try {
    final directory = options['root'] as String;
    Directory('$directory/sections').createSync();
    Directory('$directory/resources').createSync();
    final original = Map<String, dynamic>.from(options['book'] as Map);
    final input = File(options['file'] as String).readAsBytesSync();
    if (sha256.convert(input).toString() != options['expected_sha256']) {
      throw const FormatException('PDF content changed during conversion');
    }
    final document = pdf.PdfDocument.open(input);
    if (document.pageCount != (original['sections'] as List).length) {
      throw const FormatException('PDF changed during conversion');
    }
    final count = document.pageCount;
    if (count > 10000) {
      throw const FormatException('Native PDF exceeds section budget');
    }
    final fallback = <int>[],
        resources = <String>[],
        sections = <Map<String, dynamic>>[],
        targets = <Map<String, dynamic>>[];
    final chapterPages = <int>{0};
    void collect(List<dynamic> entries) {
      for (final raw in entries) {
        final entry = raw as Map, href = (entry['href'] as Map)['path'];
        final index = (original['sections'] as List).indexWhere(
          (s) => (s['href'] as Map)['path'] == href,
        );
        if (index >= 0) chapterPages.add(index);
        collect(entry['children'] as List);
      }
    }

    collect(original['table_of_contents'] as List);
    var glyphs = 0, textPages = 0, unmapped = 0, outputBytes = 0;
    for (var page = 0; page < count; page++) {
      final spine = 'pdf-native-app-v1-$page', href = 'Text/native-$page.xhtml';
      sections.add({
        'id': spine,
        'href': _url(href),
        'media_type': 'application/xhtml+xml',
        'linear': true,
        'properties': [
          if (!chapterPages.contains(page)) 'rebook-continuation-section',
        ],
      });
      targets.add(_url('$href#pdf-page-${page + 1}'));
      graphics.PdfPageText? text;
      try {
        text = graphics.PdfTextExtractor.extract(document, page);
      } catch (_) {}
      final blocks = <Map<String, dynamic>>[],
          mappings = <Map<String, dynamic>>[];
      final runs =
          text?.runs.where((r) => r.text.trim().isNotEmpty).toList() ?? [];
      final glyphStarts = <graphics.PdfExtractedRun, int>{};
      var pageGlyphs = 0;
      for (final run in runs) {
        glyphStarts[run] = pageGlyphs;
        pageGlyphs += run.text.runes.length;
      }
      glyphs += pageGlyphs;
      final heights =
          runs.map((r) => r.bounds.height.abs()).where((v) => v > 0).toList()
            ..sort();
      final median = heights.isEmpty ? 12.0 : heights[heights.length ~/ 2];
      final unreliable =
          pageGlyphs > 100000 ||
          text == null ||
          text.text.trim().length < 8 ||
          text.text.contains('\ufffd') ||
          runs.length > 100000 ||
          runs.any((r) => r.transform.a.abs() < r.transform.b.abs());
      // Preserve complex graphic pages in full. Never silently lose charts,
      // scans or illustrations while extracting the surrounding prose.
      final hasGraphics = document.page(page).resources['XObject'] != null;
      if (unreliable || hasGraphics) {
        fallback.add(page);
        final image = 'resources/page-$page.png';
        resources.add(image);
        blocks.add({
          'Image': {
            'href': _url(image),
            'alt': 'PDF page ${page + 1}',
            'style': {
              'width': null,
              'height': null,
              'max_width': null,
              'max_height': null,
            },
            'source': _range(spine, 'n0', 0, 0),
          },
        });
      } else {
        textPages++;
        final reflow = graphics.PdfTextReflower.reflow(text);
        var node = 0;
        for (final paragraph in reflow.blocks) {
          final id = 'n${node++}', prose = paragraph.text;
          final heading =
              paragraph.fontSize > median * 1.3 && prose.runes.length < 160;
          var cursor = 0;
          for (final run in runs.where(
            (r) =>
                r.bounds.intersect(paragraph.bounds).height > 0 &&
                r.bounds.intersect(paragraph.bounds).width > 0,
          )) {
            final at = prose.indexOf(run.text, cursor);
            if (at < 0) {
              unmapped += run.text.runes.length;
              continue;
            }
            final start = prose.substring(0, at).runes.length;
            cursor = at + run.text.length;
            var units = 0, scalar = 0;
            final crop = document.page(page).cropBox;
            for (final rune in run.text.runes) {
              final length = rune > 0xffff ? 2 : 1;
              final quad = text
                  .quadsFor(
                    run.startIndex + units,
                    run.startIndex + units + length,
                  )
                  .firstOrNull;
              final bounds = quad?.bounds ?? run.bounds;
              mappings.add({
                'source': _range(spine, id, start + scalar, start + scalar + 1),
                'page': page,
                'rect': [
                  bounds.left - crop.left,
                  crop.top - bounds.top,
                  bounds.right - crop.left,
                  crop.top - bounds.bottom,
                ],
                'original_glyph': glyphStarts[run]! + scalar,
              });
              units += length;
              scalar++;
            }
          }
          blocks.add({
            'Text': {
              'kind': heading ? {'Heading': 1} : 'Paragraph',
              'style': _style,
              'source': _range(spine, id, 0, prose.runes.length),
              'content': [
                {
                  'Text': {
                    'text': prose,
                    'style': {..._runStyle, 'bold': heading},
                    'link': null,
                  },
                },
              ],
            },
          });
        }
      }
      final section = {
        'id': spine,
        'href': _url(href),
        'blocks': blocks,
        'anchors': [
          {
            'fragment': 'pdf-page-${page + 1}',
            'source': _anchor(spine, 'n0', 0),
          },
        ],
      };
      final provenance = 'resources/provenance-$page.bin.z';
      final encodedMappings = encodePdfProvenance(mappings);
      File('$directory/$provenance').writeAsBytesSync(encodedMappings);
      resources.add(provenance);
      final encoded = jsonEncode({
        'section': section,
        'provenance_resource': provenance,
      });
      outputBytes += utf8.encode(encoded).length + encodedMappings.length;
      if (outputBytes > 760 * 1024 * 1024) {
        throw const FormatException(
          'Native PDF archive exceeds storage budget',
        );
      }
      if (utf8.encode(encoded).length > 32 * 1024 * 1024) {
        throw const FormatException('PDF page exceeds reflow budget');
      }
      File('$directory/sections/$page.json').writeAsStringSync(encoded);
      port.send(['progress', page + 1, count]);
    }
    List<Map<String, dynamic>> retarget(List<dynamic> entries) => [
      for (final raw in entries)
        {
          'label': raw['label'],
          'href':
              targets[(original['sections'] as List)
                  .indexWhere((s) => s['href']['path'] == raw['href']['path'])
                  .clamp(0, count - 1)],
          'children': retarget(raw['children'] as List),
        },
    ];
    final stats = {
      'pages': count,
      'text_pages': textPages,
      'fallback_pages': fallback.length,
      'fallback_regions': 0,
      'tables': 0,
      'notes': 0,
      'glyphs': glyphs,
      'unmapped_glyphs': unmapped,
      'removed_chrome_glyphs': 0,
    };
    final manifest = {
      'version': 14,
      'original': original,
      'origin': 'embedded',
      'book': {
        ...original,
        'sections': sections,
        'table_of_contents': retarget(original['table_of_contents'] as List),
      },
      'page_targets': targets,
      'resources': resources,
      'stats': stats,
    };
    File('$directory/manifest.json').writeAsStringSync(jsonEncode(manifest));
    port.send([
      'done',
      {'fallback': fallback, 'stats': stats, 'bytes': outputBytes},
    ]);
  } catch (error) {
    port.send('$error');
  }
}

void _packNative((SendPort, Map<String, dynamic>) args) async {
  try {
    final root = args.$2['root'] as String;
    final zip = ZipFileEncoder();
    zip.create('$root/native-pdf.zip');
    try {
      await zip.addFile(File('$root/manifest.json'), 'manifest.json');
      final files = [
        ...Directory('$root/sections').listSync(),
        ...Directory('$root/resources').listSync(),
      ].whereType<File>().toList()..sort((a, b) => a.path.compareTo(b.path));
      for (final file in files) {
        await zip.addFile(
          file,
          file.path.substring(root.length + 1).replaceAll('\\', '/'),
        );
      }
    } finally {
      zip.closeSync();
    }
    final digest =
        (await sha256.bind(File('$root/native-pdf.zip').openRead()).first)
            .toString();
    args.$1.send(['done', digest]);
  } catch (error) {
    args.$1.send('$error');
  }
}
