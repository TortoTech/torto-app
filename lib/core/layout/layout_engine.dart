/// Pagination for the Reading IR: turns a [Section] into a list of
/// [PageLayout]s. A Dart port of torto's `crates/layout` Paginator (column
/// cursor, collapsing margins, line-range slicing of paragraphs across
/// pages), built on `dart:ui` paragraphs instead of Parley.
///
/// Known approximations:
/// - Superscript/subscript runs are rendered at 0.7x size with NO baseline
///   shift (dart:ui's TextStyle has no baseline-shift support).
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import '../ir/ir.dart';
import 'layout_types.dart';

/// Default heading size scales by level, applied only when the IR left every
/// run at sizeScale 1.0.
const Map<int, double> _headingScales = {
  1: 1.6,
  2: 1.4,
  3: 1.25,
  4: 1.15,
  5: 1.05,
  6: 1.05,
};

/// Tolerance for floating-point fit checks, logical px.
const double _eps = 0.01;

class LayoutEngine {
  const LayoutEngine();

  /// Paginates [section] for [viewport] with [style]. Returns zero pages for
  /// a section with no placeable content (the caller handles that case).
  ///
  /// [imageResolver] is accepted for signature compatibility with the render
  /// stage but not used by layout; [imageSizeResolver] provides intrinsic
  /// image sizes (null return → a 1em square placeholder is reserved).
  List<PageLayout> paginate(
    Section section,
    LayoutViewport viewport,
    ReaderStyle style, {
    ui.Image? Function(String href)? imageResolver,
    ui.Size? Function(String href)? imageSizeResolver,
    String? coverHref,
    RenditionLayout renditionLayout = RenditionLayout.reflowable,
  }) {
    if (section.blocks.isEmpty) return const [];

    final contentLeft = style.marginLeft;
    final contentTop = style.marginTop;
    final contentWidth = math.max(
      1.0,
      viewport.width - style.marginLeft - style.marginRight,
    );
    final contentBottom = math.max(
      contentTop + 1.0,
      viewport.height - style.marginBottom,
    );
    final contentHeight = contentBottom - contentTop;

    // Cumulative UTF-16 text offsets, for progression computation.
    final textStartOf = <Block, double>{};
    var totalText = 0.0;
    for (final block in section.blocks) {
      final length = switch (block) {
        TextBlock(:final plainText) => plainText.length,
        TableBlock(:final textLength) => textLength,
        _ => 0,
      };
      if (length == 0) continue;
      textStartOf[block] = totalText;
      totalText += length;
    }

    final paginator = _Paginator(
      top: contentTop,
      bottom: contentBottom,
      left: contentLeft,
      width: contentWidth,
      centerStandaloneImage:
          renditionLayout == RenditionLayout.prePaginated ||
          _isStandaloneCover(section, coverHref),
    );

    for (final block in section.blocks) {
      switch (block) {
        case TextBlock():
          final prepared = _prepareText(
            block,
            style,
            section.spineIndex,
            contentLeft,
            contentWidth,
            textStartOf[block] ?? 0,
          );
          if (prepared == null) continue;
          paginator.pushText(prepared);
        case ImageBlock():
          _pushImage(
            paginator,
            block,
            style,
            imageSizeResolver,
            contentWidth,
            contentHeight,
            viewport.width,
          );
        case SeparatorBlock():
          paginator.pushSeparator(vMargin: style.baseFontSize * 0.75);
        case PageBreakBlock():
          paginator.forcePage();
        case TableBlock():
          final prepared = _prepareTable(
            block,
            style,
            section.spineIndex,
            contentWidth,
            textStartOf[block] ?? 0,
          );
          if (prepared != null) paginator.pushTable(prepared);
      }
    }

    final rawPages = paginator.finish();
    if (rawPages.isEmpty) return const [];

    final pages = <PageLayout>[];
    final disposalPool = ParagraphDisposalPool();
    var carriedProgression = 0.0;
    for (var i = 0; i < rawPages.length; i++) {
      final items = rawPages[i];
      SourceRange? firstSource;
      String? firstNodeId;
      int firstSpineIndex = section.spineIndex;
      var firstTextOffset = 0;
      double? firstSectionTextOffset;
      for (final item in items) {
        switch (item) {
          case TextPlacement():
            firstSource = item.source;
            firstNodeId = item.nodeId;
            firstSpineIndex = item.spineIndex;
            firstTextOffset = item.textOffsetAtStart;
            firstSectionTextOffset = item.sectionTextOffset;
          case TableCellPlacement():
            firstSource = item.source;
            firstNodeId = item.nodeId;
            firstSpineIndex = item.spineIndex;
            firstSectionTextOffset = item.sectionTextOffset;
          default:
            continue;
        }
        break;
      }
      SourceAnchor? anchor;
      var progression = carriedProgression;
      if (firstSectionTextOffset != null) {
        anchor = SourceAnchor(
          spine: firstSpineIndex,
          node: firstNodeId ?? '',
          textOffset: (firstSource?.start.textOffset ?? 0) + firstTextOffset,
        );
        if (totalText > 0) {
          progression = ((firstSectionTextOffset + firstTextOffset) / totalText)
              .clamp(0.0, 1.0);
        }
        carriedProgression = progression;
      }
      if (i == rawPages.length - 1) progression = 1.0;
      pages.add(
        PageLayout(
          viewport: viewport,
          items: items,
          firstAnchor: anchor,
          progression: progression,
          disposalPool: disposalPool,
        ),
      );
    }
    return pages;
  }

  /// Matches torto desktop's cover-alignment boundary: page breaks are not
  /// visible content, and an ordinary standalone illustration must remain in
  /// normal document flow rather than being mistaken for a cover.
  static bool _isStandaloneCover(Section section, String? coverHref) {
    if (coverHref == null) return false;
    final visibleBlocks = section.blocks
        .where((block) => block is! PageBreakBlock)
        .iterator;
    if (!visibleBlocks.moveNext()) return false;
    final first = visibleBlocks.current;
    return first is ImageBlock &&
        first.href == coverHref &&
        !visibleBlocks.moveNext();
  }

  /// Builds and lays out one paragraph for [block], or null when the block
  /// has no renderable text.
  _PreparedText? _prepareText(
    TextBlock block,
    ReaderStyle style,
    int spineIndex,
    double contentLeft,
    double contentWidth,
    double sectionTextOffset,
  ) {
    final baseSize = style.baseFontSize;
    final unified = style.typesettingMode == TypesettingMode.unified;
    final isHeading = block.kind == TextBlockKind.heading;
    final isPre = block.kind == TextBlockKind.preformatted;
    final isList = block.kind == TextBlockKind.listItem;
    final isQuote = block.kind == TextBlockKind.blockquote;

    var marginBefore = block.style.marginBefore;
    var marginAfter = block.style.marginAfter;
    var marginStart = block.style.marginStart;

    var blockScale = 1.0;
    var paragraphLineHeight = style.lineHeight * block.style.lineHeight;
    var resolvedAlign = block.style.align;

    if (unified) {
      marginBefore = 0;
      marginAfter = baseSize * 0.5;
      marginStart = 0;
      resolvedAlign = switch (block.kind) {
        TextBlockKind.paragraph => BlockAlign.justify,
        TextBlockKind.blockquote => block.style.align,
        _ => BlockAlign.start,
      };
      paragraphLineHeight = style.lineHeight;
      if (isHeading) {
        blockScale = _unifiedHeadingScale(block.headingLevel);
        paragraphLineHeight = 1.3;
        marginAfter = baseSize * 0.7;
      } else if (isPre) {
        blockScale = 0.9;
        paragraphLineHeight = 1.45;
      } else if (isQuote) {
        blockScale = 0.95;
        marginStart = baseSize * 2;
      }
    } else if (isHeading) {
      final allPlain = block.inlines.every(
        (i) => i is! TextRun || i.style.sizeScale == 1.0,
      );
      if (allPlain) {
        blockScale = _headingScales[block.headingLevel.clamp(1, 6)] ?? 1.0;
      }
      marginBefore = math.max(marginBefore, baseSize * 0.8);
      marginAfter = math.max(marginAfter, baseSize * 0.4);
    }
    if (!unified && isQuote) {
      marginStart += baseSize * 2;
    }

    var marker = '';
    var markerWidth = 0.0;
    if (isList) {
      if (block.listMarkerVisible) {
        marker = block.listOrdered
            ? '${block.listOrdinal}.'
            : _bulletForDepth(block.listDepth);
      }
      final semanticIndent = baseSize * 1.5 * (block.listDepth + 1);
      marginStart = unified
          ? semanticIndent
          : math.max(marginStart, semanticIndent);
    }

    final hasText = block.inlines.any(
      (i) => i is TextRun && i.text.isNotEmpty || i is BreakInline,
    );
    if (!hasText) return null;

    final foreground = ui.Color(style.foreground);
    final fontFamily = isPre ? 'monospace' : null;
    final align = switch (resolvedAlign) {
      BlockAlign.start => ui.TextAlign.left,
      BlockAlign.center => ui.TextAlign.center,
      BlockAlign.end => ui.TextAlign.right,
      BlockAlign.justify => ui.TextAlign.justify,
    };

    final builder = ui.ParagraphBuilder(
      ui.ParagraphStyle(
        textAlign: align,
        textDirection: ui.TextDirection.ltr,
        fontSize: baseSize * blockScale,
        height: paragraphLineHeight,
        fontFamily: fontFamily,
      ),
    );

    final indentWidth = isList
        ? 0.0
        : (unified && block.kind == TextBlockKind.paragraph
              ? baseSize * 2
              : block.style.indent);
    var syntheticPrefixLength = 0;
    if (indentWidth > 0) {
      builder.addPlaceholder(
        indentWidth,
        baseSize,
        ui.PlaceholderAlignment.baseline,
        baseline: ui.TextBaseline.alphabetic,
        baselineOffset: baseSize * 0.8,
      );
      syntheticPrefixLength = 1;
    }

    final links = <TextLinkRange>[];
    var paragraphOffset = syntheticPrefixLength;

    for (final inline in block.inlines) {
      switch (inline) {
        case TextRun(:final text, style: final runStyle, :final link):
          if (text.isEmpty) continue;
          final footnoteIcon = _usesFootnoteIcon(runStyle, link);
          if (footnoteIcon) {
            final authoredScale = unified
                ? blockScale
                : runStyle.sizeScale * blockScale;
            _appendFootnotePlaceholder(
              builder,
              text,
              (baseSize * authoredScale * 0.78).clamp(8.0, 12.0),
            );
            links.add(
              TextLinkRange(
                start: paragraphOffset,
                end: paragraphOffset + text.length,
                href: link ?? '',
                marker: link == null ? '' : text.trim(),
                role: runStyle.linkRole,
                footnoteIcon: true,
                inlineNote: runStyle.inlineRole == InlineRole.footnote
                    ? text.trim()
                    : null,
              ),
            );
            paragraphOffset += text.length;
            continue;
          }
          var scale = unified ? blockScale : runStyle.sizeScale * blockScale;
          // Super/subscript: size reduced, baseline shift not approximated.
          if (runStyle.baseline != TextBaselineShift.none) scale *= 0.7;
          final clearEmphasis = unified && (isHeading || isQuote);
          builder.pushStyle(
            ui.TextStyle(
              color: !unified && runStyle.color != null
                  ? ui.Color(runStyle.color!)
                  : foreground,
              fontWeight: ((runStyle.bold && !clearEmphasis) || isHeading)
                  ? ui.FontWeight.bold
                  : null,
              fontStyle: runStyle.italic && !clearEmphasis
                  ? ui.FontStyle.italic
                  : null,
              decoration: link != null
                  ? ui.TextDecoration.underline
                  : _decorationFor(runStyle, includeUnderline: !unified),
              fontSize: baseSize * scale,
              fontFamily: fontFamily,
            ),
          );
          builder.addText(text);
          builder.pop();
          if (link != null) {
            links.add(
              TextLinkRange(
                start: paragraphOffset,
                end: paragraphOffset + text.length,
                href: link,
                marker: text.trim(),
                role: runStyle.linkRole,
              ),
            );
          }
          paragraphOffset += text.length;
        case BreakInline():
          builder.addText('\n');
          paragraphOffset++;
      }
    }

    ui.Paragraph? markerParagraph;
    if (marker.isNotEmpty) {
      final markerBuilder = ui.ParagraphBuilder(
        ui.ParagraphStyle(
          textAlign: ui.TextAlign.left,
          textDirection: ui.TextDirection.ltr,
          fontSize: baseSize,
          height: paragraphLineHeight,
        ),
      )..pushStyle(ui.TextStyle(color: foreground, fontSize: baseSize));
      markerBuilder.addText('$marker\u00a0');
      markerBuilder.pop();
      markerParagraph = markerBuilder.build();
      markerParagraph.layout(const ui.ParagraphConstraints(width: 10000));
      markerWidth = markerParagraph.maxIntrinsicWidth;
      markerParagraph.layout(ui.ParagraphConstraints(width: markerWidth));
    }

    final paragraph = builder.build();
    final textStart = marginStart + markerWidth;
    final width = math.max(1.0, contentWidth - textStart);
    paragraph.layout(ui.ParagraphConstraints(width: width));
    final metrics = paragraph.computeLineMetrics();
    if (metrics.isEmpty) {
      paragraph.dispose();
      markerParagraph?.dispose();
      return null;
    }
    final lineTops = <double>[];
    var top = 0.0;
    for (final m in metrics) {
      lineTops.add(top);
      top += m.height;
    }

    return _PreparedText(
      paragraph: paragraph,
      metrics: metrics,
      lineTops: lineTops,
      x: contentLeft + textStart,
      width: width,
      marginBefore: marginBefore,
      marginAfter: marginAfter,
      syntheticPrefixLength: syntheticPrefixLength,
      marker: marker,
      markerParagraph: markerParagraph,
      markerX: contentLeft + marginStart,
      markerWidth: markerWidth,
      textLength: block.plainText.length,
      source: block.source,
      nodeId: block.nodeId,
      spineIndex: spineIndex,
      sectionTextOffset: sectionTextOffset,
      links: links,
    );
  }

  static bool _usesFootnoteIcon(TextStyle style, String? link) {
    if (style.inlineRole == InlineRole.footnote) return true;
    if (link == null || !link.contains('#')) return false;
    return style.linkRole == LinkRole.footnoteReference ||
        (style.linkRole == LinkRole.normal &&
            style.baseline == TextBaselineShift.superscript);
  }

  static void _appendFootnotePlaceholder(
    ui.ParagraphBuilder builder,
    String source,
    double size,
  ) {
    builder.addPlaceholder(
      size,
      size,
      ui.PlaceholderAlignment.baseline,
      baseline: ui.TextBaseline.alphabetic,
      baselineOffset: size * 1.18,
    );
    if (source.length > 1) {
      builder.addText(
        String.fromCharCodes(List.filled(source.length - 1, 0x2060)),
      );
    }
  }

  _PreparedTable? _prepareTable(
    TableBlock table,
    ReaderStyle style,
    int spineIndex,
    double contentWidth,
    double sectionTextOffset,
  ) {
    if (table.rows.isEmpty) return null;
    final rowCount = table.rows.length;
    final occupied = List.generate(rowCount, (_) => <bool>[]);
    final grid = <_GridTableCell>[];
    var columnCount = 0;

    for (var rowIndex = 0; rowIndex < rowCount; rowIndex++) {
      var column = 0;
      for (final cell in table.rows[rowIndex].cells) {
        while (column < occupied[rowIndex].length &&
            occupied[rowIndex][column]) {
          column++;
        }
        final columnSpan = cell.columnSpan.clamp(1, 64);
        final rowSpan = cell.rowSpan.clamp(1, rowCount - rowIndex);
        final endColumn = column + columnSpan;
        for (var row = rowIndex; row < rowIndex + rowSpan; row++) {
          while (occupied[row].length < endColumn) {
            occupied[row].add(false);
          }
          occupied[row].fillRange(column, endColumn, true);
        }
        grid.add(
          _GridTableCell(
            row: rowIndex,
            rowSpan: rowSpan,
            column: column,
            columnSpan: columnSpan,
            cell: cell,
          ),
        );
        column = endColumn;
        columnCount = math.max(columnCount, endColumn);
      }
    }
    if (columnCount == 0) return null;

    final unified = style.typesettingMode == TypesettingMode.unified;
    final fontScale = unified ? 0.9 : 1.0;
    final lineHeight = unified ? 1.45 : 1.3;
    final padding = unified ? style.baseFontSize * 0.35 : 6.0;
    final columnWidths = _tableColumnWidths(
      grid,
      columnCount,
      contentWidth,
      unified,
    );
    final minimumRowHeight =
        style.baseFontSize * fontScale * lineHeight + padding * 2;
    final rowHeights = List.filled(rowCount, minimumRowHeight);
    final cells = <_PreparedTableCell>[];
    var cellTextOffset = sectionTextOffset;

    for (final gridCell in grid) {
      final cellWidth = columnWidths
          .skip(gridCell.column)
          .take(gridCell.columnSpan)
          .fold(0.0, (sum, width) => sum + width);
      final builtCell = _buildTableCellParagraph(
        gridCell.cell,
        style,
        math.max(1, cellWidth - padding * 2),
        fontScale,
        lineHeight,
      );
      final paragraph = builtCell.paragraph;
      final requiredHeight = paragraph.height + padding * 2;
      if (gridCell.rowSpan == 1) {
        rowHeights[gridCell.row] = math.max(
          rowHeights[gridCell.row],
          requiredHeight,
        );
      }
      cells.add(
        _PreparedTableCell(
          grid: gridCell,
          paragraph: paragraph,
          links: builtCell.links,
          requiredHeight: requiredHeight,
          sectionTextOffset: cellTextOffset,
        ),
      );
      cellTextOffset += gridCell.cell.plainText.length;
    }

    for (final prepared in cells.where((cell) => cell.grid.rowSpan > 1)) {
      final gridCell = prepared.grid;
      final current = rowHeights
          .skip(gridCell.row)
          .take(gridCell.rowSpan)
          .fold(0.0, (sum, height) => sum + height);
      if (prepared.requiredHeight <= current) continue;
      final extra = (prepared.requiredHeight - current) / gridCell.rowSpan;
      for (
        var row = gridCell.row;
        row < gridCell.row + gridCell.rowSpan;
        row++
      ) {
        rowHeights[row] += extra;
      }
    }

    final normalizedGap = style.baseFontSize * 0.7;
    return _PreparedTable(
      columnWidths: columnWidths,
      rowHeights: rowHeights,
      cells: cells,
      padding: padding,
      marginBefore: unified
          ? normalizedGap
          : math.max(table.style.marginBefore, normalizedGap),
      marginAfter: unified
          ? normalizedGap
          : math.max(table.style.marginAfter, normalizedGap),
      spineIndex: spineIndex,
    );
  }

  List<double> _tableColumnWidths(
    List<_GridTableCell> cells,
    int columnCount,
    double contentWidth,
    bool adaptive,
  ) {
    if (!adaptive) {
      return List.filled(columnCount, contentWidth / columnCount);
    }
    final weights = List.filled(columnCount, 1.0);
    for (final entry in cells.where((cell) => cell.columnSpan == 1)) {
      final length = entry.cell.plainText.runes.length.clamp(1, 120);
      weights[entry.column] = math.max(
        weights[entry.column],
        math.sqrt(length / 8).clamp(1.0, 3.0),
      );
    }
    final total = weights.fold(0.0, (sum, weight) => sum + weight);
    return [for (final weight in weights) contentWidth * weight / total];
  }

  _BuiltTableCellParagraph _buildTableCellParagraph(
    TableCell cell,
    ReaderStyle style,
    double width,
    double fontScale,
    double lineHeight,
  ) {
    final unified = style.typesettingMode == TypesettingMode.unified;
    final foreground = ui.Color(style.foreground);
    final alignment = cell.authoredAlignment ?? BlockAlign.center;
    final builder = ui.ParagraphBuilder(
      ui.ParagraphStyle(
        textAlign: switch (alignment) {
          BlockAlign.start => ui.TextAlign.left,
          BlockAlign.center => ui.TextAlign.center,
          BlockAlign.end => ui.TextAlign.right,
          BlockAlign.justify => ui.TextAlign.justify,
        },
        textDirection: ui.TextDirection.ltr,
        fontSize: style.baseFontSize * fontScale,
        height: unified ? lineHeight : lineHeight * cell.style.lineHeight,
      ),
    );
    final links = <TextLinkRange>[];
    var paragraphOffset = 0;
    for (final inline in cell.inlines) {
      switch (inline) {
        case TextRun(:final text, style: final runStyle, :final link):
          if (text.isEmpty) continue;
          final footnoteIcon = _usesFootnoteIcon(runStyle, link);
          if (footnoteIcon) {
            final authoredScale = unified
                ? fontScale
                : fontScale * runStyle.sizeScale;
            _appendFootnotePlaceholder(
              builder,
              text,
              (style.baseFontSize * authoredScale * 0.78).clamp(8.0, 12.0),
            );
            links.add(
              TextLinkRange(
                start: paragraphOffset,
                end: paragraphOffset + text.length,
                href: link ?? '',
                marker: link == null ? '' : text.trim(),
                role: runStyle.linkRole,
                footnoteIcon: true,
                inlineNote: runStyle.inlineRole == InlineRole.footnote
                    ? text.trim()
                    : null,
              ),
            );
            paragraphOffset += text.length;
            continue;
          }
          var scale = unified ? fontScale : fontScale * runStyle.sizeScale;
          if (runStyle.baseline != TextBaselineShift.none) scale *= 0.7;
          builder.pushStyle(
            ui.TextStyle(
              color: !unified && runStyle.color != null
                  ? ui.Color(runStyle.color!)
                  : foreground,
              fontWeight: cell.header || runStyle.bold
                  ? ui.FontWeight.bold
                  : null,
              fontStyle: runStyle.italic ? ui.FontStyle.italic : null,
              decoration: link != null
                  ? ui.TextDecoration.underline
                  : _decorationFor(runStyle, includeUnderline: !unified),
              fontSize: style.baseFontSize * scale,
            ),
          );
          builder.addText(text);
          builder.pop();
          if (link != null) {
            links.add(
              TextLinkRange(
                start: paragraphOffset,
                end: paragraphOffset + text.length,
                href: link,
                marker: text.trim(),
                role: runStyle.linkRole,
              ),
            );
          }
          paragraphOffset += text.length;
        case BreakInline():
          builder.addText('\n');
          paragraphOffset++;
      }
    }
    final paragraph = builder.build()
      ..layout(ui.ParagraphConstraints(width: width));
    return _BuiltTableCellParagraph(paragraph, links);
  }

  void _pushImage(
    _Paginator paginator,
    ImageBlock block,
    ReaderStyle style,
    ui.Size? Function(String href)? imageSizeResolver,
    double contentWidth,
    double contentHeight,
    double viewportWidth,
  ) {
    final em = style.baseFontSize;
    final intrinsic = imageSizeResolver?.call(block.href);
    final availableWidth = block.fixedPage ? viewportWidth : contentWidth;
    double width;
    double height;
    if (intrinsic == null || intrinsic.width <= 0 || intrinsic.height <= 0) {
      // No resolver or unknown size: reserve a 1em square placeholder.
      width = height = em;
    } else {
      final imageStyle = block.style;
      final aspect = intrinsic.width / intrinsic.height;
      if (block.fixedPage) {
        // PDF pages use fit-width presentation: span the complete viewport,
        // preserve page geometry, and allow the viewport to clip unusually
        // tall pages instead of reintroducing horizontal reading margins.
        width = availableWidth;
        height = width / aspect;
        paginator.pushImage(
          block.href,
          width,
          height,
          gap: 0,
          centerVertically: true,
          fillViewportWidth: true,
        );
        return;
      }
      var requestedHeight = imageStyle.height?.resolve(contentHeight);
      final requestedWidth = math.max(
        1.0,
        imageStyle.width?.resolve(contentWidth) ??
            (requestedHeight != null
                ? requestedHeight * aspect
                : intrinsic.width),
      );
      requestedHeight = math.max(
        1.0,
        requestedHeight ?? requestedWidth / aspect,
      );
      final maxWidth =
          (imageStyle.maxWidth?.resolve(contentWidth) ?? contentWidth).clamp(
            1.0,
            contentWidth,
          );
      final maxHeight =
          (imageStyle.maxHeight?.resolve(contentHeight) ?? contentHeight).clamp(
            1.0,
            contentHeight,
          );
      final scale = math.min(
        math.min(maxWidth / requestedWidth, maxHeight / requestedHeight),
        1.0,
      );
      width = requestedWidth * scale;
      height = requestedHeight * scale;
    }
    paginator.pushImage(
      block.href,
      width,
      height,
      gap: block.fixedPage ? 0 : em * 0.5,
      centerVertically: block.fixedPage,
      fillViewportWidth: block.fixedPage,
    );
  }

  static double _unifiedHeadingScale(int level) {
    const emphasis = 0.6;
    final factor = switch (level.clamp(1, 6)) {
      1 => 1.0,
      2 => 0.72,
      3 => 0.45,
      4 => 0.25,
      5 => 0.12,
      _ => 0.05,
    };
    return 1 + emphasis * factor;
  }

  static String _bulletForDepth(int depth) => switch (depth % 3) {
    0 => '•',
    1 => '◦',
    _ => '▪',
  };

  static ui.TextDecoration? _decorationFor(
    TextStyle style, {
    bool includeUnderline = true,
  }) {
    final decorations = <ui.TextDecoration>[
      if (includeUnderline && style.underline) ui.TextDecoration.underline,
      if (style.strikethrough) ui.TextDecoration.lineThrough,
    ];
    if (decorations.isEmpty) return null;
    return ui.TextDecoration.combine(decorations);
  }
}

class _GridTableCell {
  final int row;
  final int rowSpan;
  final int column;
  final int columnSpan;
  final TableCell cell;

  const _GridTableCell({
    required this.row,
    required this.rowSpan,
    required this.column,
    required this.columnSpan,
    required this.cell,
  });
}

class _BuiltTableCellParagraph {
  final ui.Paragraph paragraph;
  final List<TextLinkRange> links;

  const _BuiltTableCellParagraph(this.paragraph, this.links);
}

class _PreparedTableCell {
  final _GridTableCell grid;
  final ui.Paragraph paragraph;
  final List<TextLinkRange> links;
  final double requiredHeight;
  final double sectionTextOffset;

  const _PreparedTableCell({
    required this.grid,
    required this.paragraph,
    required this.links,
    required this.requiredHeight,
    required this.sectionTextOffset,
  });
}

class _PreparedTable {
  final List<double> columnWidths;
  final List<double> rowHeights;
  final List<_PreparedTableCell> cells;
  final double padding;
  final double marginBefore;
  final double marginAfter;
  final int spineIndex;

  const _PreparedTable({
    required this.columnWidths,
    required this.rowHeights,
    required this.cells,
    required this.padding,
    required this.marginBefore,
    required this.marginAfter,
    required this.spineIndex,
  });
}

/// A shaped paragraph plus the metadata the paginator needs to slice it.
class _PreparedText {
  final ui.Paragraph paragraph;
  final List<ui.LineMetrics> metrics;

  /// Cumulative top offset of each line within the paragraph.
  final List<double> lineTops;
  final double x;
  final double width;
  final double marginBefore;
  final double marginAfter;

  /// UTF-16 length contributed by a first-line indent placeholder.
  final int syntheticPrefixLength;
  final String marker;
  final ui.Paragraph? markerParagraph;
  final double markerX;
  final double markerWidth;
  final int textLength;
  final SourceRange? source;
  final String nodeId;
  final int spineIndex;
  final double sectionTextOffset;
  final List<TextLinkRange> links;

  const _PreparedText({
    required this.paragraph,
    required this.metrics,
    required this.lineTops,
    required this.x,
    required this.width,
    required this.marginBefore,
    required this.marginAfter,
    required this.syntheticPrefixLength,
    required this.marker,
    required this.markerParagraph,
    required this.markerX,
    required this.markerWidth,
    required this.textLength,
    required this.source,
    required this.nodeId,
    required this.spineIndex,
    required this.sectionTextOffset,
    required this.links,
  });
}

/// Port of torto's Paginator: a single-column cursor over the content area.
class _Paginator {
  final double top;
  final double bottom;
  final double left;
  final double width;
  final bool centerStandaloneImage;

  double cursorY;
  bool hasContent = false;

  /// Trailing margin of the previous block, collapsed (max) with the next
  /// block's leading margin, CSS-style. Dropped at page boundaries.
  double pendingMargin = 0;

  List<PageItem> items = [];
  final List<List<PageItem>> pages = [];

  _Paginator({
    required this.top,
    required this.bottom,
    required this.left,
    required this.width,
    required this.centerStandaloneImage,
  }) : cursorY = top;

  double get remaining => bottom - cursorY;

  void pushText(_PreparedText prepared) {
    _collapseMargin(prepared.marginBefore);
    final metrics = prepared.metrics;
    final tops = prepared.lineTops;
    var lineStart = 0;
    while (lineStart < metrics.length) {
      final available = remaining;
      var lineEnd = lineStart;
      var sliceBottom = tops[lineStart];
      while (lineEnd < metrics.length) {
        final candidateBottom = tops[lineEnd] + metrics[lineEnd].height;
        final candidateHeight = candidateBottom - tops[lineStart];
        if (candidateHeight > available + _eps) {
          if (lineEnd > lineStart) break; // slice [lineStart, lineEnd) fits
          if (hasContent) {
            advance(); // retry the line on a fresh page
          } else {
            // A single line taller than a page: place it anyway (overflow
            // tolerated) rather than looping forever.
            lineEnd++;
            sliceBottom = candidateBottom;
          }
          break;
        }
        lineEnd++;
        sliceBottom = candidateBottom;
      }
      if (lineEnd == lineStart) continue; // page was advanced; retry

      final sliceTop = tops[lineStart];
      final marker = prepared.markerParagraph;
      if (lineStart == 0 && marker != null) {
        items.add(
          ListMarkerPlacement(
            marker: prepared.marker,
            paragraph: marker,
            x: prepared.markerX,
            y: cursorY,
            width: prepared.markerWidth,
            height: marker.height,
          ),
        );
      }
      items.add(
        TextPlacement(
          paragraph: prepared.paragraph,
          startLine: lineStart,
          endLine: lineEnd,
          x: prepared.x,
          y: cursorY,
          width: prepared.width,
          source: prepared.source,
          nodeId: prepared.nodeId,
          spineIndex: prepared.spineIndex,
          textOffsetAtStart: lineStart == 0
              ? 0
              : _lineStartOffset(prepared, lineStart),
          lineMetrics: metrics,
          sliceTop: sliceTop,
          sliceHeight: sliceBottom - sliceTop,
          sectionTextOffset: prepared.sectionTextOffset,
          links: prepared.links,
        ),
      );
      hasContent = true;
      cursorY += sliceBottom - sliceTop;
      lineStart = lineEnd;
      if (lineStart < metrics.length) advance();
    }
    _setMarginAfter(prepared.marginAfter);
  }

  void pushTable(_PreparedTable table) {
    _collapseMargin(table.marginBefore);
    var row = 0;
    while (row < table.rowHeights.length) {
      var groupEnd = row + 1;
      var expanded = true;
      while (expanded) {
        expanded = false;
        for (final cell in table.cells) {
          final start = cell.grid.row;
          if (start < row || start >= groupEnd) continue;
          final end = start + cell.grid.rowSpan;
          if (end > groupEnd) {
            groupEnd = end;
            expanded = true;
          }
        }
      }
      final groupHeight = table.rowHeights
          .skip(row)
          .take(groupEnd - row)
          .fold(0.0, (sum, height) => sum + height);
      if (groupHeight > remaining + _eps && hasContent) advance();
      final groupTop = cursorY;

      for (final prepared in table.cells) {
        final grid = prepared.grid;
        if (grid.row < row || grid.row >= groupEnd) continue;
        final x =
            left +
            table.columnWidths
                .take(grid.column)
                .fold(0.0, (sum, width) => sum + width);
        final y =
            groupTop +
            table.rowHeights
                .skip(row)
                .take(grid.row - row)
                .fold(0.0, (sum, height) => sum + height);
        final cellWidth = table.columnWidths
            .skip(grid.column)
            .take(grid.columnSpan)
            .fold(0.0, (sum, width) => sum + width);
        final cellHeight = table.rowHeights
            .skip(grid.row)
            .take(grid.rowSpan)
            .fold(0.0, (sum, height) => sum + height);
        items.add(
          TableCellPlacement(
            paragraph: prepared.paragraph,
            rect: ui.Rect.fromLTWH(x, y, cellWidth, cellHeight),
            padding: table.padding,
            header: grid.cell.header,
            source: grid.cell.source,
            nodeId: grid.cell.nodeId,
            spineIndex: table.spineIndex,
            sectionTextOffset: prepared.sectionTextOffset,
            links: prepared.links,
          ),
        );
      }
      hasContent = true;
      cursorY += groupHeight;
      row = groupEnd;
    }
    _setMarginAfter(table.marginAfter);
  }

  void pushImage(
    String href,
    double width,
    double height, {
    required double gap,
    bool centerVertically = false,
    bool fillViewportWidth = false,
  }) {
    _collapseMargin(gap);
    if (height > remaining + _eps && hasContent) advance();
    final x = fillViewportWidth ? 0.0 : left + (this.width - width) / 2;
    final y = centerVertically && !hasContent
        ? top + math.max(0, (bottom - top - height) / 2)
        : cursorY;
    items.add(
      ImagePlacement(href: href, rect: ui.Rect.fromLTWH(x, y, width, height)),
    );
    hasContent = true;
    cursorY = y + height;
    _setMarginAfter(gap);
  }

  void pushSeparator({required double vMargin}) {
    _addSpacing(vMargin);
    if (1.0 > remaining + _eps && hasContent) advance();
    items.add(
      SeparatorPlacement(rect: ui.Rect.fromLTWH(left, cursorY, width, 1)),
    );
    hasContent = true;
    cursorY += 1;
    _addSpacing(vMargin);
  }

  void forcePage() {
    if (items.isNotEmpty) advance();
  }

  /// Commits the current page. Never emits an empty page.
  void advance() {
    if (items.isNotEmpty) {
      if (centerStandaloneImage &&
          items.length == 1 &&
          items.single is ImagePlacement) {
        final image = items.single as ImagePlacement;
        final centeredTop =
            top + math.max(0, (bottom - top - image.rect.height) / 2);
        items[0] = ImagePlacement(
          href: image.href,
          rect: ui.Rect.fromLTWH(
            image.rect.left,
            centeredTop,
            image.rect.width,
            image.rect.height,
          ),
        );
      }
      pages.add(items);
      items = [];
    }
    cursorY = top;
    hasContent = false;
    pendingMargin = 0;
  }

  List<List<PageItem>> finish() {
    advance();
    return pages;
  }

  void _collapseMargin(double marginBefore) {
    final spacing = math.max(pendingMargin, marginBefore);
    pendingMargin = 0;
    _addSpacing(spacing);
  }

  void _setMarginAfter(double marginAfter) {
    pendingMargin = math.max(pendingMargin, marginAfter);
  }

  /// Adds vertical spacing, dropping it at the top of a fresh page and
  /// advancing the page when the spacing itself does not fit.
  void _addSpacing(double amount) {
    if (amount <= 0 || !hasContent) return;
    if (cursorY + amount > bottom + _eps) {
      advance();
    } else {
      cursorY += amount;
    }
  }

  /// UTF-16 offset into the block's plainText of the first character of
  /// paragraph line [line], excluding the synthetic marker prefix.
  int _lineStartOffset(_PreparedText prepared, int line) {
    final metric = prepared.metrics[line];
    final position = prepared.paragraph.getPositionForOffset(
      ui.Offset(metric.left + 0.1, prepared.lineTops[line] + metric.height / 2),
    );
    return (position.offset - prepared.syntheticPrefixLength).clamp(
      0,
      prepared.textLength,
    );
  }
}
