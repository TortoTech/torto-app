/// PDF font programs for text extraction.
///
/// Maps character codes to Unicode: ToUnicode CMaps (bfchar/bfrange,
/// codespace ranges) for CID and embedded fonts, plus the standard simple
/// encodings (WinAnsi ≈ cp1252, MacRoman, PDFDoc, Standard) with
/// /Differences overrides for a common glyph-name subset.
library;

import 'dart:typed_data';

import 'pdf_decode.dart';
import 'pdf_syntax.dart';

/// Decoded bytes of a font's text-mapping machinery.
class PdfFontMap {
  /// code (1–4 bytes, big-endian) → Unicode string.
  final Map<int, String> mappings;

  /// (low, high) inclusive codespace ranges; byte width per range.
  final List<(int, int, int)> codeSpaces;

  const PdfFontMap(this.mappings, this.codeSpaces);

  /// Byte width for the first codespace range (1 or 2).
  int get codeWidth => codeSpaces.isEmpty ? 1 : codeSpaces.first.$3;

  String? lookup(int code) => mappings[code];
}

/// Builds the mapping table for a font dictionary.
PdfFontMap buildFontMap(PdfDict font, PdfObject? Function(PdfRef) resolve) {
  final mappings = <int, String>{};
  final codeSpaces = <(int, int, int)>[];

  final toUnicode = resolveDeep(font['ToUnicode'], resolve);
  if (toUnicode is PdfStream) {
    _parseCMap(_streamBytes(toUnicode, resolve), mappings, codeSpaces);
  }

  final subtype = resolveDeep(font['Subtype'], resolve);
  final isType0 = subtype is PdfName && subtype.name == 'Type0';
  if (codeSpaces.isEmpty) {
    if (isType0) {
      // Identity-H and friends default to a 2-byte codespace.
      final encoding = resolveDeep(font['Encoding'], resolve);
      final encodingName = encoding is PdfName ? encoding.name : '';
      final width =
          encodingName.startsWith('Identity') ||
              encodingName.startsWith('Uni') ||
              _twoByteEncoding(encodingName)
          ? 2
          : 1;
      codeSpaces.add((0, (1 << (8 * width)) - 1, width));
    } else {
      codeSpaces.add((0, 0xFF, 1));
    }
  }

  if (!isType0) {
    _applySimpleEncoding(font, mappings, resolve);
  }
  return PdfFontMap(mappings, codeSpaces);
}

bool _twoByteEncoding(String name) => switch (name) {
  'GB-EUC-H' ||
  'GB-EUC-V' ||
  'GBK-EUC-H' ||
  'GBK2K-H' ||
  'B5pc-H' ||
  'ETen-B5-H' ||
  '90ms-RKSJ-H' ||
  'KSC-EUC-H' => true,
  _ => false,
};

Uint8List _streamBytes(PdfStream stream, PdfObject? Function(PdfRef) resolve) {
  try {
    return decodeStream(stream, resolve);
  } on FormatException {
    return Uint8List(0);
  }
}

/// Parses a CMap program: codespacerange / bfchar / bfrange sections.
void _parseCMap(
  Uint8List bytes,
  Map<int, String> mappings,
  List<(int, int, int)> codeSpaces,
) {
  final tokens = _CMapLexer(bytes).tokenize();
  var index = 0;

  void addCodeSpace(int low, int high) {
    final width = _byteWidth(high == 0 ? low : high);
    codeSpaces.add((low, high, width));
  }

  while (index < tokens.length) {
    final token = tokens[index];
    if (token is! _CMapName) {
      index++;
      continue;
    }
    switch (token.name) {
      case 'begincodespacerange':
        index++;
        while (index + 1 < tokens.length && tokens[index] is _CMapHexString) {
          final low = (tokens[index] as _CMapHexString).value;
          final high = (tokens[index + 1] as _CMapHexString).value;
          addCodeSpace(low, high);
          index += 2;
          // Consume the end marker if present.
          while (index < tokens.length && tokens[index] is _CMapInt) {
            index++;
          }
          if (index < tokens.length &&
              tokens[index] is _CMapName &&
              (tokens[index] as _CMapName).name == 'endcodespacerange') {
            index++;
          }
        }
      case 'beginbfchar':
        index++;
        while (index + 1 < tokens.length && tokens[index] is _CMapHexString) {
          final code = (tokens[index] as _CMapHexString).value;
          final value = _destinationText(tokens[index + 1]);
          if (value != null) mappings[code] = value;
          index += 2;
          while (index < tokens.length && tokens[index] is _CMapInt) {
            index++;
          }
          if (index < tokens.length &&
              tokens[index] is _CMapName &&
              (tokens[index] as _CMapName).name == 'endbfchar') {
            index++;
          }
        }
      case 'beginbfrange':
        index++;
        // [low high dst] or [low high [d1 d2 …]] possibly with /UseCMap.
        while (index + 2 < tokens.length && tokens[index] is _CMapHexString) {
          final low = (tokens[index] as _CMapHexString).value;
          final high = (tokens[index + 1] as _CMapHexString).value;
          final third = tokens[index + 2];
          if (third is _CMapHexString) {
            var base = third.value;
            final width = third.digits ~/ 2; // bytes in destination
            for (var code = low; code <= high && code - low < 65536; code++) {
              mappings[code] = _unicodeFromCode(base, width);
              base++;
            }
          } else if (third is _CMapArray) {
            for (
              var code = low;
              code <= high && code - low < third.items.length;
              code++
            ) {
              final text = _destinationText(third.items[code - low]);
              if (text != null) mappings[code] = text;
            }
          } else {
            break;
          }
          index += 3;
          while (index < tokens.length && tokens[index] is _CMapInt) {
            index++;
          }
          if (index < tokens.length &&
              tokens[index] is _CMapName &&
              (tokens[index] as _CMapName).name == 'endbfrange') {
            index++;
          }
        }
      default:
        index++;
    }
  }
}

String _unicodeFromCode(int code, int width) {
  if (width >= 2) {
    // UTF-16BE unit (surrogates handled by fromCharCodes' replacement).
    return String.fromCharCode(code & 0xFFFF);
  }
  return String.fromCharCode(code & 0xFF);
}

String? _destinationText(_CMapToken token) {
  if (token is _CMapHexString) {
    final bytes = token.valueBytes;
    if (bytes.length == 2) {
      return String.fromCharCode((bytes[0] << 8) | bytes[1]);
    }
    if (bytes.length >= 4) {
      final units = <int>[];
      for (var i = 0; i + 1 < bytes.length; i += 2) {
        units.add((bytes[i] << 8) | bytes[i + 1]);
      }
      return String.fromCharCodes(units);
    }
    if (bytes.isNotEmpty) return String.fromCharCode(bytes[0]);
    return null;
  }
  if (token is _CMapName) return _glyphNameUnicode(token.name);
  return null;
}

int _byteWidth(int value) {
  var width = 1;
  while (value > 0xFF) {
    value >>= 8;
    width++;
  }
  return width.clamp(1, 4);
}

// ----------------------------------------------------------- simple encodings

void _applySimpleEncoding(
  PdfDict font,
  Map<int, String> mappings,
  PdfObject? Function(PdfRef) resolve,
) {
  // Only fill gaps: ToUnicode entries win.
  void fill(int code, String text) => mappings.putIfAbsent(code, () => text);

  final encoding = resolveDeep(font['Encoding'], resolve);
  PdfName? encodingName;
  PdfDict? differences;
  if (encoding is PdfName) {
    encodingName = encoding;
  } else if (encoding is PdfDict) {
    final base = resolveDeep(encoding['BaseEncoding'], resolve);
    if (base is PdfName) encodingName = base;
    differences = encoding;
  }

  switch (encodingName?.name) {
    case 'WinAnsiEncoding':
      for (var code = 0; code < 256; code++) {
        fill(code, _winAnsiChar(code));
      }
    case 'MacRomanEncoding':
      for (var code = 0; code < 128; code++) {
        fill(code, String.fromCharCode(code));
      }
      for (final entry in _macRomanHigh.entries) {
        fill(entry.key, entry.value);
      }
    case 'StandardEncoding' || 'PDFDocEncoding' || null:
      for (var code = 0x20; code < 0x7F; code++) {
        fill(code, String.fromCharCode(code));
      }
      for (final entry in _pdfDocHigh.entries) {
        fill(entry.key, entry.value);
      }
    default:
      for (var code = 0x20; code < 0x7F; code++) {
        fill(code, String.fromCharCode(code));
      }
  }

  final diffs = resolveDeep(differences?['Differences'], resolve);
  if (diffs is PdfArray) {
    var code = 0;
    for (final item in diffs.items) {
      final value = resolveDeep(item, resolve);
      if (value is PdfNum && value.isInteger) {
        code = value.asInt;
      } else if (value is PdfName) {
        final text = _glyphNameUnicode(value.name);
        if (text != null) mappings[code] = text;
        code++;
      }
    }
  }
}

String _winAnsiChar(int code) {
  if (code < 0x80 || code >= 0xA0) return String.fromCharCode(code);
  const high = [
    '€',
    '',
    '‚',
    'ƒ',
    '„',
    '…',
    '†',
    '‡',
    'ˆ',
    '‰',
    'Š',
    '‹',
    'Œ',
    '',
    'Ž',
    '',
    '',
    '‘',
    '’',
    '“',
    '”',
    '•',
    '–',
    '—',
    '˜',
    '™',
    'š',
    '›',
    'œ',
    '',
    'ž',
    'Ÿ',
  ];
  final text = high[code - 0x80];
  return text.isEmpty ? String.fromCharCode(code) : text;
}

const Map<int, String> _pdfDocHigh = {
  0x18: '\u02D8',
  0x19: '\u02C7',
  0x1A: '\u02C6',
  0x1B: '\u02D9',
  0x1C: '\u02DD',
  0x1D: '\u02DB',
  0x1E: '\u02DA',
  0x1F: '\u02DC',
  0x80: '\u2022',
  0x81: '\u2020',
  0x82: '\u2021',
  0x83: '\u2026',
  0x84: '\u2014',
  0x85: '\u2013',
  0x86: '\u0192',
  0x87: '\u2044',
  0x88: '\u2039',
  0x89: '\u203A',
  0x8A: '\u2212',
  0x8B: '\u2030',
  0x8C: '\u201E',
  0x8D: '\u201C',
  0x8E: '\u201D',
  0x8F: '\u2018',
  0x90: '\u2019',
  0x91: '\u201A',
  0x92: '\u2122',
  0x93: '\uFB01',
  0x94: '\uFB02',
  0x95: '\u0141',
  0x96: '\u0152',
  0x97: '\u0160',
  0x98: '\u0178',
  0x99: '\u017D',
  0x9A: '\u0131',
  0x9B: '\u0142',
  0x9C: '\u0153',
  0x9D: '\u0161',
  0x9E: '\u017E',
  0xA0: '\u20AC',
};

const Map<int, String> _macRomanHigh = {
  0x80: 'Ä',
  0x81: 'Å',
  0x82: 'Ç',
  0x83: 'É',
  0x84: 'Ñ',
  0x85: 'Ö',
  0x86: 'Ü',
  0x87: 'á',
  0x88: 'à',
  0x89: 'â',
  0x8A: 'ä',
  0x8B: 'ã',
  0x8C: 'å',
  0x8D: 'ç',
  0x8E: 'é',
  0x8F: 'è',
  0x90: 'ê',
  0x91: 'ë',
  0x92: 'í',
  0x93: 'ì',
  0x94: 'î',
  0x95: 'ï',
  0x96: 'í',
  0x97: 'ñ',
  0x98: 'ó',
  0x99: 'ò',
  0x9A: 'ô',
  0x9B: 'ö',
  0x9C: 'õ',
  0x9D: 'ú',
  0x9E: 'ù',
  0x9F: 'û',
  0xA0: 'ü',
  0xA1: '†',
  0xA2: '°',
  0xA3: '¢',
  0xA4: '£',
  0xA5: '§',
  0xA6: '•',
  0xA7: '¶',
  0xA8: 'ß',
  0xA9: '®',
  0xAA: '©',
  0xAB: '™',
  0xAC: '´',
  0xAD: '¨',
  0xAE: '≠',
  0xAF: 'Æ',
  0xB0: 'Ø',
  0xB1: '∞',
  0xB2: '±',
  0xB3: '≤',
  0xB4: '≥',
  0xB5: '¥',
  0xB6: 'µ',
  0xB7: '∂',
  0xB8: '∑',
  0xB9: '∏',
  0xBA: 'π',
  0xBB: '∫',
  0xBC: 'ª',
  0xBD: 'º',
  0xBE: 'Ω',
  0xBF: 'æ',
  0xC0: 'ø',
  0xC1: '¿',
  0xC2: '¡',
  0xC3: '¬',
  0xC4: '√',
  0xC5: 'ƒ',
  0xC6: '≈',
  0xC7: '∆',
  0xC8: '«',
  0xC9: '»',
  0xCA: '…',
  0xCB: '\u00A0',
  0xCC: 'À',
  0xCD: 'Ã',
  0xCE: 'Õ',
  0xCF: 'Œ',
  0xD0: 'œ',
  0xD1: '–',
  0xD2: '—',
  0xD3: '“',
  0xD4: '”',
  0xD5: '‘',
  0xD6: '’',
  0xD7: '÷',
  0xD8: '◊',
  0xD9: 'ÿ',
  0xDA: 'Ÿ',
  0xDB: '⁄',
  0xDC: '€',
  0xDD: '‹',
  0xDE: '›',
  0xDF: 'ﬁ',
  0xE0: 'ﬂ',
  0xE1: '‡',
  0xE2: '·',
  0xE3: '‚',
  0xE4: '„',
  0xE5: '‰',
  0xE6: 'Â',
  0xE7: 'Ê',
  0xE8: 'Á',
  0xE9: 'Ë',
  0xEA: 'È',
  0xEB: 'Í',
  0xEC: 'Î',
  0xED: 'Ï',
  0xEE: 'Ì',
  0xEF: 'Ó',
  0xF0: 'Ô',
  0xF1: '\u0088',
  0xF2: 'Ò',
  0xF3: '\u008D',
  0xF4: 'Ù',
  0xF5: 'Û',
  0xF6: 'Ù',
  0xF7: 'ˆ',
  0xF8: '˜',
  0xF9: '¯',
  0xFA: '˘',
  0xFB: '˙',
  0xFC: '˚',
  0xFD: '¸',
  0xFE: '˝',
  0xFF: '˛',
};

/// Common AGL glyph names (subset; null → fallback to '?' at call site).
String? _glyphNameUnicode(String name) {
  if (name.isEmpty) return null;
  if (name.length == 1) return name;
  const names = <String, String>{
    'space': ' ',
    'exclam': '!',
    'quotedbl': '"',
    'numbersign': '#',
    'dollar': '\$',
    'percent': '%',
    'ampersand': '&',
    'quotesingle': "'",
    'parenleft': '(',
    'parenright': ')',
    'asterisk': '*',
    'plus': '+',
    'comma': ',',
    'hyphen': '-',
    'period': '.',
    'slash': '/',
    'colon': ':',
    'semicolon': ';',
    'less': '<',
    'equal': '=',
    'greater': '>',
    'question': '?',
    'at': '@',
    'bracketleft': '[',
    'backslash': '\\',
    'bracketright': ']',
    'asciicircum': '^',
    'underscore': '_',
    'grave': '`',
    'braceleft': '{',
    'bar': '|',
    'braceright': '}',
    'asciitilde': '~',
    'fi': 'ﬁ',
    'fl': 'ﬂ',
    'quoteright': '’',
    'quoteleft': '‘',
    'quotesingle002': '’',
    'quotedblleft': '“',
    'quotedblright': '”',
    'endash': '–',
    'emdash': '—',
    'bullet': '•',
    'dagger': '†',
    'daggerdbl': '‡',
    'ellipsis': '…',
    'perthousand': '‰',
    'guillemotleft': '«',
    'guillemotright': '»',
    'guilsinglleft': '‹',
    'guilsinglright': '›',
    'fraction': '⁄',
    'Euro': '€',
    'trademark': '™',
    'copyright': '©',
    'registered': '®',
    'mu': 'µ',
    'afii61352': '…',
    'nbspace': '\u00A0',
    'minus': '−',
    'periodcentered': '·',
    'onedotenleader': '‥',
    'twodotenleader': '…',
    'zcaron': 'ž',
    'Zcaron': 'Ž',
    'scaron': 'š',
    'Scaron': 'Š',
    'oe': 'œ',
    'OE': 'Œ',
    'ae': 'æ',
    'AE': 'Æ',
  };
  return names[name] ?? _unicodedGlyph(name);
}

String? _unicodedGlyph(String name) {
  // uniXXXX → U+XXXX; uXXXXXX → U+XXXXXX.
  if (name.startsWith('uni') && name.length == 7) {
    final code = int.tryParse(name.substring(3), radix: 16);
    if (code != null) return String.fromCharCode(code);
  }
  if (name.startsWith('u') && name.length >= 5 && name.length <= 8) {
    final dash = name.indexOf('.');
    var hex = dash > 0 ? name.substring(1, dash) : name.substring(1);
    if (hex.length == 4 || hex.length == 6) {
      final code = int.tryParse(hex, radix: 16);
      if (code != null) return String.fromCharCode(code);
    }
  }
  return null;
}

// ---------------------------------------------------------------- CMap lexer

sealed class _CMapToken {
  const _CMapToken();
}

class _CMapName extends _CMapToken {
  final String name;

  const _CMapName(this.name);
}

class _CMapInt extends _CMapToken {
  const _CMapInt();
}

class _CMapHexString extends _CMapToken {
  final int value;
  final int digits;

  const _CMapHexString(this.value, this.digits);

  Uint8List get valueBytes {
    var v = value;
    final bytes = <int>[];
    final width = (digits + 1) ~/ 2;
    for (var i = width - 1; i >= 0; i--) {
      bytes.insert(0, v & 0xFF);
      v >>= 8;
    }
    return Uint8List.fromList(bytes);
  }
}

class _CMapArray extends _CMapToken {
  final List<_CMapToken> items;

  const _CMapArray(this.items);
}

class _CMapLexer {
  final Uint8List data;

  const _CMapLexer(this.data);

  List<_CMapToken> tokenize() {
    final tokens = <_CMapToken>[];
    var position = 0;
    int? hexStart;
    final hexDigits = StringBuffer();

    void flushHex() {
      if (hexDigits.isNotEmpty) {
        final text = hexDigits.toString();
        final padded = text.length.isOdd ? '${text}0' : text;
        final value = int.tryParse(padded, radix: 16);
        if (value != null) {
          tokens.add(_CMapHexString(value, padded.length));
        }
        hexDigits.clear();
      }
      hexStart = null;
    }

    void lexName(int start, int end) {
      final raw = String.fromCharCodes(data.sublist(start, end));
      // Strip '#' escapes.
      final buffer = StringBuffer();
      for (var i = 0; i < raw.length; i++) {
        if (raw.codeUnitAt(i) == 0x23 && i + 2 < raw.length + 1) {
          final hex = int.tryParse(raw.substring(i + 1, i + 3), radix: 16);
          if (hex != null) {
            buffer.writeCharCode(hex);
            i += 2;
            continue;
          }
        }
        buffer.write(raw[i]);
      }
      final name = buffer.toString();
      if (name.startsWith('/') && name.length > 1) {
        tokens.add(_CMapName(name.substring(1)));
      } else if (name.startsWith('/')) {
        tokens.add(const _CMapName(''));
      } else if (int.tryParse(name) != null) {
        tokens.add(const _CMapInt());
      } else {
        tokens.add(_CMapName(name));
      }
    }

    while (position < data.length) {
      final byte = data[position];
      if (byte == 0x3C /* < */ ) {
        if (position + 1 < data.length && data[position + 1] == 0x3C) {
          flushHex();
          position = _skipDict(position);
          continue;
        }
        flushHex();
        hexStart = position;
        position++;
      } else if (byte == 0x3E /* > */ ) {
        flushHex();
        position++;
      } else if (hexStart != null &&
          ((byte >= 0x30 && byte <= 0x39) ||
              (byte >= 0x41 && byte <= 0x46) ||
              (byte >= 0x61 && byte <= 0x66))) {
        hexDigits.writeCharCode(byte);
        position++;
      } else if (byte == 0x2F /* / */ || _isNameByte(byte)) {
        flushHex();
        final start = byte == 0x2F ? position + 1 : position;
        var end = start;
        while (end < data.length && _isNameByte(data[end])) {
          end++;
        }
        lexName(start, end);
        position = end;
      } else if (byte == 0x5B /* [ */ ) {
        flushHex();
        // Collect the array inline until matching ']'.
        final sub = _CMapLexer(
          Uint8List.sublistView(data, position + 1, _matchingBracket(position)),
        ).tokenize();
        tokens.add(_CMapArray(sub));
        position = _matchingBracket(position) + 1;
      } else if (byte == 0x28 /* ( */ ) {
        flushHex();
        position = _skipLiteralString(position);
      } else {
        flushHex();
        position++;
      }
    }
    flushHex();
    return tokens;
  }

  static bool _isNameByte(int byte) =>
      byte > 0x20 &&
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

  int _skipDict(int from) {
    var depth = 0;
    var position = from;
    while (position + 1 < data.length) {
      if (data[position] == 0x3C && data[position + 1] == 0x3C) {
        depth++;
        position += 2;
      } else if (data[position] == 0x3E && data[position + 1] == 0x3E) {
        depth--;
        position += 2;
        if (depth == 0) return position;
      } else {
        position++;
      }
    }
    return position;
  }

  int _skipLiteralString(int from) {
    var depth = 1;
    var position = from + 1;
    while (position < data.length && depth > 0) {
      final byte = data[position];
      if (byte == 0x5C) {
        position += 2;
        continue;
      }
      if (byte == 0x28) depth++;
      if (byte == 0x29) depth--;
      position++;
    }
    return position;
  }

  int _matchingBracket(int from) {
    var depth = 1;
    var position = from + 1;
    while (position < data.length && depth > 0) {
      final byte = data[position];
      if (byte == 0x28) {
        position = _skipLiteralString(position);
        continue;
      }
      if (byte == 0x5B) depth++;
      if (byte == 0x5D) depth--;
      position++;
    }
    return position > data.length ? data.length : position;
  }
}
