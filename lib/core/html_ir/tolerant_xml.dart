/// Tolerant XML decoding/parsing helpers for untrusted EPUB content.
///
/// Real-world EPUB XML is routinely malformed: stray ampersands, HTML named
/// entities (XHTML files referencing external DTDs), DOCTYPE declarations the
/// parser cannot resolve, BOMs. Mirrors torto's recovery strategy in
/// `crates/formats/src/epub.rs` (sanitize, then recover).
library;

import 'dart:convert';

import 'package:xml/xml.dart';
import 'package:html/parser.dart' as html;
import 'package:html/dom.dart' as dom;

final _opaqueXml = RegExp(r'<!--[\s\S]*?-->|<!\[CDATA\[[\s\S]*?\]\]>');

/// Chapter-only HTML recovery. Package metadata and FB2 keep strict XML rules.
XmlDocument? tryParsePublicationContent(String text) {
  if (text.length > 2 * 1024 * 1024) return null;
  final declarations = text.replaceAll(_opaqueXml, '');
  if (RegExp(
    r'<!ENTITY|<!DOCTYPE[^>]*\[',
    caseSensitive: false,
  ).hasMatch(declarations)) {
    return null;
  }
  // Token counting respects comments, CDATA, quoted attributes and HTML's
  // optional sibling end tags; a thousand <p> siblings are not thousand-deep.
  final tokens = RegExp(
    r"""<!--[\s\S]*?-->|<!\[CDATA\[[\s\S]*?\]\]>|<(/?)([A-Za-z][\w:.-]*)\b(?:"[^"]*"|'[^']*'|[^'"<>])*>""",
  ).allMatches(text);
  const voids = {
    'area',
    'base',
    'br',
    'col',
    'embed',
    'hr',
    'img',
    'input',
    'link',
    'meta',
    'param',
    'source',
    'track',
    'wbr',
  };
  const paragraphBoundaries = {
    'p',
    'div',
    'section',
    'article',
    'aside',
    'blockquote',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'hr',
    'ul',
    'ol',
    'dl',
    'table',
    'pre',
    'figure',
  };
  final stack = <String>[];
  var count = 0;
  String? rawText;
  void closePrevious(Set<String> names, Set<String> boundaries) {
    for (var i = stack.length - 1; i >= 0; i--) {
      if (boundaries.contains(stack[i])) return;
      if (names.contains(stack[i])) {
        stack.removeRange(i, stack.length);
        return;
      }
    }
  }

  for (final token in tokens) {
    final name = token.group(2)?.toLowerCase();
    if (name == null) continue;
    final closing = token.group(1) == '/';
    if (rawText != null && !(closing && name == rawText)) continue;
    if (++count > 50000) return null;
    if (closing) {
      final i = stack.lastIndexOf(name);
      if (i >= 0) stack.removeRange(i, stack.length);
      if (name == rawText) rawText = null;
      continue;
    }
    if (paragraphBoundaries.contains(name)) closePrevious({'p'}, {});
    if (name == 'li') closePrevious({'li'}, {'ul', 'ol'});
    if (name == 'dt' || name == 'dd') closePrevious({'dt', 'dd'}, {'dl'});
    if (name == 'td' || name == 'th') {
      closePrevious({'td', 'th'}, {'tr', 'table'});
    }
    if (name == 'tr') {
      closePrevious({'tr'}, {'table', 'tbody', 'thead', 'tfoot'});
    }
    if (const {'tbody', 'thead', 'tfoot'}.contains(name)) {
      closePrevious({'tbody', 'thead', 'tfoot'}, {'table'});
    }
    if (!voids.contains(name) && !token.group(0)!.endsWith('/>')) {
      stack.add(name);
      if (stack.length > 128) return null;
      if (name == 'script' || name == 'style') rawText = name;
    }
  }
  final normal = tryParseXmlTolerant(text);
  if (normal != null) return normal;
  try {
    final document = html.parse(sanitizeXml(text));
    var nodes = 0;
    XmlName name(String value) {
      final colon = value.indexOf(':');
      return colon < 0
          ? XmlName.parts(value)
          : XmlName.parts(
              value.substring(colon + 1),
              prefix: value.substring(0, colon),
            );
    }

    XmlNode? convert(dom.Node node, int depth) {
      if (++nodes > 100000 || depth > 128) {
        throw const FormatException('Content limit');
      }
      if (node is dom.Text) return XmlText(node.data);
      if (node is! dom.Element) return null;
      return XmlElement(
        name(node.localName!),
        [
          for (final entry in node.attributes.entries)
            XmlAttribute(name(entry.key.toString()), entry.value),
        ],
        [
          for (final child in node.nodes)
            if (convert(child, depth + 1) case final XmlNode value) value,
        ],
      );
    }

    final root = document.documentElement;
    if (root == null || document.body == null || document.body!.nodes.isEmpty) {
      return null;
    }
    return XmlDocument([convert(root, 0)!]);
  } catch (_) {
    return null;
  }
}

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
  final tokens = RegExp(
    r'<!--[\s\S]*?-->|<!\[CDATA\[[\s\S]*?\]\]>|<!DOCTYPE\b',
    caseSensitive: false,
  );
  final declaration = tokens
      .allMatches(text)
      .where((token) => token.group(0)!.toLowerCase() == '<!doctype')
      .firstOrNull;
  if (declaration == null) return text;
  final start = declaration.start;
  var i = start + '<!doctype'.length;
  var bracketDepth = 0;
  String? quote;
  while (i < text.length) {
    final ch = text[i];
    if (quote != null) {
      if (ch == quote) quote = null;
      i++;
      continue;
    }
    if (ch == '"' || ch == "'") {
      quote = ch;
      i++;
      continue;
    }
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
  final recovered = StringBuffer();
  var cursor = 0;
  for (final opaque in _opaqueXml.allMatches(sanitized)) {
    recovered.write(
      replaceNamedEntities(
        escapeStrayAmpersands(sanitized.substring(cursor, opaque.start)),
      ),
    );
    recovered.write(opaque.group(0));
    cursor = opaque.end;
  }
  recovered.write(
    replaceNamedEntities(escapeStrayAmpersands(sanitized.substring(cursor))),
  );
  try {
    return XmlDocument.parse(recovered.toString());
  } on XmlException {
    return null;
  }
}
