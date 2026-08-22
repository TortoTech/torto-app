/// FictionBook 2.0 (`.fb2` / zipped `.fbz` / `.fb2.zip`) → [DirectBookSource].
///
/// Dart port of torto's `crates/formats/src/fb2.rs`: the XML document is
/// converted section by section into XHTML fragments consumed by the shared
/// HTML→IR pipeline, while `<binary>` base64 images become package resources.
/// FB2 has no embedded navigation, so the source ships a fallback TOC built
/// from section titles.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:xml/xml.dart';

import '../html_ir/tolerant_xml.dart';
import '../ir/ir.dart';
import 'direct_book_source.dart';

/// Zipped FB2 entries above this size are rejected, mirroring torto's cap.
const int _maxEntryBytes = 64 * 1024 * 1024;

class _ImageReference {
  final String path;

  const _ImageReference(this.path);
}

/// Opens an FB2/FBZ file from its raw bytes. [fileName] feeds the title
/// fallback. Throws [FormatException] on anything that is not a readable
/// FictionBook document.
Future<DirectBookSource> openFb2(Uint8List bytes, String fileName) async {
  final xmlBytes = _extractXml(bytes);
  final xml = decodeXmlBytes(xmlBytes);
  final document = tryParseXmlTolerant(xml);
  if (document == null) {
    throw const FormatException('FB2 文档不是有效的 XML');
  }
  final root = document.rootElement;
  if (_localName(root) != 'fictionbook') {
    throw const FormatException('FB2 根元素不是 FictionBook');
  }

  final titleInfo = _findFirst(root, 'title-info');
  final declaredTitle = _firstDescendantText(titleInfo, 'book-title') ?? '';
  final title = declaredTitle.isNotEmpty
      ? declaredTitle
      : _titleFromFileName(fileName);
  final authors = _extractAuthors(titleInfo);
  final language = _firstDescendantText(titleInfo, 'lang') ?? '';

  final (resources, imageReferences) = _extractImages(root);
  final coverImage = _findFirst(_findFirst(titleInfo, 'coverpage'), 'image');
  final coverPath = coverImage == null
      ? null
      : imageReferences[_imageIdentifier(coverImage)]?.path;
  final sections = _extractSections(root, imageReferences);
  if (sections.isEmpty) {
    throw const FormatException('FB2 没有可阅读的正文');
  }

  return DirectBookSource.open(
    SourceBook(
      id: sha256.convert(bytes).toString(),
      metadata: BookMetadata(
        title: title,
        authors: authors,
        languages: [if (language.isNotEmpty) language],
      ),
      sections: sections,
      resources: resources,
      coverPath: coverPath,
    ),
  );
}

/// Plain `.fb2` bytes pass through; `PK`-prefixed files are treated as FBZ
/// and the first `.fb2` zip entry is extracted (64 MiB cap).
Uint8List _extractXml(Uint8List bytes) {
  if (bytes.length < 2 || bytes[0] != 0x50 || bytes[1] != 0x4B) {
    return bytes;
  }
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes);
  } catch (error) {
    throw FormatException('FBZ 压缩包无法读取: $error');
  }
  ArchiveFile? entry;
  for (final file in archive.files) {
    if (file.isFile && file.name.toLowerCase().endsWith('.fb2')) {
      entry = file;
      break;
    }
  }
  if (entry == null) {
    throw const FormatException('FBZ 压缩包中没有 .fb2 文件');
  }
  final Uint8List? decoded;
  try {
    decoded = entry.readBytes();
  } catch (error) {
    throw FormatException('FBZ 条目无法解压: $error');
  }
  if (decoded == null || decoded.length > _maxEntryBytes) {
    throw decoded == null
        ? const FormatException('FBZ 条目无法解压')
        : const FormatException('FB2 文件超过 64 MiB 限制');
  }
  return decoded;
}

/// Decodes every `<binary>` element into a resource. Entries that declare an
/// unknown image type are skipped (fail-soft), matching torto.
(List<SourceResource>, Map<String, _ImageReference>) _extractImages(
  XmlElement root,
) {
  final resources = <SourceResource>[];
  final references = <String, _ImageReference>{};
  for (final binary in root.descendants.whereType<XmlElement>()) {
    if (_localName(binary) != 'binary') continue;
    final id = (_localAttr(binary, 'id') ?? '').trim();
    if (id.isEmpty) continue;
    final encoded = _normalizedText(binary).replaceAll(RegExp(r'\s'), '');
    Uint8List decoded;
    try {
      decoded = base64Decode(encoded);
    } catch (error) {
      throw FormatException('FB2 内嵌图片 $id 无法解码: $error');
    }
    final declared = _localAttr(binary, 'content-type') ?? '';
    final imageType = _imageType(declared, decoded);
    if (imageType == null) continue;
    final path = 'Images/image-${resources.length + 1}.${imageType.$1}';
    resources.add(
      SourceResource(path: path, mediaType: imageType.$2, bytes: decoded),
    );
    references[id] = _ImageReference(path);
  }
  return (resources, references);
}

List<SourceSection> _extractSections(
  XmlElement root,
  Map<String, _ImageReference> images,
) {
  final sections = <SourceSection>[];
  var bodyIndex = 0;
  for (final body in root.childElements) {
    if (_localName(body) != 'body') continue;
    final linear = bodyIndex == 0 && _localAttr(body, 'name') == null;
    bodyIndex++;
    final topLevelSections = body.childElements
        .where((child) => _localName(child) == 'section')
        .toList();
    if (topLevelSections.isEmpty) {
      final markup = _renderChildren(body, images);
      if (markup.trim().isNotEmpty) {
        sections.add(
          SourceSection(
            title: _sectionTitle(body, sections.length),
            content: HtmlSectionContent(markup),
            linear: linear,
          ),
        );
      }
      continue;
    }

    final preface = body.childElements
        .where((child) => _localName(child) != 'section')
        .map((child) => _renderNode(child, images))
        .join();
    if (preface.trim().isNotEmpty) {
      sections.add(
        SourceSection(
          title: _sectionTitle(body, sections.length),
          content: HtmlSectionContent(preface),
          linear: linear,
        ),
      );
    }
    for (final section in topLevelSections) {
      sections.add(
        SourceSection(
          title: _sectionTitle(section, sections.length),
          content: HtmlSectionContent(_renderNode(section, images)),
          linear: linear,
        ),
      );
    }
  }
  return sections;
}

String _renderChildren(XmlElement node, Map<String, _ImageReference> images) {
  final buffer = StringBuffer();
  for (final child in node.children) {
    buffer.write(_renderNode(child, images));
  }
  return buffer.toString();
}

String _renderNode(XmlNode node, Map<String, _ImageReference> images) {
  if (node is XmlText) return _escapeText(node.value);
  if (node is XmlCDATA) return _escapeText(node.value);
  if (node is! XmlElement) return '';
  final name = _localName(node);
  if (name == 'binary') return '';
  if (name == 'image') {
    final path = images[_imageIdentifier(node)]?.path;
    return path == null ? '' : '<img src="../$path" alt=""/>';
  }
  if (name == 'empty-line') return '<br/>';

  final tag = switch (name) {
    'section' => 'section',
    'title' => 'header',
    'p'
        when node.parentElement != null &&
            _localName(node.parentElement!) == 'title' =>
      'h1',
    'p' || 'v' || 'text-author' || 'date' => 'p',
    'subtitle' => 'h2',
    'epigraph' || 'poem' || 'cite' => 'blockquote',
    'stanza' => 'div',
    'annotation' => 'aside',
    'strong' => 'strong',
    'emphasis' => 'em',
    'strikethrough' => 's',
    'sub' => 'sub',
    'sup' => 'sup',
    'code' => 'code',
    'table' => 'table',
    'tr' => 'tr',
    'th' => 'th',
    'td' => 'td',
    'a' => 'a',
    _ => null,
  };
  if (tag == null) return _renderChildren(node, images);
  final attributes = StringBuffer();
  final id = _localAttr(node, 'id');
  if (id != null) attributes.write(' id="${_escapeAttribute(id)}"');
  if (name == 'a') {
    final href = _localAttr(node, 'href');
    if (href != null) attributes.write(' href="${_escapeAttribute(href)}"');
  }
  return '<$tag$attributes>${_renderChildren(node, images)}</$tag>';
}

String _sectionTitle(XmlElement node, int index) {
  final title = _findFirst(node, 'title');
  if (title != null) {
    final text = _normalizedText(title);
    if (text.isNotEmpty) return text;
  }
  return '第 ${index + 1} 节';
}

List<String> _extractAuthors(XmlElement? titleInfo) {
  if (titleInfo == null) return const [];
  final authors = <String>[];
  for (final author in titleInfo.childElements) {
    if (_localName(author) != 'author') continue;
    final nickname = _firstDescendantText(author, 'nickname');
    if (nickname != null && nickname.isNotEmpty) {
      authors.add(nickname);
      continue;
    }
    final parts = [
      for (final part in const ['first-name', 'middle-name', 'last-name'])
        if ((_firstDescendantText(author, part) ?? '').isNotEmpty)
          _firstDescendantText(author, part)!,
    ];
    if (parts.isNotEmpty) authors.add(parts.join(' '));
  }
  return authors;
}

XmlElement? _findFirst(XmlElement? node, String name) {
  if (node == null) return null;
  for (final descendant in node.descendants.whereType<XmlElement>()) {
    if (_localName(descendant) == name) return descendant;
  }
  return null;
}

String? _firstDescendantText(XmlElement? node, String name) {
  final element = _findFirst(node, name);
  return element == null ? null : _normalizedText(element);
}

String _normalizedText(XmlElement node) => node.descendants
    .whereType<XmlText>()
    .map((text) => text.value)
    .join()
    .split(RegExp(r'\s+'))
    .where((word) => word.isNotEmpty)
    .join(' ')
    .trim();

/// Attribute lookup by case-insensitive local name (handles `l:href`).
String? _localAttr(XmlElement element, String name) {
  for (final attribute in element.attributes) {
    if (attribute.name.local.toLowerCase() == name) return attribute.value;
  }
  return null;
}

/// FB2 image references are `#id` fragments in the `href` (or `l:href`)
/// attribute.
String? _imageIdentifier(XmlElement node) =>
    _localAttr(node, 'href')?.trim().replaceFirst(RegExp('^#'), '');

String _localName(XmlElement element) => element.name.local.toLowerCase();

String _escapeText(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

String _escapeAttribute(String value) =>
    _escapeText(value).replaceAll('"', '&quot;').replaceAll("'", '&apos;');

String _titleFromFileName(String fileName) {
  var name = fileName.replaceAll('\\', '/');
  name = name.substring(name.lastIndexOf('/') + 1);
  if (name.toLowerCase().endsWith('.fb2.zip')) {
    name = name.substring(0, name.length - '.fb2.zip'.length);
  } else {
    final dot = name.lastIndexOf('.');
    if (dot > 0) name = name.substring(0, dot);
  }
  return name.isEmpty ? '未命名书籍' : name;
}

/// Image type from the declared content type, falling back to magic-byte
/// sniffing. Returns (extension, media type), or null when unknown.
(String, String)? _imageType(String declared, Uint8List bytes) {
  switch (declared.toLowerCase()) {
    case 'image/jpeg' || 'image/jpg':
      return ('jpg', 'image/jpeg');
    case 'image/png':
      return ('png', 'image/png');
    case 'image/gif':
      return ('gif', 'image/gif');
    case 'image/webp':
      return ('webp', 'image/webp');
    case 'image/bmp' || 'image/x-ms-bmp':
      return ('bmp', 'image/bmp');
  }
  bool startsWith(List<int> prefix, [int offset = 0]) {
    if (bytes.length < offset + prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (bytes[offset + i] != prefix[i]) return false;
    }
    return true;
  }

  if (startsWith([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
    return ('png', 'image/png');
  }
  if (startsWith([0xFF, 0xD8, 0xFF])) return ('jpg', 'image/jpeg');
  if (startsWith([0x47, 0x49, 0x46, 0x38])) return ('gif', 'image/gif'); // GIF8
  if (startsWith([0x42, 0x4D])) return ('bmp', 'image/bmp'); // BM
  if (startsWith([0x52, 0x49, 0x46, 0x46]) &&
      startsWith([0x57, 0x45, 0x42, 0x50], 8)) {
    return ('webp', 'image/webp'); // RIFF….WEBP
  }
  return null;
}
