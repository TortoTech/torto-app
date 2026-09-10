/// CHM → [BookSource].
///
/// Dart port of torto's `crates/formats/src/chm.rs` (minus the libchm and
/// temp-file plumbing, replaced by `chm_archive.dart`): reads all normal
/// entries as resources, builds navigation from `#SYSTEM` + the `.hhc`
/// contents file, extracts metadata and the cover from the default topic
/// page, and parses each HTML page through the shared HTML→IR pipeline
/// after normalizing legacy CHM layout markup.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../../html_ir/html_ir_parser.dart';
import '../../html_ir/package_path.dart';
import '../../ir/ir.dart';
import '../cp1252.dart';
import '../image_dimensions.dart';
import '../toc_heading_promoter.dart';
import 'chm_archive.dart';

const int _maxTotalBytes = 512 * 1024 * 1024;

class _StoredResource {
  /// Normalized (original-case) path as addressed in the publication.
  final String path;
  final String mediaType;
  final Uint8List bytes;

  const _StoredResource(this.path, this.mediaType, this.bytes);
}

class _SystemMetadata {
  final String? contents;
  final String? defaultTopic;
  final String? title;

  const _SystemMetadata({this.contents, this.defaultTopic, this.title});
}

class ChmHhcEntry {
  final String label;
  final String? target;
  final List<ChmHhcEntry> children = [];

  ChmHhcEntry(this.label, this.target);
}

class ChmHtmlMetadata {
  final String? title;
  final List<String> authors;
  final String? coverTarget;

  const ChmHtmlMetadata(this.title, this.authors, this.coverTarget);
}

/// [BookSource] backed by a CHM archive. Sections keep their original
/// in-archive paths; resource lookup is case-insensitive.
class ChmBookSource implements BookSource {
  @override
  final Book book;
  final Map<String, _StoredResource> _resources;
  final Map<String, List<TocHeadingHint>> _tocHeadingHints;

  static const HtmlIrParser _parser = HtmlIrParser();

  ChmBookSource._(this.book, this._resources, this._tocHeadingHints);

  @override
  Future<Uint8List?> resource(String href) async {
    final (path, _) = splitPackageFragment(href);
    return _resources[path.toLowerCase()]?.bytes;
  }

  @override
  Future<Section> parseSection(int index) async {
    final item = book.spine[index];
    final stored = _resources[item.href.toLowerCase()];
    if (stored == null) {
      return Section(
        id: item.id,
        spineIndex: index,
        href: item.href,
        blocks: const [],
      );
    }
    try {
      final xhtml = htmlToXhtml(decodeChmText(stored.bytes));
      return promoteTocHeadings(
        _parser.parse(
          spineIndex: index,
          spineId: item.id,
          href: item.href,
          xhtml: xhtml,
          basePath: packageDirname(item.href),
          loadStylesheet: (href) {
            final css = _resources[href.toLowerCase()];
            return css == null ? null : decodeChmText(css.bytes);
          },
          isDecorativeSeparatorImage: (href) {
            final bytes = _resources[href.toLowerCase()]?.bytes;
            return bytes != null && isDecorativeSeparatorImage(bytes);
          },
        ),
        _tocHeadingHints[item.href] ?? const [],
      );
    } catch (_) {
      return Section(
        id: item.id,
        spineIndex: index,
        href: item.href,
        blocks: const [],
      );
    }
  }
}

/// Opens a CHM from raw bytes. Throws [FormatException] on unreadable or
/// HTML-less archives.
Future<ChmBookSource> openChm(Uint8List bytes, String fileName) async {
  final archive = ChmArchive.open(bytes);
  final system = _parseSystemMetadata(archive.systemInfo());

  final resources = <String, _StoredResource>{};
  var totalBytes = 0;
  for (final entry in archive.fileEntries) {
    if (entry.length > _maxTotalBytes) {
      throw FormatException('CHM entry ${entry.path} exceeds 512 MiB');
    }
    totalBytes += entry.length;
    if (totalBytes > _maxTotalBytes) {
      throw const FormatException('CHM expanded resources exceed 512 MiB');
    }
    final entryBytes = archive.read(entry);
    resources[entry.path.toLowerCase()] = _StoredResource(
      entry.path,
      _mediaTypeForPath(entry.path),
      Uint8List.fromList(entryBytes),
    );
  }
  if (resources.isEmpty) {
    throw const FormatException('CHM contains no readable resources');
  }

  final navigation = _buildNavigation(resources, system);
  final metadata = _buildMetadata(resources, system, fileName, navigation);
  final sections = <SpineItem>[];
  final fallbackToc = <TocEntry>[];
  final tocTitles = _tocTitlesByPath(navigation.tableOfContents);
  for (var index = 0; index < navigation.sectionHrefs.length; index++) {
    final href = navigation.sectionHrefs[index];
    final title =
        tocTitles[href.path.toLowerCase()] ??
        _storedHtmlTitle(resources[href.path.toLowerCase()]) ??
        _sectionTitleFromPath(href.path);
    sections.add(
      SpineItem(
        id: SpineItemId.generated(index),
        index: index,
        href: href.path,
      ),
    );
    fallbackToc.add(TocEntry(label: title, href: href.path, spineIndex: index));
  }
  if (sections.isEmpty) {
    throw const FormatException('CHM contains no HTML reading sections');
  }

  final toc = navigation.authored
      ? [
          for (final entry in navigation.tableOfContents)
            _toTocEntry(entry, sections),
        ]
      : fallbackToc;

  return ChmBookSource._(
    Book(
      id: sha256.convert(bytes).toString(),
      metadata: BookMetadata(
        title: metadata.title,
        authors: metadata.authors,
        languages: const [],
      ),
      spine: sections,
      toc: toc,
      coverHref: metadata.cover?.path,
    ),
    resources,
    collectTocHeadingHints(toc),
  );
}

class _ResolvedHref {
  final String path;
  final String fragment;

  const _ResolvedHref(this.path, this.fragment);
}

class _NavEntry {
  final String label;
  final _ResolvedHref? href;
  final List<_NavEntry> children;

  const _NavEntry(this.label, this.href, this.children);
}

class _NavigationModel {
  final List<_NavEntry> tableOfContents;
  final List<_ResolvedHref> sectionHrefs;
  final _ResolvedHref? defaultTopic;
  final bool authored;

  const _NavigationModel(
    this.tableOfContents,
    this.sectionHrefs,
    this.defaultTopic,
    this.authored,
  );
}

String _joinHref(_ResolvedHref href) =>
    href.fragment.isEmpty ? href.path : '${href.path}#${href.fragment}';

// ---------------------------------------------------------------- navigation

_NavigationModel _buildNavigation(
  Map<String, _StoredResource> resources,
  _SystemMetadata system,
) {
  var contentsHref = _resolveInternalTarget(null, system.contents, resources);
  if (contentsHref == null) {
    for (final resource in resources.values) {
      if (resource.path.toLowerCase().endsWith('.hhc')) {
        contentsHref = _ResolvedHref(resource.path, '');
        break;
      }
    }
  }
  var rawToc = const <ChmHhcEntry>[];
  if (contentsHref != null) {
    final stored = resources[contentsHref.path.toLowerCase()];
    if (stored != null) {
      rawToc = parseHhc(decodeChmText(stored.bytes));
    }
  }
  final tocEntries = contentsHref == null
      ? const <_NavEntry>[]
      : _resolveTocEntries(rawToc, contentsHref, resources);
  final authored = tocEntries.isNotEmpty;

  final sectionHrefs = <_ResolvedHref>[];
  final seen = <String>{};
  void collect(List<_NavEntry> entries) {
    for (final entry in entries) {
      final href = entry.href;
      if (href != null &&
          _isHtmlPath(href.path) &&
          seen.add(href.path.toLowerCase())) {
        sectionHrefs.add(href);
      }
      collect(entry.children);
    }
  }

  collect(tocEntries);
  final defaultTopic = _resolveInternalTarget(
    null,
    system.defaultTopic,
    resources,
  );
  if (defaultTopic != null &&
      _isHtmlPath(defaultTopic.path) &&
      seen.add(defaultTopic.path.toLowerCase())) {
    sectionHrefs.insert(0, defaultTopic);
  }
  if (sectionHrefs.isEmpty) {
    final htmlPaths = [
      for (final resource in resources.values)
        if (_isHtmlPath(resource.path)) resource.path,
    ]..sort();
    sectionHrefs.addAll(htmlPaths.map((path) => _ResolvedHref(path, '')));
  }
  return _NavigationModel(tocEntries, sectionHrefs, defaultTopic, authored);
}

List<_NavEntry> _resolveTocEntries(
  List<ChmHhcEntry> entries,
  _ResolvedHref base,
  Map<String, _StoredResource> resources,
) {
  final resolved = <_NavEntry>[];
  for (final entry in entries) {
    final href = _resolveInternalTarget(base.path, entry.target, resources);
    final children = _resolveTocEntries(entry.children, base, resources);
    if (href != null || children.isNotEmpty) {
      resolved.add(_NavEntry(entry.label, href, children));
    }
  }
  return resolved;
}

/// Resolves an HHC/system link target against the resource set; returns
/// null for external/missing targets. `::/` prefixes and fragments handled.
_ResolvedHref? _resolveInternalTarget(
  String? basePath,
  String? rawTarget,
  Map<String, _StoredResource> resources,
) {
  if (rawTarget == null) return null;
  var target = rawTarget.trim().replaceAll('\\', '/');
  final namedPart = target.indexOf('::/');
  if (namedPart >= 0) target = target.substring(namedPart + 3);
  while (target.startsWith('/')) {
    target = target.substring(1);
  }
  if (target.isEmpty ||
      const [
        'http:',
        'https:',
        'mailto:',
        'javascript:',
      ].any((scheme) => target.toLowerCase().startsWith(scheme))) {
    return null;
  }
  String? fragment;
  final hash = target.indexOf('#');
  if (hash >= 0) {
    fragment = target.substring(hash + 1);
    target = target.substring(0, hash);
  }
  final resolved = target.startsWith('/')
      ? target.substring(1)
      : resolvePackageHref(
          basePath == null ? '' : packageDirname(basePath),
          Uri.encodeFull(target),
        );
  final (path, _) = splitPackageFragment(resolved);
  final stored = resources[path.toLowerCase()];
  if (stored == null) return null;
  return _ResolvedHref(stored.path, fragment ?? '');
}

// ------------------------------------------------------------------ metadata

_SystemMetadata _parseSystemMetadata(Map<int, String> system) {
  String? clean(int code) {
    final value = system[code]?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  return _SystemMetadata(
    contents: clean(0),
    defaultTopic: clean(2),
    title: clean(3),
  );
}

class _PublicationMetadata {
  final String title;
  final List<String> authors;
  final _StoredResource? cover;

  const _PublicationMetadata(this.title, this.authors, this.cover);
}

_PublicationMetadata _buildMetadata(
  Map<String, _StoredResource> resources,
  _SystemMetadata system,
  String fileName,
  _NavigationModel navigation,
) {
  final metadataHref =
      (navigation.defaultTopic != null &&
          _isHtmlPath(navigation.defaultTopic!.path))
      ? navigation.defaultTopic!.path
      : navigation.sectionHrefs.first.path;
  final stored = resources[metadataHref.toLowerCase()];
  final html = stored == null
      ? const ChmHtmlMetadata(null, [], null)
      : inspectHtml(decodeChmText(stored.bytes));

  var title = system.title;
  if (title == null || title.trim().isEmpty) title = html.title;
  title ??= navigation.tableOfContents.isNotEmpty
      ? navigation.tableOfContents.first.label
      : null;
  title ??= _titleFromFileName(fileName);

  var cover = html.coverTarget == null
      ? null
      : _resolveInternalTarget(metadataHref, html.coverTarget, resources);
  if (cover == null) {
    for (final resource in resources.values) {
      if (resource.mediaType.startsWith('image/') &&
          resource.path.toLowerCase().contains('cover')) {
        cover = _ResolvedHref(resource.path, '');
        break;
      }
    }
  }
  final coverResource = cover == null
      ? null
      : resources[cover.path.toLowerCase()];
  return _PublicationMetadata(title, html.authors, coverResource);
}

String? _storedHtmlTitle(_StoredResource? stored) {
  if (stored == null) return null;
  try {
    return inspectHtml(decodeChmText(stored.bytes)).title;
  } catch (_) {
    return null;
  }
}

// --------------------------------------------------------------- HHC parsing

/// Parses an `.hhc` contents file (legacy HTML) into a nested entry list.
List<ChmHhcEntry> parseHhc(String source) {
  final document = html_parser.parse(source);
  final body = document.body;
  if (body == null) return const [];
  dom.Element? firstList;
  for (final element in body.querySelectorAll('ul')) {
    firstList = element;
    break;
  }
  if (firstList == null) return const [];
  return _parseHhcList(firstList);
}

List<ChmHhcEntry> _parseHhcList(dom.Element list) {
  final entries = <ChmHhcEntry>[];
  for (final child in list.children) {
    switch (child.localName) {
      case 'li':
        final nested = child.children
            .where((element) => element.localName == 'ul')
            .firstOrNull;
        final children = nested == null
            ? const <ChmHhcEntry>[]
            : _parseHhcList(nested);
        final entry = _parseHhcItem(child);
        if (entry != null) {
          entry.children.addAll(children);
          entries.add(entry);
        } else {
          entries.addAll(children);
        }
      case 'ul':
        // Some generated HHC files omit </li>: associate the nested list
        // with the preceding item.
        final children = _parseHhcList(child);
        if (entries.isNotEmpty) {
          entries.last.children.addAll(children);
        } else {
          entries.addAll(children);
        }
    }
  }
  return entries;
}

ChmHhcEntry? _parseHhcItem(dom.Element item) {
  final object = item.children
      .where((element) => element.localName == 'object')
      .firstOrNull;
  if (object == null) return null;
  String? label;
  String? target;
  for (final param in object.querySelectorAll('param')) {
    final name = param.attributes['name'] ?? '';
    final value = (param.attributes['value'] ?? '').trim();
    if (name.toLowerCase() == 'name' && value.isNotEmpty) {
      label = _normalizeText(value);
    } else if (name.toLowerCase() == 'local' && value.isNotEmpty) {
      target = value;
    }
  }
  label ??= target == null ? null : _sectionTitleFromPath(target);
  if (label == null) return null;
  return ChmHhcEntry(label, target);
}

// ---------------------------------------------------------- HTML inspection

ChmHtmlMetadata inspectHtml(String source) {
  final document = html_parser.parse(source);
  String? title;
  final authors = <String>[];
  String? coverTarget;

  bool isCoverImg(dom.Element element) {
    final alt = (element.attributes['alt'] ?? '').toLowerCase();
    final src = element.attributes['src'] ?? '';
    return src.isNotEmpty &&
        (alt.contains('cover') || src.toLowerCase().contains('cover'));
  }

  for (final element in document.querySelectorAll('*')) {
    switch (element.localName) {
      case 'title' when title == null:
        final value = _normalizeText(element.text);
        if (value.isNotEmpty) title = value;
      case 'meta':
        final name = element.attributes['name'] ?? '';
        if (name.toLowerCase() == 'author') {
          final value = _normalizeText(element.attributes['content'] ?? '');
          if (value.isNotEmpty) authors.add(value);
        }
      case 'img' when coverTarget == null:
        if (isCoverImg(element)) {
          coverTarget = element.attributes['src'];
        }
      case 'td' || 'p' || 'div' when authors.isEmpty:
        final text = _normalizeText(element.text);
        if (text.startsWith('By ')) {
          final author = text.substring(3).trim();
          if (author.isNotEmpty && author.length <= 120) authors.add(author);
        }
    }
  }
  final uniqueAuthors = authors.toSet().toList()..sort();
  return ChmHtmlMetadata(title, uniqueAuthors, coverTarget);
}

// ----------------------------------------------------------- HTML → XHTML

/// Legacy CHM HTML → Reading-IR-compatible XHTML: layout tables become
/// divs, decorative navigation images are dropped, and void elements are
/// self-closed for the strict XML parser.
String htmlToXhtml(String source) {
  final document = html_parser.parse(source);
  _normalizeLegacyChmLayout(document);
  var serialized =
      document.body?.outerHtml ?? document.documentElement?.outerHtml ?? '';
  // HTML-only entity: numeric reference is portable in XML without a DTD.
  serialized = serialized.replaceAll('&nbsp;', '&#160;');
  return _normalizeVoidElements(serialized);
}

void _normalizeLegacyChmLayout(dom.Document document) {
  final body = document.body;
  if (body == null) return;

  // body > table used purely for layout → its cells become divs.
  final layoutTables = <dom.Element>{
    for (final child in body.children)
      if (child.localName == 'table') child,
  };
  if (layoutTables.isEmpty) return;
  final layoutCells = <dom.Element>[];
  for (final element in document.querySelectorAll('tr, td, th')) {
    var ancestor = element.parent;
    while (ancestor != null && ancestor.localName != 'table') {
      ancestor = ancestor.parent;
    }
    if (ancestor != null && layoutTables.contains(ancestor)) {
      layoutCells.add(element);
    }
  }
  for (final table in layoutTables) {
    _rename(table, 'div');
  }
  for (final cell in layoutCells) {
    _rename(cell, 'div');
  }

  // Tiny spacer images and prev/next button images are decoration.
  final decorative = <dom.Element>[];
  for (final image in document.querySelectorAll('img')) {
    final alt = (image.attributes['alt'] ?? '').toLowerCase();
    final width = int.tryParse(image.attributes['width'] ?? '');
    final height = int.tryParse(image.attributes['height'] ?? '');
    final isNavButton = alt == 'previous page' || alt == 'next page';
    final isSpacer =
        width != null && height != null && (width <= 1 || height <= 1);
    if (isNavButton || isSpacer) decorative.add(image);
  }
  for (final image in decorative) {
    image.remove();
  }
}

void _rename(dom.Element element, String tag) {
  if (element.localName == tag) return;
  final replacement = dom.Element.tag(tag);
  for (final attribute in element.attributes.entries) {
    replacement.attributes[attribute.key] = attribute.value;
  }
  for (final child in element.nodes.toList()) {
    replacement.append(child);
  }
  element.replaceWith(replacement);
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
    final name = inner
        .replaceFirst(RegExp('^/+'), '')
        .split(RegExp(r'\s+'))
        .first
        .replaceAll('/', '');
    if (_voidElements.contains(name) &&
        !inner.startsWith('/') &&
        !inner.endsWith('/')) {
      output
        ..write(source.substring(copied, end))
        ..write('/>');
      copied = end + 1;
    }
    search = end + 1;
  }
  if (copied == 0) return source;
  output.write(source.substring(copied));
  return output.toString();
}

// ------------------------------------------------------------------- text

/// CHM text decoding: BOM → declared `charset` label → UTF-8 (if valid) →
/// Windows-1252. CJK charsets are not decoded (rendered via fallback).
String decodeChmText(Uint8List bytes) {
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    return utf8.decode(bytes.sublist(3), allowMalformed: true);
  }
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    return _decodeUtf16(bytes.sublist(2), littleEndian: true);
  }
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    return _decodeUtf16(bytes.sublist(2), littleEndian: false);
  }
  final declared = _declaredEncoding(bytes);
  if (declared != null) return declared;
  final isValidUtf8 = _isValidUtf8(bytes);
  return isValidUtf8 ? utf8.decode(bytes) : decodeCp1252(bytes);
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

String? _declaredEncoding(Uint8List bytes) {
  final head = utf8.decode(
    bytes.sublist(0, bytes.length < 4096 ? bytes.length : 4096),
    allowMalformed: true,
  );
  final lower = head.toLowerCase();
  final position = lower.indexOf('charset');
  if (position < 0) return null;
  var tail = lower.substring(position + 'charset'.length).trimLeft();
  if (tail.startsWith('=')) tail = tail.substring(1).trimLeft();
  tail = tail.replaceFirst(RegExp(r'^[\x22\x27]'), '');
  final label = tail.split(RegExp(r'[\x22\x27>\s;]')).first;
  return switch (label) {
    'utf-8' ||
    'utf8' ||
    'us-ascii' ||
    'ascii' => utf8.decode(bytes, allowMalformed: true),
    'utf-16le' => _decodeUtf16(bytes, littleEndian: true),
    'utf-16be' || 'utf-16' => _decodeUtf16(bytes, littleEndian: false),
    'windows-1252' ||
    'cp1252' ||
    '1252' ||
    'iso-8859-1' ||
    'latin1' ||
    'gb2312' ||
    'gbk' ||
    'gb18030' ||
    'big5' ||
    'shift_jis' ||
    'euc-kr' ||
    'windows-1251' => decodeCp1252(bytes),
    _ => null,
  };
}

bool _isValidUtf8(Uint8List bytes) {
  try {
    utf8.decode(bytes);
    return true;
  } on FormatException {
    return false;
  }
}

// ------------------------------------------------------------------ helpers

TocEntry _toTocEntry(_NavEntry entry, List<SpineItem> spine) {
  final href = entry.href;
  int? spineIndex;
  if (href != null) {
    for (final item in spine) {
      if (item.href.toLowerCase() == href.path.toLowerCase()) {
        spineIndex = item.index;
        break;
      }
    }
  }
  return TocEntry(
    label: entry.label,
    href: href == null ? '' : _joinHref(href),
    spineIndex: spineIndex,
    children: [for (final child in entry.children) _toTocEntry(child, spine)],
  );
}

Map<String, String> _tocTitlesByPath(List<_NavEntry> entries) {
  final titles = <String, String>{};
  void collect(List<_NavEntry> entries) {
    for (final entry in entries) {
      final href = entry.href;
      if (href != null) {
        titles.putIfAbsent(href.path.toLowerCase(), () => entry.label);
      }
      collect(entry.children);
    }
  }

  collect(entries);
  return titles;
}

String _normalizeText(String value) =>
    value.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).join(' ');

bool _isHtmlPath(String path) {
  final dot = path.lastIndexOf('.');
  if (dot < 0) return false;
  return switch (path.substring(dot + 1).toLowerCase()) {
    'html' || 'htm' || 'xhtml' => true,
    _ => false,
  };
}

String _mediaTypeForPath(String path) {
  final dot = path.lastIndexOf('.');
  if (dot < 0) return 'application/octet-stream';
  return switch (path.substring(dot + 1).toLowerCase()) {
    'html' || 'htm' || 'xhtml' => 'application/xhtml+xml',
    'css' => 'text/css',
    'svg' => 'image/svg+xml',
    'png' => 'image/png',
    'jpg' || 'jpeg' => 'image/jpeg',
    'gif' => 'image/gif',
    'bmp' => 'image/bmp',
    'webp' => 'image/webp',
    'woff' => 'font/woff',
    'woff2' => 'font/woff2',
    'otf' => 'font/otf',
    'ttf' => 'font/ttf',
    _ => 'application/octet-stream',
  };
}

String _sectionTitleFromPath(String path) {
  final normalized = path.replaceAll('\\', '/');
  var name = normalized.substring(normalized.lastIndexOf('/') + 1);
  final dot = name.lastIndexOf('.');
  if (dot > 0) name = name.substring(0, dot);
  final spaced = name.replaceAll(RegExp('[_-]'), ' ').trim();
  return spaced.isEmpty ? 'Untitled section' : spaced;
}

String _titleFromFileName(String fileName) {
  var name = fileName.replaceAll('\\', '/');
  name = name.substring(name.lastIndexOf('/') + 1);
  final dot = name.lastIndexOf('.');
  if (dot > 0) name = name.substring(0, dot);
  return name.isEmpty ? 'Untitled CHM' : name;
}
