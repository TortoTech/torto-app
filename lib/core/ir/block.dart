import 'style.dart';

/// A position in the book's source, independent of pagination.
///
/// This is the compatibility contract with torto's sync protocol: highlights
/// and reading progress anchor to source positions, never to page numbers.
///
/// [node] is a deterministic id assigned by the HTML→IR parser (document
/// order of the block-level element within its section, e.g. "n12").
/// [textOffset] is a UTF-16 code-unit offset into that block's normalized
/// text. NOTE: torto uses Unicode scalar offsets and its own node-id rule;
/// aligning both exactly ("对拍") is a planned follow-up before sync ships.
class SourceAnchor {
  final int spine;
  final String node;
  final int textOffset;

  const SourceAnchor({
    required this.spine,
    required this.node,
    required this.textOffset,
  });

  Map<String, dynamic> toJson() => {
    'spine': spine,
    'node': node,
    'text_offset': textOffset,
  };

  factory SourceAnchor.fromJson(Map<String, dynamic> json) => SourceAnchor(
    spine: json['spine'] as int,
    node: json['node'] as String,
    textOffset: json['text_offset'] as int,
  );

  @override
  bool operator ==(Object other) =>
      other is SourceAnchor &&
      other.spine == spine &&
      other.node == node &&
      other.textOffset == textOffset;

  @override
  int get hashCode => Object.hash(spine, node, textOffset);

  @override
  String toString() => 'SourceAnchor($spine, $node, $textOffset)';
}

class SourceRange {
  final SourceAnchor start;
  final SourceAnchor end;

  const SourceRange({required this.start, required this.end});

  Map<String, dynamic> toJson() => {
    'start': start.toJson(),
    'end': end.toJson(),
  };

  factory SourceRange.fromJson(Map<String, dynamic> json) => SourceRange(
    start: SourceAnchor.fromJson(json['start'] as Map<String, dynamic>),
    end: SourceAnchor.fromJson(json['end'] as Map<String, dynamic>),
  );
}

/// Inline-level content of a [TextBlock].
sealed class Inline {
  const Inline();
}

class TextRun extends Inline {
  final String text;
  final TextStyle style;

  /// Link target (resolved root-relative href, possibly with fragment), if
  /// this run is inside an <a>.
  final String? link;

  const TextRun(this.text, {this.style = TextStyle.plain, this.link});
}

/// Explicit line break (<br>).
class BreakInline extends Inline {
  const BreakInline();
}

/// TeX source retained as semantic inline content. The current Flutter
/// renderer keeps a readable text fallback while preserving enough metadata
/// for a dedicated formula rasterizer.
class MathInline extends Inline {
  final String latex;
  final bool display;
  final double sizeScale;

  const MathInline(this.latex, {this.display = false, this.sizeScale = 1.0});
}

enum TextBlockKind {
  paragraph,
  heading,
  blockquote,
  quoteAttribution,
  preformatted,
  caption,
  footnoteDefinition,
  listItem,
  definitionTerm,
  definitionDescription,
}

/// Top-level content blocks of a section. Mirrors torto's `enum Block`.
sealed class Block {
  const Block();
}

class TextBlock extends Block {
  final TextBlockKind kind;

  /// 1..6 when [kind] is [TextBlockKind.heading], else 0.
  final int headingLevel;

  /// List item data; only meaningful when [kind] is [TextBlockKind.listItem].
  final bool listOrdered;
  final int listOrdinal;
  final int listDepth;

  /// Whether this item owns a visible marker. Some EPUBs encode nested list
  /// continuations as marker-less paragraphs while retaining list indentation.
  final bool listMarkerVisible;

  final List<Inline> inlines;
  final BlockStyle style;

  /// Source range of this block's text, for highlight/progress anchoring.
  final SourceRange? source;

  /// Node id assigned by the parser (see [SourceAnchor.node]); empty string
  /// when the block carries no anchor (e.g. synthesized content).
  final String nodeId;

  TextBlock({
    this.kind = TextBlockKind.paragraph,
    this.headingLevel = 0,
    this.listOrdered = false,
    this.listOrdinal = 0,
    this.listDepth = 0,
    this.listMarkerVisible = true,
    required this.inlines,
    this.style = BlockStyle.normal,
    this.source,
    this.nodeId = '',
  });

  /// Plain text of the block (breaks become newlines).
  String get plainText {
    final buf = StringBuffer();
    for (final inline in inlines) {
      switch (inline) {
        case TextRun(:final text):
          buf.write(text);
        case BreakInline():
          buf.write('\n');
        case MathInline(:final latex):
          buf.write(latex);
      }
    }
    return buf.toString();
  }
}

/// Quoted prose and its optional attribution, retained as one semantic unit.
class QuoteBlock extends Block {
  final List<TextBlock> body;
  final TextBlock? attribution;
  final SourceRange? source;

  const QuoteBlock({required this.body, this.attribution, this.source});

  int get textLength =>
      body.fold(0, (total, block) => total + block.plainText.length) +
      (attribution?.plainText.length ?? 0);
}

enum NoteBlockKind { definition, section }

/// One footnote/endnote definition or an authored notes section.
class NoteBlock extends Block {
  final NoteBlockKind kind;
  final List<Block> blocks;
  final SourceRange? source;

  const NoteBlock({required this.kind, required this.blocks, this.source});

  int get textLength => blocks.fold(0, (total, block) {
    return total +
        switch (block) {
          TextBlock(:final plainText) => plainText.length,
          QuoteBlock(:final textLength) => textLength,
          NoteBlock(:final textLength) => textLength,
          TableBlock(:final textLength) => textLength,
          FigureBlock(:final textLength) => textLength,
          _ => 0,
        };
  });
}

/// A semantic table retained as a grid instead of being flattened into
/// unrelated paragraphs. Column and row spans use the same 1-based semantics
/// as HTML; layout clamps malformed values to a safe range.
class TableBlock extends Block {
  final List<TableRow> rows;
  final BlockStyle style;
  final SourceRange? source;

  const TableBlock({
    required this.rows,
    this.style = BlockStyle.normal,
    this.source,
  });

  int get textLength => rows.fold(
    0,
    (total, row) =>
        total + row.cells.fold(0, (sum, cell) => sum + cell.plainText.length),
  );
}

class TableRow {
  final List<TableCell> cells;

  const TableRow(this.cells);
}

class TableCell {
  final List<Inline> inlines;
  final bool header;
  final int columnSpan;
  final int rowSpan;
  final BlockAlign? authoredAlignment;
  final BlockStyle style;
  final SourceRange? source;
  final String nodeId;

  const TableCell({
    required this.inlines,
    this.header = false,
    this.columnSpan = 1,
    this.rowSpan = 1,
    this.authoredAlignment,
    this.style = BlockStyle.normal,
    this.source,
    this.nodeId = '',
  });

  String get plainText {
    final buffer = StringBuffer();
    for (final inline in inlines) {
      switch (inline) {
        case TextRun(:final text):
          buffer.write(text);
        case BreakInline():
          buffer.write('\n');
        case MathInline(:final latex):
          buffer.write(latex);
      }
    }
    return buffer.toString();
  }
}

class ImageBlock extends Block {
  /// Root-relative href of the image resource within the publication.
  final String href;
  final String alt;
  final ImageStyle style;
  final SourceRange? source;

  /// True for one-page fixed-layout resources such as PDF pages. Layout may
  /// center these within the whole reading area; ordinary book illustrations
  /// remain in normal document flow.
  final bool fixedPage;

  const ImageBlock({
    required this.href,
    this.alt = '',
    this.style = ImageStyle.normal,
    this.source,
    this.fixedPage = false,
  });
}

enum CaptionPosition { before, after }

/// One or more authored images kept together with their semantic caption.
class FigureBlock extends Block {
  final List<ImageBlock> images;
  final List<TextBlock> captions;
  final CaptionPosition captionPosition;
  final BlockStyle style;
  final SourceRange? source;

  const FigureBlock({
    required this.images,
    this.captions = const [],
    this.captionPosition = CaptionPosition.after,
    this.style = BlockStyle.normal,
    this.source,
  });

  int get textLength =>
      captions.fold(0, (total, caption) => total + caption.plainText.length);
}

enum SeparatorKind { spacing, rule, ornament }

/// A semantic, non-prose boundary retained for the active typesetting mode.
class SeparatorBlock extends Block {
  final SeparatorKind kind;
  final bool inQuote;
  final ImageBlock? image;
  final BlockStyle style;

  const SeparatorBlock({
    this.kind = SeparatorKind.rule,
    this.inQuote = false,
    this.image,
    this.style = BlockStyle.normal,
  });
}

/// Explicit page break marker.
class PageBreakBlock extends Block {
  const PageBreakBlock();
}

/// Authored standalone line break between block elements.
class LineBreakBlock extends Block {
  const LineBreakBlock();
}
