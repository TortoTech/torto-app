/// Style types for the Reading IR.
///
/// Mirrors `torto/crates/publication` style subsets: the IR carries only a
/// deliberately small, owned subset of CSS — full HTML/CSS compatibility is
/// an explicit non-goal (see torto docs/adr-0001-native-epub-renderer.md).
library;

/// Vertical baseline shift for inline text (superscript / subscript).
enum TextBaselineShift { none, superscript, subscript }

/// Inline text style. All values are resolved (no relative CSS units left).
class TextStyle {
  final bool bold;
  final bool italic;
  final bool underline;
  final bool strikethrough;

  /// Multiplier on the reader's base font size (1.0 = unchanged).
  final double sizeScale;

  /// Foreground color as ARGB int; null = inherit reader foreground.
  final int? color;

  final TextBaselineShift baseline;

  const TextStyle({
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strikethrough = false,
    this.sizeScale = 1.0,
    this.color,
    this.baseline = TextBaselineShift.none,
  });

  static const TextStyle plain = TextStyle();

  /// Returns a copy where every field set on [overlay] replaces this one's.
  /// [overlay]'s defaults (false / 1.0 / null) mean "no change".
  TextStyle merge(TextStyle overlay) {
    return TextStyle(
      bold: bold || overlay.bold,
      italic: italic || overlay.italic,
      underline: underline || overlay.underline,
      strikethrough: strikethrough || overlay.strikethrough,
      sizeScale: sizeScale * overlay.sizeScale,
      color: overlay.color ?? color,
      baseline: overlay.baseline != TextBaselineShift.none
          ? overlay.baseline
          : baseline,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TextStyle &&
      other.bold == bold &&
      other.italic == italic &&
      other.underline == underline &&
      other.strikethrough == strikethrough &&
      other.sizeScale == sizeScale &&
      other.color == color &&
      other.baseline == baseline;

  @override
  int get hashCode => Object.hash(
    bold,
    italic,
    underline,
    strikethrough,
    sizeScale,
    color,
    baseline,
  );
}

enum BlockAlign { start, center, end, justify }

/// Block-level style. Lengths are resolved to logical pixels at parse time
/// (using the base font size), matching torto's BlockStyle semantics.
class BlockStyle {
  final BlockAlign align;

  /// Space before / after the block, logical px.
  final double marginBefore;
  final double marginAfter;

  /// Start-side (left in LTR) margin, logical px.
  final double marginStart;

  /// First-line indent, logical px.
  final double indent;

  /// Line height as a multiple of the font's natural line height.
  final double lineHeight;

  const BlockStyle({
    this.align = BlockAlign.start,
    this.marginBefore = 0,
    this.marginAfter = 0,
    this.marginStart = 0,
    this.indent = 0,
    this.lineHeight = 1.0,
  });

  static const BlockStyle normal = BlockStyle();

  BlockStyle copyWith({
    BlockAlign? align,
    double? marginBefore,
    double? marginAfter,
    double? marginStart,
    double? indent,
    double? lineHeight,
  }) {
    return BlockStyle(
      align: align ?? this.align,
      marginBefore: marginBefore ?? this.marginBefore,
      marginAfter: marginAfter ?? this.marginAfter,
      marginStart: marginStart ?? this.marginStart,
      indent: indent ?? this.indent,
      lineHeight: lineHeight ?? this.lineHeight,
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

  const ImageStyle({this.width, this.height, this.maxWidth, this.maxHeight});

  static const ImageStyle normal = ImageStyle();
}
