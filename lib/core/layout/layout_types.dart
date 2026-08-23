/// Output types of the layout stage: positioned, renderer-independent page
/// content (a "display list"), mirroring torto's `PageLayout`/`PageItem`.
///
/// This library is pure Dart + `dart:ui` — no Flutter widgets. Coordinates
/// are logical pixels relative to the page's top-left corner.
library;

import 'dart:ui' as ui;

import '../ir/ir.dart';

/// Logical viewport in device-independent pixels: the full page area,
/// margins included.
class LayoutViewport {
  final double width;
  final double height;

  const LayoutViewport({required this.width, required this.height});

  @override
  String toString() => 'LayoutViewport($width x $height)';
}

/// User-controlled values that invalidate pagination.
enum TypesettingMode {
  /// Replace publication-authored metrics with one semantic profile.
  unified,

  /// Preserve publication-authored font sizes, spacing, alignment and color.
  book,
}

class ReaderStyle {
  /// Base reading font size, logical px.
  final double baseFontSize;

  /// Line-height multiplier applied on top of each block's own
  /// [BlockStyle.lineHeight].
  final double lineHeight;

  /// Page padding, logical px.
  final double marginTop;
  final double marginBottom;
  final double marginLeft;
  final double marginRight;

  /// Default text color, ARGB.
  final int foreground;

  /// Page background color, ARGB.
  final int background;

  /// Whether semantic reader metrics override the publication's own layout.
  final TypesettingMode typesettingMode;

  const ReaderStyle({
    this.baseFontSize = 18,
    this.lineHeight = 1.5,
    this.marginTop = 24,
    this.marginBottom = 24,
    this.marginLeft = 32,
    this.marginRight = 32,
    this.foreground = 0xFF000000,
    this.background = 0xFFFAF8F3,
    this.typesettingMode = TypesettingMode.unified,
  });

  ReaderStyle copyWith({
    double? baseFontSize,
    double? lineHeight,
    double? marginTop,
    double? marginBottom,
    double? marginLeft,
    double? marginRight,
    int? foreground,
    int? background,
    TypesettingMode? typesettingMode,
  }) => ReaderStyle(
    baseFontSize: baseFontSize ?? this.baseFontSize,
    lineHeight: lineHeight ?? this.lineHeight,
    marginTop: marginTop ?? this.marginTop,
    marginBottom: marginBottom ?? this.marginBottom,
    marginLeft: marginLeft ?? this.marginLeft,
    marginRight: marginRight ?? this.marginRight,
    foreground: foreground ?? this.foreground,
    background: background ?? this.background,
    typesettingMode: typesettingMode ?? this.typesettingMode,
  );

  @override
  bool operator ==(Object other) =>
      other is ReaderStyle &&
      other.baseFontSize == baseFontSize &&
      other.lineHeight == lineHeight &&
      other.marginTop == marginTop &&
      other.marginBottom == marginBottom &&
      other.marginLeft == marginLeft &&
      other.marginRight == marginRight &&
      other.foreground == foreground &&
      other.background == background &&
      other.typesettingMode == typesettingMode;

  @override
  int get hashCode => Object.hash(
    baseFontSize,
    lineHeight,
    marginTop,
    marginBottom,
    marginLeft,
    marginRight,
    foreground,
    background,
    typesettingMode,
  );
}

/// Positioned page content.
sealed class PageItem {
  const PageItem();
}

/// A line slice of a shaped paragraph placed on a page.
class TextPlacement extends PageItem {
  /// Retained paragraph, laid out at [width]. Shared between placements when
  /// one paragraph spans several pages; disposed by [PageLayout.dispose].
  final ui.Paragraph paragraph;

  /// Slice of paragraph lines drawn on this page: [startLine, endLine).
  final int startLine;
  final int endLine;

  /// Position on the page of the top of [startLine].
  final double x;
  final double y;

  /// Column width the paragraph was laid out at.
  final double width;

  /// Source range of the originating [TextBlock], when it carried one.
  final SourceRange? source;

  /// Node id of the originating [TextBlock] (see [SourceAnchor.node]).
  final String nodeId;

  /// Spine index of the section being paginated.
  final int spineIndex;

  /// UTF-16 offset into the block's plainText of the first visible character
  /// on this page (synthetic list-marker prefixes are excluded).
  final int textOffsetAtStart;

  /// Cached per-line metrics of [paragraph] (from `computeLineMetrics`),
  /// so renderers do not need to recompute them.
  final List<ui.LineMetrics> lineMetrics;

  /// Top offset of [startLine] within the paragraph, logical px. Draw the
  /// paragraph at `Offset(x, y - sliceTop)`.
  final double sliceTop;

  /// Height of the visible slice on this page, logical px.
  final double sliceHeight;

  /// UTF-16 offset of the start of the block's text within the whole
  /// section's text. Engine-internal; used for progression computation.
  final double sectionTextOffset;

  /// Interactive link ranges in the retained paragraph's UTF-16 text.
  final List<TextLinkRange> links;

  const TextPlacement({
    required this.paragraph,
    required this.startLine,
    required this.endLine,
    required this.x,
    required this.y,
    required this.width,
    required this.source,
    required this.nodeId,
    required this.spineIndex,
    required this.textOffsetAtStart,
    required this.lineMetrics,
    required this.sliceTop,
    required this.sliceHeight,
    required this.sectionTextOffset,
    this.links = const [],
  });
}

/// One linked UTF-16 range inside a laid-out paragraph.
class TextLinkRange {
  final int start;
  final int end;
  final String href;
  final String marker;
  final LinkRole role;
  final bool footnoteIcon;

  /// Body of an inline footnote whose authored text was replaced by [footnoteIcon].
  final String? inlineNote;

  const TextLinkRange({
    required this.start,
    required this.end,
    required this.href,
    required this.marker,
    required this.role,
    this.footnoteIcon = false,
    this.inlineNote,
  });
}

/// Marker for a list item. It is shaped independently so wrapped item text
/// uses a true hanging indent instead of wrapping beneath the bullet/number.
class ListMarkerPlacement extends PageItem {
  final String marker;
  final ui.Paragraph paragraph;
  final double x;
  final double y;
  final double width;
  final double height;

  const ListMarkerPlacement({
    required this.marker,
    required this.paragraph,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });
}

/// One laid-out table cell. Borders and header fill are painted by the render
/// stage so a table remains crisp at every device density.
class TableCellPlacement extends PageItem {
  final ui.Paragraph paragraph;
  final ui.Rect rect;
  final double padding;
  final bool header;
  final SourceRange? source;
  final String nodeId;
  final int spineIndex;
  final double sectionTextOffset;
  final List<TextLinkRange> links;

  const TableCellPlacement({
    required this.paragraph,
    required this.rect,
    required this.padding,
    required this.header,
    required this.source,
    required this.nodeId,
    required this.spineIndex,
    required this.sectionTextOffset,
    this.links = const [],
  });
}

/// Positioned raster image. The pixels are resolved at render time from
/// [href]; layout only reserves the rectangle.
class ImagePlacement extends PageItem {
  /// Root-relative href of the image resource within the publication.
  final String href;

  /// Destination rectangle on the page, logical px.
  final ui.Rect rect;

  const ImagePlacement({required this.href, required this.rect});
}

/// Positioned thematic break (1 px horizontal rule).
class SeparatorPlacement extends PageItem {
  /// Rectangle of the rule; height is 1 px.
  final ui.Rect rect;

  const SeparatorPlacement({required this.rect});
}

/// Tracks disposed paragraphs across the pages of one paginate() call, so a
/// paragraph whose slices span several pages is disposed exactly once.
/// Created by the layout engine and shared by all pages it returns.
class ParagraphDisposalPool {
  final Set<ui.Paragraph> _disposed = {};

  /// Returns true the first time [paragraph] is marked, false afterwards.
  bool markDisposed(ui.Paragraph paragraph) => _disposed.add(paragraph);
}

/// Renderer-independent display data for one page.
class PageLayout {
  final LayoutViewport viewport;
  final List<PageItem> items;

  /// Anchor of the first visible text, for progress restore; null when the
  /// page carries no text.
  final SourceAnchor? firstAnchor;

  /// 0..1 progress within the section, by text offset of the first visible
  /// character. The final page of a section always reports 1.0.
  final double progression;

  /// Shared disposal tracker for paragraphs spanning several pages. When
  /// null, [dispose] tracks paragraphs only within this page.
  final ParagraphDisposalPool? disposalPool;

  const PageLayout({
    required this.viewport,
    required this.items,
    required this.firstAnchor,
    required this.progression,
    this.disposalPool,
  });

  /// Returns the authored link under [position], including semantic footnote
  /// role. Geometry comes from the same shaped paragraph used for painting.
  TextLinkRange? linkAt(ui.Offset position) {
    for (final item in items.reversed) {
      final ui.Paragraph paragraph;
      final List<TextLinkRange> links;
      final ui.Offset paragraphOffset;
      final ui.Rect slice;
      switch (item) {
        case TextPlacement():
          paragraph = item.paragraph;
          links = item.links;
          paragraphOffset = ui.Offset(item.x, item.y - item.sliceTop);
          slice = ui.Rect.fromLTWH(
            item.x,
            item.y,
            item.width,
            item.sliceHeight,
          );
        case TableCellPlacement():
          paragraph = item.paragraph;
          links = item.links;
          paragraphOffset = ui.Offset(
            item.rect.left + item.padding,
            item.rect.top + item.padding,
          );
          slice = item.rect.deflate(item.padding);
        default:
          continue;
      }
      if (links.isEmpty) continue;
      if (!slice.contains(position)) continue;
      for (final link in links) {
        for (final box in paragraph.getBoxesForRange(link.start, link.end)) {
          final rect = ui.Rect.fromLTRB(
            paragraphOffset.dx + box.left,
            paragraphOffset.dy + box.top,
            paragraphOffset.dx + box.right,
            paragraphOffset.dy + box.bottom,
          ).intersect(slice);
          if (!rect.isEmpty && rect.inflate(2).contains(position)) return link;
        }
      }
    }
    return null;
  }

  /// Disposes every retained paragraph exactly once, even when a paragraph
  /// spans several pages (slices of it appear in several [PageLayout]s).
  void dispose() {
    final pool = disposalPool;
    final seen = <ui.Paragraph>{};
    for (final item in items) {
      final paragraph = switch (item) {
        TextPlacement(:final paragraph) => paragraph,
        ListMarkerPlacement(:final paragraph) => paragraph,
        TableCellPlacement(:final paragraph) => paragraph,
        _ => null,
      };
      if (paragraph == null) continue;
      final firstSeen = pool != null
          ? pool.markDisposed(paragraph)
          : seen.add(paragraph);
      if (firstSeen) paragraph.dispose();
    }
  }
}
