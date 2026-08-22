/// MOBI / AZW / AZW3 (KF8) → [DirectBookSource].
///
/// Dart port of torto's `crates/formats/src/mobi.rs`: reads metadata and the
/// book body via the KF8/MOBI6 internals (`mobi_kf8.dart`), then normalizes
/// the loose Kindle HTML (recindex/filepos attributes, unclosed void
/// elements, entity protection) into XHTML fragments for the shared
/// HTML→IR pipeline.
library;

import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../ir/ir.dart';
import '../direct_book_source.dart';
import 'mobi_kf8.dart';

/// Opens a MOBI-family file. Throws [FormatException] on unreadable content.
Future<DirectBookSource> openMobi(Uint8List bytes, String fileName) async {
  final metadata = kf8Metadata(bytes);
  final sections = <SourceSection>[];
  List<SourceTocEntry> tableOfContents = const [];
  List<SourceResource> resources;
  if (isKf8(bytes)) {
    final parsed = parseKf8(bytes);
    resources = parsed.resources;
    tableOfContents = parsed.tableOfContents;
    for (final section in parsed.sections) {
      sections.add(
        SourceSection(
          title: section.title,
          content: HtmlSectionContent(normalizeChapter(section.html, const {})),
        ),
      );
    }
  } else {
    final legacy = parseMobi6(bytes);
    resources = legacy.resources;
    for (var index = 0; index < legacy.sections.length; index++) {
      final chapter = legacy.sections[index];
      final title = chapter.title.trim().isEmpty
          ? '第 ${index + 1} 节'
          : chapter.title.trim();
      final body = normalizeChapter(chapter.html, legacy.imageSources);
      if (body.trim().isNotEmpty) {
        sections.add(
          SourceSection(title: title, content: HtmlSectionContent(body)),
        );
      }
    }
  }
  if (sections.isEmpty) {
    throw const FormatException('没有可阅读的正文');
  }
  final declaredTitle = metadata.title?.trim() ?? '';
  final title = declaredTitle.isNotEmpty
      ? declaredTitle
      : _titleFromFileName(fileName);
  final coverPath = metadata.coverPath == null
      ? null
      : (resources.any((resource) => resource.path == metadata.coverPath)
            ? metadata.coverPath
            : null);
  return DirectBookSource.open(
    SourceBook(
      id: sha256.convert(bytes).toString(),
      metadata: BookMetadata(
        title: title,
        authors: metadata.authors,
        languages: metadata.languages,
      ),
      sections: sections,
      tableOfContents: tableOfContents,
      resources: resources,
      coverPath: coverPath,
    ),
  );
}

String _titleFromFileName(String fileName) {
  var name = fileName.replaceAll('\\', '/');
  name = name.substring(name.lastIndexOf('/') + 1);
  final dot = name.lastIndexOf('.');
  if (dot > 0) name = name.substring(0, dot);
  return name.isEmpty ? '未命名书籍' : name;
}

// ------------------------------------------------------- chapter normalization

/// Kindle HTML → IR-pipeline-safe XHTML fragment.
///
/// Rewrites `recindex` image references and `filepos` link targets, strips
/// document wrappers, self-closes void elements, and re-renders the element
/// tree so only known-good constructs survive.
String normalizeChapter(String source, Map<int, String> images) {
  var working = source;
  images.forEach((index, path) {
    final replacement = 'src="../$path"';
    for (final recindex in [
      index.toString().padLeft(5, '0'),
      index.toString(),
    ]) {
      working = working
          .replaceAll('recindex="$recindex"', replacement)
          .replaceAll("recindex='$recindex'", replacement)
          .replaceAll('recindex=$recindex', replacement);
    }
  });
  working = _rewriteNumericAttribute(working, 'recindex', (value) {
    final path = images[value];
    return path == null ? null : 'src="../$path"';
  });
  working = _rewriteNumericAttribute(
    working,
    'filepos',
    (value) => 'href="#filepos$value"',
  );
  working = _stripDocumentWrappers(working);
  working = _normalizeVoidElements(working);
  working = _protectEntities(working);
  final items = _parseHtmlEvents(working);
  final body = items.map(_renderItem).join();
  if (body.trim().isEmpty) {
    final plain = _stripMarkup(working);
    if (plain.trim().isEmpty) return '';
    return '<p>${escapeText(plain.trim())}</p>';
  }
  return body;
}

/// Rewrites `name="<digits>"`-style attributes inside tags (the value must
/// be numeric; unquoted values are tolerated).
String _rewriteNumericAttribute(
  String source,
  String name,
  String? Function(int value) replacement,
) {
  final output = StringBuffer();
  var copied = 0;
  var search = 0;
  while (true) {
    final start = _indexOfWord(source, name, search);
    if (start < 0) break;
    search = start + name.length;
    // Must sit inside a tag: a '<' nearer than the previous '>'.
    final lastOpen = source.lastIndexOf('<', start - 1);
    final lastClose = source.lastIndexOf('>', start - 1);
    if (lastOpen < 0 || lastOpen < lastClose) continue;
    if (start > 0 && _isAlphanumeric(source.codeUnitAt(start - 1))) continue;
    var position = search;
    while (position < source.length && _isSpace(source.codeUnitAt(position))) {
      position++;
    }
    if (position >= source.length || source.codeUnitAt(position) != 0x3D) {
      continue;
    }
    position++;
    while (position < source.length && _isSpace(source.codeUnitAt(position))) {
      position++;
    }
    var quote = 0;
    if (position < source.length &&
        (source.codeUnitAt(position) == 0x27 ||
            source.codeUnitAt(position) == 0x22)) {
      quote = source.codeUnitAt(position);
      position++;
    }
    final valueStart = position;
    while (position < source.length &&
        source.codeUnitAt(position) >= 0x30 &&
        source.codeUnitAt(position) <= 0x39) {
      position++;
    }
    if (position == valueStart) continue;
    if (quote != 0 &&
        (position >= source.length || source.codeUnitAt(position) != quote)) {
      continue;
    }
    final end = position + (quote != 0 ? 1 : 0);
    final value = int.tryParse(source.substring(valueStart, position));
    if (value == null) continue;
    final replacementText =
        replacement(value) ??
        '$name="${source.substring(valueStart, position)}"';
    output
      ..write(source.substring(copied, start))
      ..write(replacementText);
    copied = end;
    search = end;
  }
  if (copied == 0) return source;
  output.write(source.substring(copied));
  return output.toString();
}

/// Case-insensitive [needle] search from [from].
int _indexOfWord(String haystack, String needle, int from) =>
    haystack.toLowerCase().indexOf(needle, from);

/// Removes `<!DOCTYPE>`, `<html>`, `<body>` tags and `<head>` blocks.
String _stripDocumentWrappers(String source) {
  final lower = source.toLowerCase();
  final output = StringBuffer();
  var copied = 0;
  var search = 0;
  while (true) {
    final start = lower.indexOf('<', search);
    if (start < 0) break;
    final end = lower.indexOf('>', start);
    if (end < 0) break;
    final inner = lower.substring(start + 1, end).trim();
    final name = inner
        .replaceFirst(RegExp('^/+'), '')
        .split(RegExp(r'\s+'))
        .first
        .replaceAll('/', '');
    if (inner.startsWith('!doctype') || name == 'html' || name == 'body') {
      output.write(source.substring(copied, start));
      copied = end + 1;
    } else if (name == 'head' && !inner.startsWith('/')) {
      output.write(source.substring(copied, start));
      final headClose = lower.indexOf('</head>', end);
      final blockEnd = headClose < 0 ? end + 1 : headClose + '</head>'.length;
      copied = blockEnd;
      search = blockEnd;
      continue;
    }
    search = end + 1;
  }
  if (copied == 0) return source;
  output.write(source.substring(copied));
  return output.toString();
}

const Set<String> _voidElements = {
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

/// Self-closes HTML void elements so the strict XML parser accepts them.
String _normalizeVoidElements(String source) {
  final lower = source.toLowerCase();
  final output = StringBuffer();
  var copied = 0;
  var search = 0;
  while (true) {
    final start = lower.indexOf('<', search);
    if (start < 0) break;
    final end = lower.indexOf('>', start);
    if (end < 0) break;
    final inner = lower.substring(start + 1, end).trim();
    final closing = inner.startsWith('/');
    final name = inner
        .replaceFirst(RegExp('^/+'), '')
        .split(RegExp(r'\s+'))
        .first
        .replaceAll('/', '');
    if (_voidElements.contains(name)) {
      if (!closing) {
        final tag = source.substring(start, end).trimRight();
        output
          ..write(source.substring(copied, start))
          ..write(tag);
        if (!tag.endsWith('/')) output.write('/');
        output.write('>');
      }
      copied = end + 1;
    }
    search = end + 1;
  }
  if (copied == 0) return source;
  output.write(source.substring(copied));
  return output.toString();
}

bool _isSpace(int code) => code == 0x20 || (code >= 0x09 && code <= 0x0D);

bool _isAlphanumeric(int code) =>
    (code >= 0x30 && code <= 0x39) ||
    (code >= 0x41 && code <= 0x5A) ||
    (code >= 0x61 && code <= 0x7A);

// ------------------------------------------------------------ element model

enum _ContentKind {
  paragraph,
  heading1,
  heading2,
  heading3,
  heading4,
  heading5,
  heading6,
  image,
  link,
  listItem,
  blockQuote,
  codeBlock,
  horizontalRule,
  text,
  other,
}

class _ContentItem {
  final _ContentKind kind;
  final String tag;
  final StringBuffer _text = StringBuffer();
  final List<(String, String)> attributes = [];
  final List<_ContentItem> children = [];

  _ContentItem(this.kind, this.tag);

  /// Text directly inside this element, rendered before its children.
  String get textContent => _text.toString();
}

/// Tolerant HTML event parser (quick-xml stand-in): start/end/text events,
/// empty elements expanded, comments/declarations skipped. Structure follows
/// mobi.rs's HtmlParser: content outside `<body>` (or before any wrapper) is
/// dropped; unmatched end tags still pop the stack.
List<_ContentItem> _parseHtmlEvents(String html) {
  final root = <_ContentItem>[];
  var stack = <_ContentItem>[];
  var inBody = false;
  var hasBody = false;

  void push(_ContentItem item) {
    if (stack.isEmpty) {
      root.add(item);
    } else {
      stack.last.children.add(item);
    }
  }

  var position = 0;
  while (position < html.length) {
    final open = html.indexOf('<', position);
    if (open < 0) {
      _emitText(html.substring(position), stack, root, inBody);
      break;
    }
    if (open > position) {
      _emitText(html.substring(position, open), stack, root, inBody);
    }
    final end = html.indexOf('>', open);
    if (end < 0) break;
    final inner = html.substring(open + 1, end);
    position = end + 1;

    if (inner.startsWith('!--')) continue; // comment
    if (inner.startsWith('!') || inner.startsWith('?')) continue;
    if (inner.startsWith('/')) {
      final name = inner.substring(1).trim().toLowerCase();
      if (name == 'body') {
        inBody = false;
        continue;
      }
      if (inBody && stack.isNotEmpty) {
        push(stack.removeLast());
      }
      continue;
    }
    // <name attr="v" ...> with optional trailing '/'
    final selfClosing = inner.endsWith('/');
    final trimmed = selfClosing ? inner.substring(0, inner.length - 1) : inner;
    final match = RegExp(r'^([^\s/>]+)(.*)$', dotAll: true).firstMatch(trimmed);
    if (match == null) continue;
    final name = match.group(1)!.toLowerCase();
    final rest = match.group(2)!;
    if (name == 'body') {
      inBody = true;
      hasBody = true;
      continue;
    }
    if (!hasBody && !_isDocumentWrapper(name)) inBody = true;
    if (!inBody) continue;
    final item = _ContentItem(_kindOf(name), name);
    item.attributes.addAll(_parseAttributes(rest));
    if (selfClosing) {
      push(item);
    } else {
      stack.add(item);
    }
  }
  while (stack.isNotEmpty) {
    push(stack.removeLast());
  }
  return root;
}

void _emitText(
  String value,
  List<_ContentItem> stack,
  List<_ContentItem> root,
  bool inBody,
) {
  if (!inBody || value.trim().isEmpty) return;
  if (stack.isNotEmpty) {
    stack.last._text.write(value);
  } else {
    final item = _ContentItem(_ContentKind.text, '#text');
    item._text.write(value);
    root.add(item);
  }
}

bool _isDocumentWrapper(String name) => switch (name) {
  'html' || 'head' || 'meta' || 'title' || 'link' || 'style' => true,
  _ => false,
};

_ContentKind _kindOf(String name) => switch (name) {
  'p' => _ContentKind.paragraph,
  'h1' => _ContentKind.heading1,
  'h2' => _ContentKind.heading2,
  'h3' => _ContentKind.heading3,
  'h4' => _ContentKind.heading4,
  'h5' => _ContentKind.heading5,
  'h6' => _ContentKind.heading6,
  'img' => _ContentKind.image,
  'a' => _ContentKind.link,
  'li' => _ContentKind.listItem,
  'blockquote' => _ContentKind.blockQuote,
  'pre' || 'code' => _ContentKind.codeBlock,
  'hr' => _ContentKind.horizontalRule,
  _ => _ContentKind.other,
};

List<(String, String)> _parseAttributes(String rest) {
  final attributes = <(String, String)>[];
  final pattern = RegExp(
    r'''([^\s=/>]+)(?:\s*=\s*("([^"]*)"|'([^']*)'|[^\s>]*))?''',
  );
  for (final match in pattern.allMatches(rest)) {
    final name = match.group(1);
    if (name == null || name.isEmpty) continue;
    final value = match.group(3) ?? match.group(4) ?? match.group(2) ?? '';
    attributes.add((name, value));
  }
  return attributes;
}

/// Private-use placeholders protecting entities through re-rendering.
const _entityAmp = '\ue000';
const _entityLt = '\ue001';
const _entityGt = '\ue002';
const _entityQuot = '\ue003';
const _entityApos = '\ue004';
const _entityNbsp = '\ue005';

String _protectEntities(String value) => value
    .replaceAll('&amp;', _entityAmp)
    .replaceAll('&lt;', _entityLt)
    .replaceAll('&gt;', _entityGt)
    .replaceAll('&quot;', _entityQuot)
    .replaceAll('&apos;', _entityApos)
    .replaceAll('&nbsp;', _entityNbsp)
    .replaceAll('&#160;', _entityNbsp);

String _decodeEntities(String value) => value
    .replaceAll(_entityAmp, '&')
    .replaceAll(_entityLt, '<')
    .replaceAll(_entityGt, '>')
    .replaceAll(_entityQuot, '"')
    .replaceAll(_entityApos, "'")
    .replaceAll(_entityNbsp, ' ')
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&#160;', ' ')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&amp;', '&');

String escapeText(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

String escapeAttribute(String value) =>
    escapeText(value).replaceAll('"', '&quot;').replaceAll("'", '&apos;');

String _stripMarkup(String value) {
  final output = StringBuffer();
  var inTag = false;
  for (final character in value.split('')) {
    if (character == '<') {
      inTag = true;
    } else if (character == '>') {
      inTag = false;
      output.write(' ');
    } else if (!inTag) {
      output.write(character);
    }
  }
  return _decodeEntities(output.toString());
}

String _renderItem(_ContentItem item) {
  String contentOf(_ContentItem item) {
    final buffer = StringBuffer(escapeText(_decodeEntities(item.textContent)));
    for (final child in item.children) {
      buffer.write(_renderItem(child));
    }
    return buffer.toString();
  }

  final content = contentOf(item);
  switch (item.kind) {
    case _ContentKind.paragraph:
      return _wrap('p', item, content);
    case _ContentKind.heading1:
      return _wrap('h1', item, content);
    case _ContentKind.heading2:
      return _wrap('h2', item, content);
    case _ContentKind.heading3:
      return _wrap('h3', item, content);
    case _ContentKind.heading4:
      return _wrap('h4', item, content);
    case _ContentKind.heading5:
      return _wrap('h5', item, content);
    case _ContentKind.heading6:
      return _wrap('h6', item, content);
    case _ContentKind.image:
      final src = _attribute(item, 'src');
      if (src == null || !src.startsWith('../Images/')) return '';
      final alt = _attribute(item, 'alt') ?? '';
      return '<img src="${escapeAttribute(src)}" alt="${escapeAttribute(alt)}"/>';
    case _ContentKind.link:
      final href = _attribute(item, 'href') ?? '';
      final id = _authoredIdentifier(item);
      if (!href.startsWith('#') && id == null) return content;
      final idText = id == null ? '' : ' id="${escapeAttribute(id)}"';
      final hrefText = href.startsWith('#')
          ? ' href="${escapeAttribute(href)}"'
          : '';
      return '<a$idText$hrefText>$content</a>';
    case _ContentKind.listItem:
      return _wrap('li', item, content);
    case _ContentKind.blockQuote:
      return _wrap('blockquote', item, content);
    case _ContentKind.codeBlock:
      return _wrap('pre', item, content);
    case _ContentKind.horizontalRule:
      return '<hr/>';
    case _ContentKind.text:
      return content;
    case _ContentKind.other:
      return switch (item.tag) {
        'br' || 'mbp:pagebreak' => '<br/>',
        'div' || 'section' || 'article' => _wrap('div', item, content),
        'ul' => _wrap('ul', item, content),
        'ol' => _wrap('ol', item, content),
        'strong' || 'b' => _wrap('strong', item, content),
        'em' || 'i' => _wrap('em', item, content),
        'sup' => _wrap('sup', item, content),
        'sub' => _wrap('sub', item, content),
        _ => content,
      };
  }
}

String _wrap(String tag, _ContentItem item, String content) {
  final id = _authoredIdentifier(item);
  final idText = id == null ? '' : ' id="${escapeAttribute(id)}"';
  return '<$tag$idText>$content</$tag>';
}

String? _authoredIdentifier(_ContentItem item) =>
    _attribute(item, 'id') ??
    _attribute(item, 'name') ??
    _attribute(item, 'aid');

String? _attribute(_ContentItem item, String name) {
  for (final (key, value) in item.attributes) {
    if (key.toLowerCase() == name) return value;
  }
  return null;
}
