import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../../core/ir/ir.dart';
import '../../core/ir/inline_content.dart';
import '../../core/layout/layout_engine.dart';
import '../../core/layout/layout_types.dart';
import '../../core/render/formula_rasterizer.dart';
import '../../core/semantic_layout/media_references.dart';
import '../../l10n/app_localizations.dart';
import '../../core/render/page_painter.dart';

List<List<Block>> mediaBlockCandidates(Section section, String reference) {
  final targets = <List<Block>>[];
  for (var i = 0; i < section.blocks.length; i++) {
    final block = section.blocks[i];
    if (block is FigureBlock &&
        block.captions.any(
          (t) => MediaReferences.captionKey(t.plainText) == reference,
        )) {
      targets.add([block]);
    } else if (block is TableBlock &&
        [
          ...block.before,
          ...block.after,
        ].any((t) => MediaReferences.captionKey(t.plainText) == reference)) {
      targets.add([block]);
    } else if (block is ImageBlock) {
      var end = i;
      while (end < section.blocks.length && section.blocks[end] is ImageBlock) {
        end++;
      }
      final captions = <TextBlock>[];
      for (
        var next = end;
        next < section.blocks.length &&
            section.blocks[next] is TextBlock &&
            (section.blocks[next] as TextBlock).kind == TextBlockKind.caption;
        next++
      ) {
        captions.add(section.blocks[next] as TextBlock);
      }
      if (captions.any(
        (t) => MediaReferences.captionKey(t.plainText) == reference,
      )) {
        targets.add([...section.blocks.sublist(i, end), ...captions]);
      }
      i = end - 1;
    }
  }
  return targets;
}

List<Block>? mediaBlocks(Section section, String reference) {
  final targets = mediaBlockCandidates(section, reference);
  return targets.length == 1 ? targets.single : null;
}

Future<List<Block>?> findMediaReference(
  BookSource source,
  int current,
  String reference, {
  bool Function()? cancelled,
}) async {
  final local = mediaBlockCandidates(
    await source.parseSection(current),
    reference,
  );
  // Numbering may restart in each chapter. An ambiguous local number must not
  // resolve to an unrelated chapter, and a local match takes precedence.
  if (local.isNotEmpty) return local.length == 1 ? local.single : null;
  List<Block>? result;
  for (var i = 0; i < source.book.sectionCount; i++) {
    if (i == current) continue;
    if (cancelled?.call() ?? false) return null;
    final candidates = mediaBlockCandidates(
      await source.parseSection(i),
      reference,
    );
    if (candidates.isEmpty) continue;
    if (result != null || candidates.length != 1) return null;
    result = candidates.single;
  }
  return result;
}

Future<void> showMediaReferencePreview(
  BuildContext context,
  BookSource source,
  int current,
  ReaderStyle style,
  String reference,
) async {
  final width = (MediaQuery.sizeOf(context).width - 40).clamp(240.0, 900.0);
  final height = (MediaQuery.sizeOf(context).height * .7).clamp(240.0, 1200.0);
  final images = <String, ui.Image>{}, sizes = <String, ui.Size>{};
  final formulas = FormulaRasterizer();
  final pages = <PageLayout>[];
  try {
    final blocks = await findMediaReference(
      source,
      current,
      reference,
      cancelled: () => !context.mounted,
    );
    if (blocks == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.l10n.text(
                '无法定位图表引用',
                'Could not locate this figure or table',
              ),
            ),
          ),
        );
      }
      return;
    }
    final resources = <String>{};
    for (final block in blocks) {
      mapBlockContent(
        block,
        (text) {
          resources.addAll(
            text.inlines.whereType<InlineImageRun>().map((i) => i.image.href),
          );
          return text;
        },
        image: (image) {
          resources.add(image.href);
          return image;
        },
      );
    }
    var imageBytes = 0;
    for (final href in resources) {
      final bytes = await source.resource(href);
      if (bytes == null) continue;
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      final codec = await ui.instantiateImageCodecWithSize(
        buffer,
        getTargetSize: (w, h) {
          sizes[href] = ui.Size(w.toDouble(), h.toDouble());
          final longest = w > h ? w : h;
          if (longest <= 4096) return const ui.TargetImageSize();
          return ui.TargetImageSize(
            width: (w * 4096 / longest).round().clamp(1, 4096),
            height: (h * 4096 / longest).round().clamp(1, 4096),
          );
        },
      );
      try {
        final image = (await codec.getNextFrame()).image;
        imageBytes += image.width * image.height * 4;
        if (imageBytes > 64 * 1024 * 1024) {
          image.dispose();
          throw const FormatException(
            'Preview exceeds the image memory budget',
          );
        }
        images[href] = image;
      } finally {
        codec.dispose();
      }
    }
    final section = Section(
      id: source.book.spine[current].id,
      spineIndex: current,
      href: source.book.spine[current].href,
      blocks: blocks,
    );
    await formulas.prepare(section, style.foreground);
    pages.addAll(
      await LayoutEngine(formulaResolver: formulas.lookup).paginateAsync(
        section,
        LayoutViewport(width: width, height: height),
        style.copyWith(
          focusMode: false,
          sentenceSplit: false,
          marginLeft: 16,
          marginRight: 16,
          marginTop: 16,
          marginBottom: 16,
        ),
        imageSizeResolver: (href) => sizes[href],
      ),
    );
    if (!context.mounted) return;
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: Colors.black.withValues(alpha: .65),
      pageBuilder: (context, _, _) => SafeArea(
        child: Center(
          child: Material(
            color: Colors.transparent,
            child: SizedBox(
              width: width,
              height: height,
              child: Column(
                children: [
                  Align(
                    alignment: Alignment.centerRight,
                    child: IconButton(
                      onPressed: () => Navigator.pop(context),
                      color: Colors.white,
                      icon: const Icon(Icons.close),
                    ),
                  ),
                  Expanded(
                    child: InteractiveViewer(
                      minScale: .5,
                      maxScale: 8,
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final page in pages)
                              SizedBox(
                                width: width,
                                height: height,
                                child: PageWidget(
                                  page: page,
                                  imageResolver: (href) =>
                                      formulas.image(href) ?? images[href],
                                  background: Color(style.background),
                                  foreground: Color(style.foreground),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  } finally {
    for (final page in pages) {
      page.dispose();
    }
    formulas.dispose();
    for (final image in images.values) {
      image.dispose();
    }
  }
}
