import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart' as fm;
import '../../core/layout/layout_types.dart';
import '../../l10n/app_localizations.dart';

({String href, bool formula})? readerImagePreviewTarget(
  PageLayout page,
  ui.Offset position,
) {
  for (final item in page.items) {
    if (item is ImagePlacement && item.rect.contains(position)) {
      return (
        href: item.originalImage ?? item.href,
        formula: item.latex != null,
      );
    }
    final ui.Paragraph paragraph;
    final ui.Offset origin;
    final ui.Rect clip;
    final List<InlineImageRange> images;
    switch (item) {
      case TextPlacement():
        paragraph = item.paragraph;
        origin = ui.Offset(item.x, item.y - item.sliceTop);
        clip = ui.Rect.fromLTWH(item.x, item.y, item.width, item.sliceHeight);
        images = item.inlineImages;
      case TableCellPlacement():
        paragraph = item.paragraph;
        origin = item.rect.topLeft + ui.Offset(item.padding, item.padding);
        clip = item.rect.deflate(item.padding);
        images = item.inlineImages;
      default:
        continue;
    }
    if (!clip.contains(position)) continue;
    final links = item is TextPlacement
        ? item.links
        : (item as TableCellPlacement).links;
    for (final link in links.where(
      (l) => l.originalImage != null && l.latex == null,
    )) {
      if (paragraph
          .getBoxesForRange(link.start, link.end)
          .any(
            (box) =>
                box.toRect().shift(origin).intersect(clip).contains(position),
          )) {
        return (href: link.originalImage!, formula: false);
      }
    }
    for (final image in images) {
      if (image.ruby != null || image.href.isEmpty) continue;
      final boxes = paragraph.getBoxesForRange(image.start, image.end);
      if (boxes.isEmpty) continue;
      final box = boxes.first;
      final rect = ui.Rect.fromLTWH(
        origin.dx + box.left + (box.right - box.left - image.width) / 2,
        origin.dy + box.top + image.paintOffsetY,
        image.width,
        image.height,
      );
      if (rect.contains(position)) return (href: image.href, formula: false);
    }
  }
  return null;
}

Future<void> _showMediaOverlay(BuildContext context, WidgetBuilder builder) =>
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: Colors.black.withValues(alpha: .65),
      transitionDuration: const Duration(milliseconds: 160),
      pageBuilder: (context, _, _) => SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(size: constraints.biggest, padding: EdgeInsets.zero),
            child: Material(
              type: MaterialType.transparency,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.pop(context),
                child: InteractiveViewer(
                  minScale: .5,
                  maxScale: 8,
                  clipBehavior: Clip.none,
                  boundaryMargin: const EdgeInsets.all(24),
                  child: SizedBox.expand(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Center(
                        child: GestureDetector(
                          onTap: () {},
                          child: Builder(builder: builder),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

/// The overlay owns no texture: the caller disposes it after this route closes.
Future<void> showReaderImagePreview(
  BuildContext context,
  Future<ui.Image?> image, {
  bool formula = false,
  String? recognizedText,
}) => _showMediaOverlay(
  context,
  (context) => FutureBuilder<ui.Image?>(
    future: image,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const SizedBox(
          width: 36,
          height: 36,
          child: CircularProgressIndicator(),
        );
      }
      final raster = snapshot.data;
      if (snapshot.hasError || raster == null) {
        return Text(
          context.l10n.text('无法读取图片', 'Could not load image'),
          style: const TextStyle(color: Colors.white),
        );
      }
      final viewport = MediaQuery.sizeOf(context),
          padding = MediaQuery.paddingOf(context);
      final scale = math.min(
        (viewport.width - 40) / raster.width,
        (viewport.height - padding.vertical - 40) *
            (recognizedText == null ? 1 : .65) /
            raster.height,
      );
      Widget content = SizedBox(
        key: const Key('reader-image-preview'),
        width: raster.width * scale,
        height: raster.height * scale,
        child: RawImage(
          image: raster,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.high,
        ),
      );
      if (formula) content = ColoredBox(color: Colors.white, child: content);
      if (recognizedText != null) {
        content = Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            content,
            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: viewport.width - 40,
                maxHeight: viewport.height * .25,
              ),
              child: SingleChildScrollView(
                child: ColoredBox(
                  color: Colors.white,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: SelectableText(
                      recognizedText,
                      style: const TextStyle(color: Colors.black, fontSize: 18),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      }
      return content;
    },
  ),
);

Future<void> showReaderFormulaPreview(BuildContext context, String latex) =>
    _showMediaOverlay(
      context,
      (context) => ColoredBox(
        key: const Key('reader-formula-preview'),
        color: Colors.white,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.sizeOf(context).width - 80,
              maxHeight: MediaQuery.sizeOf(context).height * .7,
            ),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: fm.Math.tex(
                latex,
                textStyle: const TextStyle(fontSize: 24, color: Colors.black),
                onErrorFallback: (_) =>
                    Text(latex, style: const TextStyle(color: Colors.black)),
              ),
            ),
          ),
        ),
      ),
    );
