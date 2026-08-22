/// Pagination for the Reading IR: turns a [Section] into a list of
/// [PageLayout]s. A Dart port of torto's `crates/layout` Paginator (column
/// cursor, collapsing margins, line-range slicing of paragraphs across
/// pages), built on `dart:ui` paragraphs instead of Parley.
///
/// Known v1 approximations (deliberate, see task notes):
/// - First-line indent ([BlockStyle.indent]) is ignored.
/// - Superscript/subscript runs are rendered at 0.7x size with NO baseline
///   shift (dart:ui's TextStyle has no baseline-shift support).
/// - List markers are synthetic prefix runs; wrapped lines align to the
///   (indented) column edge, not past the marker (no true hanging indent).
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
    final textStartOf = <TextBlock, double>{};
    var totalText = 0.0;
    for (final block in section.blocks) {
      if (block is TextBlock) {
        textStartOf[block] = totalText;
        totalText += block.plainText.length;
      }
    }

    final paginator = _Paginator(
      top: contentTop,
      bottom: contentBottom,
      left: contentLeft,
      width: contentWidth,
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
          );
        case SeparatorBlock():
          paginator.pushSeparator(vMargin: style.baseFontSize * 0.75);
        case PageBreakBlock():
          paginator.forcePage();
      }
    }

    final rawPages = paginator.finish();
    if (rawPages.isEmpty) return const [];

    final pages = <PageLayout>[];
    final disposalPool = ParagraphDisposalPool();
    var carriedProgression = 0.0;
    for (var i = 0; i < rawPages.length; i++) {
      final items = rawPages[i];
      TextPlacement? firstText;
      for (final item in items) {
        if (item is TextPlacement) {
          firstText = item;
          break;
        }
      }
      SourceAnchor? anchor;
      var progression = carriedProgression;
      if (firstText != null) {
        anchor = SourceAnchor(
          spine: section.spineIndex,
          node: firstText.nodeId,
          textOffset:
              (firstText.source?.start.textOffset ?? 0) +
              firstText.textOffsetAtStart,
        );
        if (totalText > 0) {
          progression =
              ((firstText.sectionTextOffset + firstText.textOffsetAtStart) /
                      totalText)
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
    final isHeading = block.kind == TextBlockKind.heading;
    final isPre = block.kind == TextBlockKind.preformatted;

    var marginBefore = block.style.marginBefore;
    var marginAfter = block.style.marginAfter;
    var marginStart = block.style.marginStart;

    // Heading defaults: size scale by level (only when the IR left all runs
    // at scale 1.0), bold, extra margins.
    var headingScale = 1.0;
    if (isHeading) {
      final allPlain = block.inlines.every(
        (i) => i is! TextRun || i.style.sizeScale == 1.0,
      );
      if (allPlain) {
        headingScale = _headingScales[block.headingLevel.clamp(1, 6)] ?? 1.0;
      }
      marginBefore = math.max(marginBefore, baseSize * 0.8);
      marginAfter = math.max(marginAfter, baseSize * 0.4);
    }
    if (block.kind == TextBlockKind.blockquote) {
      marginStart += baseSize * 2;
    }

    // List items: synthetic marker run + indented column (simple hanging
    // indent approximation).
    var marker = '';
    if (block.kind == TextBlockKind.listItem) {
      marker = block.listOrdered ? '${block.listOrdinal}. ' : '• ';
      marginStart += baseSize * 1.5;
    }

    final hasText = block.inlines.any(
      (i) => i is TextRun && i.text.isNotEmpty || i is BreakInline,
    );
    if (!hasText) return null;

    final foreground = ui.Color(style.foreground);
    final fontFamily = isPre ? 'monospace' : null;
    final align = switch (block.style.align) {
      BlockAlign.start => ui.TextAlign.left,
      BlockAlign.center => ui.TextAlign.center,
      BlockAlign.end => ui.TextAlign.right,
      BlockAlign.justify => ui.TextAlign.justify,
    };

    final builder = ui.ParagraphBuilder(
      ui.ParagraphStyle(
        textAlign: align,
        textDirection: ui.TextDirection.ltr,
        fontSize: baseSize * headingScale,
        height: style.lineHeight * block.style.lineHeight,
        fontFamily: fontFamily,
      ),
    );

    if (marker.isNotEmpty) {
      builder.pushStyle(
        ui.TextStyle(
          color: foreground,
          fontSize: baseSize * headingScale,
          fontWeight: isHeading ? ui.FontWeight.bold : null,
          fontFamily: fontFamily,
        ),
      );
      builder.addText(marker);
      builder.pop();
    }

    for (final inline in block.inlines) {
      switch (inline) {
        case TextRun(:final text, style: final runStyle):
          if (text.isEmpty) continue;
          var scale = runStyle.sizeScale * headingScale;
          // Super/subscript: size reduced, baseline shift not approximated.
          if (runStyle.baseline != TextBaselineShift.none) scale *= 0.7;
          builder.pushStyle(
            ui.TextStyle(
              color: runStyle.color != null
                  ? ui.Color(runStyle.color!)
                  : foreground,
              fontWeight: (runStyle.bold || isHeading)
                  ? ui.FontWeight.bold
                  : null,
              fontStyle: runStyle.italic ? ui.FontStyle.italic : null,
              decoration: _decorationFor(runStyle),
              fontSize: baseSize * scale,
              fontFamily: fontFamily,
            ),
          );
          builder.addText(text);
          builder.pop();
        case BreakInline():
          builder.addText('\n');
      }
    }

    final paragraph = builder.build();
    final width = math.max(1.0, contentWidth - marginStart);
    paragraph.layout(ui.ParagraphConstraints(width: width));
    final metrics = paragraph.computeLineMetrics();
    if (metrics.isEmpty) {
      paragraph.dispose();
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
      x: contentLeft + marginStart,
      width: width,
      marginBefore: marginBefore,
      marginAfter: marginAfter,
      markerLength: marker.length,
      textLength: block.plainText.length,
      source: block.source,
      nodeId: block.nodeId,
      spineIndex: spineIndex,
      sectionTextOffset: sectionTextOffset,
    );
  }

  void _pushImage(
    _Paginator paginator,
    ImageBlock block,
    ReaderStyle style,
    ui.Size? Function(String href)? imageSizeResolver,
    double contentWidth,
    double contentHeight,
  ) {
    final em = style.baseFontSize;
    final intrinsic = imageSizeResolver?.call(block.href);
    double width;
    double height;
    if (intrinsic == null || intrinsic.width <= 0 || intrinsic.height <= 0) {
      // No resolver or unknown size: reserve a 1em square placeholder.
      width = height = em;
    } else {
      final imageStyle = block.style;
      final aspect = intrinsic.width / intrinsic.height;
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
    paginator.pushImage(block.href, width, height, gap: em * 0.5);
  }

  static ui.TextDecoration? _decorationFor(TextStyle style) {
    final decorations = <ui.TextDecoration>[
      if (style.underline) ui.TextDecoration.underline,
      if (style.strikethrough) ui.TextDecoration.lineThrough,
    ];
    if (decorations.isEmpty) return null;
    return ui.TextDecoration.combine(decorations);
  }
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

  /// UTF-16 length of the synthetic prefix (list marker) not present in the
  /// block's plainText.
  final int markerLength;
  final int textLength;
  final SourceRange? source;
  final String nodeId;
  final int spineIndex;
  final double sectionTextOffset;

  const _PreparedText({
    required this.paragraph,
    required this.metrics,
    required this.lineTops,
    required this.x,
    required this.width,
    required this.marginBefore,
    required this.marginAfter,
    required this.markerLength,
    required this.textLength,
    required this.source,
    required this.nodeId,
    required this.spineIndex,
    required this.sectionTextOffset,
  });
}

/// Port of torto's Paginator: a single-column cursor over the content area.
class _Paginator {
  final double top;
  final double bottom;
  final double left;
  final double width;

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
        ),
      );
      hasContent = true;
      cursorY += sliceBottom - sliceTop;
      lineStart = lineEnd;
      if (lineStart < metrics.length) advance();
    }
    _setMarginAfter(prepared.marginAfter);
  }

  void pushImage(
    String href,
    double width,
    double height, {
    required double gap,
  }) {
    _collapseMargin(gap);
    if (height > remaining + _eps && hasContent) advance();
    final x = left + (this.width - width) / 2;
    items.add(
      ImagePlacement(
        href: href,
        rect: ui.Rect.fromLTWH(x, cursorY, width, height),
      ),
    );
    hasContent = true;
    cursorY += height;
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
    return (position.offset - prepared.markerLength).clamp(
      0,
      prepared.textLength,
    );
  }
}
