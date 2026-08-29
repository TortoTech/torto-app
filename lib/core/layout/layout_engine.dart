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

import 'package:characters/characters.dart';
import 'package:flutter/foundation.dart';

import '../ir/ir.dart';
import '../linebreak/paragraph_optimizer.dart';
import '../linebreak/unicode_line_breaker.dart';
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

/// Desktop torto's minimum spacing around authored images in book mode.
const double _imageBlockGap = 14.0;

class LayoutEngine {
  const LayoutEngine();

  @visibleForTesting
  static ({bool bold, bool italic, bool underline, bool strikethrough})
  debugResolvedInlineEmphasis(
    TextStyle runStyle, {
    bool unified = true,
    bool linked = false,
    bool isHeading = false,
    bool isQuote = false,
    bool isDefinitionTerm = false,
  }) => _resolvedInlineEmphasis(
    runStyle: runStyle,
    linked: linked,
    unified: unified,
    isHeading: isHeading,
    isQuote: isQuote,
    isDefinitionTerm: isDefinitionTerm,
  );

  @visibleForTesting
  static BlockAlign debugResolvedUnifiedAlignment(
    TextBlock block, {
    BlockAlign? override,
  }) => _resolvedUnifiedAlignment(block, override: override);

  @visibleForTesting
  static int debugResolvedBookTextColor(
    TextStyle runStyle, {
    required int foreground,
  }) => _resolvedRunColor(
    runStyle: runStyle,
    unified: false,
    foreground: ui.Color(foreground),
  ).toARGB32();

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
    final flowBlocks = _collectFlowBlocks(section.blocks, style);
    if (flowBlocks.isEmpty) return const [];

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
    for (final block in flowBlocks) {
      final length = switch (block) {
        TextBlock(:final plainText) => plainText.length,
        TableBlock(:final textLength) => textLength,
        FigureBlock(:final textLength) => textLength,
        QuoteBlock(:final textLength) => textLength,
        NoteBlock(:final textLength) => textLength,
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

    var blockIndex = 0;
    while (blockIndex < flowBlocks.length) {
      final block = flowBlocks[blockIndex];
      if (style.typesettingMode == TypesettingMode.unified &&
          block is ImageBlock &&
          blockIndex + 1 < flowBlocks.length &&
          flowBlocks[blockIndex + 1] is TextBlock &&
          (flowBlocks[blockIndex + 1] as TextBlock).kind ==
              TextBlockKind.caption) {
        final caption = flowBlocks[blockIndex + 1] as TextBlock;
        _pushFigure(
          paginator,
          FigureBlock(images: [block], captions: [caption]),
          style,
          imageSizeResolver,
          contentLeft,
          contentWidth,
          contentHeight,
          viewport.width,
          section.spineIndex,
          textStartOf[caption] ?? 0,
        );
        blockIndex += 2;
        continue;
      }
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
        case FigureBlock():
          _pushFigure(
            paginator,
            block,
            style,
            imageSizeResolver,
            contentLeft,
            contentWidth,
            contentHeight,
            viewport.width,
            section.spineIndex,
            textStartOf[block] ?? 0,
          );
        case SeparatorBlock():
          if (block.kind == SeparatorKind.ornament && block.image != null) {
            _pushImage(
              paginator,
              block.image!,
              style,
              imageSizeResolver,
              contentWidth,
              contentHeight,
              viewport.width,
            );
          } else if (block.kind == SeparatorKind.spacing) {
            paginator.addSemanticSpacing(
              math.max(style.baseFontSize, block.style.marginAfter),
            );
          } else {
            paginator.pushSeparator(vMargin: style.baseFontSize * 0.75);
          }
        case PageBreakBlock():
          paginator.forcePage();
        case LineBreakBlock():
          paginator.addSemanticSpacing(style.baseFontSize * style.lineHeight);
        case TableBlock():
          final prepared = _prepareTable(
            block,
            style,
            section.spineIndex,
            contentWidth,
            textStartOf[block] ?? 0,
          );
          if (prepared != null) paginator.pushTable(prepared);
        case QuoteBlock():
          _pushQuote(
            paginator,
            block,
            style,
            contentLeft,
            contentWidth,
            section.spineIndex,
            textStartOf[block] ?? 0,
          );
        case NoteBlock():
          // Note blocks are filtered or flattened by [_collectFlowBlocks].
          throw StateError('Unexpected note block in the layout flow.');
      }
      blockIndex++;
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

  static List<Block> _collectFlowBlocks(List<Block> blocks, ReaderStyle style) {
    final output = <Block>[];
    for (final block in blocks) {
      switch (block) {
        case QuoteBlock():
          output.add(block);
        case NoteBlock(:final kind, :final blocks):
          if (kind == NoteBlockKind.section &&
              style.typesettingMode == TypesettingMode.book) {
            output.addAll(_collectFlowBlocks(blocks, style));
          }
        case SeparatorBlock(:final kind, :final inQuote):
          if (style.typesettingMode == TypesettingMode.book ||
              inQuote ||
              kind != SeparatorKind.spacing) {
            output.add(block);
          }
        default:
          output.add(block);
      }
    }
    return output;
  }

  /// Matches torto desktop's cover-alignment boundary: page breaks are not
  /// visible content, and an ordinary standalone illustration must remain in
  /// normal document flow rather than being mistaken for a cover.
  static bool _isStandaloneCover(Section section, String? coverHref) {
    if (coverHref == null) return false;
    final visibleBlocks = section.blocks
        .where((block) => block is! PageBreakBlock && block is! LineBreakBlock)
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
    double sectionTextOffset, {
    BlockAlign? unifiedAlignmentOverride,
  }) {
    final baseSize = style.baseFontSize;
    final unified = style.typesettingMode == TypesettingMode.unified;
    final isHeading = block.kind == TextBlockKind.heading;
    final isPre = block.kind == TextBlockKind.preformatted;
    final isList = block.kind == TextBlockKind.listItem;
    final isQuote =
        block.kind == TextBlockKind.blockquote ||
        block.kind == TextBlockKind.quoteAttribution;
    final isCaption = block.kind == TextBlockKind.caption;
    final isDefinitionTerm = block.kind == TextBlockKind.definitionTerm;
    final isDefinitionDescription =
        block.kind == TextBlockKind.definitionDescription;

    var marginBefore = block.style.marginBefore;
    var marginAfter = block.style.marginAfter;
    var marginStart =
        block.style.marginStart +
        contentWidth * block.style.marginStartFraction;

    var blockScale = 1.0;
    var paragraphLineHeight = style.lineHeight * block.style.lineHeight;
    var resolvedAlign = block.style.align;

    if (unified) {
      marginBefore = 0;
      marginAfter = baseSize * 0.5;
      marginStart = 0;
      resolvedAlign = _resolvedUnifiedAlignment(
        block,
        override: unifiedAlignmentOverride,
      );
      paragraphLineHeight = style.lineHeight;
      if (isHeading) {
        blockScale = _unifiedHeadingScale(block.headingLevel);
        paragraphLineHeight = 1.3;
        marginAfter = baseSize * 0.7;
      } else if (isPre) {
        blockScale = 0.9;
        paragraphLineHeight = 1.45;
      } else if (isCaption) {
        blockScale = 0.88;
        paragraphLineHeight = 1.4;
        marginAfter = 0;
      } else if (block.kind == TextBlockKind.blockquote) {
        blockScale = 0.95;
        marginStart = 0;
      } else if (block.kind == TextBlockKind.quoteAttribution) {
        blockScale = 0.88;
        paragraphLineHeight = 1.4;
        marginStart = 0;
        marginAfter = 0;
      } else if (isDefinitionTerm) {
        marginAfter = baseSize * 0.2;
        marginStart = baseSize * 1.5 * block.listDepth;
      } else if (isDefinitionDescription) {
        marginStart = baseSize * 1.5 * (block.listDepth + 1);
      }
    } else if (isHeading) {
      final allPlain = block.inlines.every(
        (i) => i is! TextRun || i.style.sizeScale == 1.0,
      );
      if (allPlain) {
        blockScale = _headingScales[block.headingLevel.clamp(1, 6)] ?? 1.0;
      }
    }
    if (block.style.hardBreakAfter) {
      marginAfter += baseSize * paragraphLineHeight;
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
      (i) =>
          i is TextRun && i.text.isNotEmpty ||
          i is BreakInline ||
          i is MathInline && i.latex.isNotEmpty,
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
        : switch ((unified, block.kind)) {
            (true, TextBlockKind.paragraph) =>
              baseSize * style.paragraphIndentEm,
            (true, TextBlockKind.blockquote) when block.style.indent > _eps =>
              baseSize * 2,
            _ => block.style.indent,
          };
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
          builder.pushStyle(
            _resolvedUiTextStyle(
              runStyle: runStyle,
              linked: link != null,
              unified: unified,
              blockScale: blockScale,
              baseSize: baseSize,
              foreground: foreground,
              fontFamily: fontFamily,
              isHeading: isHeading,
              isQuote: isQuote,
              isDefinitionTerm: isDefinitionTerm,
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
        case MathInline(:final latex, :final sizeScale):
          if (latex.isEmpty) continue;
          final scale = unified ? blockScale : sizeScale * blockScale;
          builder.pushStyle(
            ui.TextStyle(
              color: foreground,
              fontSize: baseSize * scale,
              fontFamily: 'monospace',
              fontStyle: ui.FontStyle.italic,
            ),
          );
          builder.addText(latex);
          builder.pop();
          paragraphOffset += latex.length;
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

    var paragraph = builder.build();
    final textStart = marginStart + markerWidth;
    final width = math.max(1.0, contentWidth - textStart);
    paragraph.layout(ui.ParagraphConstraints(width: width));
    var metrics = paragraph.computeLineMetrics();
    List<int>? displayToSource;
    if (style.lineBreakStrategy == LineBreakStrategy.optimized &&
        metrics.length > 1 &&
        (((block.kind == TextBlockKind.paragraph ||
                    block.kind == TextBlockKind.blockquote) &&
                resolvedAlign == BlockAlign.justify) ||
            (block.kind == TextBlockKind.caption &&
                resolvedAlign == BlockAlign.start))) {
      final optimized = _tryBuildOptimizedParagraph(
        block: block,
        unified: unified,
        blockScale: blockScale,
        baseSize: baseSize,
        lineHeight: paragraphLineHeight,
        foreground: foreground,
        fontFamily: fontFamily,
        isHeading: isHeading,
        isQuote: isQuote,
        firstLineIndent: indentWidth,
        width: width,
      );
      if (optimized != null) {
        paragraph.dispose();
        paragraph = optimized.paragraph;
        metrics = optimized.metrics;
        links
          ..clear()
          ..addAll(optimized.links);
        displayToSource = optimized.displayToSource;
      }
    }
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
      displayToSource: displayToSource,
    );
  }

  static ui.TextStyle _resolvedUiTextStyle({
    required TextStyle runStyle,
    required bool linked,
    required bool unified,
    required double blockScale,
    required double baseSize,
    required ui.Color foreground,
    required String? fontFamily,
    required bool isHeading,
    required bool isQuote,
    required bool isDefinitionTerm,
    double? letterSpacing,
  }) {
    var scale = unified ? blockScale : runStyle.sizeScale * blockScale;
    if (runStyle.baseline != TextBaselineShift.none) scale *= 0.7;
    final emphasis = _resolvedInlineEmphasis(
      runStyle: runStyle,
      linked: linked,
      unified: unified,
      isHeading: isHeading,
      isQuote: isQuote,
      isDefinitionTerm: isDefinitionTerm,
    );
    return ui.TextStyle(
      color: _resolvedRunColor(
        runStyle: runStyle,
        unified: unified,
        foreground: foreground,
      ),
      fontWeight: emphasis.bold ? ui.FontWeight.bold : null,
      fontStyle: emphasis.italic ? ui.FontStyle.italic : null,
      decoration: _resolvedDecoration(
        underline: emphasis.underline,
        strikethrough: emphasis.strikethrough,
      ),
      fontSize: baseSize * scale,
      fontFamily: fontFamily,
      letterSpacing: letterSpacing,
    );
  }

  static ui.Color _resolvedRunColor({
    required TextStyle runStyle,
    required bool unified,
    required ui.Color foreground,
  }) {
    final authored = runStyle.color;
    if (unified || authored == null || authored == 0xFF000000) {
      return foreground;
    }
    return ui.Color(authored);
  }

  static ({bool bold, bool italic, bool underline, bool strikethrough})
  _resolvedInlineEmphasis({
    required TextStyle runStyle,
    required bool linked,
    required bool unified,
    required bool isHeading,
    required bool isQuote,
    required bool isDefinitionTerm,
  }) {
    final clearBold = unified && (isHeading || isQuote);
    final clearItalic = unified && (isHeading || isQuote);
    return (
      bold: (runStyle.bold && !clearBold) || isHeading || isDefinitionTerm,
      italic: runStyle.italic && !clearItalic,
      underline: !unified && runStyle.underline,
      strikethrough: runStyle.strikethrough,
    );
  }

  _OptimizedParagraphBuild? _tryBuildOptimizedParagraph({
    required TextBlock block,
    required bool unified,
    required double blockScale,
    required double baseSize,
    required double lineHeight,
    required ui.Color foreground,
    required String? fontFamily,
    required bool isHeading,
    required bool isQuote,
    required double firstLineIndent,
    required double width,
  }) {
    final slices = <_SourceRunSlice>[];
    final text = StringBuffer();
    var sourceOffset = 0;
    for (final inline in block.inlines) {
      switch (inline) {
        case BreakInline():
          return null;
        case MathInline():
          return null;
        case TextRun(text: final value, style: final runStyle, :final link):
          if (value.isEmpty) continue;
          if (_usesFootnoteIcon(runStyle, link)) return null;
          final start = sourceOffset;
          sourceOffset += value.length;
          text.write(value);
          slices.add(
            _SourceRunSlice(
              start: start,
              end: sourceOffset,
              style: runStyle,
              link: link,
              fontSize: _resolvedFontSize(
                runStyle,
                unified: unified,
                blockScale: blockScale,
                baseSize: baseSize,
              ),
            ),
          );
      }
    }
    final sourceText = text.toString();
    if (sourceText.isEmpty || slices.isEmpty) return null;
    final legalBreaks = Icu4xLineBreaker.instance.breakOpportunities(
      sourceText,
    );

    final measureBuilder = ui.ParagraphBuilder(
      ui.ParagraphStyle(
        textAlign: ui.TextAlign.left,
        textDirection: ui.TextDirection.ltr,
        fontSize: baseSize * blockScale,
        height: lineHeight,
        fontFamily: fontFamily,
      ),
    );
    for (final slice in slices) {
      measureBuilder.pushStyle(
        _resolvedUiTextStyle(
          runStyle: slice.style,
          linked: slice.link != null,
          unified: unified,
          blockScale: blockScale,
          baseSize: baseSize,
          foreground: foreground,
          fontFamily: fontFamily,
          isHeading: isHeading,
          isQuote: isQuote,
          isDefinitionTerm: block.kind == TextBlockKind.definitionTerm,
        ),
      );
      measureBuilder.addText(sourceText.substring(slice.start, slice.end));
      measureBuilder.pop();
    }
    final measurement = measureBuilder.build()
      ..layout(const ui.ParagraphConstraints(width: 1000000));
    final ranges = _measurementRanges(sourceText, slices, legalBreaks);
    if (ranges == null) {
      measurement.dispose();
      return null;
    }
    final measured = <MeasuredCluster>[];
    var sliceIndex = 0;
    for (final range in ranges) {
      while (sliceIndex + 1 < slices.length &&
          slices[sliceIndex].end <= range.start) {
        sliceIndex++;
      }
      final slice = slices[sliceIndex];
      if (range.end > slice.end) {
        measurement.dispose();
        return null;
      }
      final boxes = measurement.getBoxesForRange(range.start, range.end);
      var advance = boxes.fold<double>(
        0,
        (total, box) => total + box.right - box.left,
      );
      if (boxes.isEmpty || !advance.isFinite || advance < 0) {
        final glyph = measurement.getGlyphInfoAt(range.start);
        if (glyph == null ||
            glyph.graphemeClusterCodeUnitRange.start != range.start ||
            glyph.graphemeClusterCodeUnitRange.end != range.end) {
          measurement.dispose();
          return null;
        }
        advance = glyph.graphemeClusterLayoutBounds.width;
      }
      measured.add(
        MeasuredCluster(
          start: range.start,
          end: range.end,
          advance: advance,
          em: slice.fontSize,
          ordinaryBaseline: slice.style.baseline == TextBaselineShift.none,
          footnoteReference: slice.style.linkRole == LinkRole.footnoteReference,
        ),
      );
    }
    measurement.dispose();
    final plan = const ParagraphOptimizer().plan(
      text: sourceText,
      clusters: measured,
      legalBreaks: legalBreaks,
      lineWidth: width,
      firstLineIndent: firstLineIndent,
      defaultEm: baseSize,
    );
    if (plan == null || plan.lines.length < 2) return null;

    final builder = ui.ParagraphBuilder(
      ui.ParagraphStyle(
        textAlign: ui.TextAlign.left,
        textDirection: ui.TextDirection.ltr,
        fontSize: baseSize * blockScale,
        height: lineHeight,
        fontFamily: fontFamily,
      ),
    );
    final hasIndent = firstLineIndent > 0;
    final displayToSource = <int>[0];
    var displayOffset = 0;
    if (hasIndent) {
      builder.addPlaceholder(
        firstLineIndent,
        baseSize,
        ui.PlaceholderAlignment.baseline,
        baseline: ui.TextBaseline.alphabetic,
        baselineOffset: baseSize * 0.8,
      );
      displayOffset++;
      displayToSource.add(0);
    }
    final sourceToDisplayStart = List<int>.filled(sourceText.length + 1, -1);
    final sourceToDisplayEnd = List<int>.filled(sourceText.length + 1, -1);
    sourceToDisplayStart[0] = displayOffset;
    sourceToDisplayEnd[0] = displayOffset;
    var activeSlice = 0;
    for (var lineIndex = 0; lineIndex < plan.lines.length; lineIndex++) {
      final line = plan.lines[lineIndex];
      var clusterIndex = line.startCluster;
      while (clusterIndex < line.endCluster) {
        final cluster = measured[clusterIndex];
        while (activeSlice + 1 < slices.length &&
            slices[activeSlice].end <= cluster.start) {
          activeSlice++;
        }
        final slice = slices[activeSlice];
        final adjustment = plan.adjustments[clusterIndex];
        final groupedAdjustment =
            adjustment.abs() > 0.0001 &&
            sourceText.substring(cluster.start, cluster.end).characters.length >
                1;
        var segmentEnd = clusterIndex + 1;
        while (!groupedAdjustment && segmentEnd < line.endCluster) {
          final next = measured[segmentEnd];
          if (next.end > slice.end ||
              (plan.adjustments[segmentEnd] - adjustment).abs() > 0.0001 ||
              (adjustment.abs() > 0.0001 &&
                  sourceText.substring(next.start, next.end).characters.length >
                      1)) {
            break;
          }
          segmentEnd++;
        }
        final sourceStart = cluster.start;
        final sourceEnd = measured[segmentEnd - 1].end;

        void addSegment(int start, int end, double? letterSpacing) {
          if (end <= start) return;
          builder.pushStyle(
            _resolvedUiTextStyle(
              runStyle: slice.style,
              linked: slice.link != null,
              unified: unified,
              blockScale: blockScale,
              baseSize: baseSize,
              foreground: foreground,
              fontFamily: fontFamily,
              isHeading: isHeading,
              isQuote: isQuote,
              isDefinitionTerm: block.kind == TextBlockKind.definitionTerm,
              letterSpacing: letterSpacing,
            ),
          );
          builder.addText(sourceText.substring(start, end));
          builder.pop();
        }

        if (groupedAdjustment) {
          final last = sourceText
              .substring(sourceStart, sourceEnd)
              .characters
              .last;
          final lastStart = sourceEnd - last.length;
          addSegment(sourceStart, lastStart, null);
          addSegment(lastStart, sourceEnd, adjustment);
        } else {
          addSegment(
            sourceStart,
            sourceEnd,
            adjustment.abs() <= 0.0001 ? null : adjustment,
          );
        }
        for (var unit = sourceStart; unit < sourceEnd; unit++) {
          sourceToDisplayStart[unit] = displayOffset;
          sourceToDisplayEnd[unit] = displayOffset;
          displayOffset++;
          displayToSource.add(unit + 1);
        }
        sourceToDisplayStart[sourceEnd] = displayOffset;
        sourceToDisplayEnd[sourceEnd] = displayOffset;
        clusterIndex = segmentEnd;
      }
      if (lineIndex + 1 < plan.lines.length) {
        final boundary = measured[line.endCluster - 1].end;
        sourceToDisplayEnd[boundary] = displayOffset;
        builder.addText('\n');
        displayOffset++;
        displayToSource.add(boundary);
        sourceToDisplayStart[boundary] = displayOffset;
      }
    }
    final paragraph = builder.build()
      ..layout(ui.ParagraphConstraints(width: width));
    final metrics = paragraph.computeLineMetrics();
    if (metrics.length != plan.lines.length) {
      paragraph.dispose();
      return null;
    }
    final tolerance = math.max(1.0, width * 0.01);
    for (var index = 0; index + 1 < metrics.length; index++) {
      if ((metrics[index].width - width).abs() > tolerance) {
        paragraph.dispose();
        return null;
      }
    }
    final links = <TextLinkRange>[];
    for (final slice in slices) {
      final link = slice.link;
      if (link == null) continue;
      final start = sourceToDisplayStart[slice.start];
      final end = sourceToDisplayEnd[slice.end];
      if (start < 0 || end <= start) continue;
      links.add(
        TextLinkRange(
          start: start,
          end: end,
          href: link,
          marker: sourceText.substring(slice.start, slice.end).trim(),
          role: slice.style.linkRole,
        ),
      );
    }
    return _OptimizedParagraphBuild(
      paragraph: paragraph,
      metrics: metrics,
      links: links,
      displayToSource: displayToSource,
    );
  }

  static double _resolvedFontSize(
    TextStyle style, {
    required bool unified,
    required double blockScale,
    required double baseSize,
  }) {
    var scale = unified ? blockScale : style.sizeScale * blockScale;
    if (style.baseline != TextBaselineShift.none) scale *= 0.7;
    return baseSize * scale;
  }

  static List<_MeasurementRange>? _measurementRanges(
    String text,
    List<_SourceRunSlice> slices,
    Set<int> legalBreaks,
  ) {
    final ranges = <_MeasurementRange>[];
    var offset = 0;
    var sliceIndex = 0;
    int? groupedStart;

    void flushGroup() {
      final start = groupedStart;
      if (start != null && start < offset) {
        ranges.add(_MeasurementRange(start, offset));
      }
      groupedStart = null;
    }

    for (final grapheme in text.characters) {
      final end = offset + grapheme.length;
      while (sliceIndex + 1 < slices.length &&
          slices[sliceIndex].end <= offset) {
        flushGroup();
        sliceIndex++;
      }
      if (end > slices[sliceIndex].end) return null;
      if (_requiresStandaloneMeasurement(grapheme)) {
        flushGroup();
        ranges.add(_MeasurementRange(offset, end));
      } else {
        groupedStart ??= offset;
      }
      offset = end;
      if (legalBreaks.contains(offset) || offset == slices[sliceIndex].end) {
        flushGroup();
      }
    }
    flushGroup();
    return offset == text.length ? ranges : null;
  }

  static bool _requiresStandaloneMeasurement(String grapheme) {
    for (final rune in grapheme.runes) {
      if (_isLayoutWhitespace(rune) ||
          _isLayoutCjk(rune) ||
          const {
            0x2d,
            0x2010,
            0x2013,
            0x2014,
            0x200b,
            0x2060,
            0x00b7,
            0x30fb,
            0x300a,
            0x3008,
            0xff08,
            0x300e,
            0x300c,
            0x3010,
            0x3016,
            0x3014,
            0xff3b,
            0xff5b,
            0xff0c,
            0xff0e,
            0x3002,
            0x3001,
            0xff1a,
            0xff1b,
            0x300b,
            0x3009,
            0xff09,
            0x300f,
            0x300d,
            0x3011,
            0x3017,
            0x3015,
            0xff3d,
            0xff5d,
            0xff1f,
            0xff01,
            0x201c,
            0x2018,
            0x201d,
            0x2019,
          }.contains(rune)) {
        return true;
      }
    }
    return false;
  }

  static bool _isLayoutWhitespace(int rune) =>
      String.fromCharCode(rune).trim().isEmpty;

  static bool _isLayoutCjk(int rune) =>
      rune == 0x30fc ||
      (rune >= 0x3040 && rune <= 0x30ff) ||
      (rune >= 0x3400 && rune <= 0x4dbf) ||
      (rune >= 0x4e00 && rune <= 0x9fff) ||
      (rune >= 0x20000 && rune <= 0x323af) ||
      (rune >= 0xac00 && rune <= 0xd7af) ||
      (rune >= 0xf900 && rune <= 0xfaff);

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
      style,
      fontScale,
      lineHeight,
      padding,
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
      horizontalOffset: unified
          ? math.max(
              0,
              (contentWidth -
                      columnWidths.fold<double>(
                        0,
                        (sum, width) => sum + width,
                      )) /
                  2,
            )
          : 0,
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
    ReaderStyle style,
    double fontScale,
    double lineHeight,
    double padding,
  ) {
    if (!adaptive) {
      return List.filled(columnCount, contentWidth / columnCount);
    }
    final equalWidth = contentWidth / columnCount;
    final minimumWidth = math.max(
      1.0,
      math.min(style.baseFontSize * 3, equalWidth),
    );
    final preferred = List.filled(columnCount, minimumWidth);
    for (final entry in cells) {
      final measured = _buildTableCellParagraph(
        entry.cell,
        style,
        16384,
        fontScale,
        lineHeight,
      ).paragraph;
      final desired =
          (measured.maxIntrinsicWidth +
                  padding * 2 +
                  style.baseFontSize * fontScale * 0.5)
              .clamp(minimumWidth, contentWidth);
      measured.dispose();
      final current = preferred
          .skip(entry.column)
          .take(entry.columnSpan)
          .fold<double>(0, (sum, width) => sum + width);
      if (desired <= current) continue;
      final addition = (desired - current) / entry.columnSpan;
      for (
        var column = entry.column;
        column < entry.column + entry.columnSpan;
        column++
      ) {
        preferred[column] += addition;
      }
    }
    final preferredTotal = preferred.fold<double>(
      0,
      (sum, width) => sum + width,
    );
    if (preferredTotal <= contentWidth) return preferred;
    final minimumTotal = minimumWidth * columnCount;
    if (minimumTotal >= contentWidth) {
      return List.filled(columnCount, equalWidth);
    }
    final availableFlex = contentWidth - minimumTotal;
    final preferredFlex = preferred.fold<double>(
      0,
      (sum, width) => sum + width - minimumWidth,
    );
    final fitted = [
      for (final width in preferred)
        minimumWidth +
            availableFlex *
                ((width - minimumWidth) / math.max(1, preferredFlex)),
    ];
    final fittedTotal = fitted.fold<double>(0, (sum, width) => sum + width);
    fitted[fitted.length - 1] += contentWidth - fittedTotal;
    return fitted;
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
              color: _resolvedRunColor(
                runStyle: runStyle,
                unified: unified,
                foreground: foreground,
              ),
              fontWeight: cell.header || runStyle.bold
                  ? ui.FontWeight.bold
                  : null,
              fontStyle: runStyle.italic ? ui.FontStyle.italic : null,
              decoration: _decorationFor(runStyle, includeUnderline: !unified),
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
        case MathInline(:final latex, :final sizeScale):
          if (latex.isEmpty) continue;
          builder.pushStyle(
            ui.TextStyle(
              color: foreground,
              fontSize: style.baseFontSize * fontScale * sizeScale,
              fontFamily: 'monospace',
              fontStyle: ui.FontStyle.italic,
            ),
          );
          builder.addText(latex);
          builder.pop();
          paragraphOffset += latex.length;
      }
    }
    final paragraph = builder.build()
      ..layout(ui.ParagraphConstraints(width: width));
    return _BuiltTableCellParagraph(paragraph, links);
  }

  void _pushQuote(
    _Paginator paginator,
    QuoteBlock quote,
    ReaderStyle style,
    double contentLeft,
    double contentWidth,
    int spineIndex,
    double sectionTextOffset,
  ) {
    final unified = style.typesettingMode == TypesettingMode.unified;
    final horizontalPadding = unified
        ? style.baseFontSize * style.paragraphIndentEm
        : 0.0;
    final quoteLeft = contentLeft + horizontalPadding;
    final quoteWidth = math.max(40.0, contentWidth - horizontalPadding * 2);
    final prepared = <_PreparedText>[];
    var offset = sectionTextOffset;
    for (var index = 0; index < quote.body.length; index++) {
      final body = quote.body[index];
      var value = _prepareText(
        body,
        style,
        spineIndex,
        quoteLeft,
        quoteWidth,
        offset,
      );
      if (value != null &&
          unified &&
          quote.attribution == null &&
          index + 1 == quote.body.length) {
        value = value.copyWith(marginAfter: 0);
      }
      if (value != null) prepared.add(value);
      offset += body.plainText.length;
    }
    final attribution = quote.attribution;
    if (attribution != null) {
      final value = _prepareText(
        attribution,
        style,
        spineIndex,
        quoteLeft,
        quoteWidth,
        offset,
      );
      if (value != null) prepared.add(value);
    }
    if (prepared.isEmpty) return;

    if (unified) {
      const verticalPadding = 12.0;
      final outerGap = math.max(style.baseFontSize * 0.5, verticalPadding);
      final contentHeight = prepared.fold<double>(
        0,
        (height, item) =>
            height +
            _preparedTextHeight(item) +
            math.max(0, item.marginBefore) +
            math.max(0, item.marginAfter),
      );
      paginator.prepareGroup(contentHeight + verticalPadding * 3, outerGap);
      paginator.beginQuote(style.foreground, outerGap);
      for (final item in prepared) {
        paginator.pushText(item);
      }
      paginator.endQuote();
    } else {
      for (final item in prepared) {
        paginator.pushText(item);
      }
    }
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
    final prepared = _prepareImage(
      block,
      style,
      imageSizeResolver,
      contentWidth,
      contentHeight,
      viewportWidth,
    );
    paginator.pushImage(
      prepared.href,
      prepared.width,
      prepared.height,
      marginBefore: block.fixedPage
          ? 0
          : style.typesettingMode == TypesettingMode.unified
          ? style.baseFontSize
          : math.max(_imageBlockGap, block.style.marginBefore),
      marginAfter: block.fixedPage
          ? 0
          : style.typesettingMode == TypesettingMode.unified
          ? style.baseFontSize
          : math.max(_imageBlockGap, block.style.marginAfter),
      centerVertically: prepared.centerVertically,
      fillViewportWidth: prepared.fillViewportWidth,
    );
  }

  _PreparedImage _prepareImage(
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
        return _PreparedImage(
          href: block.href,
          width: width,
          height: height,
          centerVertically: true,
          fillViewportWidth: true,
        );
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
    return _PreparedImage(
      href: block.href,
      width: width,
      height: height,
      centerVertically: block.fixedPage,
      fillViewportWidth: block.fixedPage,
    );
  }

  void _pushFigure(
    _Paginator paginator,
    FigureBlock figure,
    ReaderStyle style,
    ui.Size? Function(String href)? imageSizeResolver,
    double contentLeft,
    double contentWidth,
    double contentHeight,
    double viewportWidth,
    int spineIndex,
    double sectionTextOffset,
  ) {
    final unified = style.typesettingMode == TypesettingMode.unified;
    final images = figure.images
        .map(
          (image) => _prepareImage(
            image,
            style,
            imageSizeResolver,
            contentWidth,
            contentHeight,
            viewportWidth,
          ),
        )
        .toList();
    final captions = <_PreparedText>[];
    var captionOffset = sectionTextOffset;
    for (final caption in figure.captions) {
      final prepared = _prepareFigureCaption(
        caption,
        style,
        spineIndex,
        contentLeft,
        contentWidth,
        captionOffset,
      );
      if (prepared != null) captions.add(prepared);
      captionOffset += caption.plainText.length;
    }

    final em = style.baseFontSize;
    final authoredImageGap = figure.images.fold<double>(
      0,
      (gap, image) => math.max(
        gap,
        math.max(image.style.marginBefore, image.style.marginAfter),
      ),
    );
    final outerGap = unified
        ? em
        : math.max(
            _imageBlockGap,
            math.max(
              authoredImageGap,
              math.max(figure.style.marginBefore, figure.style.marginAfter),
            ),
          );
    final captionGap = unified ? em * 0.35 : 6.0;
    final imageHeight = images.fold(0.0, (sum, image) => sum + image.height);
    final captionHeight = captions.fold(
      0.0,
      (sum, caption) =>
          sum +
          _preparedTextHeight(caption) +
          math.max(0, caption.marginBefore) +
          math.max(0, caption.marginAfter),
    );
    final internalImageGaps = captionGap * math.max(0, images.length - 1);
    final imageCaptionGap = images.isEmpty || captions.isEmpty
        ? 0.0
        : captionGap;
    paginator.prepareGroup(
      imageHeight + captionHeight + internalImageGaps + imageCaptionGap,
      outerGap,
    );

    void pushImages() {
      for (var index = 0; index < images.length; index++) {
        if (index > 0) paginator.addSemanticSpacing(captionGap);
        final image = images[index];
        paginator.pushImage(
          image.href,
          image.width,
          image.height,
          marginBefore: 0,
          marginAfter: 0,
          centerVertically: image.centerVertically,
          fillViewportWidth: image.fillViewportWidth,
        );
      }
    }

    void pushCaptions() {
      for (final caption in captions) {
        paginator.pushText(caption);
      }
    }

    switch (figure.captionPosition) {
      case CaptionPosition.before:
        pushCaptions();
        if (captions.isNotEmpty && images.isNotEmpty) {
          paginator.addSemanticSpacing(captionGap);
        }
        pushImages();
      case CaptionPosition.after:
        pushImages();
        if (captions.isNotEmpty && images.isNotEmpty) {
          paginator.addSemanticSpacing(captionGap);
        }
        pushCaptions();
    }
    paginator.finishGroup(outerGap);
  }

  _PreparedText? _prepareFigureCaption(
    TextBlock caption,
    ReaderStyle style,
    int spineIndex,
    double contentLeft,
    double contentWidth,
    double sectionTextOffset,
  ) {
    var prepared = _prepareText(
      caption,
      style,
      spineIndex,
      contentLeft,
      contentWidth,
      sectionTextOffset,
    );
    if (prepared == null ||
        style.typesettingMode != TypesettingMode.unified ||
        prepared.metrics.length <= 1) {
      return prepared;
    }
    prepared.paragraph.dispose();
    prepared.markerParagraph?.dispose();
    prepared = _prepareText(
      caption,
      style,
      spineIndex,
      contentLeft,
      contentWidth,
      sectionTextOffset,
      unifiedAlignmentOverride: BlockAlign.start,
    );
    return prepared;
  }

  static double _preparedTextHeight(_PreparedText prepared) =>
      prepared.lineTops.last + prepared.metrics.last.height;

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

  static BlockAlign _resolvedUnifiedAlignment(
    TextBlock block, {
    BlockAlign? override,
  }) {
    if (override != null) return override;
    final prose =
        block.kind == TextBlockKind.paragraph ||
        block.kind == TextBlockKind.blockquote;
    final authored = block.style.authoredAlignment;
    if (prose && authored != null && authored != BlockAlign.start) {
      return authored;
    }
    if (prose ||
        block.kind == TextBlockKind.listItem &&
            _supportsSpaceJustification(block)) {
      return BlockAlign.justify;
    }
    return switch (block.kind) {
      TextBlockKind.caption => BlockAlign.center,
      TextBlockKind.quoteAttribution => BlockAlign.end,
      _ => BlockAlign.start,
    };
  }

  static bool _supportsSpaceJustification(TextBlock block) {
    for (final inline in block.inlines) {
      if (inline is! TextRun) continue;
      for (final rune in inline.text.runes) {
        if (rune == 0x00a0 || _isLayoutCjk(rune)) return false;
      }
    }
    return true;
  }

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

  static ui.TextDecoration? _resolvedDecoration({
    required bool underline,
    required bool strikethrough,
  }) {
    final decorations = <ui.TextDecoration>[
      if (underline) ui.TextDecoration.underline,
      if (strikethrough) ui.TextDecoration.lineThrough,
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

class _SourceRunSlice {
  final int start;
  final int end;
  final TextStyle style;
  final String? link;
  final double fontSize;

  const _SourceRunSlice({
    required this.start,
    required this.end,
    required this.style,
    required this.link,
    required this.fontSize,
  });
}

class _MeasurementRange {
  final int start;
  final int end;

  const _MeasurementRange(this.start, this.end);
}

class _OptimizedParagraphBuild {
  final ui.Paragraph paragraph;
  final List<ui.LineMetrics> metrics;
  final List<TextLinkRange> links;
  final List<int> displayToSource;

  const _OptimizedParagraphBuild({
    required this.paragraph,
    required this.metrics,
    required this.links,
    required this.displayToSource,
  });
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
  final double horizontalOffset;
  final List<double> rowHeights;
  final List<_PreparedTableCell> cells;
  final double padding;
  final double marginBefore;
  final double marginAfter;
  final int spineIndex;

  const _PreparedTable({
    required this.columnWidths,
    required this.horizontalOffset,
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

  /// Maps UTF-16 offsets in a paragraph containing optimizer-inserted line
  /// breaks back to offsets in the source text.
  final List<int>? displayToSource;

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
    required this.displayToSource,
  });

  _PreparedText copyWith({double? marginAfter}) => _PreparedText(
    paragraph: paragraph,
    metrics: metrics,
    lineTops: lineTops,
    x: x,
    width: width,
    marginBefore: marginBefore,
    marginAfter: marginAfter ?? this.marginAfter,
    syntheticPrefixLength: syntheticPrefixLength,
    marker: marker,
    markerParagraph: markerParagraph,
    markerX: markerX,
    markerWidth: markerWidth,
    textLength: textLength,
    source: source,
    nodeId: nodeId,
    spineIndex: spineIndex,
    sectionTextOffset: sectionTextOffset,
    links: links,
    displayToSource: displayToSource,
  );
}

class _PreparedImage {
  final String href;
  final double width;
  final double height;
  final bool centerVertically;
  final bool fillViewportWidth;

  const _PreparedImage({
    required this.href,
    required this.width,
    required this.height,
    required this.centerVertically,
    required this.fillViewportWidth,
  });
}

class _ActiveQuote {
  final int color;
  final double outerGap;
  int? decorationIndex;
  bool hasStarted = false;

  _ActiveQuote({required this.color, required this.outerGap});
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
  _ActiveQuote? activeQuote;

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
    _ensureQuoteDecoration();
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
      _updateQuoteDecoration();
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
            table.horizontalOffset +
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
    required double marginBefore,
    required double marginAfter,
    bool centerVertically = false,
    bool fillViewportWidth = false,
  }) {
    _collapseMargin(marginBefore);
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
    _setMarginAfter(marginAfter);
  }

  /// Keeps a semantic media group together when it fits on a fresh page.
  /// Oversized groups keep their normal item-by-item overflow behavior.
  void prepareGroup(double contentHeight, double outerGap) {
    _collapseMargin(outerGap);
    final pageHeight = bottom - top;
    if (contentHeight <= pageHeight + _eps &&
        contentHeight > remaining + _eps &&
        hasContent) {
      advance();
    }
  }

  void beginQuote(int color, double outerGap) {
    _collapseMargin(outerGap);
    activeQuote = _ActiveQuote(color: color, outerGap: outerGap);
  }

  void _ensureQuoteDecoration() {
    final active = activeQuote;
    if (active == null || active.decorationIndex != null) return;
    final index = items.length;
    items.add(
      QuotePlacement(
        x: left,
        y: cursorY,
        width: width,
        height: 12,
        color: active.color,
        continuedBefore: active.hasStarted,
      ),
    );
    active
      ..decorationIndex = index
      ..hasStarted = true;
    cursorY = math.min(bottom, cursorY + 12);
    hasContent = true;
  }

  void _updateQuoteDecoration() {
    final index = activeQuote?.decorationIndex;
    if (index == null || index >= items.length) return;
    final placement = items[index];
    if (placement is QuotePlacement) {
      placement.height = math.max(12, cursorY - placement.y);
    }
  }

  void endQuote() {
    final active = activeQuote;
    if (active == null) return;
    if (active.decorationIndex != null) {
      cursorY = math.min(bottom, cursorY + 12);
      _updateQuoteDecoration();
    }
    activeQuote = null;
    _setMarginAfter(active.outerGap);
  }

  void addSemanticSpacing(double amount) => _collapseMargin(amount);

  void finishGroup(double outerGap) => _setMarginAfter(outerGap);

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
      final active = activeQuote;
      final quoteIndex = active?.decorationIndex;
      if (quoteIndex != null && quoteIndex < items.length) {
        final placement = items[quoteIndex];
        if (placement is QuotePlacement) {
          placement
            ..height = math.max(placement.height, bottom - placement.y)
            ..continuedAfter = true;
        }
        active!.decorationIndex = null;
      }
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
    final mapping = prepared.displayToSource;
    if (mapping != null) {
      return mapping[position.offset.clamp(0, mapping.length - 1)].clamp(
        0,
        prepared.textLength,
      );
    }
    return (position.offset - prepared.syntheticPrefixLength).clamp(
      0,
      prepared.textLength,
    );
  }
}
