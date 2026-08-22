/// Tolerant XML decoding/parsing helpers for untrusted EPUB content.
///
/// Real-world EPUB XML is routinely malformed: stray ampersands, HTML named
/// entities (XHTML files referencing external DTDs), DOCTYPE declarations the
/// parser cannot resolve, BOMs. Mirrors torto's recovery strategy in
/// `crates/formats/src/epub.rs` (sanitize, then recover).
library;

import 'dart:convert';

import 'package:xml/xml.dart';

/// Decodes XML bytes to text, handling UTF-8 / UTF-16 BOMs and malformed
/// UTF-8 gracefully.
String decodeXmlBytes(List<int> bytes) {
  if (bytes.length >= 2) {
    if (bytes[0] == 0xFF && bytes[1] == 0xFE) {
      return _decodeUtf16(bytes.sublist(2), littleEndian: true);
    }
    if (bytes[0] == 0xFE && bytes[1] == 0xFF) {
      return _decodeUtf16(bytes.sublist(2), littleEndian: false);
    }
  }
  var body = bytes;
  if (body.length >= 3 &&
      body[0] == 0xEF &&
      body[1] == 0xBB &&
      body[2] == 0xBF) {
    body = body.sublist(3);
  }
  return utf8.decode(body, allowMalformed: true);
}

String _decodeUtf16(List<int> bytes, {required bool littleEndian}) {
  final units = <int>[];
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    units.add(
      littleEndian
          ? bytes[i] | (bytes[i + 1] << 8)
          : (bytes[i] << 8) | bytes[i + 1],
    );
  }
  return String.fromCharCodes(units);
}

/// Strips a leading BOM character and any DOCTYPE declaration (we never
/// resolve external DTDs; internal subsets are dropped with it).
String sanitizeXml(String text) {
  var result = text;
  if (result.startsWith('﻿')) result = result.substring(1);
  return stripDoctype(result);
}

/// Removes `<!DOCTYPE ...>` declarations, tolerating internal subsets.
String stripDoctype(String text) {
  final lower = text.toLowerCase();
  final start = lower.indexOf('<!doctype');
  if (start < 0) return text;
  var i = start + '<!doctype'.length;
  var bracketDepth = 0;
  while (i < text.length) {
    final ch = text[i];
    if (ch == '[') bracketDepth++;
    if (ch == ']') bracketDepth--;
    if (ch == '>' && bracketDepth <= 0) {
      return text.substring(0, start) + text.substring(i + 1);
    }
    i++;
  }
  // Unterminated doctype: drop everything from it onwards.
  return text.substring(0, start);
}

/// Escapes `&` characters that do not start a well-formed XML reference
/// (port of torto's `escape_invalid_xml_ampersands`).
String escapeStrayAmpersands(String xml) {
  final buf = StringBuffer();
  var copiedUntil = 0;
  var index = xml.indexOf('&');
  while (index >= 0) {
    if (_isWellFormedReference(xml, index + 1)) {
      index = xml.indexOf('&', index + 1);
      continue;
    }
    buf
      ..write(xml.substring(copiedUntil, index))
      ..write('&amp;');
    copiedUntil = index + 1;
    index = xml.indexOf('&', index + 1);
  }
  if (copiedUntil == 0) return xml;
  buf.write(xml.substring(copiedUntil));
  return buf.toString();
}

bool _isWellFormedReference(String xml, int start) {
  if (start >= xml.length) return false;
  if (xml.codeUnitAt(start) == 0x23 /* # */ ) {
    var i = start + 1;
    var isHex = false;
    if (i < xml.length && xml.codeUnitAt(i) == 0x78 /* x */ ) {
      isHex = true;
      i++;
    }
    final digitStart = i;
    while (i < xml.length) {
      final c = xml.codeUnitAt(i);
      final ok = isHex
          ? (c >= 0x30 && c <= 0x39) ||
                (c >= 0x41 && c <= 0x46) ||
                (c >= 0x61 && c <= 0x66)
          : c >= 0x30 && c <= 0x39;
      if (!ok) break;
      i++;
    }
    return i > digitStart &&
        i < xml.length &&
        xml.codeUnitAt(i) == 0x3B /* ; */;
  }
  if (!_isNameStart(xml.codeUnitAt(start))) return false;
  var i = start;
  while (i < xml.length && _isNameChar(xml.codeUnitAt(i))) {
    i++;
  }
  return i < xml.length && xml.codeUnitAt(i) == 0x3B /* ; */;
}

bool _isNameStart(int c) =>
    (c >= 0x41 && c <= 0x5A) ||
    (c >= 0x61 && c <= 0x7A) ||
    c == 0x5F ||
    c == 0x3A;

bool _isNameChar(int c) =>
    _isNameStart(c) || (c >= 0x30 && c <= 0x39) || c == 0x2D || c == 0x2E;

/// Common HTML named entities mapped to their Unicode characters. XHTML
/// content authored against the HTML/XHTML DTDs uses these without declaring
/// them, which a strict XML parser rejects.
const Map<String, String> namedEntities = {
  'nbsp': ' ',
  'ensp': ' ',
  'emsp': ' ',
  'thinsp': ' ',
  'shy': '­',
  'mdash': '—',
  'ndash': '–',
  'minus': '−',
  'lsquo': '‘',
  'rsquo': '’',
  'sbquo': '‚',
  'ldquo': '“',
  'rdquo': '”',
  'bdquo': '„',
  'dagger': '†',
  'Dagger': '‡',
  'bull': '•',
  'hellip': '…',
  'prime': '′',
  'Prime': '″',
  'lsaquo': '‹',
  'rsaquo': '›',
  'oline': '‾',
  'frasl': '⁄',
  'euro': '€',
  'trade': '™',
  'copy': '©',
  'reg': '®',
  'sect': '§',
  'para': '¶',
  'middot': '·',
  'laquo': '«',
  'raquo': '»',
  'deg': '°',
  'plusmn': '±',
  'times': '×',
  'divide': '÷',
  'micro': 'µ',
  'iexcl': '¡',
  'iquest': '¿',
  'szlig': 'ß',
  'agrave': 'à',
  'aacute': 'á',
  'acirc': 'â',
  'atilde': 'ã',
  'auml': 'ä',
  'aring': 'å',
  'aelig': 'æ',
  'ccedil': 'ç',
  'egrave': 'è',
  'eacute': 'é',
  'ecirc': 'ê',
  'euml': 'ë',
  'igrave': 'ì',
  'iacute': 'í',
  'icirc': 'î',
  'iuml': 'ï',
  'ntilde': 'ñ',
  'ograve': 'ò',
  'oacute': 'ó',
  'ocirc': 'ô',
  'otilde': 'õ',
  'ouml': 'ö',
  'oslash': 'ø',
  'ugrave': 'ù',
  'uacute': 'ú',
  'ucirc': 'û',
  'uuml': 'ü',
  'yacute': 'ý',
  'yuml': 'ÿ',
  'Agrave': 'À',
  'Aacute': 'Á',
  'Acirc': 'Â',
  'Atilde': 'Ã',
  'Auml': 'Ä',
  'Aring': 'Å',
  'AElig': 'Æ',
  'Ccedil': 'Ç',
  'Egrave': 'È',
  'Eacute': 'É',
  'Ecirc': 'Ê',
  'Euml': 'Ë',
  'Igrave': 'Ì',
  'Iacute': 'Í',
  'Icirc': 'Î',
  'Iuml': 'Ï',
  'Ntilde': 'Ñ',
  'Ograve': 'Ò',
  'Oacute': 'Ó',
  'Ocirc': 'Ô',
  'Otilde': 'Õ',
  'Ouml': 'Ö',
  'Oslash': 'Ø',
  'Ugrave': 'Ù',
  'Uacute': 'Ú',
  'Ucirc': 'Û',
  'Uuml': 'Ü',
  'Yacute': 'Ý',
};

final RegExp _namedEntityPattern = RegExp(r'&([a-zA-Z][a-zA-Z0-9]*);');

/// Replaces known HTML named entities with their Unicode characters.
/// Standard XML entities are left untouched for the XML parser.
String replaceNamedEntities(String xml) {
  return xml.replaceAllMapped(_namedEntityPattern, (match) {
    final name = match.group(1)!;
    if (name == 'lt' || name == 'gt' || name == 'amp' || name == 'quot') {
      return match.group(0)!;
    }
    return namedEntities[name] ?? match.group(0)!;
  });
}

/// Parses [text] as XML with recovery: strip BOM/DOCTYPE, escape stray
/// ampersands, replace HTML named entities (package:xml keeps unknown
/// entities as literal text instead of failing, so this must happen before
/// parsing). Returns null when parsing still fails.
XmlDocument? tryParseXmlTolerant(String text) {
  final sanitized = sanitizeXml(text);
  final recovered = replaceNamedEntities(escapeStrayAmpersands(sanitized));
  try {
    return XmlDocument.parse(recovered);
  } on XmlParserException {
    return null;
  }
}
