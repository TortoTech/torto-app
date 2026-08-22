/// PDF content-stream text extraction.
///
/// A deliberately small interpreter of the text operators (BT/ET, Tf, Tm,
/// Td/TD/T*/TL, Tc/Tw, Tj/TJ/'/") that records positioned text runs and
/// assembles them into paragraphs: runs group into lines by y proximity
/// (lines read top-down since PDF y is up), gaps become spaces, and line
/// spacing becomes paragraph breaks.
library;

import 'dart:typed_data';

import 'pdf_decode.dart' show resolveDeep;
import 'pdf_fonts.dart';
import 'pdf_syntax.dart';

class _TextRun {
  final double x;
  final double y;
  final double size;
  final String text;

  const _TextRun(this.x, this.y, this.size, this.text);
}

/// Extracts the text of one page as paragraphs.
List<String> extractPageText(
  Uint8List content,
  PdfObject? resources,
  PdfObject? Function(PdfRef) resolve,
) {
  final fonts = _loadResourcesFonts(resources, resolve);
  final runs = _interpret(content, fonts);
  if (runs.isEmpty) return const [];
  return _assembleParagraphs(runs);
}

Map<String, PdfFontMap> _loadResourcesFonts(
  PdfObject? resources,
  PdfObject? Function(PdfRef) resolve,
) {
  final resolved = resolveDeep(resources, resolve);
  if (resolved is! PdfDict) return const {};
  final fontDict = resolveDeep(resolved['Font'], resolve);
  if (fontDict is! PdfDict) return const {};
  final maps = <String, PdfFontMap>{};
  fontDict.entries.forEach((name, value) {
    final font = resolveDeep(value, resolve);
    if (font is PdfDict) {
      try {
        maps[name] = buildFontMap(font, resolve);
      } on FormatException {
        // Font we cannot map: its text shows as gaps, not a dead page.
      }
    }
  });
  return maps;
}

List<_TextRun> _interpret(Uint8List content, Map<String, PdfFontMap> fonts) {
  final runs = <_TextRun>[];
  var font = const PdfFontMap({}, []);
  var fontSize = 12.0;

  // Text matrix translation (x, y) — tracked through Tm/Td/T*/'.
  var textX = 0.0, textY = 0.0;
  var lineX = 0.0, lineY = 0.0;
  var leading = 0.0;
  var inText = false;

  String decode(Uint8List bytes) {
    final width = font.codeWidth;
    final buffer = StringBuffer();
    for (var i = 0; i < bytes.length;) {
      var code = bytes[i];
      var consumed = 1;
      if (width == 2 && i + 1 < bytes.length) {
        code = (code << 8) | bytes[i + 1];
        consumed = 2;
      } else if (width > 2 && i + width <= bytes.length) {
        code = 0;
        for (var j = 0; j < width; j++) {
          code = (code << 8) | bytes[i + j];
        }
        consumed = width;
      }
      final mapped = font.lookup(code);
      if (mapped != null && mapped.isNotEmpty) {
        buffer.write(mapped);
      } else if (code >= 0x20 && code <= 0x7E) {
        buffer.writeCharCode(code);
      } else if (width == 1 && code >= 0xA0 && code != 0xAD) {
        buffer.writeCharCode(code);
      }
      // Unmapped codes in 2-byte fonts are dropped (subset glyphs).
      i += consumed;
    }
    return buffer.toString();
  }

  void show(Uint8List bytes) {
    final text = decode(bytes);
    if (text.isEmpty) return;
    runs.add(_TextRun(textX, textY, fontSize, text));
  }

  void showArray(List<PdfObject> items) {
    final buffer = StringBuffer();
    for (final item in items) {
      if (item is PdfString) {
        buffer.write(decode(item.bytes));
      } else if (item is PdfNum) {
        final shift = item.value;
        // Negative numbers open gaps (kern): a sizable gap reads as a space.
        if (shift < -0.08 * fontSize &&
            buffer.isNotEmpty &&
            !_endsWithSpace(buffer.toString())) {
          buffer.write(' ');
        }
      }
    }
    final text = buffer.toString();
    if (text.isNotEmpty) {
      runs.add(_TextRun(textX, textY, fontSize, text));
    }
  }

  final lexer = _ContentLexer(content);
  final operands = <PdfObject>[];
  while (true) {
    final operator = lexer.next();
    if (operator == null) break;
    operands.clear();
    lexer.drainOperands(operands);
    switch (operator) {
      case 'BT':
        inText = true;
        textX = lineX = 0;
        textY = lineY = 0;
        continue;
      case 'ET':
        inText = false;
        continue;
      case 'Tf':
        if (operands.length >= 2) {
          final name = operands[0];
          final size = operands[1];
          if (name is PdfName) {
            font = fonts[name.name] ?? const PdfFontMap({}, []);
          }
          if (size is PdfNum) fontSize = size.value.abs().clamp(1.0, 400.0);
        }
      case 'Tm':
        if (operands.length >= 6) {
          final e = operands[4];
          final f = operands[5];
          if (e is PdfNum && f is PdfNum) {
            lineX = textX = e.value;
            lineY = textY = f.value;
          }
        }
      case 'Td':
        if (operands.length >= 2) {
          final tx = operands[0];
          final ty = operands[1];
          if (tx is PdfNum && ty is PdfNum) {
            lineX += tx.value;
            lineY += ty.value;
            textX = lineX;
            textY = lineY;
          }
        }
      case 'TD':
        if (operands.length >= 2) {
          final tx = operands[0];
          final ty = operands[1];
          if (tx is PdfNum && ty is PdfNum) {
            leading = -ty.value;
            lineX += tx.value;
            lineY += ty.value;
            textX = lineX;
            textY = lineY;
          }
        }
      case 'TL':
        if (operands.isNotEmpty && operands[0] is PdfNum) {
          leading = (operands[0] as PdfNum).value;
        }
      case 'Tc':
      case 'Tw':
        // Char/word spacing only affects gap sizing; ignored.
        break;
      case 'T*':
        lineY -= leading;
        textX = lineX;
        textY = lineY;
      case 'Tj':
        if (inText && operands.isNotEmpty && operands[0] is PdfString) {
          show((operands[0] as PdfString).bytes);
        }
      case 'TJ':
        if (inText && operands.isNotEmpty && operands[0] is PdfArray) {
          showArray((operands[0] as PdfArray).items);
        }
      case "'":
        if (inText && operands.isNotEmpty && operands[0] is PdfString) {
          lineY -= leading;
          textX = lineX;
          textY = lineY;
          show((operands[0] as PdfString).bytes);
        }
      case '"':
        if (inText && operands.length >= 3 && operands[2] is PdfString) {
          lineY -= leading;
          textX = lineX;
          textY = lineY;
          show((operands[2] as PdfString).bytes);
        }
      default:
        break;
    }
  }
  return runs;
}

bool _endsWithSpace(String text) =>
    text.isNotEmpty && (text.endsWith(' ') || text.endsWith('\u00A0'));

// ------------------------------------------------------------- line assembly

List<String> _assembleParagraphs(List<_TextRun> runs) {
  // Group runs into lines by y proximity (page order: top = larger y).
  final lines = <_Line>[];
  final sorted = [...runs]
    ..sort((a, b) {
      final byY = b.y.compareTo(a.y);
      return byY != 0 ? byY : a.x.compareTo(b.x);
    });
  for (final run in sorted) {
    final last = lines.isEmpty ? null : lines.last;
    if (last != null && (last.y - run.y).abs() <= run.size * 0.45) {
      last.runs.add(run);
    } else {
      lines.add(_Line(run.y)..runs.add(run));
    }
  }
  lines.sort((a, b) => b.y.compareTo(a.y));
  for (final line in lines) {
    line.runs.sort((a, b) => a.x.compareTo(b.x));
  }

  // Merge runs within a line, inserting spaces at horizontal gaps.
  final lineTexts = <({String text, double x, double size, double y})>[];
  for (final line in lines) {
    final buffer = StringBuffer();
    _TextRun? previous;
    for (final run in line.runs) {
      if (previous != null) {
        final estimate = previous.text.length * previous.size * 0.5;
        final expectedX = previous.x + estimate;
        final dx = run.x - expectedX;
        final bothCjk = _endsWithCjk(previous.text) && _startsWithCjk(run.text);
        if (dx > previous.size * 0.22 &&
            !_endsWithSpace(buffer.toString()) &&
            !bothCjk) {
          buffer.write(' ');
        }
      }
      buffer.write(run.text);
      previous = run;
    }
    var text = buffer.toString();
    text = text.replaceAll('\u00A0', ' ');
    text = text.split(RegExp(r'\s+')).join(' ').trim();
    if (text.isNotEmpty) {
      lineTexts.add((
        text: text,
        x: line.runs.first.x,
        size: line.runs.first.size,
        y: line.y,
      ));
    }
  }
  if (lineTexts.isEmpty) return const [];

  // Paragraphs: consecutive lines with tight spacing merge.
  final paragraphs = <String>[];
  final buffer = StringBuffer();
  var previous = lineTexts.first;
  buffer.write(previous.text);
  for (final line in lineTexts.skip(1)) {
    final gap = previous.y - line.y;
    final lineHeight = (previous.size + line.size) / 2;
    final newParagraph =
        gap > lineHeight * 1.7 ||
        _startsParagraph(line.text) ||
        !_endsWithContinuation(previous.text, line.text);
    if (newParagraph) {
      paragraphs.add(buffer.toString());
      buffer
        ..clear()
        ..write(line.text);
    } else {
      buffer.write(_joinText(previous.text, line.text));
    }
    previous = line;
  }
  if (buffer.isNotEmpty) paragraphs.add(buffer.toString());
  return paragraphs;
}

class _Line {
  final double y;
  final List<_TextRun> runs = [];

  _Line(this.y);
}

bool _endsWithCjk(String text) {
  if (text.isEmpty) return false;
  final code = text.codeUnitAt(text.length - 1);
  return code >= 0x2E80 && code <= 0x9FFF || code >= 0x3400 && code <= 0x4DBF;
}

bool _startsWithCjk(String text) {
  if (text.isEmpty) return false;
  final code = text.codeUnitAt(0);
  return code >= 0x2E80 && code <= 0x9FFF || code >= 0x3400 && code <= 0x4DBF;
}

/// Heading-ish or list-marker openers start a new paragraph.
bool _startsParagraph(String text) {
  if (text.length < 2) return false;
  if (RegExp(r'^[•·▪‣⁃-]\s').hasMatch(text)) return true;
  if (RegExp(r'^[0-9]+[.、)]\s?').hasMatch(text) && text.length > 3) {
    return true;
  }
  if (RegExp(r'^[一二三四五六七八九十]+[、.]\s?').hasMatch(text)) return true;
  return false;
}

bool _endsWithContinuation(String previous, String next) {
  // A hyphen at the line end joins words.
  if (previous.endsWith('-')) return true;
  final prevLast = previous.isEmpty
      ? ' '
      : previous.substring(previous.length - 1);
  final nextFirst = next.isEmpty ? ' ' : next.substring(0, 1);
  // Latin: continuation when the previous line doesn't end a sentence.
  final endsSentence = RegExp(
    r'[.!?。！？：:;；]["”』）)]?$',
  ).hasMatch(previous.trimRight());
  if (_isLatin(prevLast) && _isLatin(nextFirst)) {
    return !endsSentence;
  }
  // CJK flows across lines unless the previous line closes a sentence.
  return !endsSentence;
}

String _joinText(String previous, String next) {
  if (previous.endsWith('-')) {
    final stem = previous.substring(0, previous.length - 1);
    if (_isLatin(next.substring(0, 1))) return '$stem${next.trimLeft()}';
  }
  final prevLast = previous.substring(previous.length - 1);
  final nextFirst = next.substring(0, 1);
  if (_endsWithCjk(previous) && _startsWithCjk(next)) {
    return '$previous$next'; // no space between CJK characters
  }
  if (_isLatin(prevLast) && _isLatin(nextFirst)) return '$previous $next';
  return '$previous $next';
}

bool _isLatin(String character) {
  if (character.isEmpty) return false;
  final code = character.codeUnitAt(0);
  return code < 0x2E80;
}

// ------------------------------------------------------------ content lexer

/// Streams (operator, operands) from a content stream: operands accumulate
/// on the caller's stack; operators are returned one per [next].
class _ContentLexer {
  final Uint8List data;
  int position = 0;

  _ContentLexer(this.data);

  String? next() {
    while (position < data.length) {
      final byte = data[position];
      if (_isWhitespace(byte) || byte == 0x25 /* % */ ) {
        _skipWhitespaceOrComment();
        continue;
      }
      // Operand starters: parse with the object parser and drop the value;
      // the caller collects operands through [drainOperands].
      if (byte == 0x28 ||
          byte == 0x3C ||
          byte == 0x5B ||
          byte == 0x7B ||
          byte == 0x2F ||
          (byte >= 0x30 && byte <= 0x39) ||
          byte == 0x2B ||
          byte == 0x2D ||
          byte == 0x2E) {
        final parser = PdfParser(data, position);
        final object = parser.parseObject();
        if (object != null && object is! PdfNull) {
          _pendingOperands.add(object);
          position = parser.position;
          continue;
        }
        position = parser.position;
        continue;
      }
      // Keyword operator.
      final start = position;
      while (position < data.length && _isRegular(data[position])) {
        position++;
      }
      if (position == start) {
        position++;
        continue;
      }
      return String.fromCharCodes(data.sublist(start, position));
    }
    return null;
  }

  final List<PdfObject> _pendingOperands = [];

  /// Moves pending operands collected since the last operator to [target].
  void drainOperands(List<PdfObject> target) {
    target.addAll(_pendingOperands);
    _pendingOperands.clear();
  }

  void _skipWhitespaceOrComment() {
    while (position < data.length) {
      final byte = data[position];
      if (_isWhitespace(byte)) {
        position++;
      } else if (byte == 0x25) {
        while (position < data.length &&
            data[position] != 0x0A &&
            data[position] != 0x0D) {
          position++;
        }
      } else {
        return;
      }
    }
  }

  static bool _isWhitespace(int byte) =>
      byte == 0x00 ||
      byte == 0x09 ||
      byte == 0x0A ||
      byte == 0x0C ||
      byte == 0x0D ||
      byte == 0x20;

  static bool _isRegular(int byte) =>
      !_isWhitespace(byte) &&
      byte != 0x28 &&
      byte != 0x29 &&
      byte != 0x3C &&
      byte != 0x3E &&
      byte != 0x5B &&
      byte != 0x5D &&
      byte != 0x7B &&
      byte != 0x7D &&
      byte != 0x2F &&
      byte != 0x25;
}
