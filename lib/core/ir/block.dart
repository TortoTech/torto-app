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

enum TextBlockKind { paragraph, heading, blockquote, preformatted, listItem }

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
      }
    }
    return buf.toString();
  }
}

/// A semantic table retained as a grid instead of being flattened into
/// unrelated paragraphs. Column and row spans use the same 1-based semantics
/// as HTML; layout clamps malformed values to a safe range.
class TableBlock extends Block {
  final List<TableRow> rows;
  final BlockStyle style;

  const TableBlock({required this.rows, this.style = BlockStyle.normal});

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

/// Horizontal rule (<hr>).
class SeparatorBlock extends Block {
  const SeparatorBlock();
}

/// Explicit page break marker.
class PageBreakBlock extends Block {
  const PageBreakBlock();
}
