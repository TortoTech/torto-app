import 'dart:convert';
import 'dart:ui' as ui;
import '../../core/ir/ir.dart';
import '../../core/ir/text_index.dart';
import '../../core/layout/focus_layout.dart';
import '../../core/reading/reading_units.dart';
import '../reader/reader_controller.dart';
import '../reader/text_selection_layer.dart';
import 'book_citations.dart';

class ReaderBookTools {
  final ReaderController controller;
  final ReaderSelection? selection;
  final Map<String, String> _readBlocks = {};
  ReaderBookTools(this.controller, {this.selection});
  Future<Map<String, dynamic>> execute(
    String action,
    Map<String, dynamic> args, {
    bool wholeBook = false,
    bool confirmed = false,
  }) async {
    final source = controller.assistantSource;
    if (source == null) throw StateError('Book closed');
    final book = source.book;
    if (action == 'getCurrentPosition') {
      return {
        'unit': controller.sectionIndex,
        'kind': controller.pdfSource == null ? 'section' : 'page',
        'anchor': controller.readingAnchor?.toJson(),
        if (controller.pdfSource != null)
          'citation': pageCitation(controller.sectionIndex),
      };
    }
    if (action == 'getBookMetadata') {
      return {
        'title': controller.title,
        'authors': book.metadata.authors,
        'languages': book.metadata.languages,
        'units': book.sectionCount,
        'kind': controller.pdfSource == null ? 'section' : 'page',
      };
    }
    if (action == 'getCurrentSelection') {
      return {
        'text': selection?.quote ?? '',
        'citations': [
          for (final range in selection?.ranges ?? <SourceRange>[])
            sourceCitation(range),
        ],
      };
    }
    if (action == 'getTOC') {
      final entries = <Map<String, dynamic>>[];
      void visit(List<TocEntry> toc, int depth) {
        for (final entry in toc) {
          if (entries.length >= 128) return;
          entries.add({
            'title': entry.label,
            'href': entry.href,
            'depth': depth,
            'unit': entry.spineIndex,
            'citation':
                '[${entry.label.replaceAll('[', '').replaceAll(']', '')}](torto://toc?href=${Uri.encodeComponent(entry.href)})',
          });
          visit(entry.children, depth + 1);
        }
      }

      visit(controller.toc, 0);
      return {'items': entries};
    }
    if (action == 'getAnnotations' || action == 'searchAnnotations') {
      await controller.loadAnnotations();
      final query = (args['query'] as String? ?? '').toLowerCase();
      return {
        'items': [
          for (final note
              in controller.annotations
                  .where(
                    (n) =>
                        wholeBook ||
                        n.ranges.any(
                          (r) =>
                              r.start.spine ==
                              book.spine[controller.sectionIndex].id,
                        ),
                  )
                  .where(
                    (n) =>
                        query.isEmpty ||
                        '${n.quote} ${n.note ?? ''}'.toLowerCase().contains(
                          query,
                        ),
                  )
                  .take(30))
            {
              'id': note.id,
              'quote': note.quote,
              'note': note.note,
              'citations': [
                for (final range in note.ranges) sourceCitation(range),
              ],
            },
        ],
      };
    }
    if (action == 'annotation') {
      final operation = args['operation'] ?? 'create';
      if (!const {'create', 'update', 'delete'}.contains(operation)) {
        return {'error': 'Unknown annotation operation.'};
      }
      await controller.loadAnnotations();
      final old = controller.annotations
          .where((n) => n.id == args['id'])
          .firstOrNull;
      if (operation == 'create' &&
          (selection == null || selection!.ranges.isEmpty)) {
        return {
          'error': 'Creating an annotation requires a current user selection.',
        };
      }
      if (operation != 'create' && old == null) {
        return {'error': 'Unknown annotation identity.'};
      }
      if (!confirmed) {
        return {
          'pending_confirmation': true,
          'operation': operation,
          'quote': old?.quote ?? selection?.quote,
          'note': args['note'],
        };
      }
      await controller.saveAnnotation(
        old?.ranges ?? selection!.ranges,
        old?.quote ?? selection!.quote,
        note: args['note'] as String?,
        previous: old,
        delete: operation == 'delete',
      );
      return {'status': 'applied'};
    }
    if (action == 'rewriteBlocks') {
      if (controller.translationEnabled) {
        return {
          'error':
              'Switch to original text before proposing a temporary rewrite.',
        };
      }
      final blocks = args['blocks'];
      if (blocks is! Map) {
        return {
          'error':
              'Supply blocks as an object mapping previously read block IDs to replacement text.',
        };
      }
      if (blocks.isEmpty ||
          blocks.keys.any((id) => !_readBlocks.containsKey(id))) {
        return {
          'error':
              'Read every block with getContent before proposing a rewrite.',
        };
      }
      if (!confirmed) {
        return {
          'pending_confirmation': true,
          'operation': 'rewriteBlocks',
          'blocks': blocks,
          'original': {for (final id in blocks.keys) id: _readBlocks[id]},
          'persistent': false,
        };
      }
      await controller.rewriteAssistantBlocks(Map<String, String>.from(blocks));
      return {'status': 'applied', 'persistent': false};
    }
    final index = (args['unit'] as num?)?.toInt() ?? controller.sectionIndex;
    if (index < 0 || index >= book.sectionCount) {
      return {'error': 'Unit outside book.'};
    }
    if (!wholeBook && index != controller.sectionIndex) {
      return {'error': 'Enable whole-book scope to inspect another unit.'};
    }
    final pdf = controller.pdfSource;
    if (action == 'getVisualContent') {
      final page = await source.parseSection(index);
      final image = page.blocks.whereType<ImageBlock>().firstOrNull;
      if (image == null) return {'error': 'No visual page'};
      ui.Image? raster;
      if (pdf != null) {
        raster = await pdf.rasterResource(image.href, maxDimension: 1600);
      } else {
        final bytes = await source.resource(image.href);
        if (bytes == null || bytes.length > 20 * 1024 * 1024) {
          return {'error': 'Image resource unavailable or too large'};
        }
        final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
        ui.ImageDescriptor? descriptor;
        ui.Codec? codec;
        try {
          descriptor = await ui.ImageDescriptor.encoded(buffer);
          final scale =
              (1600 /
                      (descriptor.width > descriptor.height
                          ? descriptor.width
                          : descriptor.height))
                  .clamp(0.0, 1.0);
          codec = await descriptor.instantiateCodec(
            targetWidth: (descriptor.width * scale).round().clamp(1, 1600),
            targetHeight: (descriptor.height * scale).round().clamp(1, 1600),
          );
          raster = (await codec.getNextFrame()).image;
        } finally {
          codec?.dispose();
          descriptor?.dispose();
          buffer.dispose();
        }
      }
      if (raster == null) return {'error': 'Could not render page'};
      try {
        final data = await raster.toByteData(format: ui.ImageByteFormat.png);
        return {
          'unit': index,
          'citation': pdf != null
              ? pageCitation(index)
              : image.source == null
              ? null
              : sourceCitation(image.source!),
          'images': [
            {
              'type': 'image_url',
              'image_url': {
                'url':
                    'data:image/png;base64,${base64Encode(data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes))}',
              },
            },
          ],
        };
      } finally {
        raster.dispose();
      }
    }
    if (action != 'getCurrentContext' && action != 'getContent') {
      return {'error': 'Unknown book tool'};
    }
    if (pdf != null) {
      final text = pdf.pageText(index)?.text ?? '';
      return {
        'unit': index,
        'kind': 'page',
        'visual': text.trim().isEmpty,
        'citation': pageCitation(index),
        'text': text.substring(0, text.length.clamp(0, 14000)),
      };
    }
    final section = await source.parseSection(index);
    Iterable<BookTextNode> nodes = sectionTextNodes(section);
    if (index == controller.sectionIndex &&
        (action == 'getCurrentContext' || args['scope'] == 'chapter')) {
      final anchor = controller.readingAnchor;
      final at = section.blocks.indexWhere(
        (b) => FocusUnitBuilder.sources(
          b,
        ).any((s) => s.start.node == anchor?.node),
      );
      final boundaries = ReadingUnitIndex.build(
        section,
        section.blocks,
        controller.toc,
      ).starts;
      final first = boundaries.where((n) => n <= at).lastOrNull ?? 0;
      final end =
          boundaries.where((n) => n > at).firstOrNull ?? section.blocks.length;
      final allowed = section.blocks
          .sublist(first, end)
          .expand(FocusUnitBuilder.sources)
          .map((s) => s.start.node)
          .toSet();
      nodes = nodes.where((n) => allowed.contains(n.source.start.node));
    }
    final offset = ((args['offset'] as num?)?.toInt() ?? 0).clamp(0, 100000);
    final limit = ((args['limit'] as num?)?.toInt() ?? 40).clamp(1, 80);
    final values = nodes.toList(), output = <Map<String, dynamic>>[];
    var budget = 14000;
    for (final node in values.skip(offset).take(limit)) {
      if (budget <= 0) break;
      final text = node.text.substring(0, node.text.length.clamp(0, budget));
      budget -= text.length;
      output.add({
        'id': '$index/${node.source.start.node}',
        'text': text,
        'truncated': text.length != node.text.length,
        'citation': sourceCitation(node.source),
      });
      if (text.length == node.text.length) {
        _readBlocks['$index/${node.source.start.node}'] = text;
      }
    }
    return {
      'unit': index,
      'scope': 'chapter',
      'blocks': output,
      'next_offset': offset + output.length < values.length
          ? offset + output.length
          : null,
    };
  }
}
