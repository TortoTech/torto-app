import 'ir.dart';

TextBlock withInlines(TextBlock b, List<Inline> inlines) => TextBlock(
  inlines: inlines,
  nodeId: b.nodeId,
  source: b.source,
  style: b.style,
  kind: b.kind,
  headingLevel: b.headingLevel,
  headingOrdinal: b.headingOrdinal,
  listOrdered: b.listOrdered,
  listOrdinal: b.listOrdinal,
  listDepth: b.listDepth,
  listGroupId: b.listGroupId,
  listMarkerVisible: b.listMarkerVisible,
);

TextRun withRun(TextRun run, String text, {TextStyle? style, String? link}) =>
    TextRun(
      text,
      style: style ?? run.style,
      link: link ?? run.link,
      language: run.language,
      displayWritingSystem: run.displayWritingSystem,
    );

/// Caption numbering is emphasized without changing authored source offsets.
List<Inline> emphasizeCaptionLabel(List<Inline> inlines) {
  final prefix = inlines
      .takeWhile((inline) => inline is TextRun)
      .cast<TextRun>()
      .map((run) => run.text)
      .join();
  final label = RegExp(
    r'^\s*(?:(?:fig(?:ure)?\.?|table)\s+[0-9]+(?:[.\-–][0-9]+)*|[图表](?:格)?\s*[0-9一二三四五六七八九十]+(?:[.\-–][0-9]+)*)(?:[.:：、])?',
    caseSensitive: false,
  ).firstMatch(prefix);
  if (label == null) return inlines;
  final out = <Inline>[];
  var offset = 0;
  for (final inline in inlines) {
    if (inline is! TextRun || offset >= label.end) {
      out.add(inline);
      continue;
    }
    final end = (label.end - offset).clamp(0, inline.text.length);
    out.add(
      withRun(
        inline,
        inline.text.substring(0, end),
        style: inline.style.copyWith(bold: true),
      ),
    );
    if (end < inline.text.length) {
      out.add(withRun(inline, inline.text.substring(end)));
    }
    offset += inline.text.length;
  }
  return out;
}

bool standaloneTableLabel(String text) => RegExp(
  r'^(?:table|表格|表)\s*[0-9一二三四五六七八九十]+(?:[.\-–][0-9]+)*[.:：]?$',
  caseSensitive: false,
).hasMatch(text.trim());

/// Reading-order traversal shared by recognition, transformation and popups.
List<TextBlock> blockTexts(Block b) => switch (b) {
  TextBlock() => [b],
  QuoteBlock() => [...b.body, ?b.attribution],
  TableBlock() => [
    ...b.before,
    for (final cell in b.rows.expand((row) => row.cells))
      TextBlock(
        inlines: cell.inlines,
        nodeId: cell.nodeId,
        source: cell.source,
        style: cell.style,
      ),
    ...b.after,
  ],
  FigureBlock() => b.captions,
  NoteBlock() => b.blocks.expand(blockTexts).toList(),
  _ => [],
};

Block mapBlockContent(
  Block b,
  TextBlock Function(TextBlock) text, {
  ImageBlock Function(ImageBlock)? image,
}) {
  ImageBlock img(ImageBlock b) => image?.call(b) ?? b;
  TextBlock txt(TextBlock b) {
    final t = text(b);
    if (image == null) return t;
    return withInlines(t, [
      for (final inline in t.inlines)
        if (inline is InlineImageRun)
          InlineImageRun(
            image: img(inline.image),
            sizeScale: inline.sizeScale,
            intrinsicSizing: inline.intrinsicSizing,
            verticalAlign: inline.verticalAlign,
            presentation: inline.presentation,
          )
        else
          inline,
    ]);
  }

  return switch (b) {
    TextBlock() => txt(b),
    ImageBlock() => img(b),
    QuoteBlock() => QuoteBlock(
      body: b.body.map(txt).toList(),
      attribution: b.attribution == null ? null : txt(b.attribution!),
      source: b.source,
    ),
    TableBlock() => TableBlock(
      before: b.before.map(txt).toList(),
      after: b.after.map(txt).toList(),
      style: b.style,
      source: b.source,
      rows: [
        for (final row in b.rows)
          TableRow([
            for (final cell in row.cells)
              TableCell(
                inlines: txt(
                  TextBlock(
                    inlines: cell.inlines,
                    nodeId: cell.nodeId,
                    source: cell.source,
                  ),
                ).inlines,
                nodeId: cell.nodeId,
                source: cell.source,
                style: cell.style,
                header: cell.header,
                columnSpan: cell.columnSpan,
                rowSpan: cell.rowSpan,
                authoredAlignment: cell.authoredAlignment,
              ),
          ]),
      ],
    ),
    FigureBlock() => FigureBlock(
      images: b.images.map(img).toList(),
      captions: b.primaryCaptions.map(txt).toList(),
      afterCaptions: b.afterCaptions.map(txt).toList(),
      captionPosition: b.captionPosition,
      style: b.style,
      source: b.source,
    ),
    NoteBlock() => NoteBlock(
      kind: b.kind,
      source: b.source,
      blocks: [
        for (final child in b.blocks)
          mapBlockContent(child, text, image: image),
      ],
    ),
    _ => b,
  };
}

Section withBlocks(Section section, List<Block> blocks) => Section(
  id: section.id,
  spineIndex: section.spineIndex,
  href: section.href,
  anchors: section.anchors,
  blocks: blocks,
);
