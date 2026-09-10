/// Pagination for the Reading IR: turns a [Section] into a list of
/// [PageLayout]s. A Dart port of torto's `crates/layout` Paginator (column
/// cursor, collapsing margins, line-range slicing of paragraphs across
/// pages), built on `dart:ui` paragraphs instead of Parley.
///
/// Known approximations:
/// - Superscript/subscript runs retain their text offsets and carry explicit
///   paint regions for baseline shifting (dart:ui has no baseline-shift style).
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:characters/characters.dart';
import 'package:flutter/foundation.dart';

import '../ir/ir.dart';
import '../linebreak/english_hyphenator.dart';
import '../linebreak/paragraph_optimizer.dart';
import '../linebreak/measurement.dart';
import '../linebreak/unicode_line_breaker.dart';
import 'layout_types.dart';
import 'source_offset_map.dart';

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

/// Opt-in release diagnostics for device-side hyphenation investigations.
const bool _debugHyphenation = bool.fromEnvironment('TORTO_DEBUG_HYPHENATION');

enum _SemanticScriptClass { cjk, italicFriendly, neutral }

class _SemanticTextSegment {
  final int start;
  final int end;
  final TextStyle style;

  const _SemanticTextSegment(this.start, this.end, this.style);
}

class _SemanticCluster {
  final int start;
  final int end;
  final int? firstRune;
  _SemanticScriptClass script;

  _SemanticCluster(this.start, this.end, this.firstRune, this.script);
}

class _InlineImageMetrics {
  final double width;
  final double height;
  final double boxHeight;
  final double baselineOffset;
  final double paintOffsetY;

  const _InlineImageMetrics({
    required this.width,
    required this.height,
    required this.boxHeight,
    required this.baselineOffset,
    required this.paintOffsetY,
  });
}

List<_SemanticTextSegment> _semanticTextSegments(
  String text,
  TextStyle style, {
  required bool unified,
  required WritingSystem fallbackWritingSystem,
}) {
  final semantic = style.emphasis || style.alternateVoice || style.citation;
  if (!unified || !semantic || text.isEmpty) {
    return [_SemanticTextSegment(0, text.length, style)];
  }
  final clusters = <_SemanticCluster>[];
  var offset = 0;
  for (final grapheme in text.characters) {
    final end = offset + grapheme.length;
    clusters.add(
      _SemanticCluster(
        offset,
        end,
        grapheme.runes.firstOrNull,
        _semanticGraphemeScript(grapheme),
      ),
    );
    offset = end;
  }
  if (clusters.isEmpty) return const [];
  final fallback = fallbackWritingSystem == WritingSystem.cjk
      ? _SemanticScriptClass.cjk
      : _SemanticScriptClass.italicFriendly;
  final nextStrong = List<_SemanticScriptClass?>.filled(clusters.length, null);
  _SemanticScriptClass? next;
  for (var index = clusters.length - 1; index >= 0; index--) {
    nextStrong[index] = next;
    if (clusters[index].script != _SemanticScriptClass.neutral) {
      next = clusters[index].script;
    }
  }
  _SemanticScriptClass? previous;
  for (var index = 0; index < clusters.length; index++) {
    final cluster = clusters[index];
    if (cluster.script == _SemanticScriptClass.neutral) {
      final right = nextStrong[index];
      cluster.script = _isSemanticOpeningPunctuation(cluster.firstRune)
          ? right ?? previous ?? fallback
          : previous ?? right ?? fallback;
    }
    previous = cluster.script;
  }

  final segments = <_SemanticTextSegment>[];
  for (final cluster in clusters) {
    var resolved = style;
    if (cluster.script == _SemanticScriptClass.cjk) {
      resolved = resolved.copyWith(
        bold: resolved.bold || resolved.emphasis || resolved.alternateVoice,
        italic: false,
      );
    } else {
      resolved = resolved.copyWith(italic: true);
    }
    if (segments.isNotEmpty &&
        segments.last.end == cluster.start &&
        segments.last.style == resolved) {
      final previousSegment = segments.removeLast();
      segments.add(
        _SemanticTextSegment(previousSegment.start, cluster.end, resolved),
      );
    } else {
      segments.add(_SemanticTextSegment(cluster.start, cluster.end, resolved));
    }
  }
  return segments;
}

_SemanticScriptClass _semanticGraphemeScript(String grapheme) {
  for (final rune in grapheme.runes) {
    if (_isSemanticCjkRune(rune)) return _SemanticScriptClass.cjk;
    if (_isSemanticItalicFriendlyRune(rune)) {
      return _SemanticScriptClass.italicFriendly;
    }
  }
  return _SemanticScriptClass.neutral;
}

bool _isSemanticCjkRune(int rune) =>
    (rune >= 0x3400 && rune <= 0x9fff) ||
    (rune >= 0xf900 && rune <= 0xfaff) ||
    (rune >= 0x20000 && rune <= 0x323af) ||
    (rune >= 0x3040 && rune <= 0x30ff) ||
    (rune >= 0x31f0 && rune <= 0x31ff) ||
    (rune >= 0xac00 && rune <= 0xd7af) ||
    (rune >= 0x1100 && rune <= 0x11ff);

bool _isSemanticItalicFriendlyRune(int rune) =>
    (rune >= 0x0041 && rune <= 0x024f) ||
    (rune >= 0x0370 && rune <= 0x052f) ||
    (rune >= 0x1e00 && rune <= 0x1eff) ||
    (rune >= 0x2c60 && rune <= 0x2c7f) ||
    (rune >= 0xa640 && rune <= 0xa69f);

bool _isSemanticOpeningPunctuation(int? rune) => const {
  0x0028,
  0x005b,
  0x2018,
  0x201c,
  0x3008,
  0x300a,
  0x300c,
  0x3010,
  0xff08,
}.contains(rune);

class LayoutEngine {
  final ParagraphHyphenator? hyphenator;

  const LayoutEngine({this.hyphenator});

  @visibleForTesting
  static double debugResolvedFontSize(
    TextStyle runStyle, {
    required bool unified,
    double blockScale = 1,
    double baseSize = 20,
  }) => _resolvedFontSize(
    runStyle,
    unified: unified,
    blockScale: blockScale,
    baseSize: baseSize,
  );

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
  static List<({String text, bool bold, bool italic})>
  debugResolvedSemanticSegments(
    String text,
    TextStyle style, {
    WritingSystem writingSystem = WritingSystem.unknown,
  }) => [
    for (final segment in _semanticTextSegments(
      text,
      style,
      unified: true,
      fallbackWritingSystem: writingSystem,
    ))
      (
        text: text.substring(segment.start, segment.end),
        bold: segment.style.bold,
        italic: segment.style.italic,
      ),
  ];

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

    // Cumulative Unicode-scalar source offsets for progression.
    final textStartOf = <Block, double>{};
    var totalText = 0.0;
    for (final block in flowBlocks) {
      final length = switch (block) {
        TextBlock(:final plainText) => plainText.runes.length,
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
            imageSizeResolver: imageSizeResolver,
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
            imageSizeResolver,
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
      var firstTextOffset = 0;
      double? firstSectionTextOffset;
      for (final item in items) {
        switch (item) {
          case TextPlacement():
            firstSource = item.source;
            firstNodeId = item.nodeId;
            firstTextOffset = item.textOffsetAtStart;
            firstSectionTextOffset = item.sectionTextOffset;
          case TableCellPlacement():
            firstSource = item.source;
            firstNodeId = item.nodeId;
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
          spine: firstSource?.start.spine ?? section.id,
          node: firstSource?.start.node ?? firstNodeId ?? '',
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
          if (block.text != null) {
            if (style.typesettingMode == TypesettingMode.book) {
              output.add(block.text!);
            }
            continue;
          }
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
    ui.Size? Function(String href)? imageSizeResolver,
  }) {
    final displaySystem = block.inlines
        .whereType<TextRun>()
        .map((run) => run.displayWritingSystem)
        .whereType<WritingSystem>()
        .firstOrNull;
    if (displaySystem != null) {
      style = style.copyWith(writingSystem: displaySystem);
    }
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
      paragraphLineHeight = style.unifiedBodyLineHeight;
      if (isHeading) {
        blockScale = _unifiedHeadingScale(block.headingLevel);
        paragraphLineHeight = 1.3;
        marginAfter = baseSize * 0.7;
        if (block.headingOrdinal) {
          blockScale *= .72;
          paragraphLineHeight = 1.15;
          marginAfter = baseSize * .25;
        }
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
          i is MathInline && i.latex.isNotEmpty ||
          i is InlineImageRun,
    );
    if (!hasText) return null;

    final foreground = ui.Color(style.foreground);
    final typography = style.typography;
    final latinFont = typography.latinFontFor(style.writingSystem);
    final cjkFont = typography.cjkFontFor(style.writingSystem);
    final fontFamily = isPre ? 'monospace' : latinFont.family;
    final fontFamilyFallback = <String>[cjkFont.family];
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
        fontWeight: _readerFontWeight(typography.fontWeight),
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
    final normalDisplayToSource = <int>[0];
    var sourceOffset = 0;
    if (indentWidth > 0) {
      builder.addPlaceholder(
        indentWidth,
        baseSize,
        ui.PlaceholderAlignment.baseline,
        baseline: ui.TextBaseline.alphabetic,
        baselineOffset: baseSize * 0.8,
      );
      syntheticPrefixLength = 1;
      normalDisplayToSource.add(0);
    }

    final links = <TextLinkRange>[];
    final inlineImages = <InlineImageRange>[];
    var paragraphOffset = syntheticPrefixLength;

    void appendSourceText(String text) {
      for (final rune in text.runes) {
        if (rune > 0xffff) normalDisplayToSource.add(sourceOffset);
        normalDisplayToSource.add(++sourceOffset);
      }
    }

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
            appendSourceText(text);
            continue;
          }
          for (final segment in _semanticTextSegments(
            text,
            runStyle,
            unified: unified,
            fallbackWritingSystem: style.writingSystem,
          )) {
            builder.pushStyle(
              _resolvedUiTextStyle(
                runStyle: segment.style,
                linked: link != null,
                unified: unified,
                blockScale: blockScale,
                baseSize: baseSize,
                foreground: foreground,
                fontFamily: fontFamily,
                fontFamilyFallback: fontFamilyFallback,
                typography: typography,
                isHeading: isHeading,
                isQuote: isQuote,
                isDefinitionTerm: isDefinitionTerm,
              ),
            );
            builder.addText(text.substring(segment.start, segment.end));
            builder.pop();
          }
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
          appendSourceText(text);
        case MathInline(:final latex, :final sizeScale):
          if (latex.isEmpty) continue;
          final scale = unified ? blockScale : sizeScale * blockScale;
          final fontSize = baseSize * scale;
          builder.pushStyle(
            ui.TextStyle(
              color: foreground,
              fontSize: unified
                  ? fontSize
                  : math.max(ReaderTypography.minimumFontSize, fontSize),
              fontFamily: 'monospace',
              fontStyle: ui.FontStyle.italic,
            ),
          );
          builder.addText(latex);
          builder.pop();
          paragraphOffset += latex.length;
          normalDisplayToSource.addAll(List.filled(latex.length, sourceOffset));
        case BreakInline(:final synthetic):
          builder.addText('\n');
          paragraphOffset++;
          if (synthetic) {
            normalDisplayToSource.add(sourceOffset);
          } else {
            appendSourceText('\n');
          }
        case InlineImageRun():
          final metrics = _inlineImageMetrics(
            inline,
            baseSize: baseSize,
            resolvedScale: unified ? blockScale : inline.sizeScale * blockScale,
            availableWidth: contentWidth,
            imageSizeResolver: imageSizeResolver,
          );
          builder.addPlaceholder(
            metrics.width,
            metrics.boxHeight,
            ui.PlaceholderAlignment.baseline,
            baseline: ui.TextBaseline.alphabetic,
            baselineOffset: metrics.baselineOffset,
          );
          inlineImages.add(
            InlineImageRange(
              start: paragraphOffset,
              end: paragraphOffset + 1,
              href: inline.image.href,
              width: metrics.width,
              height: metrics.height,
              paintOffsetY: metrics.paintOffsetY,
            ),
          );
          paragraphOffset++;
          normalDisplayToSource.add(sourceOffset);
      }
    }

    ui.Paragraph? markerParagraph;
    if (marker.isNotEmpty) {
      final markerBuilder =
          ui.ParagraphBuilder(
            ui.ParagraphStyle(
              textAlign: ui.TextAlign.left,
              textDirection: ui.TextDirection.ltr,
              fontSize: baseSize,
              height: paragraphLineHeight,
              fontFamily: latinFont.family,
              fontWeight: _readerFontWeight(typography.fontWeight),
            ),
          )..pushStyle(
            ui.TextStyle(
              color: foreground,
              fontSize: baseSize,
              fontFamily: latinFont.family,
              fontFamilyFallback: fontFamilyFallback,
              fontWeight: _readerFontWeight(typography.fontWeight),
              fontVariations: _fontVariations(
                typography,
                baseSize,
                latinFont.family,
                typography.fontWeight,
              ),
            ),
          );
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
    List<int> displayToSource = normalDisplayToSource;
    if (style.lineBreakStrategy == LineBreakStrategy.optimized &&
        metrics.length > 1 &&
        (resolvedAlign == BlockAlign.start ||
            resolvedAlign == BlockAlign.justify) &&
        (block.kind == TextBlockKind.paragraph ||
            block.kind == TextBlockKind.blockquote ||
            block.kind == TextBlockKind.caption ||
            block.kind == TextBlockKind.listItem ||
            block.kind == TextBlockKind.definitionDescription)) {
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
        publicationLanguage: style.publicationLanguage,
        writingSystem: style.writingSystem,
        imageSizeResolver: imageSizeResolver,
        typography: typography,
        fontFamilyFallback: fontFamilyFallback,
      );
      if (optimized != null) {
        paragraph.dispose();
        paragraph = optimized.paragraph;
        metrics = optimized.metrics;
        links
          ..clear()
          ..addAll(optimized.links);
        inlineImages
          ..clear()
          ..addAll(optimized.inlineImages);
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
      baselineRegions: _baselineRegions(
        block.inlines,
        paragraph,
        displayToSource,
      ),
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
      textLength: block.plainText.runes.length,
      source: block.source,
      nodeId: block.nodeId,
      spineIndex: spineIndex,
      sectionTextOffset: sectionTextOffset,
      links: links,
      inlineImages: inlineImages,
      displayToSource: displayToSource,
    );
  }

  static List<TextBaselineRegion> _baselineRegions(
    List<Inline> inlines,
    ui.Paragraph paragraph,
    List<int> mapping,
  ) {
    final regions = <TextBaselineRegion>[];
    var offset = 0;
    for (final inline in inlines) {
      if (inline is BreakInline && !inline.synthetic) offset++;
      if (inline is! TextRun) continue;
      final end = offset + inline.text.runes.length;
      if (inline.style.baseline != TextBaselineShift.none &&
          !_usesFootnoteIcon(inline.style, inline.link)) {
        // Work from the final display map, including optimizer-inserted breaks.
        final startDisplay = mapping.lastIndexOf(offset);
        final endDisplay = mapping.indexOf(end);
        if (startDisplay >= 0 && endDisplay > startDisplay) {
          for (final box in paragraph.getBoxesForRange(
            startDisplay,
            endDisplay,
          )) {
            final rect = box.toRect();
            regions.add(
              TextBaselineRegion(
                rect,
                rect.height *
                    (inline.style.baseline == TextBaselineShift.superscript
                        ? -0.35
                        : 0.2),
              ),
            );
          }
        }
      }
      offset = end;
    }
    return regions;
  }

  static ui.TextStyle _resolvedUiTextStyle({
    required TextStyle runStyle,
    required bool linked,
    required bool unified,
    required double blockScale,
    required double baseSize,
    required ui.Color foreground,
    required String? fontFamily,
    required List<String> fontFamilyFallback,
    required ReaderTypography typography,
    required bool isHeading,
    required bool isQuote,
    required bool isDefinitionTerm,
    double? letterSpacing,
  }) {
    final emphasis = _resolvedInlineEmphasis(
      runStyle: runStyle,
      linked: linked,
      unified: unified,
      isHeading: isHeading,
      isQuote: isQuote,
      isDefinitionTerm: isDefinitionTerm,
    );
    final fontSize = _resolvedFontSize(
      runStyle,
      unified: unified,
      blockScale: blockScale,
      baseSize: baseSize,
    );
    final weight = emphasis.bold
        ? math.max(700, typography.fontWeight)
        : typography.fontWeight;
    return ui.TextStyle(
      color: _resolvedRunColor(
        runStyle: runStyle,
        unified: unified,
        foreground: foreground,
      ),
      fontWeight: _readerFontWeight(weight),
      fontStyle: emphasis.italic ? ui.FontStyle.italic : null,
      decoration: _resolvedDecoration(
        underline: emphasis.underline,
        strikethrough: emphasis.strikethrough,
      ),
      fontSize: fontSize,
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
      fontVariations: _fontVariations(typography, fontSize, fontFamily, weight),
      letterSpacing: letterSpacing,
    );
  }

  static ui.FontWeight _readerFontWeight(int weight) =>
      ui.FontWeight.values[((weight / 100).round() - 1).clamp(0, 8)];

  static List<ui.FontVariation>? _fontVariations(
    ReaderTypography typography,
    double fontSize,
    String? fontFamily,
    int fontWeight,
  ) => fontFamily == 'Literata'
      ? [
          ui.FontVariation('wght', fontWeight.toDouble()),
          ui.FontVariation('opsz', (fontSize * 0.75).clamp(7.0, 72.0)),
        ]
      : null;

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
    final semantic =
        runStyle.emphasis || runStyle.alternateVoice || runStyle.citation;
    final semanticCjkEmphasis =
        unified &&
        (runStyle.emphasis || runStyle.alternateVoice) &&
        runStyle.bold &&
        !runStyle.italic;
    return (
      bold:
          (runStyle.bold && !clearBold) ||
          semanticCjkEmphasis ||
          isHeading ||
          isDefinitionTerm,
      italic: runStyle.italic && (!clearItalic || semantic),
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
    required List<String> fontFamilyFallback,
    required ReaderTypography typography,
    required bool isHeading,
    required bool isQuote,
    required double firstLineIndent,
    required double width,
    required String publicationLanguage,
    required WritingSystem writingSystem,
    required ui.Size? Function(String href)? imageSizeResolver,
  }) {
    final slices = <_SourceRunSlice>[];
    final text = StringBuffer();
    var sourceOffset = 0;
    var originalSourceOffset = 0;
    final logicalToOriginalSource = <int>[0];
    for (final inline in block.inlines) {
      switch (inline) {
        case BreakInline(:final synthetic):
          if (synthetic) return null;
          text.write('\n');
          slices.add(
            _SourceRunSlice(
              start: sourceOffset,
              end: sourceOffset + 1,
              style: TextStyle.plain,
              link: null,
              language: null,
              footnoteIcon: false,
              footnoteSize: 0,
              fontSize: baseSize * blockScale,
            ),
          );
          sourceOffset++;
          logicalToOriginalSource.add(++originalSourceOffset);
        case MathInline():
          return null;
        case InlineImageRun():
          final metrics = _inlineImageMetrics(
            inline,
            baseSize: baseSize,
            resolvedScale: unified ? blockScale : inline.sizeScale * blockScale,
            availableWidth: width,
            imageSizeResolver: imageSizeResolver,
          );
          final start = sourceOffset;
          text.write('\uFFFC');
          sourceOffset++;
          logicalToOriginalSource.add(originalSourceOffset);
          slices.add(
            _SourceRunSlice(
              start: start,
              end: sourceOffset,
              style: TextStyle.plain,
              link: null,
              language: null,
              footnoteIcon: false,
              footnoteSize: 0,
              fontSize: baseSize * blockScale,
              inlineImageMetrics: metrics,
              inlineImageHref: inline.image.href,
            ),
          );
        case TextRun(
          text: final value,
          style: final runStyle,
          :final link,
          :final language,
        ):
          if (value.isEmpty) continue;
          final footnoteIcon = _usesFootnoteIcon(runStyle, link);
          final authoredScale = unified
              ? blockScale
              : runStyle.sizeScale * blockScale;
          final runStart = sourceOffset;
          sourceOffset += value.length;
          for (final rune in value.runes) {
            if (rune > 0xffff) {
              logicalToOriginalSource.add(originalSourceOffset);
            }
            logicalToOriginalSource.add(++originalSourceOffset);
          }
          text.write(value);
          final semanticSegments = footnoteIcon
              ? [_SemanticTextSegment(0, value.length, runStyle)]
              : _semanticTextSegments(
                  value,
                  runStyle,
                  unified: unified,
                  fallbackWritingSystem: writingSystem,
                );
          for (final segment in semanticSegments) {
            final segmentStyle = segment.style;
            slices.add(
              _SourceRunSlice(
                start: runStart + segment.start,
                end: runStart + segment.end,
                style: segmentStyle,
                link: link,
                language: language,
                footnoteIcon: footnoteIcon,
                footnoteSize: footnoteIcon
                    ? (baseSize * authoredScale * 0.78).clamp(8.0, 12.0)
                    : 0,
                fontSize: _resolvedFontSize(
                  segmentStyle,
                  unified: unified,
                  blockScale: blockScale,
                  baseSize: baseSize,
                ),
              ),
            );
          }
      }
    }
    final sourceText = text.toString();
    if (sourceText.isEmpty || slices.isEmpty) return null;
    final legalBreaks = Icu4xLineBreaker.instance.breakOpportunities(
      sourceText,
    );
    final hyphenationBreaks =
        hyphenator?.breakOpportunities(
          text: sourceText,
          spans: [
            for (final slice in slices)
              HyphenationSpan(
                start: slice.start,
                end: slice.end,
                language: slice.language,
                suppress:
                    slice.link != null ||
                    slice.footnoteIcon ||
                    slice.inlineImageMetrics != null,
                mode: slice.style.hyphenation,
              ),
          ],
          publicationLanguage: publicationLanguage,
        ) ??
        const <int>{};
    final measurementBreaks = {...legalBreaks, ...hyphenationBreaks};
    if (_debugHyphenation && hyphenationBreaks.isNotEmpty) {
      debugPrint(
        'TORTO_HYPH candidates=${hyphenationBreaks.length} '
        'language=$publicationLanguage text=${sourceText.substring(0, math.min(60, sourceText.length))}',
      );
    }

    final measureBuilder = ui.ParagraphBuilder(
      ui.ParagraphStyle(
        textAlign: ui.TextAlign.left,
        textDirection: ui.TextDirection.ltr,
        fontSize: baseSize * blockScale,
        height: lineHeight,
        fontFamily: fontFamily,
        fontWeight: _readerFontWeight(typography.fontWeight),
      ),
    );
    for (final slice in slices) {
      final inlineImage = slice.inlineImageMetrics;
      if (inlineImage != null) {
        measureBuilder.addPlaceholder(
          inlineImage.width,
          inlineImage.boxHeight,
          ui.PlaceholderAlignment.baseline,
          baseline: ui.TextBaseline.alphabetic,
          baselineOffset: inlineImage.baselineOffset,
        );
        continue;
      }
      if (slice.footnoteIcon) {
        _appendFootnotePlaceholder(
          measureBuilder,
          sourceText.substring(slice.start, slice.end),
          slice.footnoteSize,
        );
        continue;
      }
      measureBuilder.pushStyle(
        _resolvedUiTextStyle(
          runStyle: slice.style,
          linked: slice.link != null,
          unified: unified,
          blockScale: blockScale,
          baseSize: baseSize,
          foreground: foreground,
          fontFamily: fontFamily,
          fontFamilyFallback: fontFamilyFallback,
          typography: typography,
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
    final ranges = _measurementRanges(sourceText, slices, measurementBreaks);
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
      final inlineImage = slice.inlineImageMetrics;
      if (inlineImage != null) {
        if (range.start != slice.start || range.end != slice.end) {
          measurement.dispose();
          return null;
        }
        measured.add(
          MeasuredCluster(
            start: range.start,
            end: range.end,
            advance: inlineImage.width,
            em: math.max(baseSize, inlineImage.boxHeight),
            ordinaryBaseline: false,
            footnoteReference: false,
          ),
        );
        continue;
      }
      if (slice.footnoteIcon) {
        if (range.start != slice.start || range.end != slice.end) {
          measurement.dispose();
          return null;
        }
        measured.add(
          MeasuredCluster(
            start: range.start,
            end: range.end,
            advance: slice.footnoteSize,
            em: slice.fontSize,
            ordinaryBaseline: false,
            footnoteReference: true,
          ),
        );
        continue;
      }
      if (sourceText
          .substring(range.start, range.end)
          .contains(RegExp(r'[\r\n]'))) {
        measured.add(
          MeasuredCluster(
            start: range.start,
            end: range.end,
            advance: 0,
            em: slice.fontSize,
          ),
        );
        continue;
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
    final hyphenBreakWidths = <int, double>{};
    var hyphenSliceIndex = 0;
    final orderedHyphenBreaks = hyphenationBreaks.toList()..sort();
    for (final offset in orderedHyphenBreaks) {
      if (offset <= 0 || offset >= sourceText.length) continue;
      while (hyphenSliceIndex + 1 < slices.length &&
          slices[hyphenSliceIndex].end < offset) {
        hyphenSliceIndex++;
      }
      final slice = slices[hyphenSliceIndex];
      if (offset <= slice.start || offset > slice.end) continue;
      final advance = _measureDiscretionaryHyphen(
        slice: slice,
        unified: unified,
        blockScale: blockScale,
        baseSize: baseSize,
        lineHeight: lineHeight,
        foreground: foreground,
        fontFamily: fontFamily,
        fontFamilyFallback: fontFamilyFallback,
        typography: typography,
        isHeading: isHeading,
        isQuote: isQuote,
        isDefinitionTerm: block.kind == TextBlockKind.definitionTerm,
      );
      if (advance.isFinite && advance > 0) {
        hyphenBreakWidths[offset] = advance;
      }
    }
    // Leave one physical-pixel-sized sliver for SkParagraph shaping and
    // letter-spacing rounding. Without it, a line that is mathematically an
    // exact fit can auto-wrap its final word before our explicit line break.
    final optimizedWidth = math.max(
      1.0,
      width - math.min(1.0, baseSize * 0.05),
    );
    final plan = const ParagraphOptimizer().plan(
      text: sourceText,
      clusters: measured,
      legalBreaks: legalBreaks,
      hyphenBreaks: hyphenBreakWidths,
      lineWidth: optimizedWidth,
      firstLineIndent: firstLineIndent,
      defaultEm: baseSize,
    );
    if (_debugHyphenation && plan == null) {
      debugPrint(
        'TORTO_HYPH optimizer-input width=${optimizedWidth.toStringAsFixed(1)} '
        'indent=${firstLineIndent.toStringAsFixed(1)} clusters=${measured.length} '
        'legal=${legalBreaks.length} textLength=${sourceText.length}',
      );
    }
    if (plan == null || plan.lines.length < 2) {
      if (_debugHyphenation) {
        debugPrint(
          'TORTO_HYPH rejected=optimizer-null candidates=${hyphenationBreaks.length}',
        );
      }
      return null;
    }
    if (_debugHyphenation) {
      debugPrint(
        'TORTO_HYPH planned=${plan.lines.length} '
        'selected=${plan.lines.where((line) => line.hyphenated).length}',
      );
    }

    final builder = ui.ParagraphBuilder(
      ui.ParagraphStyle(
        textAlign: ui.TextAlign.left,
        textDirection: ui.TextDirection.ltr,
        fontSize: baseSize * blockScale,
        height: lineHeight,
        fontFamily: fontFamily,
        fontWeight: _readerFontWeight(typography.fontWeight),
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
    final intendedLineEnds = <int>[];
    final optimizedInlineImages = <InlineImageRange>[];
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

        final inlineImage = slice.inlineImageMetrics;
        if (inlineImage != null) {
          builder.addPlaceholder(
            inlineImage.width,
            inlineImage.boxHeight,
            ui.PlaceholderAlignment.baseline,
            baseline: ui.TextBaseline.alphabetic,
            baselineOffset: inlineImage.baselineOffset,
          );
          sourceToDisplayStart[sourceStart] = displayOffset;
          sourceToDisplayEnd[sourceStart] = displayOffset;
          optimizedInlineImages.add(
            InlineImageRange(
              start: displayOffset,
              end: displayOffset + 1,
              href: slice.inlineImageHref!,
              width: inlineImage.width,
              height: inlineImage.height,
              paintOffsetY: inlineImage.paintOffsetY,
            ),
          );
          displayOffset++;
          displayToSource.add(logicalToOriginalSource[sourceEnd]);
          sourceToDisplayStart[sourceEnd] = displayOffset;
          sourceToDisplayEnd[sourceEnd] = displayOffset;
          clusterIndex = segmentEnd;
          continue;
        }

        if (slice.footnoteIcon) {
          _appendFootnotePlaceholder(
            builder,
            sourceText.substring(sourceStart, sourceEnd),
            slice.footnoteSize,
          );
          for (var unit = sourceStart; unit < sourceEnd; unit++) {
            sourceToDisplayStart[unit] = displayOffset;
            sourceToDisplayEnd[unit] = displayOffset;
            displayOffset++;
            displayToSource.add(logicalToOriginalSource[unit + 1]);
          }
          sourceToDisplayStart[sourceEnd] = displayOffset;
          sourceToDisplayEnd[sourceEnd] = displayOffset;
          clusterIndex = segmentEnd;
          continue;
        }

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
              fontFamilyFallback: fontFamilyFallback,
              typography: typography,
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
          displayToSource.add(logicalToOriginalSource[unit + 1]);
        }
        sourceToDisplayStart[sourceEnd] = displayOffset;
        sourceToDisplayEnd[sourceEnd] = displayOffset;
        clusterIndex = segmentEnd;
      }
      if (lineIndex + 1 < plan.lines.length) {
        final boundary = measured[line.endCluster - 1].end;
        if (line.hyphenated) {
          final slice = slices[activeSlice];
          builder.pushStyle(
            _resolvedUiTextStyle(
              runStyle: slice.style,
              linked: slice.link != null,
              unified: unified,
              blockScale: blockScale,
              baseSize: baseSize,
              foreground: foreground,
              fontFamily: fontFamily,
              fontFamilyFallback: fontFamilyFallback,
              typography: typography,
              isHeading: isHeading,
              isQuote: isQuote,
              isDefinitionTerm: block.kind == TextBlockKind.definitionTerm,
            ),
          );
          builder.addText('\u2010');
          builder.pop();
          displayOffset++;
          displayToSource.add(logicalToOriginalSource[boundary]);
        }
        sourceToDisplayEnd[boundary] = displayOffset;
        intendedLineEnds.add(displayOffset);
        if (!sourceText.substring(0, boundary).endsWith('\n') &&
            !sourceText.substring(0, boundary).endsWith('\r')) {
          builder.addText('\n');
          displayOffset++;
          displayToSource.add(logicalToOriginalSource[boundary]);
        }
        sourceToDisplayStart[boundary] = displayOffset;
      }
    }
    final paragraph = builder.build()
      ..layout(ui.ParagraphConstraints(width: width));
    final metrics = paragraph.computeLineMetrics();
    if (metrics.length != plan.lines.length) {
      if (_debugHyphenation) {
        final planned = plan.lines
            .map(
              (line) =>
                  '${line.naturalWidth.toStringAsFixed(1)}${line.hyphenated ? 'h' : ''}',
            )
            .join(',');
        final actual = metrics
            .map(
              (metric) =>
                  '${metric.width.toStringAsFixed(1)}${metric.hardBreak ? '!' : ''}',
            )
            .join(',');
        final intended = intendedLineEnds
            .map((offset) => paragraph.getLineNumberAt(math.max(0, offset - 1)))
            .join(',');
        debugPrint(
          'TORTO_HYPH rejected=line-count planned=${plan.lines.length} '
          'actual=${metrics.length} plan=[$planned] metrics=[$actual] '
          'ends=[$intended]',
        );
      }
      paragraph.dispose();
      return null;
    }
    final tolerance = math.max(1.0, width * 0.01);
    for (var index = 0; index + 1 < metrics.length; index++) {
      if (plan.lines[index].paragraphEnd) continue;
      if ((metrics[index].width - optimizedWidth).abs() > tolerance) {
        if (_debugHyphenation) {
          debugPrint(
            'TORTO_HYPH rejected=width line=$index '
            'actual=${metrics[index].width} target=$optimizedWidth',
          );
        }
        paragraph.dispose();
        return null;
      }
    }
    if (_debugHyphenation) {
      debugPrint('TORTO_HYPH accepted');
    }
    final links = <TextLinkRange>[];
    for (final slice in slices) {
      final link = slice.link;
      if (link == null && !slice.footnoteIcon) continue;
      final start = sourceToDisplayStart[slice.start];
      final end = sourceToDisplayEnd[slice.end];
      if (start < 0 || end <= start) continue;
      links.add(
        TextLinkRange(
          start: start,
          end: end,
          href: link ?? '',
          marker: sourceText.substring(slice.start, slice.end).trim(),
          role: slice.style.linkRole,
          footnoteIcon: slice.footnoteIcon,
          inlineNote: slice.style.inlineRole == InlineRole.footnote
              ? sourceText.substring(slice.start, slice.end).trim()
              : null,
        ),
      );
    }
    return _OptimizedParagraphBuild(
      paragraph: paragraph,
      metrics: metrics,
      links: links,
      displayToSource: displayToSource,
      inlineImages: optimizedInlineImages,
    );
  }

  static double _measureDiscretionaryHyphen({
    required _SourceRunSlice slice,
    required bool unified,
    required double blockScale,
    required double baseSize,
    required double lineHeight,
    required ui.Color foreground,
    required String? fontFamily,
    required List<String> fontFamilyFallback,
    required ReaderTypography typography,
    required bool isHeading,
    required bool isQuote,
    required bool isDefinitionTerm,
  }) {
    final builder = ui.ParagraphBuilder(
      ui.ParagraphStyle(
        textAlign: ui.TextAlign.left,
        textDirection: ui.TextDirection.ltr,
        fontSize: baseSize * blockScale,
        height: lineHeight,
        fontFamily: fontFamily,
        fontWeight: _readerFontWeight(typography.fontWeight),
      ),
    );
    builder.pushStyle(
      _resolvedUiTextStyle(
        runStyle: slice.style,
        linked: slice.link != null,
        unified: unified,
        blockScale: blockScale,
        baseSize: baseSize,
        foreground: foreground,
        fontFamily: fontFamily,
        fontFamilyFallback: fontFamilyFallback,
        typography: typography,
        isHeading: isHeading,
        isQuote: isQuote,
        isDefinitionTerm: isDefinitionTerm,
      ),
    );
    builder.addText('\u2010');
    builder.pop();
    final paragraph = builder.build()
      ..layout(const ui.ParagraphConstraints(width: 1000));
    final advance = paragraph.maxIntrinsicWidth;
    paragraph.dispose();
    return advance;
  }

  static double _resolvedFontSize(
    TextStyle style, {
    required bool unified,
    required double blockScale,
    required double baseSize,
  }) {
    var scale = unified ? blockScale : style.sizeScale * blockScale;
    if (style.baseline != TextBaselineShift.none) scale *= 0.7;
    final resolved = baseSize * scale;
    return unified
        ? resolved
        : math.max(ReaderTypography.minimumFontSize, resolved);
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
      if (slices[sliceIndex].footnoteIcon ||
          slices[sliceIndex].inlineImageMetrics != null) {
        flushGroup();
        if (offset == slices[sliceIndex].start) {
          ranges.add(
            _MeasurementRange(slices[sliceIndex].start, slices[sliceIndex].end),
          );
        }
        offset = end;
        continue;
      }
      if (requiresStandaloneMeasurement(grapheme)) {
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

  static _InlineImageMetrics _inlineImageMetrics(
    InlineImageRun run, {
    required double baseSize,
    required double resolvedScale,
    required double availableWidth,
    required ui.Size? Function(String href)? imageSizeResolver,
  }) {
    final intrinsic = imageSizeResolver?.call(run.image.href);
    final aspectRatio = intrinsic == null || intrinsic.height <= 0
        ? 1.0
        : intrinsic.width / intrinsic.height;
    final surroundingScale = math.max(0.1, resolvedScale);
    double? authoredHeight = switch (run.image.style.height) {
      ImagePixels(:final value) => baseSize * surroundingScale * value / 16,
      ImageFraction(:final value) => baseSize * surroundingScale * value,
      null => null,
    };
    double? authoredWidth = switch (run.image.style.width) {
      ImagePixels(:final value) => baseSize * surroundingScale * value / 16,
      ImageFraction(:final value) => availableWidth * value,
      null => null,
    };
    double requestedWidth;
    double requestedHeight;
    if (run.intrinsicSizing) {
      if (authoredHeight != null) {
        requestedHeight = authoredHeight;
        requestedWidth = requestedHeight * aspectRatio;
      } else if (authoredWidth != null) {
        requestedWidth = authoredWidth;
        requestedHeight = requestedWidth / math.max(0.01, aspectRatio);
      } else {
        requestedHeight =
            baseSize * surroundingScale * (intrinsic?.height ?? 16) / 16;
        requestedWidth = requestedHeight * aspectRatio;
      }
    } else {
      requestedHeight = baseSize * resolvedScale;
      requestedWidth = requestedHeight * aspectRatio;
    }
    final minimumHeight = baseSize * 0.2;
    final maximumHeight = baseSize * 4.0;
    final heightScale =
        requestedHeight.clamp(minimumHeight, maximumHeight) /
        math.max(1.0, requestedHeight);
    requestedWidth *= heightScale;
    requestedHeight *= heightScale;
    final widthScale = requestedWidth <= 0
        ? 1.0
        : math.min(1.0, availableWidth / requestedWidth);
    final width = math.max(1.0, requestedWidth * widthScale);
    final height = math.max(1.0, requestedHeight * widthScale);
    final surroundingEm = baseSize * surroundingScale;
    final shift = switch (run.verticalAlign) {
      InlineImageAlignment.baseline => 0.0,
      InlineImageAlignment.middle => height * 0.5 - surroundingEm * 0.3,
      InlineImageAlignment.textTop ||
      InlineImageAlignment.top => height - surroundingEm * 0.8,
      InlineImageAlignment.textBottom ||
      InlineImageAlignment.bottom ||
      InlineImageAlignment.subscript => surroundingEm * 0.2,
      InlineImageAlignment.superscript => -surroundingEm * 0.35,
    };
    final ascent = surroundingEm * 0.8;
    final descent = surroundingEm * 0.2;
    final aboveBaseline = math.max(height - shift, ascent);
    final belowBaseline = math.max(shift, descent);
    final boxHeight = math.max(height, aboveBaseline + belowBaseline);
    return _InlineImageMetrics(
      width: width,
      height: height,
      boxHeight: boxHeight,
      baselineOffset: aboveBaseline,
      paintOffsetY: aboveBaseline + shift - height,
    );
  }

  _PreparedTable? _prepareTable(
    TableBlock table,
    ReaderStyle style,
    int spineIndex,
    double contentWidth,
    double sectionTextOffset,
    ui.Size? Function(String href)? imageSizeResolver,
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
      imageSizeResolver,
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
        imageSizeResolver,
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
          baselineRegions: _baselineRegions(
            gridCell.cell.inlines,
            paragraph,
            builtCell.displayToSource,
          ),
          displayToSource: builtCell.displayToSource,
          grid: gridCell,
          paragraph: paragraph,
          links: builtCell.links,
          inlineImages: builtCell.inlineImages,
          requiredHeight: requiredHeight,
          sectionTextOffset: cellTextOffset,
        ),
      );
      cellTextOffset += gridCell.cell.plainText.runes.length;
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
    ui.Size? Function(String href)? imageSizeResolver,
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
        imageSizeResolver,
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
    ui.Size? Function(String href)? imageSizeResolver,
  ) {
    final displaySystem = cell.inlines
        .whereType<TextRun>()
        .map((run) => run.displayWritingSystem)
        .whereType<WritingSystem>()
        .firstOrNull;
    if (displaySystem != null) {
      style = style.copyWith(writingSystem: displaySystem);
    }
    final unified = style.typesettingMode == TypesettingMode.unified;
    final foreground = ui.Color(style.foreground);
    final typography = style.typography;
    final latinFont = typography.latinFontFor(style.writingSystem);
    final cjkFont = typography.cjkFontFor(style.writingSystem);
    final fontFamily = latinFont.family;
    final fontFamilyFallback = <String>[cjkFont.family];
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
        fontFamily: fontFamily,
        fontWeight: _readerFontWeight(typography.fontWeight),
      ),
    );
    final links = <TextLinkRange>[];
    final inlineImages = <InlineImageRange>[];
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
          for (final segment in _semanticTextSegments(
            text,
            runStyle,
            unified: unified,
            fallbackWritingSystem: style.writingSystem,
          )) {
            final segmentStyle = segment.style;
            var scale = unified
                ? fontScale
                : fontScale * segmentStyle.sizeScale;
            if (segmentStyle.baseline != TextBaselineShift.none) scale *= 0.7;
            final resolvedFontSize = style.baseFontSize * scale;
            final fontSize = unified
                ? resolvedFontSize
                : math.max(ReaderTypography.minimumFontSize, resolvedFontSize);
            final weight = cell.header || segmentStyle.bold
                ? math.max(700, typography.fontWeight)
                : typography.fontWeight;
            builder.pushStyle(
              ui.TextStyle(
                color: _resolvedRunColor(
                  runStyle: segmentStyle,
                  unified: unified,
                  foreground: foreground,
                ),
                fontWeight: _readerFontWeight(weight),
                fontStyle: segmentStyle.italic ? ui.FontStyle.italic : null,
                decoration: _decorationFor(
                  segmentStyle,
                  includeUnderline: !unified,
                ),
                fontSize: fontSize,
                fontFamily: fontFamily,
                fontFamilyFallback: fontFamilyFallback,
                fontVariations: _fontVariations(
                  typography,
                  fontSize,
                  fontFamily,
                  weight,
                ),
              ),
            );
            builder.addText(text.substring(segment.start, segment.end));
            builder.pop();
          }
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
          final resolvedFontSize = style.baseFontSize * fontScale * sizeScale;
          builder.pushStyle(
            ui.TextStyle(
              color: foreground,
              fontSize: unified
                  ? resolvedFontSize
                  : math.max(
                      ReaderTypography.minimumFontSize,
                      resolvedFontSize,
                    ),
              fontFamily: 'monospace',
              fontStyle: ui.FontStyle.italic,
            ),
          );
          builder.addText(latex);
          builder.pop();
          paragraphOffset += latex.length;
        case InlineImageRun():
          final metrics = _inlineImageMetrics(
            inline,
            baseSize: style.baseFontSize,
            resolvedScale: unified ? fontScale : inline.sizeScale * fontScale,
            availableWidth: width,
            imageSizeResolver: imageSizeResolver,
          );
          builder.addPlaceholder(
            metrics.width,
            metrics.boxHeight,
            ui.PlaceholderAlignment.baseline,
            baseline: ui.TextBaseline.alphabetic,
            baselineOffset: metrics.baselineOffset,
          );
          inlineImages.add(
            InlineImageRange(
              start: paragraphOffset,
              end: paragraphOffset + 1,
              href: inline.image.href,
              width: metrics.width,
              height: metrics.height,
              paintOffsetY: metrics.paintOffsetY,
            ),
          );
          paragraphOffset++;
      }
    }
    final paragraph = builder.build()
      ..layout(ui.ParagraphConstraints(width: width));
    return _BuiltTableCellParagraph(
      paragraph,
      links,
      inlineImages,
      inlineDisplayToSource(cell.inlines),
    );
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
      offset += body.plainText.runes.length;
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
      captionOffset += caption.plainText.runes.length;
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
    // Desktop rule: probe with centered layout first. A one-line caption
    // stays centered; a multi-line caption is rebuilt start-aligned through
    // the whole-paragraph optimizer (including ICU and hyphenation).
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
  final List<int> displayToSource;
  final ui.Paragraph paragraph;
  final List<TextLinkRange> links;
  final List<InlineImageRange> inlineImages;

  const _BuiltTableCellParagraph(
    this.paragraph,
    this.links,
    this.inlineImages,
    this.displayToSource,
  );
}

class _SourceRunSlice {
  final int start;
  final int end;
  final TextStyle style;
  final String? link;
  final String? language;
  final bool footnoteIcon;
  final double footnoteSize;
  final double fontSize;
  final _InlineImageMetrics? inlineImageMetrics;
  final String? inlineImageHref;

  const _SourceRunSlice({
    required this.start,
    required this.end,
    required this.style,
    required this.link,
    required this.language,
    required this.footnoteIcon,
    required this.footnoteSize,
    required this.fontSize,
    this.inlineImageMetrics,
    this.inlineImageHref,
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
  final List<InlineImageRange> inlineImages;

  const _OptimizedParagraphBuild({
    required this.paragraph,
    required this.metrics,
    required this.links,
    required this.displayToSource,
    required this.inlineImages,
  });
}

class _PreparedTableCell {
  final List<TextBaselineRegion> baselineRegions;
  final List<int> displayToSource;
  final _GridTableCell grid;
  final ui.Paragraph paragraph;
  final List<TextLinkRange> links;
  final List<InlineImageRange> inlineImages;
  final double requiredHeight;
  final double sectionTextOffset;

  const _PreparedTableCell({
    required this.baselineRegions,
    required this.displayToSource,
    required this.grid,
    required this.paragraph,
    required this.links,
    required this.inlineImages,
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
  final List<TextBaselineRegion> baselineRegions;
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
  final List<InlineImageRange> inlineImages;

  /// Maps UTF-16 offsets in a paragraph containing optimizer-inserted line
  /// breaks back to Unicode-scalar offsets in the source text.
  final List<int> displayToSource;

  const _PreparedText({
    required this.baselineRegions,
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
    required this.inlineImages,
    required this.displayToSource,
  });

  _PreparedText copyWith({double? marginAfter}) => _PreparedText(
    baselineRegions: baselineRegions,
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
    inlineImages: inlineImages,
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
          baselineRegions: prepared.baselineRegions,
          displayToSource: prepared.displayToSource,
          syntheticPrefixLength: prepared.syntheticPrefixLength,
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
          inlineImages: prepared.inlineImages,
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
            baselineRegions: prepared.baselineRegions,
            displayToSource: prepared.displayToSource,
            paragraph: prepared.paragraph,
            rect: ui.Rect.fromLTWH(x, y, cellWidth, cellHeight),
            padding: table.padding,
            header: grid.cell.header,
            source: grid.cell.source,
            nodeId: grid.cell.nodeId,
            spineIndex: table.spineIndex,
            sectionTextOffset: prepared.sectionTextOffset,
            links: prepared.links,
            inlineImages: prepared.inlineImages,
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

  /// Unicode-scalar offset into the block's plainText of the first character of
  /// paragraph line [line], excluding the synthetic marker prefix.
  int _lineStartOffset(_PreparedText prepared, int line) {
    final metric = prepared.metrics[line];
    final position = prepared.paragraph.getPositionForOffset(
      ui.Offset(metric.left + 0.1, prepared.lineTops[line] + metric.height / 2),
    );
    final mapping = prepared.displayToSource;
    return mapping[position.offset.clamp(0, mapping.length - 1)].clamp(
      0,
      prepared.textLength,
    );
  }
}
