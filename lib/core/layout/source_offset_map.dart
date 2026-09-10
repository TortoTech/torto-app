/// Boundary conversions between canonical Unicode-scalar source positions and
/// Flutter UTF-16 glyph positions. Never serialize a Flutter offset.
library;

import '../ir/ir.dart';

List<int> inlineDisplayToSource(List<Inline> inlines) {
  final map = <int>[0];
  var scalar = 0;
  for (final run in inlines) {
    switch (run) {
      case TextRun(:final text):
        for (final rune in text.runes) {
          if (rune > 0xffff) map.add(scalar);
          map.add(++scalar);
        }
      case BreakInline(:final synthetic):
        map.add(synthetic ? scalar : ++scalar);
      case MathInline(:final latex):
        map.addAll(List.filled(latex.length, scalar));
      case InlineImageRun():
        map.add(scalar);
    }
  }
  return map;
}

int scalarToUtf16(String text, int scalar) {
  if (scalar < 0) throw const FormatException('Invalid source offset');
  var count = 0, units = 0;
  for (final rune in text.runes) {
    if (count == scalar) return units;
    units += rune > 0xffff ? 2 : 1;
    count++;
  }
  if (count == scalar) return units;
  throw const FormatException('Source offset outside text');
}

int utf16ToScalar(String text, int offset) {
  if (offset < 0 || offset > text.length) {
    throw const FormatException('Source offset outside text');
  }
  if (offset > 0 &&
      offset < text.length &&
      text.codeUnitAt(offset) >= 0xdc00 &&
      text.codeUnitAt(offset) <= 0xdfff) {
    throw const FormatException('Offset splits a surrogate pair');
  }
  return text.substring(0, offset).runes.length;
}
