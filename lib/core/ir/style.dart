/// Style types for the Reading IR.
///
/// Mirrors `torto/crates/publication` style subsets: the IR carries only a
/// deliberately small, owned subset of CSS — full HTML/CSS compatibility is
/// an explicit non-goal (see torto docs/adr-0001-native-epub-renderer.md).
library;

/// Vertical baseline shift for inline text (superscript / subscript).
enum TextBaselineShift { none, superscript, subscript }

/// Semantic role of a link, matching torto's renderer-independent IR.
enum LinkRole { normal, footnoteReference, footnoteBacklink }

/// Semantic role carried by inline content independently of links.
enum InlineRole { normal, footnote }

enum HyphenationMode { none, manual, auto }

/// Inline text style. All values are resolved (no relative CSS units left).
class TextStyle {
  final bool bold;
  final bool italic;

  /// Semantic stress emphasis originating from HTML `<em>`.
  final bool emphasis;

  /// Semantic alternate voice or term originating from HTML `<i>`.
  final bool alternateVoice;

  /// Authored work-title or citation semantics originating from HTML `<cite>`.
  final bool citation;

  final bool underline;
  final bool strikethrough;

  /// Multiplier on the reader's base font size (1.0 = unchanged).
  final double sizeScale;

  /// Foreground color as ARGB int; null = inherit reader foreground.
  final int? color;

  final TextBaselineShift baseline;
  final LinkRole linkRole;
  final InlineRole inlineRole;
  final HyphenationMode hyphenation;

  const TextStyle({
    this.bold = false,
    this.italic = false,
    this.emphasis = false,
    this.alternateVoice = false,
    this.citation = false,
    this.underline = false,
    this.strikethrough = false,
    this.sizeScale = 1.0,
    this.color,
    this.baseline = TextBaselineShift.none,
    this.linkRole = LinkRole.normal,
    this.inlineRole = InlineRole.normal,
    this.hyphenation = HyphenationMode.auto,
  });

  static const TextStyle plain = TextStyle();

  /// Returns a copy where every field set on [overlay] replaces this one's.
  /// [overlay]'s defaults (false / 1.0 / null) mean "no change".
  TextStyle merge(TextStyle overlay) {
    return TextStyle(
      bold: bold || overlay.bold,
      italic: italic || overlay.italic,
      emphasis: emphasis || overlay.emphasis,
      alternateVoice: alternateVoice || overlay.alternateVoice,
      citation: citation || overlay.citation,
      underline: underline || overlay.underline,
      strikethrough: strikethrough || overlay.strikethrough,
      sizeScale: sizeScale * overlay.sizeScale,
      color: overlay.color ?? color,
      baseline: overlay.baseline != TextBaselineShift.none
          ? overlay.baseline
          : baseline,
      linkRole: overlay.linkRole != LinkRole.normal
          ? overlay.linkRole
          : linkRole,
      inlineRole: overlay.inlineRole != InlineRole.normal
          ? overlay.inlineRole
          : inlineRole,
      hyphenation: overlay.hyphenation != HyphenationMode.auto
          ? overlay.hyphenation
          : hyphenation,
    );
  }

  TextStyle copyWith({
    bool? bold,
    bool? italic,
    bool? emphasis,
    bool? alternateVoice,
    bool? citation,
    bool? underline,
    bool? strikethrough,
    double? sizeScale,
    int? color,
    bool clearColor = false,
    TextBaselineShift? baseline,
    LinkRole? linkRole,
    InlineRole? inlineRole,
    HyphenationMode? hyphenation,
  }) => TextStyle(
    bold: bold ?? this.bold,
    italic: italic ?? this.italic,
    emphasis: emphasis ?? this.emphasis,
    alternateVoice: alternateVoice ?? this.alternateVoice,
    citation: citation ?? this.citation,
    underline: underline ?? this.underline,
    strikethrough: strikethrough ?? this.strikethrough,
    sizeScale: sizeScale ?? this.sizeScale,
    color: clearColor ? null : (color ?? this.color),
    baseline: baseline ?? this.baseline,
    linkRole: linkRole ?? this.linkRole,
    inlineRole: inlineRole ?? this.inlineRole,
    hyphenation: hyphenation ?? this.hyphenation,
  );

  @override
  bool operator ==(Object other) =>
      other is TextStyle &&
      other.bold == bold &&
      other.italic == italic &&
      other.emphasis == emphasis &&
      other.alternateVoice == alternateVoice &&
      other.citation == citation &&
      other.underline == underline &&
      other.strikethrough == strikethrough &&
      other.sizeScale == sizeScale &&
      other.color == color &&
      other.baseline == baseline &&
      other.linkRole == linkRole &&
      other.inlineRole == inlineRole &&
      other.hyphenation == hyphenation;

  @override
  int get hashCode => Object.hash(
    bold,
    italic,
    emphasis,
    alternateVoice,
    citation,
    underline,
    strikethrough,
    sizeScale,
    color,
    baseline,
    linkRole,
    inlineRole,
    hyphenation,
  );
}

enum BlockAlign { start, center, end, justify }

/// Block-level style. Lengths are resolved to logical pixels at parse time
/// (using the base font size), matching torto's BlockStyle semantics.
class BlockStyle {
  final BlockAlign align;

  /// Alignment explicitly authored by the publication. Null means [align]
  /// only contains the parser/default value.
  final BlockAlign? authoredAlignment;

  /// Space before / after the block, logical px.
  final double marginBefore;
  final double marginAfter;

  /// Start-side (left in LTR) margin, logical px.
  final double marginStart;

  /// Start-side margin represented as a fraction of the content width.
  final double marginStartFraction;

  /// First-line indent, logical px.
  final double indent;

  /// Line height as a multiple of the font's natural line height.
  final double lineHeight;

  /// Preserve one authored structural blank line after this block.
  final bool hardBreakAfter;

  /// Compact gap between semantic subparagraphs kept in one text block.
  final double? subparagraphGapEm;

  const BlockStyle({
    this.align = BlockAlign.start,
    this.authoredAlignment,
    this.marginBefore = 0,
    this.marginAfter = 0,
    this.marginStart = 0,
    this.marginStartFraction = 0,
    this.indent = 0,
    this.lineHeight = 1.0,
    this.hardBreakAfter = false,
    this.subparagraphGapEm,
  });

  static const BlockStyle normal = BlockStyle();

  BlockStyle copyWith({
    BlockAlign? align,
    BlockAlign? authoredAlignment,
    bool clearAuthoredAlignment = false,
    double? marginBefore,
    double? marginAfter,
    double? marginStart,
    double? marginStartFraction,
    double? indent,
    double? lineHeight,
    bool? hardBreakAfter,
    double? subparagraphGapEm,
  }) {
    return BlockStyle(
      align: align ?? this.align,
      authoredAlignment: clearAuthoredAlignment
          ? null
          : (authoredAlignment ?? this.authoredAlignment),
      marginBefore: marginBefore ?? this.marginBefore,
      marginAfter: marginAfter ?? this.marginAfter,
      marginStart: marginStart ?? this.marginStart,
      marginStartFraction: marginStartFraction ?? this.marginStartFraction,
      indent: indent ?? this.indent,
      lineHeight: lineHeight ?? this.lineHeight,
      hardBreakAfter: hardBreakAfter ?? this.hardBreakAfter,
      subparagraphGapEm: subparagraphGapEm ?? this.subparagraphGapEm,
    );
  }
}

/// A length on an image: either absolute logical px or a fraction of the
/// containing column / page dimension.
sealed class ImageLength {
  const ImageLength();

  const factory ImageLength.pixels(double value) = ImagePixels;
  const factory ImageLength.fraction(double value) = ImageFraction;

  double resolve(double basis);
}

class ImagePixels extends ImageLength {
  final double value;
  const ImagePixels(this.value);
  @override
  double resolve(double basis) => value;
}

class ImageFraction extends ImageLength {
  final double value;
  const ImageFraction(this.value);
  @override
  double resolve(double basis) => value * basis;
}

class ImageStyle {
  final ImageLength? width;
  final ImageLength? height;
  final ImageLength? maxWidth;
  final ImageLength? maxHeight;

  /// Block spacing before/after the image. Image-only containers can
  /// contribute their authored margins here when the HTML boxes are flattened.
  final double marginBefore;
  final double marginAfter;

  const ImageStyle({
    this.width,
    this.height,
    this.maxWidth,
    this.maxHeight,
    this.marginBefore = 0,
    this.marginAfter = 0,
  });

  static const ImageStyle normal = ImageStyle();
}
