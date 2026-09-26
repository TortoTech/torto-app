import 'dart:convert';
import 'dart:typed_data';
import 'dart:isolate';
import '../ir/ir.dart';
import 'inline_semantics.dart';
import 'image_formulas.dart';

typedef SemanticGroup = Map<String, dynamic>;

Future<Section> _composeInWorker(
  Section original,
  Section displayed,
  List<SemanticGroup> groups,
) => Isolate.run(() => composeSemanticLayout(original, displayed, groups));

String? sourceKey(Block b) {
  final s = switch (b) {
    TextBlock(:final source) ||
    ImageBlock(:final source) ||
    QuoteBlock(:final source) => source,
    _ => null,
  };
  return s == null ? null : jsonEncode(s.toJson());
}

bool paragraph(Block b) =>
    b is TextBlock &&
    b.kind == TextBlockKind.paragraph &&
    b.source != null &&
    b.plainText.trim().isNotEmpty;
bool numbered(Block b) =>
    paragraph(b) &&
    RegExp(
      r'^[1-9][0-9]{0,3}[.)．）]?$',
    ).hasMatch((b as TextBlock).plainText.trim());

bool headingCandidate(Block b) =>
    paragraph(b) &&
    (b as TextBlock).plainText.trim().runes.length <= 120 &&
    (numbered(b) || RegExp(r'\p{L}', unicode: true).hasMatch(b.plainText)) &&
    b.inlines.every(
      (inline) => switch (inline) {
        TextRun(:final style) =>
          style.inlineRole == InlineRole.normal &&
              style.linkRole == LinkRole.normal,
        BreakInline() => true,
        _ => false,
      },
    );

Map<String, dynamic> headingStyle(TextBlock block) {
  var count = 0, bold = 0, italic = 0;
  var size = 0.0;
  for (final run in block.inlines.whereType<TextRun>()) {
    final length = run.text.replaceAll(RegExp(r'\s'), '').runes.length;
    count += length;
    bold += run.style.bold ? length : 0;
    italic += run.style.italic ? length : 0;
    size += length * run.style.sizeScale;
  }
  final total = count > 0 ? count : 1;
  return {
    'bold_ratio': bold / total,
    'italic_ratio': italic / total,
    'relative_font_size': size / total,
    'align': block.style.align.name,
    'margin_before': block.style.marginBefore,
    'margin_after': block.style.marginAfter,
  };
}

List<Map<String, dynamic>> semanticInput(Section section) {
  final blocks = section.blocks;
  final protectedImages = <int>{};
  for (var i = 0; i < blocks.length; i++) {
    if (blocks[i] is! ImageBlock) continue;
    var end = i + 1;
    while (end < blocks.length && blocks[end] is ImageBlock) {
      end++;
    }
    bool caption(int j) =>
        j >= 0 &&
        j < blocks.length &&
        blocks[j] is TextBlock &&
        (blocks[j] as TextBlock).kind == TextBlockKind.caption;
    if (caption(i - 1) || caption(end)) {
      protectedImages.addAll(List.generate(end - i, (n) => n + i));
    }
    i = end - 1;
  }
  return [
    for (var i = 0; i < blocks.length; i++)
      {
        'id': i,
        ...switch (blocks[i]) {
          TextBlock b when paragraph(b) => {
            'type': 'paragraph',
            'text': b.plainText,
            'heading_eligible': headingCandidate(b),
            if (headingCandidate(b)) 'style': headingStyle(b),
          },
          TextBlock b when b.kind == TextBlockKind.heading => {
            'type': 'boundary',
            'heading': b.plainText,
          },
          TextBlock b
              when b.kind == TextBlockKind.quoteAttribution &&
                  b.source != null =>
            {'type': 'attribution_candidate', 'text': b.plainText},
          ImageBlock b
              when b.source != null &&
                  !b.fixedPage &&
                  !protectedImages.contains(i) =>
            {'type': 'image_needs_caption'},
          QuoteBlock b when b.attribution == null => {
            'type': 'quote_missing_attribution',
            'body': [
              for (var j = 0; j < b.body.length; j++)
                {
                  'index': j,
                  'text': b.body[j].plainText,
                  'attribution_eligible':
                      j > 0 &&
                      j == b.body.length - 1 &&
                      b.body[j].source != null,
                },
            ],
          },
          _ => {'type': 'protected_boundary'},
        },
      },
  ];
}

bool creditLike(String value) {
  final text = value.trim();
  if (text.isEmpty ||
      text.runes.length > 300 ||
      text.split(RegExp(r'\s+')).length > 40 ||
      !RegExp(r'\p{L}', unicode: true).hasMatch(text) ||
      RegExp(r'[?!？！]').hasMatch(text)) {
    return false;
  }
  final lower = text.toLowerCase();
  if (lower.startsWith('someone') || text.startsWith('有人')) return false;
  if (!RegExp(r'^[—–\-(（\[【]').hasMatch(text)) {
    if (RegExp('["”’」』]\$').hasMatch(text) ||
        RegExp(r'^(i|we|he|she|they|nothing|this|that|it) ').hasMatch(lower)) {
      return false;
    }
  }
  return true;
}

bool introducesQuote(String value) {
  final text = value.trim().toLowerCase();
  if (text.length < 4 ||
      RegExp(r'someone|somebody|people say|有人|研究表明').hasMatch(text)) {
    return false;
  }
  return text.endsWith(':') ||
      text.endsWith('：') ||
      RegExp(
        r'( writes| wrote| says| said| as follows| the following| put it|写道|说道|指出|说)[.。]*$',
      ).hasMatch(text);
}

List<int> groupIds(SemanticGroup g) => switch (g['kind']) {
  'citation' || 'text_formula' || 'image_formula' => [g['block'] as int],
  'section_heading' => [g['block'] as int],
  'figure' => [
    ...(g['images'] as List).cast<int>(),
    ...(g['captions'] as List).cast<int>(),
  ],
  'quote_attribution' => [
    g['quote'] as int,
    if (g['attribution'] != null) g['attribution'] as int,
  ],
  _ => [
    ...(g['body'] as List).cast<int>(),
    if (g['attribution'] != null) g['attribution'] as int,
  ],
}..sort();

List<SemanticGroup> validateGroups(
  Section section,
  Object? raw, {
  int start = 0,
  int? end,
  Set<int>? protected,
  Set<String>? kinds,
}) {
  if (raw is! List) throw const FormatException('Missing groups');
  final input = semanticInput(section);
  final used = {...?protected};
  final accepted = <SemanticGroup>[];
  bool consecutive(List<int> ids) =>
      ids.isNotEmpty &&
      List.generate(
        ids.length - 1,
        (i) => ids[i + 1] == ids[i] + 1,
      ).every((b) => b);
  bool eligible(int id) => input[id]['type'] == 'paragraph';
  for (final value in raw) {
    try {
      if (value is! Map) continue;
      final g = Map<String, dynamic>.from(value);
      final kind = g['kind'];
      if (kind == 'citation' || kind == 'text_formula') {
        if (validInlineAnnotation(
              section,
              g,
              start,
              end ?? section.blocks.length,
            ) &&
            !accepted.any(
              (a) => a['kind'] == kind && jsonEncode(a) == jsonEncode(g),
            )) {
          accepted.add(g);
        }
        continue;
      }
      if (kind == 'image_formula') {
        if (validImageAnnotation(
          section,
          g,
          start,
          end ?? section.blocks.length,
        )) {
          accepted.add(g);
        }
        continue;
      }
      final fields = switch (kind) {
        'quote' ||
        'quote_before' => {'kind', 'body', 'attribution', 'alignment'},
        'quote_inline' => {'kind', 'body', 'credit', 'alignment'},
        'figure' => {'kind', 'images', 'captions'},
        'section_heading' => {'kind', 'block'},
        'quote_attribution' => {'kind', 'quote', 'attribution', 'body_index'},
        _ => <String>{},
      };
      if (fields.isEmpty ||
          g.keys.toSet().difference(fields).isNotEmpty ||
          fields.difference(g.keys.toSet()).isNotEmpty ||
          kinds != null && !kinds.contains(kind)) {
        continue;
      }
      final ids = groupIds(g);
      if (!consecutive(ids) ||
          ids.first < start ||
          ids.first >= (end ?? input.length) ||
          ids.last >= (end ?? input.length) ||
          ids.last >= input.length ||
          ids.any(used.contains)) {
        continue;
      }
      if (g.containsKey('alignment') &&
          ![
            null,
            'start',
            'center',
            'end',
            'justify',
          ].contains(g['alignment'])) {
        continue;
      }
      if (kind == 'section_heading') {
        if (!headingCandidate(section.blocks[ids.first])) continue;
      } else if (kind == 'figure') {
        final images = (g['images'] as List).cast<int>();
        final captions = (g['captions'] as List).cast<int>();
        if (!consecutive(images) ||
            !consecutive(captions) ||
            images.any((i) => input[i]['type'] != 'image_needs_caption') ||
            !captions.every(eligible)) {
          continue;
        }
        if (images.first > 0 &&
                section.blocks[images.first - 1] is ImageBlock ||
            images.last + 1 < section.blocks.length &&
                section.blocks[images.last + 1] is ImageBlock) {
          continue;
        }
      } else if (kind == 'quote_attribution') {
        final q = section.blocks[g['quote'] as int];
        if (q is! QuoteBlock || q.attribution != null) continue;
        final a = g['attribution'];
        final b = g['body_index'];
        if ((a == null) == (b == null)) continue;
        if (a != null &&
            (a != (g['quote'] as int) + 1 ||
                ![
                  'paragraph',
                  'attribution_candidate',
                ].contains(input[a]['type']) ||
                !creditLike((section.blocks[a] as TextBlock).plainText))) {
          continue;
        }
        if (b != null &&
            (b is! int ||
                b < 1 ||
                b != q.body.length - 1 ||
                q.body[b].source == null ||
                !creditLike(q.body[b].plainText))) {
          continue;
        }
      } else {
        final body = (g['body'] as List).cast<int>();
        if (!consecutive(body)) continue;
        if (kind == 'quote_inline' &&
            body.length == 1 &&
            section.blocks[body.first] is QuoteBlock) {
          final q = section.blocks[body.first] as QuoteBlock;
          if (q.attribution != null ||
              q.body.isEmpty ||
              splitCredit(q.body.last, g['credit'] as String) == null) {
            continue;
          }
        } else {
          if (!body.every(eligible)) continue;
          if (kind == 'quote_inline') {
            if (splitCredit(
                  section.blocks[body.last] as TextBlock,
                  g['credit'] as String,
                ) ==
                null) {
              continue;
            }
          } else {
            final a = g['attribution'] as int;
            if (!eligible(a)) continue;
            final text = (section.blocks[a] as TextBlock).plainText;
            if (kind == 'quote_before'
                ? a != body.first - 1 || !introducesQuote(text)
                : a != body.last + 1 || !creditLike(text)) {
              continue;
            }
          }
        }
      }
      used.addAll(ids);
      accepted.add(g);
    } on Object {
      /* Untrusted model proposals never damage source content. */
    }
  }
  return accepted;
}

TextBlock copyText(
  TextBlock b, {
  TextBlockKind? kind,
  BlockAlign? alignment,
  List<Inline>? inlines,
  SourceRange? source,
}) => TextBlock(
  kind: kind ?? b.kind,
  headingLevel: kind == TextBlockKind.heading ? 3 : b.headingLevel,
  headingOrdinal: b.headingOrdinal,
  listOrdered: b.listOrdered,
  listOrdinal: b.listOrdinal,
  listDepth: b.listDepth,
  listMarkerVisible: b.listMarkerVisible,
  inlines: inlines ?? b.inlines,
  style: b.style.copyWith(semanticAlignment: alignment),
  source: source ?? b.source,
  nodeId: b.nodeId,
);

(TextBlock, TextBlock)? splitCredit(TextBlock b, String credit) {
  final text = b.plainText.trimRight();
  final suffix = credit.trimRight();
  final s = b.source;
  if (s == null ||
      b.nodeId.endsWith('@translation') ||
      s.start.node != s.end.node ||
      s.start.spine != s.end.spine ||
      s.end.textOffset - s.start.textOffset != b.plainText.runes.length ||
      suffix.isEmpty ||
      !text.endsWith(suffix) ||
      !creditLike(suffix) ||
      b.inlines.any((i) => i is! TextRun && i is! BreakInline)) {
    return null;
  }
  final boundary = text.length - suffix.length;
  if (boundary == 0 ||
      !(RegExp(r'^[—–\-(（\[【\n]').hasMatch(suffix.trimLeft()) ||
          suffix.startsWith('\n') ||
          text.substring(0, boundary).endsWith('\n'))) {
    return null;
  }
  final offset = text.substring(0, boundary).runes.length;
  if (text.substring(0, boundary).trim().isEmpty) return null;
  List<Inline> slice(int start, int end) {
    var at = 0;
    final result = <Inline>[];
    for (final i in b.inlines) {
      final length = i is TextRun
          ? i.text.runes.length
          : (i as BreakInline).synthetic
          ? 0
          : 1;
      final from = (start - at).clamp(0, length);
      final to = (end - at).clamp(0, length);
      if (to > from) {
        if (i is TextRun) {
          result.add(
            TextRun(
              String.fromCharCodes(i.text.runes.skip(from).take(to - from)),
              style: i.style,
              link: i.link,
              language: i.language,
              displayWritingSystem: i.displayWritingSystem,
            ),
          );
        } else {
          result.add(i);
        }
      }
      at += length;
    }
    return result;
  }

  final mid = SourceAnchor(
    spine: s.start.spine,
    node: s.start.node,
    textOffset: s.start.textOffset + offset,
  );
  return (
    copyText(
      b,
      inlines: slice(0, offset),
      source: SourceRange(start: s.start, end: mid),
    ),
    copyText(
      b,
      kind: TextBlockKind.quoteAttribution,
      inlines: slice(offset, b.plainText.runes.length),
      source: SourceRange(start: mid, end: s.end),
    ),
  );
}

Section composeSemanticLayout(
  Section original,
  Section displayed,
  List<SemanticGroup> groups,
) {
  displayed = composeImageAnnotations(
    composeInlineAnnotations(original, displayed, groups),
    groups,
  );
  final bySource = <String, List<int>>{};
  for (var i = 0; i < displayed.blocks.length; i++) {
    final key = sourceKey(displayed.blocks[i]);
    if (key != null) (bySource[key] ??= []).add(i);
  }
  final replacements = <int, List<Block>>{};
  final consumed = <int>{};
  for (final g in groups) {
    if (const {
      'citation',
      'text_formula',
      'image_formula',
    }.contains(g['kind'])) {
      continue;
    }
    final ids = groupIds(g);
    final positions = <int>[];
    var missing = false;
    for (final id in ids) {
      final matched = bySource[sourceKey(original.blocks[id])];
      if (matched == null) {
        missing = true;
        break;
      }
      positions.addAll(matched);
    }
    positions.sort();
    if (missing ||
        positions.isEmpty ||
        positions.toSet().length != positions.length ||
        positions.last - positions.first + 1 != positions.length ||
        positions.any(consumed.contains)) {
      continue;
    }
    List<Block> variants(int id) => [
      for (final p in bySource[sourceKey(original.blocks[id])]!)
        displayed.blocks[p],
    ];
    List<TextBlock> texts(int id) =>
        variants(id).whereType<TextBlock>().toList();
    final kind = g['kind'];
    final out = <Block>[];
    if (kind == 'section_heading') {
      out.addAll(
        texts(g['block']).map((b) => copyText(b, kind: TextBlockKind.heading)),
      );
    } else if (kind == 'figure') {
      out.add(
        FigureBlock(
          images: [
            for (final id in g['images'])
              ...variants(id).whereType<ImageBlock>(),
          ],
          captions: [
            for (final id in g['captions'])
              ...texts(id).map((b) => copyText(b, kind: TextBlockKind.caption)),
          ],
          captionPosition:
              (g['captions'] as List).first < (g['images'] as List).first
              ? CaptionPosition.before
              : CaptionPosition.after,
        ),
      );
    } else {
      final align = BlockAlign.values
          .where((a) => a.name == g['alignment'])
          .firstOrNull;
      var body = <TextBlock>[];
      var credits = <TextBlock>[];
      SourceRange? quoteSource;
      if (kind == 'quote_attribution') {
        final q = variants(g['quote']).whereType<QuoteBlock>().firstOrNull;
        if (q == null) continue;
        body = [...q.body];
        quoteSource = q.source;
        if (g['attribution'] != null) {
          credits = texts(g['attribution']);
        } else {
          final old = original.blocks[g['quote']] as QuoteBlock;
          final key = sourceKey(old.body[g['body_index']]);
          credits = body.where((b) => sourceKey(b) == key).toList();
          body.removeWhere((b) => sourceKey(b) == key);
        }
      } else {
        for (final id in g['body']) {
          for (final v in variants(id)) {
            if (v is TextBlock) {
              body.add(
                copyText(v, kind: TextBlockKind.blockquote, alignment: align),
              );
            }
            if (v is QuoteBlock) {
              body.addAll(v.body);
              quoteSource = v.source;
            }
          }
        }
        if (kind == 'quote_before') out.addAll(variants(g['attribution']));
        if (kind == 'quote') credits = texts(g['attribution']);
        if (kind == 'quote_inline') {
          var split = false;
          final lastOriginal = original.blocks[(g['body'] as List).last];
          final lastKey = sourceKey(
            lastOriginal is QuoteBlock ? lastOriginal.body.last : lastOriginal,
          );
          for (var i = body.length - 1; i >= 0; i--) {
            if (sourceKey(body[i]) != lastKey) continue;
            final pieces = splitCredit(body[i], g['credit']);
            if (pieces != null) {
              body[i] = pieces.$1;
              credits.insert(0, pieces.$2);
              split = true;
            }
          }
          if (!split) {
            continue; // Translated-only suffix cannot safely be guessed.
          }
        }
      }
      if (body.isEmpty) continue;
      body.addAll(
        credits
            .take(credits.isNotEmpty ? credits.length - 1 : 0)
            .map((b) => copyText(b, kind: TextBlockKind.quoteAttribution)),
      );
      out.add(
        QuoteBlock(
          body: body,
          attribution: credits.isEmpty
              ? null
              : copyText(credits.last, kind: TextBlockKind.quoteAttribution),
          source: quoteSource,
        ),
      );
    }
    if (out.isEmpty) continue;
    consumed.addAll(positions);
    replacements[positions.first] = out;
  }
  final result = <Block>[];
  for (var i = 0; i < displayed.blocks.length; i++) {
    if (replacements.containsKey(i)) {
      result.addAll(replacements[i]!);
    } else if (!consumed.contains(i)) {
      result.add(displayed.blocks[i]);
    }
  }
  return Section(
    id: displayed.id,
    spineIndex: displayed.spineIndex,
    href: displayed.href,
    anchors: displayed.anchors,
    blocks: result,
  );
}

class SemanticLayoutBookSource implements BookSource {
  final BookSource inner;
  final Map<int, (Section, List<SemanticGroup>)> annotations;
  final bool inlineOnly;
  final Map<int, (Section, Object, Section)> _rendered = {};
  SemanticLayoutBookSource(
    this.inner, {
    Map<int, (Section, List<SemanticGroup>)>? annotations,
    this.inlineOnly = false,
  }) : annotations = annotations ?? {};
  @override
  Book get book => inner.book;
  @override
  Future<Uint8List?> resource(String href) => inner.resource(href);
  @override
  Future<Section> parseSection(int index) async {
    final displayed = await inner.parseSection(index);
    final data = annotations[index];
    if (data == null || data.$2.isEmpty) {
      _rendered.remove(index);
      return displayed;
    }
    final cached = _rendered[index];
    if (cached != null &&
        identical(cached.$1, displayed) &&
        identical(cached.$2, data)) {
      return cached.$3;
    }
    final original = data.$1;
    final groups = inlineOnly
        ? data.$2
              .where(
                (g) => const {
                  'citation',
                  'text_formula',
                  'image_formula',
                }.contains(g['kind']),
              )
              .toList()
        : data.$2;
    final result = await _composeInWorker(original, displayed, groups);
    _rendered.removeWhere((key, _) => (key - index).abs() > 2);
    if (identical(annotations[index], data)) {
      _rendered[index] = (displayed, data, result);
    }
    return result;
  }
}
