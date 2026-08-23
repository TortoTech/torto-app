/// EPUB container → Reading IR.
///
/// Dart port of torto's `crates/formats/src/epub.rs`: opens the ZIP
/// container, reads `META-INF/container.xml` and the OPF package document,
/// builds the book descriptor (metadata, spine, TOC, cover), and parses
/// spine sections lazily via [HtmlIrParser].
///
/// Fail-soft throughout: malformed navigation, missing resources, or a bad
/// section never abort the book — only a missing container or an unusable
/// package document is fatal.
library;

import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:xml/xml.dart';

import '../html_ir/html_ir_parser.dart';
import '../html_ir/package_path.dart';
import '../html_ir/tolerant_xml.dart';
import '../ir/ir.dart';

class _ManifestItem {
  final String id;
  final String href; // canonical root-relative path
  final String mediaType;
  final List<String> properties;

  const _ManifestItem({
    required this.id,
    required this.href,
    required this.mediaType,
    this.properties = const [],
  });
}

/// [BookSource] backed by EPUB file bytes.
class EpubBookSource implements BookSource {
  /// Zip entries by both their raw name and their percent-decoded,
  /// normalized name (real-world EPUBs disagree on whether entry names are
  /// percent-encoded).
  final Map<String, ArchiveFile> _entries = {};

  late Book _book;

  @override
  Book get book => _book;

  final HtmlIrParser _parser = const HtmlIrParser();
  final Map<String, Uint8List?> _resourceCache = {};
  final Map<int, Section> _sectionCache = {};

  EpubBookSource._();

  /// Opens an EPUB from its raw file bytes.
  ///
  /// Throws [FormatException] when the bytes are not a ZIP archive, when
  /// `META-INF/container.xml` is missing or has no rootfile, or when the
  /// package document cannot be parsed at all.
  static Future<EpubBookSource> fromBytes(
    Uint8List bytes, {
    String? publicationIdHint,
  }) async {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (error) {
      throw FormatException('invalid EPUB ZIP archive: $error');
    }

    final source = EpubBookSource._();
    for (final file in archive.files) {
      if (!file.isFile) continue;
      source._entries[file.name] = file;
      final decoded = normalizePackagePath(safePercentDecode(file.name));
      source._entries.putIfAbsent(decoded, () => file);
    }

    final containerText = source._readXmlText('META-INF/container.xml');
    if (containerText == null) {
      throw const FormatException('EPUB is missing META-INF/container.xml');
    }
    final opfPath = _parseContainer(containerText);
    if (opfPath == null) {
      throw const FormatException(
        'EPUB container.xml has no rootfile full-path',
      );
    }

    final opfDir = packageDirname(opfPath);
    final opfText = source._readXmlText(opfPath);
    if (opfText == null) {
      throw FormatException('EPUB package document not found: $opfPath');
    }
    final package = tryParseXmlTolerant(opfText);
    if (package == null) {
      throw FormatException('EPUB package document is not valid XML: $opfPath');
    }

    final hintedId = publicationIdHint?.trim() ?? '';
    final id = hintedId.isNotEmpty
        ? hintedId
        : sha256.convert(bytes).toString();
    final model = _PackageModel.parse(package, opfDir);
    final spine = model.buildSpine();
    final toc = source._parseNavigation(model, spine);
    final cover = model.coverHref;

    source._book = Book(
      id: id,
      metadata: model.metadata,
      spine: spine,
      toc: toc,
      coverHref: cover,
    );
    return source;
  }

  /// Reads and indexes an EPUB outside the UI isolate. This keeps large books
  /// with thousands of ZIP entries from stalling page transitions while the
  /// package manifest is opened.
  static Future<EpubBookSource> fromFileInBackground(
    String path, {
    String? publicationIdHint,
  }) => Isolate.run(() async {
    final bytes = await File(path).readAsBytes();
    return fromBytes(bytes, publicationIdHint: publicationIdHint);
  });

  /// Opens already-loaded EPUB bytes outside the UI isolate. A transferable
  /// buffer avoids costly message serialization when crossing isolates.
  static Future<EpubBookSource> fromBytesInBackground(
    Uint8List bytes, {
    String? publicationIdHint,
  }) {
    final transferable = TransferableTypedData.fromList([bytes]);
    return Isolate.run(
      () => fromBytes(
        transferable.materialize().asUint8List(),
        publicationIdHint: publicationIdHint,
      ),
    );
  }

  /// Reads and decodes an XML resource, tolerating BOMs, DOCTYPE
  /// declarations, and stray ampersands. Returns null when absent.
  String? _readXmlText(String path) {
    final bytes = _readEntry(path);
    return bytes == null ? null : decodeXmlBytes(bytes);
  }

  Uint8List? _readEntry(String path) {
    if (_resourceCache.containsKey(path)) return _resourceCache[path];
    Uint8List? bytes;
    try {
      bytes = _entries[path]?.readBytes();
    } catch (_) {
      bytes = null;
    }
    _resourceCache[path] = bytes;
    return bytes;
  }

  @override
  Future<Uint8List?> resource(String href) async {
    final (path, _) = splitPackageFragment(href);
    return _readEntry(normalizePackagePath(safePercentDecode(path)));
  }

  @override
  Future<Section> parseSection(int index) async {
    final cached = _sectionCache[index];
    if (cached != null) return cached;
    final item = book.spine[index];
    Section section;
    try {
      final text = _readXmlText(item.href);
      if (text == null) {
        section = Section(spineIndex: index, href: item.href, blocks: const []);
      } else {
        section = _parser.parse(
          spineIndex: index,
          href: item.href,
          xhtml: text,
          basePath: packageDirname(item.href),
        );
      }
    } catch (_) {
      // A single bad section must not kill the book.
      section = Section(spineIndex: index, href: item.href, blocks: const []);
    }
    _sectionCache[index] = section;
    return section;
  }

  // ------------------------------------------------------------------- TOC

  List<TocEntry> _parseNavigation(_PackageModel model, List<SpineItem> spine) {
    // EPUB 3 Nav document first, NCX fallback.
    final navItem = model.items
        .where((item) => item.properties.contains('nav'))
        .firstOrNull;
    if (navItem != null) {
      final text = _readXmlText(navItem.href);
      if (text != null) {
        final document = tryParseXmlTolerant(text);
        if (document != null) {
          final toc = _parseNavDocument(
            document,
            packageDirname(navItem.href),
            spine,
          );
          if (toc.isNotEmpty) return toc;
        }
      }
    }

    final ncxItem =
        (model.ncxId == null ? null : model.manifest[model.ncxId!]) ??
        model.items
            .where((item) => item.mediaType == 'application/x-dtbncx+xml')
            .firstOrNull;
    if (ncxItem == null) return const [];
    final text = _readXmlText(ncxItem.href);
    if (text == null) return const [];
    final document = tryParseXmlTolerant(text);
    if (document == null) return const [];
    return _parseNcx(document, packageDirname(ncxItem.href), spine);
  }

  int? _spineIndexFor(List<SpineItem> spine, String href) {
    final (path, _) = splitPackageFragment(href);
    for (final item in spine) {
      if (item.href == path) return item.index;
    }
    return null;
  }

  List<TocEntry> _parseNavDocument(
    XmlDocument document,
    String navDir,
    List<SpineItem> spine,
  ) {
    XmlElement? nav;
    for (final element in document.descendants.whereType<XmlElement>()) {
      if (_localName(element) != 'nav') continue;
      final type = _localAttr(element, 'type') ?? '';
      if (type.split(RegExp(r'\s+')).contains('toc')) {
        nav = element;
        break;
      }
    }
    if (nav == null) return const [];
    final list = nav.childElements
        .where((element) => _localName(element) == 'ol')
        .firstOrNull;
    if (list == null) return const [];
    return _parseNavList(list, navDir, spine);
  }

  List<TocEntry> _parseNavList(
    XmlElement list,
    String navDir,
    List<SpineItem> spine,
  ) {
    final entries = <TocEntry>[];
    for (final item in list.childElements) {
      if (_localName(item) != 'li') continue;
      final labelNode = item.childElements
          .where(
            (element) =>
                _localName(element) == 'a' || _localName(element) == 'span',
          )
          .firstOrNull;
      final label = labelNode == null
          ? 'Untitled section'
          : _normalizedText(labelNode);
      var href = '';
      final rawHref = labelNode == null ? null : _localAttr(labelNode, 'href');
      if (rawHref != null &&
          rawHref.trim().isNotEmpty &&
          !isExternalHref(rawHref.trim())) {
        href = resolvePackageHref(navDir, rawHref);
      }
      final children = <TocEntry>[];
      for (final child in item.childElements) {
        if (_localName(child) == 'ol') {
          children.addAll(_parseNavList(child, navDir, spine));
        }
      }
      entries.add(
        TocEntry(
          label: label.isEmpty ? 'Untitled section' : label,
          href: href,
          spineIndex: href.isEmpty ? null : _spineIndexFor(spine, href),
          children: children,
        ),
      );
    }
    return entries;
  }

  List<TocEntry> _parseNcx(
    XmlDocument document,
    String ncxDir,
    List<SpineItem> spine,
  ) {
    final navMap = document.descendants
        .whereType<XmlElement>()
        .where((element) => _localName(element) == 'navmap')
        .firstOrNull;
    if (navMap == null) return const [];
    return _parseNavPoints(navMap, ncxDir, spine);
  }

  List<TocEntry> _parseNavPoints(
    XmlElement parent,
    String ncxDir,
    List<SpineItem> spine,
  ) {
    final entries = <TocEntry>[];
    for (final point in parent.childElements) {
      if (_localName(point) != 'navpoint') continue;
      var label = 'Untitled section';
      for (final descendant in point.descendants.whereType<XmlElement>()) {
        if (_localName(descendant) == 'navlabel') {
          label = _normalizedText(descendant);
          break;
        }
      }
      var href = '';
      final content = point.childElements
          .where((element) => _localName(element) == 'content')
          .firstOrNull;
      final src = content == null ? null : _localAttr(content, 'src');
      if (src != null && src.trim().isNotEmpty && !isExternalHref(src.trim())) {
        href = resolvePackageHref(ncxDir, src);
      }
      entries.add(
        TocEntry(
          label: label.isEmpty ? 'Untitled section' : label,
          href: href,
          spineIndex: href.isEmpty ? null : _spineIndexFor(spine, href),
          children: _parseNavPoints(point, ncxDir, spine),
        ),
      );
    }
    return entries;
  }
}

/// Parses `META-INF/container.xml` → rootfile OPF path (package-root
/// relative, decoded). Returns null when no rootfile is present.
String? _parseContainer(String containerText) {
  final document = tryParseXmlTolerant(containerText);
  if (document == null) return null;
  for (final element in document.descendants.whereType<XmlElement>()) {
    if (_localName(element) == 'rootfile') {
      final fullPath = _localAttr(element, 'full-path');
      if (fullPath != null && fullPath.trim().isNotEmpty) {
        return normalizePackagePath(safePercentDecode(fullPath.trim()));
      }
    }
  }
  return null;
}

String _localName(XmlElement element) => element.name.local.toLowerCase();

String? _localAttr(XmlElement element, String name) {
  final direct = element.getAttribute(name);
  if (direct != null) return direct;
  for (final attribute in element.attributes) {
    if (attribute.name.local.toLowerCase() == name) return attribute.value;
  }
  return null;
}

String _normalizedText(XmlElement element) {
  final text = element.descendants
      .whereType<XmlText>()
      .map((node) => node.value)
      .join()
      .split(RegExp(r'\s+'))
      .where((word) => word.isNotEmpty)
      .join(' ');
  return text.trim();
}

class _PackageModel {
  final BookMetadata metadata;
  final Map<String, _ManifestItem> manifest;
  final List<_ManifestItem> items; // manifest order
  final List<String> spineIdrefs;
  final String? ncxId;
  final String? coverHref;

  _PackageModel({
    required this.metadata,
    required this.manifest,
    required this.items,
    required this.spineIdrefs,
    this.ncxId,
    this.coverHref,
  });

  static _PackageModel parse(XmlDocument document, String opfDir) {
    XmlElement? package;
    for (final element in document.descendants.whereType<XmlElement>()) {
      if (_localName(element) == 'package') {
        package = element;
        break;
      }
    }
    if (package == null) {
      throw const FormatException('OPF document has no package element');
    }

    // ---- metadata
    var title = '';
    final authors = <String>[];
    final languages = <String>[];
    String? coverMetaId;
    for (final child in package.childElements) {
      if (_localName(child) != 'metadata') continue;
      for (final field in child.descendants.whereType<XmlElement>()) {
        switch (_localName(field)) {
          case 'title':
            if (title.isEmpty) title = _normalizedText(field);
          case 'creator':
            final name = _normalizedText(field);
            if (name.isNotEmpty) authors.add(name);
          case 'language':
            final language = _normalizedText(field);
            if (language.isNotEmpty) languages.add(language);
          case 'meta':
            if (_localAttr(field, 'name') == 'cover') {
              coverMetaId = _localAttr(field, 'content');
            }
        }
      }
      break;
    }

    // ---- manifest
    final manifest = <String, _ManifestItem>{};
    final items = <_ManifestItem>[];
    for (final child in package.childElements) {
      if (_localName(child) != 'manifest') continue;
      for (final item in child.childElements) {
        if (_localName(item) != 'item') continue;
        final id = _localAttr(item, 'id');
        final rawHref = _localAttr(item, 'href');
        final mediaType = _localAttr(item, 'media-type') ?? '';
        if (id == null || rawHref == null || rawHref.trim().isEmpty) {
          continue;
        }
        if (manifest.containsKey(id)) continue; // fail-soft on duplicates
        final properties = (_localAttr(item, 'properties') ?? '')
            .split(RegExp(r'\s+'))
            .where((token) => token.isNotEmpty)
            .toList();
        final entry = _ManifestItem(
          id: id,
          href: resolvePackageHref(opfDir, rawHref),
          mediaType: mediaType,
          properties: properties,
        );
        manifest[id] = entry;
        items.add(entry);
      }
      break;
    }

    // ---- spine
    final spineIdrefs = <String>[];
    String? ncxId;
    for (final child in package.childElements) {
      if (_localName(child) != 'spine') continue;
      ncxId = _localAttr(child, 'toc');
      for (final itemref in child.childElements) {
        if (_localName(itemref) != 'itemref') continue;
        final idref = _localAttr(itemref, 'idref');
        if (idref != null) spineIdrefs.add(idref);
      }
      break;
    }

    // ---- cover: EPUB3 properties="cover-image", else EPUB2 <meta name="cover">
    String? coverHref;
    for (final item in items) {
      if (item.properties.contains('cover-image')) {
        coverHref = item.href;
        break;
      }
    }
    if (coverHref == null && coverMetaId != null) {
      coverHref = manifest[coverMetaId]?.href;
    }

    return _PackageModel(
      metadata: BookMetadata(
        title: title,
        authors: authors,
        languages: languages,
      ),
      manifest: manifest,
      items: items,
      spineIdrefs: spineIdrefs,
      ncxId: ncxId,
      coverHref: coverHref,
    );
  }

  List<SpineItem> buildSpine() {
    final spine = <SpineItem>[];
    for (final idref in spineIdrefs) {
      final item = manifest[idref];
      if (item == null) continue; // fail-soft: skip dangling references
      spine.add(SpineItem(index: spine.length, href: item.href));
    }
    return spine;
  }
}
