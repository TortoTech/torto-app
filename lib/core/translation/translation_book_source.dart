import 'dart:typed_data';

import '../ir/ir.dart';
import 'translation_markup.dart';
import 'translation_models.dart';

class TranslationBookSource implements BookSource {
  final BookSource inner;
  final Map<int, Map<int, _StoredBlockTranslation>> _sections = {};

  bool enabled = false;
  TranslationMode mode;
  String targetLanguageCode = 'zh-CN';

  TranslationBookSource(this.inner, {this.mode = TranslationMode.replace});

  @override
  Book get book => inner.book;

  void clear() => _sections.clear();

  Future<List<TranslationBlockInput>> untranslatedBlocksForNodes(
    int sectionIndex,
    Set<String> visibleNodes,
  ) async {
    final section = await inner.parseSection(sectionIndex);
    final stored = _sections[sectionIndex];
    return _translatableBlocks(section)
        .where((input) => visibleNodes.contains(input.nodeId))
        .where(
          (input) =>
              !(stored?[input.blockIndex]?.contains(input.segmentIndex) ??
                  false),
        )
        .toList(growable: false);
  }

  Future<void> storeBatch(
    int sectionIndex,
    List<BlockTranslation> translations,
  ) async {
    final section = await inner.parseSection(sectionIndex);
    for (final translation in translations) {
      final original = _segmentInlines(
        section,
        translation.blockIndex,
        translation.segmentIndex,
      );
      if (original == null) continue;
      // Validate protected inline structure before accepting the result. A bad
      // result remains retryable instead of silently disappearing at render.
      TranslationMarkupCodec.decode(
        translation.text,
        original,
        language: targetLanguageCode,
      );
    }
    final values = _sections.putIfAbsent(sectionIndex, () => {});
    for (final translation in translations) {
      if (translation.text.trim().isEmpty) continue;
      final stored = values.putIfAbsent(
        translation.blockIndex,
        _StoredBlockTranslation.new,
      );
      if (translation.segmentIndex == null) {
        stored.whole = translation.text;
      } else {
        stored.segments[translation.segmentIndex!] = translation.text;
      }
    }
  }

  @override
  Future<Section> parseSection(int index) async {
    final section = await inner.parseSection(index);
    final translations = enabled ? _sections[index] : null;
    if (translations == null || translations.isEmpty) return section;
    final blocks = <Block>[];
    for (var blockIndex = 0; blockIndex < section.blocks.length; blockIndex++) {
      final block = section.blocks[blockIndex];
      final translation = translations[blockIndex];
      if (translation == null) {
        blocks.add(block);
        continue;
      }
      switch (block) {
        case TextBlock():
          final value = translation.whole;
          if (value == null) {
            blocks.add(block);
            continue;
          }
          final translated = _translatedText(block, value);
          if (mode == TranslationMode.replace) {
            blocks.add(translated);
          } else {
            blocks
              ..add(_withReducedBottomMargin(block))
              ..add(
                _copyText(
                  translated,
                  clearSource: true,
                  nodeId: '',
                  listMarkerVisible: false,
                  style: translated.style.copyWith(
                    marginBefore: 0,
                    marginAfter: block.style.marginAfter,
                  ),
                ),
              );
          }
        case QuoteBlock():
          blocks.add(_translatedQuote(block, translation));
        case TableBlock():
          blocks.add(_translatedTable(block, translation));
        case FigureBlock():
          blocks.add(_translatedFigure(block, translation));
        case NoteBlock() ||
            ImageBlock() ||
            SeparatorBlock() ||
            PageBreakBlock() ||
            LineBreakBlock():
          blocks.add(block);
      }
    }
    return Section(
      spineIndex: section.spineIndex,
      href: section.href,
      blocks: blocks,
      anchors: section.anchors,
    );
  }

  @override
  Future<Uint8List?> resource(String href) => inner.resource(href);

  List<TranslationBlockInput> _translatableBlocks(Section section) {
    final inputs = <TranslationBlockInput>[];
    for (var blockIndex = 0; blockIndex < section.blocks.length; blockIndex++) {
      final block = section.blocks[blockIndex];
      switch (block) {
        case TextBlock():
          _appendInput(inputs, blockIndex, null, block);
        case QuoteBlock():
          final values = [...block.body, ?block.attribution];
          for (var index = 0; index < values.length; index++) {
            _appendInput(inputs, blockIndex, index, values[index]);
          }
        case TableBlock():
          var cellIndex = 0;
          for (final row in block.rows) {
            for (final cell in row.cells) {
              final text = TranslationMarkupCodec.encode(cell.inlines);
              if (text.trim().isNotEmpty && cell.nodeId.isNotEmpty) {
                inputs.add(
                  TranslationBlockInput(
                    blockIndex: blockIndex,
                    segmentIndex: cellIndex,
                    nodeId: cell.nodeId,
                    text: text,
                  ),
                );
              }
              cellIndex++;
            }
          }
        case FigureBlock():
          for (var index = 0; index < block.captions.length; index++) {
            _appendInput(inputs, blockIndex, index, block.captions[index]);
          }
        case NoteBlock() ||
            ImageBlock() ||
            SeparatorBlock() ||
            PageBreakBlock() ||
            LineBreakBlock():
          break;
      }
    }
    return inputs;
  }

  static void _appendInput(
    List<TranslationBlockInput> output,
    int blockIndex,
    int? segmentIndex,
    TextBlock block,
  ) {
    final text = TranslationMarkupCodec.encode(block.inlines);
    if (text.trim().isEmpty || block.nodeId.isEmpty) return;
    output.add(
      TranslationBlockInput(
        blockIndex: blockIndex,
        segmentIndex: segmentIndex,
        nodeId: block.nodeId,
        text: text,
      ),
    );
  }

  TextBlock _translatedText(TextBlock original, String translation) =>
      _copyText(
        original,
        inlines: TranslationMarkupCodec.decode(
          translation,
          original.inlines,
          language: targetLanguageCode,
        ),
      );

  QuoteBlock _translatedQuote(
    QuoteBlock quote,
    _StoredBlockTranslation translation,
  ) {
    final body = <TextBlock>[];
    for (var index = 0; index < quote.body.length; index++) {
      body.addAll(
        _translatedPair(quote.body[index], translation.segments[index]),
      );
    }
    TextBlock? attribution;
    final originalAttribution = quote.attribution;
    if (originalAttribution != null) {
      final pair = _translatedPair(
        originalAttribution,
        translation.segments[quote.body.length],
      );
      if (pair.isNotEmpty) {
        body.addAll(pair.take(pair.length - 1));
        attribution = pair.last;
      }
    }
    return QuoteBlock(
      body: body,
      attribution: attribution,
      source: quote.source,
    );
  }

  List<TextBlock> _translatedPair(TextBlock original, String? value) {
    if (value == null) return [original];
    final translated = _translatedText(original, value);
    if (mode == TranslationMode.replace) return [translated];
    return [
      _withReducedBottomMargin(original),
      _copyText(
        translated,
        clearSource: true,
        nodeId: '',
        listMarkerVisible: false,
        style: translated.style.copyWith(
          marginBefore: 0,
          marginAfter: original.style.marginAfter,
        ),
      ),
    ];
  }

  TableBlock _translatedTable(
    TableBlock table,
    _StoredBlockTranslation translation,
  ) {
    var cellIndex = 0;
    final rows = <TableRow>[];
    for (final row in table.rows) {
      final cells = <TableCell>[];
      for (final cell in row.cells) {
        final value = translation.segments[cellIndex++];
        var inlines = cell.inlines;
        if (value != null) {
          final translated = TranslationMarkupCodec.decode(
            value,
            cell.inlines,
            language: targetLanguageCode,
          );
          inlines = mode == TranslationMode.replace
              ? translated
              : [...cell.inlines, const BreakInline(), ...translated];
        }
        cells.add(
          TableCell(
            inlines: inlines,
            header: cell.header,
            columnSpan: cell.columnSpan,
            rowSpan: cell.rowSpan,
            authoredAlignment: cell.authoredAlignment,
            style: cell.style,
            source: cell.source,
            nodeId: cell.nodeId,
          ),
        );
      }
      rows.add(TableRow(cells));
    }
    return TableBlock(rows: rows, style: table.style, source: table.source);
  }

  FigureBlock _translatedFigure(
    FigureBlock figure,
    _StoredBlockTranslation translation,
  ) {
    final captions = <TextBlock>[];
    for (var index = 0; index < figure.captions.length; index++) {
      final caption = figure.captions[index];
      final value = translation.segments[index];
      if (value == null) {
        captions.add(caption);
        continue;
      }
      final translated = TranslationMarkupCodec.decode(
        value,
        caption.inlines,
        language: targetLanguageCode,
      );
      captions.add(
        _copyText(
          caption,
          inlines: mode == TranslationMode.replace
              ? translated
              : [...caption.inlines, const BreakInline(), ...translated],
        ),
      );
    }
    return FigureBlock(
      images: figure.images,
      captions: captions,
      captionPosition: figure.captionPosition,
      style: figure.style,
      source: figure.source,
    );
  }

  static List<Inline>? _segmentInlines(
    Section section,
    int blockIndex,
    int? segmentIndex,
  ) {
    if (blockIndex < 0 || blockIndex >= section.blocks.length) return null;
    final block = section.blocks[blockIndex];
    return switch (block) {
      TextBlock() when segmentIndex == null => block.inlines,
      QuoteBlock() when segmentIndex != null => [
        ...block.body,
        ?block.attribution,
      ].elementAtOrNull(segmentIndex)?.inlines,
      TableBlock() when segmentIndex != null =>
        block.rows
            .expand((row) => row.cells)
            .elementAtOrNull(segmentIndex)
            ?.inlines,
      FigureBlock() when segmentIndex != null =>
        block.captions.elementAtOrNull(segmentIndex)?.inlines,
      _ => null,
    };
  }

  static TextBlock _withReducedBottomMargin(TextBlock block) => _copyText(
    block,
    style: block.style.copyWith(
      marginAfter: block.style.marginAfter.clamp(0.0, 6.0).toDouble(),
    ),
  );

  static TextBlock _copyText(
    TextBlock block, {
    List<Inline>? inlines,
    BlockStyle? style,
    SourceRange? source,
    bool clearSource = false,
    String? nodeId,
    bool? listMarkerVisible,
  }) => TextBlock(
    kind: block.kind,
    headingLevel: block.headingLevel,
    listOrdered: block.listOrdered,
    listOrdinal: block.listOrdinal,
    listDepth: block.listDepth,
    listMarkerVisible: listMarkerVisible ?? block.listMarkerVisible,
    inlines: inlines ?? block.inlines,
    style: style ?? block.style,
    source: clearSource ? null : (source ?? block.source),
    nodeId: nodeId ?? block.nodeId,
  );
}

class _StoredBlockTranslation {
  String? whole;
  final Map<int, String> segments = {};

  bool contains(int? segmentIndex) =>
      segmentIndex == null ? whole != null : segments.containsKey(segmentIndex);
}
