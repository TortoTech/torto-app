/// Render stage: paints a [PageLayout] display list onto a Flutter canvas.
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../layout/layout_types.dart';

/// Paints one paginated page: background fill, text slices (clipped to their
/// line range), images, and separator rules.
class PagePainter extends CustomPainter {
  final PageLayout page;

  /// Resolves an image href to decoded pixels. Returning null skips the
  /// image silently (its rectangle stays background-colored).
  final ui.Image? Function(String href) imageResolver;

  final Color background;

  /// Base foreground used to derive the muted separator color. When null it
  /// is inferred from [background] luminance.
  final Color? foreground;

  PagePainter({
    required this.page,
    required this.imageResolver,
    required this.background,
    this.foreground,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(ui.Offset.zero & size, Paint()..color = background);
    final separatorColor = (foreground ??
            (background.computeLuminance() > 0.5 ? Colors.black : Colors.white))
        .withAlpha(102);

    for (final item in page.items) {
      switch (item) {
        case TextPlacement():
          // Clip to the visible line slice, then draw the whole retained
          // paragraph offset so the slice lands at (x, y).
          canvas.save();
          canvas.clipRect(
              ui.Rect.fromLTWH(0, item.y, size.width, item.sliceHeight));
          canvas.drawParagraph(
              item.paragraph, ui.Offset(item.x, item.y - item.sliceTop));
          canvas.restore();
        case ImagePlacement():
          final image = imageResolver(item.href);
          if (image != null) {
            canvas.drawImageRect(
              image,
              ui.Rect.fromLTWH(
                  0, 0, image.width.toDouble(), image.height.toDouble()),
              item.rect,
              Paint(),
            );
          }
        case SeparatorPlacement():
          canvas.drawLine(
            item.rect.centerLeft,
            item.rect.centerRight,
            Paint()
              ..color = separatorColor
              ..strokeWidth = item.rect.height,
          );
      }
    }
  }

  @override
  bool shouldRepaint(PagePainter oldDelegate) =>
      !identical(oldDelegate.page, page) ||
      oldDelegate.background != background ||
      oldDelegate.foreground != foreground;
}

/// Drop-in widget that paints a [PageLayout] at the page's viewport size.
class PageWidget extends StatelessWidget {
  final PageLayout page;
  final ui.Image? Function(String href) imageResolver;
  final Color background;
  final Color? foreground;

  const PageWidget({
    super.key,
    required this.page,
    required this.background,
    ui.Image? Function(String href)? imageResolver,
    this.foreground,
  }) : imageResolver = imageResolver ?? _noImage;

  static ui.Image? _noImage(String href) => null;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: page.viewport.width,
      height: page.viewport.height,
      child: CustomPaint(
        painter: PagePainter(
          page: page,
          imageResolver: imageResolver,
          background: background,
          foreground: foreground,
        ),
      ),
    );
  }
}
