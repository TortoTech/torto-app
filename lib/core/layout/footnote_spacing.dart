import 'dart:math' as math;
import 'dart:ui' as ui;
import '../ir/ir.dart';
import '../ir/inline_content.dart';
import 'footnote_numbering.dart';
import 'layout_types.dart';

class _Ink {
  final double advance, left, right;
  final bool hasInk;
  const _Ink(this.advance, this.left, this.right, [this.hasInk = false]);
}

/// Desktop optical rules measured from the same runtime fonts used to paint.
class FootnoteSpacing {
  static final Map<String, _Ink> _cache = {};
  static double advance(
    String marker,
    String family,
    double size,
    int weight,
  ) => _measure(marker, family, size, weight).advance;
  static bool _cjk(int r) =>
      (r >= 0x3400 && r <= 0x9fff) ||
      (r >= 0xf900 && r <= 0xfaff) ||
      (r >= 0x20000 && r <= 0x2fa1f) ||
      (r >= 0x3040 && r <= 0x30ff) ||
      (r >= 0xac00 && r <= 0xd7af);
  static bool _closing(String value) =>
      '。！？、，；：）」』】'.contains(value) && value.isNotEmpty;
  static bool _latinClosing(String value) =>
      '.!?;:,)]}”’'.contains(value) && value.isNotEmpty;
  static String _key(String text, String family, double size, int weight) =>
      '$family:$size:$weight:$text';
  static ui.Paragraph _shape(
    String text,
    String family,
    double size,
    int weight,
  ) {
    final builder = ui.ParagraphBuilder(ui.ParagraphStyle(fontSize: size))
      ..pushStyle(
        ui.TextStyle(
          fontFamily: family,
          fontSize: size,
          fontWeight: ui.FontWeight.values[(weight ~/ 100 - 1).clamp(0, 8)],
          fontVariations: family == 'Literata'
              ? [
                  ui.FontVariation('wght', weight.toDouble()),
                  ui.FontVariation('opsz', size * 0.75),
                ]
              : null,
        ),
      )
      ..addText(text);
    return builder.build()
      ..layout(const ui.ParagraphConstraints(width: 100000));
  }

  static _Ink _measure(String text, String family, double size, int weight) {
    final cached = _cache[_key(text, family, size, weight)];
    if (cached != null) return cached;
    final p = _shape(text, family, size, weight);
    final width = p.longestLine;
    p.dispose();
    if (_cache.length >= 512) _cache.remove(_cache.keys.first);
    return _cache[_key(text, family, size, weight)] = _Ink(width, 0, width);
  }

  static Future<void> _prepare(
    String text,
    String family,
    double size,
    int weight,
  ) async {
    final key = _key(text, family, size, weight);
    if (_cache[key]?.hasInk == true) return;
    final p = _shape(text, family, size, weight);
    final advance = p.longestLine;
    const scale = 3.0, padding = 2.0;
    final recorder = ui.PictureRecorder();
    // Separate recorder ownership keeps every native resource local to this load.
    ui.Canvas(recorder)
      ..scale(scale)
      ..drawParagraph(p, const ui.Offset(padding, padding));
    final picture = recorder.endRecording();
    ui.Image? image;
    try {
      image = await picture.toImage(
        math.max(1, ((advance + padding * 2) * scale).ceil()),
        math.max(1, ((p.height + padding * 2) * scale).ceil()),
      );
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      var left = image.width, right = -1;
      if (data != null) {
        for (var y = 0; y < image.height; y++) {
          for (var x = 0; x < image.width; x++) {
            if (data.getUint8((y * image.width + x) * 4 + 3) > 8) {
              left = math.min(left, x);
              right = math.max(right, x);
            }
          }
        }
      }
      if (_cache.length >= 512) _cache.remove(_cache.keys.first);
      _cache[key] = right < left
          ? _Ink(advance, 0, advance)
          : _Ink(
              advance,
              left / scale - padding,
              (right + 1) / scale - padding,
              true,
            );
    } catch (_) {
      // Glyph metrics are optional: keep reading if raster measurement fails.
      if (_cache.length >= 512) _cache.remove(_cache.keys.first);
      _cache[key] = _Ink(advance, 0, advance);
    } finally {
      image?.dispose();
      picture.dispose();
      p.dispose();
    }
  }

  static String _edge(List<Inline> values, int index, bool last) {
    while (index >= 0 && index < values.length) {
      final run = values[index];
      if (run is! TextRun ||
          run.style.footnoteNumber > 0 ||
          run.style.inlineCitation > 0) {
        return '';
      }
      if (run.text.isNotEmpty) {
        return String.fromCharCode(
          last ? run.text.runes.last : run.text.runes.first,
        );
      }
      index += last ? -1 : 1;
    }
    return '';
  }

  static double _size(TextRun run, ReaderStyle style) =>
      run.style.footnoteNumber > 0
      ? style.baseFontSize * 0.78
      : style.baseFontSize *
            (run.style.keywordSizeScale ?? 1) *
            (run.style.baseline == TextBaselineShift.none ? 1 : 0.7) *
            0.78;
  static String _label(TextRun run) => run.style.footnoteNumber > 0
      ? '${run.style.footnoteNumber}'
      : '[${run.style.inlineCitation}]';
  static Future<void> prepare(Section section, ReaderStyle style) async {
    if (style.typesettingMode != TypesettingMode.unified) return;
    final numbered = numberFootnotes(section), typography = style.typography;
    final family = typography.latinFontFor(style.writingSystem).family;
    final cjkFamily = typography.cjkFontFor(style.writingSystem).family;
    for (final block in numbered.blocks) {
      for (final text in blockTexts(block)) {
        final values = coalesceNumberedFootnotes(text.inlines);
        for (var i = 0; i < values.length; i++) {
          final run = values[i];
          if (run is! TextRun || run.style.footnoteNumber == 0) continue;
          final previous = _edge(values, i - 1, true),
              next = _edge(values, i + 1, false);
          if (!_closing(previous) &&
              !_latinClosing(previous) &&
              (previous.isEmpty || !_cjk(previous.runes.first)) &&
              (next.isEmpty || !_cjk(next.runes.first))) {
            continue;
          }
          await _prepare(
            _label(run),
            family,
            _size(run, style),
            typography.fontWeight,
          );
          if (_closing(previous) ||
              _latinClosing(previous) ||
              (previous.isNotEmpty && _cjk(previous.runes.first))) {
            await _prepare(
              previous,
              _latinClosing(previous) ? family : cjkFamily,
              style.baseFontSize,
              typography.fontWeight,
            );
          }
          if (next.isNotEmpty && _cjk(next.runes.first)) {
            await _prepare(
              next,
              cjkFamily,
              style.baseFontSize,
              typography.fontWeight,
            );
          }
        }
      }
    }
  }

  static Section apply(Section section, ReaderStyle style) {
    if (style.typesettingMode != TypesettingMode.unified) return section;
    final typography = style.typography;
    final family = typography.latinFontFor(style.writingSystem).family;
    final cjkFamily = typography.cjkFontFor(style.writingSystem).family;
    return withBlocks(section, [
      for (final block in section.blocks)
        mapBlockContent(block, (text) {
          if (!text.inlines.whereType<TextRun>().any(
            (r) => r.style.footnoteNumber > 0 || r.style.inlineCitation > 0,
          )) {
            return text;
          }
          final values = coalesceNumberedFootnotes(text.inlines),
              result = <Inline>[];
          for (var i = 0; i < values.length; i++) {
            final run = values[i];
            if (run is! TextRun ||
                (run.style.footnoteNumber == 0 &&
                    run.style.inlineCitation == 0)) {
              result.add(run);
              continue;
            }
            final note = _measure(
              _label(run),
              family,
              _size(run, style),
              typography.fontWeight,
            );
            var before = 0.0, after = 0.0;
            if (run.style.footnoteNumber > 0) {
              final previous = _edge(values, i - 1, true),
                  next = _edge(values, i + 1, false),
                  em = style.baseFontSize;
              if (_closing(previous) ||
                  _latinClosing(previous) ||
                  (previous.isNotEmpty && _cjk(previous.runes.first))) {
                final ink = _measure(
                  previous,
                  _latinClosing(previous) ? family : cjkFamily,
                  em,
                  typography.fontWeight,
                );
                final gap = ink.advance - ink.right + note.left;
                if (_closing(previous)) {
                  // A Flutter placeholder cannot reserve negative width. Keep
                  // its real advance and painted origin in agreement instead
                  // of relying on negative spacing on an invisible joiner.
                  before = (em * 0.10 - gap).clamp(
                    -math.min(
                      math.min(em * 0.65, ink.advance * 0.8),
                      math.max(0.0, note.advance - 1.0),
                    ),
                    0.0,
                  );
                } else {
                  // Separate the numeral from CJK text and Latin punctuation,
                  // whose trailing whitespace may be too narrow on its own.
                  before = (em * 0.16 - gap).clamp(0.0, em * 0.20);
                }
              }
              if (next.isNotEmpty && _cjk(next.runes.first)) {
                final ink = _measure(
                  next,
                  cjkFamily,
                  em,
                  typography.fontWeight,
                );
                after = (em * 0.16 - (note.advance - note.right + ink.left))
                    .clamp(0.0, em * 0.20);
              }
            }
            result.add(
              withRun(
                run,
                run.text,
                style: run.style.copyWith(
                  referenceAdvance: note.advance + before + after,
                  referencePaintOffset: before,
                  referenceGlyphAdvance: note.advance,
                ),
              ),
            );
          }
          return withInlines(text, result);
        }),
    ]);
  }
}
