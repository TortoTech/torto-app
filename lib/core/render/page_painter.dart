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
    final resolvedForeground =
        foreground ??
        (background.computeLuminance() > 0.5 ? Colors.black : Colors.white);
    final separatorColor = resolvedForeground.withAlpha(102);
    final tableCells = <TableCellPlacement>[];

    for (final item in page.items) {
      switch (item) {
        case TextPlacement():
          // Clip to the visible line slice, then draw the whole retained
          // paragraph offset so the slice lands at (x, y).
          canvas.save();
          canvas.clipRect(
            ui.Rect.fromLTWH(0, item.y, size.width, item.sliceHeight),
          );
          canvas.drawParagraph(
            item.paragraph,
            ui.Offset(item.x, item.y - item.sliceTop),
          );
          canvas.restore();
        case ListMarkerPlacement():
          canvas.drawParagraph(item.paragraph, ui.Offset(item.x, item.y));
        case TableCellPlacement():
          tableCells.add(item);
          if (item.header) {
            canvas.drawRect(
              item.rect,
              Paint()..color = resolvedForeground.withAlpha(22),
            );
          }
          canvas.save();
          canvas.clipRect(item.rect.deflate(item.padding));
          canvas.drawParagraph(
            item.paragraph,
            ui.Offset(
              item.rect.left + item.padding,
              item.rect.top + item.padding,
            ),
          );
          canvas.restore();
        case ImagePlacement():
          final image = imageResolver(item.href);
          if (image != null) {
            canvas.drawImageRect(
              image,
              ui.Rect.fromLTWH(
                0,
                0,
                image.width.toDouble(),
                image.height.toDouble(),
              ),
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

    // A cell-by-cell rectangle stroke paints every shared edge twice, making
    // inner rules visibly darker than the table outline. Build the union of
    // all horizontal and vertical edges and submit it as one path instead.
    _paintTableGrid(canvas, tableCells, resolvedForeground.withAlpha(96));
  }

  @override
  bool shouldRepaint(PagePainter oldDelegate) =>
      !identical(oldDelegate.page, page) ||
      oldDelegate.background != background ||
      oldDelegate.foreground != foreground;
}

const double _gridMergeTolerance = 0.001;
const double _gridCoordinateScale = 1000;

void _paintTableGrid(
  Canvas canvas,
  List<TableCellPlacement> cells,
  Color color,
) {
  if (cells.isEmpty) return;

  final horizontal = <int, _GridLineBucket>{};
  final vertical = <int, _GridLineBucket>{};

  for (final cell in cells) {
    _addGridInterval(
      horizontal,
      cell.rect.top,
      cell.rect.left,
      cell.rect.right,
    );
    _addGridInterval(
      horizontal,
      cell.rect.bottom,
      cell.rect.left,
      cell.rect.right,
    );
    _addGridInterval(vertical, cell.rect.left, cell.rect.top, cell.rect.bottom);
    _addGridInterval(
      vertical,
      cell.rect.right,
      cell.rect.top,
      cell.rect.bottom,
    );
  }

  final path = ui.Path();
  _appendGridLines(path, horizontal.values, horizontal: true);
  _appendGridLines(path, vertical.values, horizontal: false);
  canvas.drawPath(
    path,
    Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..strokeCap = StrokeCap.butt,
  );
}

void _addGridInterval(
  Map<int, _GridLineBucket> buckets,
  double coordinate,
  double start,
  double end,
) {
  final key = (coordinate * _gridCoordinateScale).round();
  final bucket = buckets.putIfAbsent(key, () => _GridLineBucket(coordinate));
  bucket.intervals.add(_GridInterval(start, end));
}

void _appendGridLines(
  ui.Path path,
  Iterable<_GridLineBucket> buckets, {
  required bool horizontal,
}) {
  for (final bucket in buckets) {
    final intervals = bucket.intervals
      ..sort((a, b) => a.start.compareTo(b.start));
    var start = intervals.first.start;
    var end = intervals.first.end;

    void append() {
      if (horizontal) {
        path
          ..moveTo(start, bucket.coordinate)
          ..lineTo(end, bucket.coordinate);
      } else {
        path
          ..moveTo(bucket.coordinate, start)
          ..lineTo(bucket.coordinate, end);
      }
    }

    for (final interval in intervals.skip(1)) {
      if (interval.start <= end + _gridMergeTolerance) {
        end = interval.end > end ? interval.end : end;
      } else {
        append();
        start = interval.start;
        end = interval.end;
      }
    }
    append();
  }
}

class _GridLineBucket {
  final double coordinate;
  final List<_GridInterval> intervals = [];

  _GridLineBucket(this.coordinate);
}

class _GridInterval {
  final double start;
  final double end;

  const _GridInterval(this.start, this.end);
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
