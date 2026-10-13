import '../ir/ir.dart';

/// Decode desktop's serde Reading IR directly, retaining spine/node/scalar
/// identities. Going through HTML would assign new nodes and break sync marks.
class DesktopIrCodec {
  final String Function(String) resolve;
  DesktopIrCodec({String Function(String)? resolve})
    : resolve = resolve ?? ((s) => s);
  static Map<String, dynamic> map(Object? value) {
    if (value is! Map) throw const FormatException('Invalid desktop IR object');
    return Map<String, dynamic>.from(value);
  }

  static List<dynamic> list(Object? value) {
    if (value is! List) throw const FormatException('Invalid desktop IR list');
    return value;
  }

  static String string(Object? value) {
    if (value is Map && value['path'] is String) {
      final path = value['external_web'] ?? value['path'];
      final fragment = value['fragment'];
      return string('$path${fragment == null ? '' : '#${string(fragment)}'}');
    }
    if (value is! String || value.contains('\x00')) {
      throw const FormatException('Invalid desktop IR string');
    }
    return value;
  }

  static double number(Object? value, [double fallback = 0]) {
    if (value == null) return fallback;
    if (value is! num || !value.isFinite || value.abs() > 1e9) {
      throw const FormatException('Invalid desktop IR number');
    }
    return value.toDouble();
  }

  static int integer(Object? value, [int fallback = 0]) {
    if (value == null) return fallback;
    if (value is! int || value < 0 || value > 0x7fffffff) {
      throw const FormatException('Invalid desktop IR integer');
    }
    return value;
  }

  SourceRange? range(Object? value) =>
      value == null ? null : SourceRange.fromJson(map(value));
  BlockAlign alignment(Object? value) => switch (value) {
    'Center' => BlockAlign.center,
    'End' => BlockAlign.end,
    'Justify' => BlockAlign.justify,
    _ => BlockAlign.start,
  };
  BlockStyle blockStyle(Object? raw) {
    final s = raw == null ? <String, dynamic>{} : map(raw);
    return BlockStyle(
      align: alignment(s['align']),
      authoredAlignment: s['authored_alignment'] == null
          ? null
          : alignment(s['authored_alignment']),
      semanticAlignment: s['semantic_alignment'] == null
          ? null
          : alignment(s['semantic_alignment']),
      marginBefore: number(s['margin_before']),
      marginAfter: number(s['margin_after']),
      marginStart: number(s['margin_start']),
      marginStartFraction: number(s['margin_start_fraction']),
      indent: number(s['indent']),
      lineHeight: number(s['line_height'], 1.5),
      hardBreakAfter: s['hard_break_after'] == true,
    );
  }

  TextRun run(Object? raw) {
    final r = map(raw),
        s = r['style'] == null ? <String, dynamic>{} : map(r['style']);
    final color = s['color'] is Map ? map(s['color']) : null;
    final language = s['language'];
    return TextRun(
      string(r['text']),
      link: r['link'] == null ? null : resolve(string(r['link'])),
      language: switch (language) {
        'english' => 'en',
        'english-us' => 'en-US',
        'english-gb' => 'en-GB',
        _ => null,
      },
      displayWritingSystem: switch (s['display_writing_system']) {
        'cjk' => WritingSystem.cjk,
        'latin' => WritingSystem.latin,
        'other' => WritingSystem.other,
        'unknown' => WritingSystem.unknown,
        _ => null,
      },
      style: TextStyle(
        bold: s['bold'] == true,
        italic: s['italic'] == true,
        emphasis: s['emphasis'] == true,
        alternateVoice: s['alternate_voice'] == true,
        citation: s['citation'] == true,
        underline: s['underline'] == true,
        sizeScale: number(s['size_scale'], 1),
        keywordSizeScale: s['keyword_size_scale'] == null
            ? null
            : number(s['keyword_size_scale']),
        color: color == null
            ? null
            : (integer(color['alpha'], 255) << 24) |
                  (integer(color['red']) << 16) |
                  (integer(color['green']) << 8) |
                  integer(color['blue']),
        baseline: switch (s['baseline']) {
          'Superscript' => TextBaselineShift.superscript,
          'Subscript' => TextBaselineShift.subscript,
          _ => TextBaselineShift.none,
        },
        linkRole: switch (s['link_role']) {
          'FootnoteReference' => LinkRole.footnoteReference,
          'FootnoteBacklink' => LinkRole.footnoteBacklink,
          _ => LinkRole.normal,
        },
        inlineRole: s['inline_role'] == 'Footnote'
            ? InlineRole.footnote
            : InlineRole.normal,
        inlineCitation: integer(s['inline_citation']),
        hyphenation: switch (s['hyphenation']) {
          'none' => HyphenationMode.none,
          'manual' => HyphenationMode.manual,
          _ => HyphenationMode.auto,
        },
      ),
    );
  }

  Inline inline(Object? raw) {
    if (raw == 'Break') return const BreakInline();
    final variant = map(raw);
    if (variant.length != 1) {
      throw const FormatException('Invalid desktop inline variant');
    }
    final key = variant.keys.single, value = variant.values.single;
    switch (key) {
      case 'Text':
        return run(value);
      case 'Ruby':
        final r = map(value);
        return RubyRun(
          base: list(r['base']).map(run).toList(),
          annotation: list(r['annotation']).map(run).toList(),
          below: r['below'] == true,
        );
      case 'Math':
        final m = map(value);
        return MathInline(
          string(m['latex']),
          display: m['display'] == true,
          sizeScale: number(m['size_scale'], 1),
          original: m['original'] == null
              ? null
              : list(m['original']).map(run).toList(),
        );
      case 'Image':
        final m = map(value);
        return InlineImageRun(
          image: image(m['image']),
          sizeScale: number(m['size_scale'], 1),
          intrinsicSizing: m['intrinsic_sizing'] == true,
          presentation: m['presentation'] == true,
          verticalAlign: switch (m['vertical_align']) {
            'middle' => InlineImageAlignment.middle,
            'text-top' => InlineImageAlignment.textTop,
            'text-bottom' => InlineImageAlignment.textBottom,
            'top' => InlineImageAlignment.top,
            'bottom' => InlineImageAlignment.bottom,
            'super' => InlineImageAlignment.superscript,
            'sub' => InlineImageAlignment.subscript,
            _ => InlineImageAlignment.baseline,
          },
        );
      default:
        throw FormatException('Unsupported desktop inline: $key');
    }
  }

  TextBlock text(Object? raw) {
    final t = map(raw), kind = t['kind'], source = range(t['source']);
    final key = kind is Map ? kind.keys.single as String : kind as String;
    final details = kind is Map && kind.values.single is Map
        ? map(kind.values.single)
        : <String, dynamic>{};
    final style = t['style'] == null ? <String, dynamic>{} : map(t['style']);
    return TextBlock(
      nodeId: source == null
          ? ''
          : '${source.start.spine.value}/${source.start.node}',
      source: source,
      inlines: list(t['content']).map(inline).toList(),
      style: blockStyle(style),
      kind: switch (key) {
        'Heading' || 'HeadingOrdinal' => TextBlockKind.heading,
        'Blockquote' => TextBlockKind.blockquote,
        'QuoteAttribution' => TextBlockKind.quoteAttribution,
        'Preformatted' => TextBlockKind.preformatted,
        'Caption' => TextBlockKind.caption,
        'FootnoteDefinition' => TextBlockKind.footnoteDefinition,
        'ListItem' => TextBlockKind.listItem,
        'DefinitionTerm' => TextBlockKind.definitionTerm,
        'DefinitionDescription' => TextBlockKind.definitionDescription,
        'Paragraph' => TextBlockKind.paragraph,
        _ => throw FormatException('Unsupported desktop text kind: $key'),
      },
      headingLevel: key == 'Heading' || key == 'HeadingOrdinal'
          ? integer((kind as Map).values.single)
          : 0,
      headingOrdinal: key == 'HeadingOrdinal',
      listOrdered: details['ordered'] == true,
      listOrdinal: integer(details['ordinal'], 1),
      listDepth: integer(details['depth']),
      listMarkerVisible: details['marker_visible'] != false,
      listGroupId: style['list_group']?.toString(),
      authoredListMarkerChars: integer(style['authored_list_marker']),
    );
  }

  ImageLength? length(Object? raw) {
    if (raw == null) return null;
    final m = map(raw);
    if (m.length != 1) throw const FormatException('Invalid image length');
    return switch (m.keys.single) {
      'Pixels' => ImagePixels(number(m.values.single)),
      'Fraction' => ImageFraction(number(m.values.single)),
      _ => throw const FormatException('Invalid image length'),
    };
  }

  ImageBlock image(Object? raw) {
    final i = map(raw),
        s = i['style'] == null ? <String, dynamic>{} : map(i['style']);
    final formula = i['formula'] == null ? null : map(i['formula']);
    return ImageBlock(
      ocrText: i['ocr_text'] == null
          ? null
          : ImageText(
              string(map(i['ocr_text'])['text']),
              literal: map(i['ocr_text'])['literal'] == true,
            ),
      href: string(i['href']),
      alt: i['alt'] as String? ?? '',
      source: range(i['source']),
      style: ImageStyle(
        containerFraction: s['container_width'] is Map
            ? number(map(s['container_width'])['fraction'], 1)
            : 1,
        containerPixels:
            s['container_width'] is Map &&
                map(s['container_width'])['pixels'] != null
            ? number(map(s['container_width'])['pixels'])
            : null,
        width: length(s['width']),
        height: length(s['height']),
        maxWidth: length(s['max_width']),
        maxHeight: length(s['max_height']),
        marginBefore: number(s['margin_before']),
        marginAfter: number(s['margin_after']),
      ),
      formula: formula == null
          ? null
          : MathInline(
              string(formula['latex']),
              originalImage: string(i['href']),
              equationNumber: formula['equation_number'] as String?,
            ),
    );
  }

  Block block(Object? raw, [int depth = 0]) {
    if (depth > 64) {
      throw const FormatException('Desktop IR nesting exceeds limit');
    }
    if (raw == 'PageBreak') return const PageBreakBlock();
    if (raw == 'LineBreak') return const LineBreakBlock();
    final variant = map(raw);
    if (variant.length != 1) {
      throw const FormatException('Invalid desktop block variant');
    }
    final key = variant.keys.single, v = map(variant.values.single);
    switch (key) {
      case 'Text':
        return text(v);
      case 'Image':
        return image(v);
      case 'Quote':
        return QuoteBlock(
          body: list(v['body']).map(text).toList(),
          attribution: v['attribution'] == null ? null : text(v['attribution']),
          source: range(v['source']),
        );
      case 'Table':
        return TableBlock(
          source: range(v['source']),
          before: (v['before'] as List? ?? []).map(text).toList(),
          after: (v['after'] as List? ?? []).map(text).toList(),
          rows: list(v['rows'])
              .map(
                (r) => TableRow(
                  list(map(r)['cells']).map((c) {
                    final cell = map(c), t = text(cell['text']);
                    return TableCell(
                      inlines: t.inlines,
                      nodeId: t.nodeId,
                      source: t.source,
                      style: t.style,
                      header: cell['header'] == true,
                      columnSpan: integer(cell['column_span'], 1),
                      rowSpan: integer(cell['row_span'], 1),
                      authoredAlignment: cell['authored_alignment'] == null
                          ? null
                          : alignment(cell['authored_alignment']),
                    );
                  }).toList(),
                ),
              )
              .toList(),
        );
      case 'Figure':
        return FigureBlock(
          images: list(v['images']).map(image).toList(),
          captions: list(v['captions']).map(text).toList(),
          style: blockStyle(v['style']),
          source: range(v['source']),
          captionPosition: v['caption_position'] == 'before'
              ? CaptionPosition.before
              : CaptionPosition.after,
        );
      case 'Note':
        return NoteBlock(
          kind: v['kind'] == 'Section'
              ? NoteBlockKind.section
              : NoteBlockKind.definition,
          blocks: list(v['blocks']).map((b) => block(b, depth + 1)).toList(),
          source: range(v['source']),
        );
      case 'Separator':
        return SeparatorBlock(
          text: v['text'] == null ? null : text(v['text']),
          image: v['image'] == null ? null : image(v['image']),
          style: blockStyle(v['style']),
          inQuote: v['in_quote'] == true,
          kind: switch (v['kind']) {
            'spacing' => SeparatorKind.spacing,
            'ornament' => SeparatorKind.ornament,
            _ => SeparatorKind.rule,
          },
        );
      default:
        throw FormatException('Unsupported desktop block: $key');
    }
  }

  Section section(Object? raw, int index) {
    final s = map(raw);
    return Section(
      id: SpineItemId.fromJson(s['id']),
      spineIndex: index,
      href: resolve(string(s['href'])),
      blocks: list(s['blocks']).map((b) => block(b)).toList(),
      anchors: (s['anchors'] as List? ?? []).map((a) {
        final value = map(a);
        return SectionAnchor(
          fragment: string(value['fragment']),
          source: SourceAnchor.fromJson(map(value['source'])),
        );
      }).toList(),
    );
  }

  Book book(Object? raw) {
    final b = map(raw), m = map(b['metadata']);
    final spine = list(b['sections']).indexed.map((entry) {
      final s = map(entry.$2);
      return SpineItem(
        id: SpineItemId.fromJson(s['id']),
        linear: s['linear'] != false,
        index: entry.$1,
        href: resolve(string(s['href'])),
      );
    }).toList();
    List<TocEntry> toc(Object? raw) => (raw as List? ?? []).map((r) {
      final t = map(r),
          href = t['href'] == null ? '' : resolve(string(t['href']));
      final index = spine.indexWhere((s) => s.href == href.split('#').first);
      return TocEntry(
        label: string(t['label']),
        href: href,
        spineIndex: index < 0 ? null : index,
        children: toc(t['children']),
      );
    }).toList();
    return Book(
      id: string(b['id']),
      metadata: BookMetadata(
        title: string(m['title']),
        authors: list(m['authors']).cast<String>(),
        languages: list(m['languages']).cast<String>(),
        layout: m['layout'] == 'pre-paginated'
            ? RenditionLayout.prePaginated
            : RenditionLayout.reflowable,
      ),
      spine: spine,
      toc: toc(b['table_of_contents']),
      coverHref: b['cover'] == null ? null : resolve(string(b['cover'])),
    );
  }
}
