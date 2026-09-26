import '../ir/ir.dart';
import '../ir/inline_content.dart';
import 'formula_validation.dart';

List<(int, ImageBlock)> formulaImageCandidates(
  Section section,
  int start,
  int end,
) {
  final out = <(int, ImageBlock)>[];
  for (var b = start; b < end; b++) {
    final block = section.blocks[b];
    if (block is FigureBlock || block is SeparatorBlock) continue;
    if (block is ImageBlock && !block.fixedPage) {
      var left = b, right = b + 1;
      while (left > 0 && section.blocks[left - 1] is ImageBlock) {
        left--;
      }
      while (right < section.blocks.length &&
          section.blocks[right] is ImageBlock) {
        right++;
      }
      bool caption(int i) =>
          i >= 0 &&
          i < section.blocks.length &&
          section.blocks[i] is TextBlock &&
          (section.blocks[i] as TextBlock).kind == TextBlockKind.caption;
      if (!caption(left - 1) && !caption(right)) out.add((b, block));
    }
    for (final text in blockTexts(block)) {
      if (text.kind == TextBlockKind.caption) continue;
      for (final inline in text.inlines.whereType<InlineImageRun>()) {
        if (!inline.image.fixedPage) out.add((b, inline.image));
      }
    }
  }
  return out;
}

bool validImageAnnotation(
  Section section,
  Map<String, dynamic> g,
  int start,
  int end,
) {
  final block = g['block'];
  return block is int &&
      block >= start &&
      block < end &&
      g['href'] is String &&
      g['latex'] is String &&
      (g['equation_number'] == null || g['equation_number'] is String) &&
      ((g['latex'] as String).isEmpty || formulaError(g['latex']) == null) &&
      formulaImageCandidates(
        section,
        block,
        block + 1,
      ).any((c) => c.$2.href == g['href']);
}

Section composeImageAnnotations(
  Section displayed,
  List<Map<String, dynamic>> groups,
) {
  final formulas = {
    for (final g in groups.where(
      (g) => g['kind'] == 'image_formula' && g['latex'] != '',
    ))
      g['href'] as String: g,
  };
  if (formulas.isEmpty) return displayed;
  final converted = withBlocks(displayed, [
    for (final b in displayed.blocks)
      mapBlockContent(
        b,
        (t) => t,
        image: (image) {
          final g = formulas[image.href];
          if (g == null) return image;
          return ImageBlock(
            href: image.href,
            alt: image.alt,
            style: image.style,
            source: image.source,
            fixedPage: image.fixedPage,
            formula: MathInline(
              g['latex'] as String,
              originalImage: image.href,
              equationNumber: g['equation_number'] as String?,
            ),
          );
        },
      ),
  ]);
  String? number(String text) =>
      RegExp(r'^\(?[A-Za-z]?[0-9]+(?:[.\-][0-9]+)*\)?$').hasMatch(text.trim())
      ? text.trim().replaceAll(RegExp(r'[()\s]'), '')
      : null;
  ImageBlock reconcile(ImageBlock image, String? external) {
    final formula = image.formula;
    if (formula?.equationNumber == null || external == null) return image;
    final agrees = number(formula!.equationNumber!) == external;
    return ImageBlock(
      href: image.href,
      alt: image.alt,
      style: image.style,
      source: image.source,
      fixedPage: image.fixedPage,
      formula: agrees
          ? MathInline(formula.latex, originalImage: image.href)
          : null,
    );
  }

  return withBlocks(converted, [
    for (var i = 0; i < converted.blocks.length; i++)
      if (converted.blocks[i] is ImageBlock)
        reconcile(
          converted.blocks[i] as ImageBlock,
          i + 1 < converted.blocks.length &&
                  converted.blocks[i + 1] is TextBlock
              ? number((converted.blocks[i + 1] as TextBlock).plainText)
              : null,
        )
      else
        mapBlockContent(
          converted.blocks[i],
          (text) => withInlines(text, [
            for (var j = 0; j < text.inlines.length; j++)
              if (text.inlines[j] is InlineImageRun)
                (() {
                  final inline = text.inlines[j] as InlineImageRun;
                  final external =
                      j + 1 < text.inlines.length &&
                          text.inlines[j + 1] is TextRun
                      ? number((text.inlines[j + 1] as TextRun).text)
                      : null;
                  return InlineImageRun(
                    image: reconcile(inline.image, external),
                    sizeScale: inline.sizeScale,
                    intrinsicSizing: inline.intrinsicSizing,
                    verticalAlign: inline.verticalAlign,
                    presentation: inline.presentation,
                  );
                })()
              else
                text.inlines[j],
          ]),
        ),
  ]);
}
