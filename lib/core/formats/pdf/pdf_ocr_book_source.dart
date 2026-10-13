import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive_io.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:html/parser.dart' as html;
import 'package:html/dom.dart' as dom;

import '../../html_ir/html_ir_parser.dart';
import '../../ir/ir.dart';
import '../../ir/text_index.dart';
import '../image_dimensions.dart';
import 'pdf_book_source.dart';

enum PdfOcrViewMode { original, reflow }

/// Reads the desktop's derived-sync-v1 OCR archive. Extraction and Markdown
/// parsing run off the UI thread; only requested image bytes enter memory.
Future<PdfOcrBookSource?> loadPdfOcrBookSource(
  PdfBookSource original,
  Directory directory, {
  List<TocEntry> toc = const [],
}) async {
  final zip = File('${directory.path}/ocr.zip');
  if (!await zip.exists()) return null;
  final path = directory.path;
  final id = original.book.id;
  final document = await Isolate.run(() => _extractDocument(path, id));
  var mode = document['view_mode'] == 'reflow'
      ? PdfOcrViewMode.reflow
      : PdfOcrViewMode.original;
  final preference = File('$path/view-mode.json');
  if (await preference.exists()) {
    try {
      final value = jsonDecode(await preference.readAsString());
      if (value == 'original' || value == 'reflow') {
        mode = value == 'reflow'
            ? PdfOcrViewMode.reflow
            : PdfOcrViewMode.original;
      }
    } catch (_) {
      /* Ignore a damaged display preference. */
    }
  }
  return PdfOcrBookSource(original, document, directory, toc: toc, mode: mode);
}

Map<String, dynamic> _extractDocument(String path, String id) {
  final stat = File('$path/ocr.zip').statSync();
  final stamp = '${stat.size}:${stat.modified.microsecondsSinceEpoch}';
  final stampFile = File('$path/extracted-version');
  final reusable =
      stampFile.existsSync() && stampFile.readAsStringSync() == stamp;
  final input = InputFileStream('$path/ocr.zip');
  try {
    final archive = ZipDecoder().decodeStream(input);
    var total = 0;
    for (final entry in archive) {
      total += entry.size;
      if (entry.size > 512 * 1024 * 1024 ||
          total > 768 * 1024 * 1024 ||
          entry.isSymbolicLink ||
          !_safeArchiveName(entry.name)) {
        throw const FormatException('Invalid PDF OCR archive');
      }
    }
    final bytes = archive.find('document.json')?.readBytes();
    if (bytes == null) throw const FormatException('Missing PDF OCR document');
    final document = jsonDecode(utf8.decode(bytes));
    if (document is! Map<String, dynamic> ||
        document['version'] != 1 ||
        document['book_id'] != id ||
        document['pages'] is! List ||
        document['resources'] is! List) {
      throw const FormatException('Invalid PDF OCR document');
    }
    for (final resource in document['resources'] as List) {
      final name = resource['file_name'];
      if (name is! String || !_safeResourceName(name)) {
        throw const FormatException('Invalid PDF OCR resource');
      }
      final entry = archive.find('resources/$name');
      if (entry == null || !entry.isFile) {
        throw const FormatException('Missing PDF OCR resource');
      }
      final file = File('$path/resources/$name');
      if (reusable && file.existsSync() && file.lengthSync() == entry.size) {
        continue;
      }
      file.parent.createSync(recursive: true);
      final output = OutputFileStream('${file.path}.part');
      try {
        entry.writeContent(output);
      } finally {
        output.closeSync();
      }
      File('${file.path}.part').renameSync(file.path);
    }
    stampFile.writeAsStringSync(stamp, flush: true);
    return document;
  } finally {
    input.closeSync();
  }
}

bool _safeResourceName(String name) =>
    name.isNotEmpty &&
    name != '.' &&
    name != '..' &&
    !name.contains(RegExp(r'[/\\:\x00]'));

bool _safeArchiveName(String name) =>
    name == 'document.json' ||
    name == 'resources/' ||
    (name.startsWith('resources/') &&
        _safeResourceName(name.substring('resources/'.length)));

class PdfOcrBookSource
    implements BookSource, RasterResourceSource, DisposableBookSource {
  final BookSource original;
  final Directory directory;
  PdfOcrViewMode mode;
  late final Book reflowBook;
  late final List<TocEntry> originalToc;
  late final List<String> _pages;
  final List<(int, int)> _ranges = [];
  final Map<String, String> _resources = {};
  final Set<int> _specialPages = {};
  final Set<int> _fallbackPages = {};
  final Map<int, List<(String, String)>> _tocHeadings = {};
  final Map<int, Section> _cache = {};
  bool _disposed = false;

  PdfOcrBookSource(
    this.original,
    Map<String, dynamic> document,
    this.directory, {
    List<TocEntry> toc = const [],
    this.mode = PdfOcrViewMode.original,
  }) {
    _pages = [
      for (final page in document['pages'] as List)
        (page['markdown'] as String? ?? '').replaceAll('\r\n', '\n'),
    ];
    if (_pages.length != original.book.sectionCount) {
      throw const FormatException('PDF OCR page count does not match PDF');
    }
    for (var i = 0; i < _pages.length; i++) {
      if (_pages[i].trim().isEmpty ||
          RegExp(
            r'^\s*#{1,6}\s*第\s*\d+\s*页\s*本页(?:未识别到|尚未生成\s*OCR\s*)正文[。.]?\s*$',
          ).hasMatch(_pages[i])) {
        _pages[i] = '';
        _fallbackPages.add(i);
      }
    }
    for (final role in document['page_roles'] as List? ?? const []) {
      final page = (role['physical_page'] as num?)?.toInt();
      if (page != null && page > 0 && page <= _pages.length) {
        _specialPages.add(page - 1);
      }
    }
    for (final resource in document['resources'] as List) {
      final href = resource['href'] as String;
      final name = resource['file_name'] as String;
      if (!_safeResourceName(name)) {
        throw const FormatException('Invalid PDF OCR resource');
      }
      _resources[href] = '${directory.path}/resources/$name';
    }
    _joinPageParagraphs();
    final navigation = toc.isEmpty ? original.book.toc : toc;
    originalToc = navigation;
    final starts = <int>{0};
    int? firstPage(TocEntry entry) =>
        entry.spineIndex ??
        entry.children.map(firstPage).whereType<int>().firstOrNull;
    for (final entry in navigation) {
      final page = firstPage(entry);
      if (page != null && page >= 0 && page < _pages.length) starts.add(page);
    }
    final sorted = starts.toList()..sort();
    for (var i = 0; i < sorted.length; i++) {
      _ranges.add((
        sorted[i],
        i + 1 < sorted.length ? sorted[i + 1] : _pages.length,
      ));
    }
    final spine = [
      for (var i = 0; i < _ranges.length; i++)
        SpineItem(
          id: SpineItemId('pdf-ocr-reflow-${i + 1}'),
          index: i,
          href: 'Text/ocr-reflow-${i + 1}.xhtml',
        ),
    ];
    var nextTocAnchor = 0;
    String tocTarget(TocEntry entry, int page) {
      final key = _headingKey(entry.label);
      final firstChildPage = entry.children.firstOrNull?.spineIndex;
      final candidates = <int>[];
      for (
        var i = (page - 12).clamp(0, _pages.length - 1);
        i <= (page + 12).clamp(0, _pages.length - 1);
        i++
      ) {
        if (_specialPages.contains(i) ||
            (firstChildPage != null && i > firstChildPage)) {
          continue;
        }
        if (RegExp(
          r'^#{1,6}\s+(.+?)\s*#*$',
          multiLine: true,
        ).allMatches(_pages[i]).any((match) => _headingKey(match[1]!) == key)) {
          candidates.add(i);
        }
      }
      if (key.isEmpty || candidates.isEmpty) return reflowTarget(page);
      candidates.sort((a, b) => (a - page).abs().compareTo((b - page).abs()));
      final matched = candidates.first;
      final fragment = 'ocr-toc-${nextTocAnchor++}';
      (_tocHeadings[matched] ??= []).add((fragment, key));
      return 'Text/ocr-reflow-${sectionForPage(matched) + 1}.xhtml#$fragment';
    }

    List<TocEntry> remap(List<TocEntry> entries) {
      return [
        for (final entry in entries)
          () {
            final page = firstPage(entry);
            final target = page == null ? '' : tocTarget(entry, page);
            final index = spine.indexWhere(
              (item) => item.href == target.split('#').first,
            );
            return TocEntry(
              label: entry.label,
              href: target,
              spineIndex: index < 0 ? null : index,
              children: remap(entry.children),
            );
          }(),
      ];
    }

    // Targets only depend on ranges, so book construction can use them too.
    reflowBook = Book(
      id: original.book.id,
      metadata: BookMetadata(
        title: original.book.metadata.title,
        authors: original.book.metadata.authors,
        languages: original.book.metadata.languages,
        layout: RenditionLayout.reflowable,
      ),
      spine: spine,
      toc: remap(navigation),
      coverHref: original.book.coverHref,
    );
  }

  @override
  Book get book => mode == PdfOcrViewMode.reflow ? reflowBook : original.book;

  int sectionForPage(int page) {
    final index = _ranges.indexWhere((r) => page >= r.$1 && page < r.$2);
    return index < 0 ? 0 : index;
  }

  String reflowTarget(int page) =>
      'Text/ocr-reflow-${sectionForPage(page) + 1}.xhtml#pdf-page-${page + 1}';

  int physicalPage(int section, SourceAnchor? anchor, Section? content) {
    if (mode == PdfOcrViewMode.original) return section;
    return _physicalReflowPage(section, anchor, content);
  }

  int _physicalReflowPage(int section, SourceAnchor? anchor, Section? content) {
    var result = _ranges[section].$1;
    if (anchor == null || content == null) return result;
    final nodes = sectionTextNodes(
      content,
    ).map((b) => b.source.start.node).toList();
    final at = nodes.indexOf(anchor.node);
    int? ordinal(String node) =>
        int.tryParse(RegExp(r'^n(\d+)$').firstMatch(node)?[1] ?? '');
    final anchorOrdinal = ordinal(anchor.node);
    for (final marker in content.anchors) {
      final page = int.tryParse(marker.fragment.replaceFirst('pdf-page-', ''));
      final position = nodes.indexOf(marker.source.node);
      if (marker.fragment.startsWith('pdf-page-') &&
          page != null &&
          ((position >= 0 && position <= at) ||
              (at < 0 &&
                  anchorOrdinal != null &&
                  ordinal(marker.source.node) != null &&
                  ordinal(marker.source.node)! <= anchorOrdinal))) {
        result = page - 1;
      }
    }
    return result;
  }

  Future<String?> targetForLocator(LocatorV1 locator) async {
    final path = locator.href.split('#').first;
    if (book.spine.any((item) => item.href == path)) return null;
    var physical = original.book.spine.indexWhere((item) => item.href == path);
    if (physical < 0) {
      final section = reflowBook.spine.indexWhere((item) => item.href == path);
      if (section < 0) return null;
      physical = _physicalReflowPage(
        section,
        locator.source?.start,
        await _parseReflowSection(section),
      );
    }
    return mode == PdfOcrViewMode.reflow
        ? reflowTarget(physical)
        : original.book.spine[physical].href;
  }

  Future<void> saveMode() async {
    await directory.create(recursive: true);
    await File(
      '${directory.path}/view-mode.json',
    ).writeAsString(jsonEncode(mode.name));
  }

  void _joinPageParagraphs() {
    for (var i = 0; i + 1 < _pages.length; i++) {
      if (_specialPages.contains(i) || _specialPages.contains(i + 1)) continue;
      final left = _pages[i].trim().split(RegExp(r'\n\s*\n'));
      final right = _pages[i + 1].trim().split(RegExp(r'\n\s*\n'));
      final tail = left.last, head = right.first;
      bool plain(String value) =>
          value.isNotEmpty &&
          !value.contains(
            RegExp(
              r'^(?:#{1,6}\s|[-*+]\s|\d+[.)]\s|>|```|\|)|!\[|<|\$\$',
              multiLine: true,
            ),
          );
      if (!plain(tail) || !plain(head)) continue;
      final hyphen = RegExp(r'[-‐‑\u00ad]$').hasMatch(tail);
      final terminal = tail.replaceFirst(RegExp(r'''[”’"')）\]】]+$'''), '');
      if (!hyphen && RegExp(r'[.!?。！？；;:]$').hasMatch(terminal)) {
        if (!terminal.endsWith('.') || !RegExp(r'^[a-z]').hasMatch(head)) {
          continue;
        }
      }
      final space =
          RegExp(r'[A-Za-z0-9]$').hasMatch(tail) &&
          RegExp(r'^[A-Za-z0-9]').hasMatch(head);
      left[left.length - 1] = hyphen
          ? tail.substring(0, tail.length - 1) + head
          : tail + (space ? ' ' : '') + head;
      right.removeAt(0);
      _pages[i] = left.join('\n\n');
      _pages[i + 1] = right.join('\n\n');
    }
  }

  @override
  Future<Section> parseSection(int index) async {
    if (_disposed) throw StateError('PDF OCR source is disposed');
    if (mode == PdfOcrViewMode.original) return original.parseSection(index);
    return _parseReflowSection(index);
  }

  Future<Section> _parseReflowSection(int index) async {
    final cached = _cache.remove(index);
    if (cached != null) {
      _cache[index] = cached;
      return cached;
    }
    final descriptor = reflowBook.spine[index];
    final range = _ranges[index];
    final entries = <(int, String, String?)>[];
    for (var page = range.$1; page < range.$2; page++) {
      if (_specialPages.contains(page) || _fallbackPages.contains(page)) {
        final section = await original.parseSection(page);
        final image = section.blocks.whereType<ImageBlock>().firstOrNull;
        entries.add((page, '', image?.href));
      } else {
        entries.add((page, _pages[page], null));
      }
    }
    final section = await _parseOcrSectionInWorker(
      index,
      descriptor,
      entries,
      _tocHeadings,
      original.book.metadata.language,
    );
    if (_disposed) throw StateError('PDF OCR source is disposed');
    _cache[index] = section;
    while (_cache.length > 3) {
      _cache.remove(_cache.keys.first);
    }
    return section;
  }

  ui.Size? originalResourceSize(String href) => original is PdfBookSource
      ? (original as PdfBookSource).resourceSize(href)
      : null;

  @override
  Future<Uint8List?> resource(String href) async {
    final path = _resources[href.split('#').first];
    return path == null ? original.resource(href) : File(path).readAsBytes();
  }

  @override
  Future<ui.Image?> rasterResource(
    String href, {
    required int maxDimension,
  }) async {
    if (!_resources.containsKey(href) && original is RasterResourceSource) {
      return (original as RasterResourceSource).rasterResource(
        href,
        maxDimension: maxDimension,
      );
    }
    final bytes = await resource(href);
    if (bytes == null) return null;
    final size = readImageDimensions(bytes);
    final longest = size == null
        ? maxDimension
        : (size.$1 > size.$2 ? size.$1 : size.$2);
    final scale = longest > maxDimension ? maxDimension / longest : 1.0;
    final codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: size == null
          ? null
          : (size.$1 * scale).round().clamp(1, maxDimension),
      targetHeight: size == null
          ? null
          : (size.$2 * scale).round().clamp(1, maxDimension),
    );
    try {
      return (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _cache.clear();
    if (original is DisposableBookSource) {
      (original as DisposableBookSource).dispose();
    }
  }
}

Future<Section> _parseOcrSectionInWorker(
  int index,
  SpineItem descriptor,
  List<(int, String, String?)> entries,
  Map<int, List<(String, String)>> headings,
  String publicationLanguage,
) => Isolate.run(() {
  final body = StringBuffer();
  for (final entry in entries) {
    body.write('<div id="pdf-page-${entry.$1 + 1}">');
    body.write(
      entry.$3 == null
          ? _markdownHtml(
              entry.$2,
              headings[entry.$1] ?? const [],
              entry.$1,
              publicationLanguage,
            )
          : '<img src="../${const HtmlEscape(HtmlEscapeMode.attribute).convert(entry.$3!)}" />',
    );
    body.write('</div>');
  }
  return const HtmlIrParser().parse(
    spineIndex: index,
    spineId: descriptor.id,
    href: descriptor.href,
    xhtml:
        '<html><body${publicationLanguage.isEmpty ? '' : ' lang="${const HtmlEscape(HtmlEscapeMode.attribute).convert(publicationLanguage)}"'}>$body</body></html>',
    basePath: 'Text',
  );
});

String _headingKey(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');

String _markdownHtml(
  String markdown,
  List<(String, String)> anchors,
  int page,
  String publicationLanguage,
) {
  final rendered = md.markdownToHtml(
    markdown.replaceAllMapped(
      RegExp(r'\$\$([\s\S]+?)\$\$'),
      (m) => '\$\$${m[1]!.trim().replaceAll('\n', ' ')}\$\$',
    ),
    extensionSet: md.ExtensionSet.gitHubFlavored,
    inlineSyntaxes: [_OcrMathSyntax()],
  );
  final fragment = html.parseFragment(rendered);
  if (publicationLanguage.isEmpty) {
    for (final paragraph in fragment.querySelectorAll('p,li,dd,figcaption')) {
      var declared = false;
      for (
        dom.Element? element = paragraph;
        element != null;
        element = element.parent
      ) {
        if ((element.attributes['lang'] ?? element.attributes['xml:lang'] ?? '')
            .trim()
            .isNotEmpty) {
          declared = true;
          break;
        }
      }
      if (declared) continue;
      // Formulae and code are not evidence of a paragraph's prose language.
      final prose = paragraph.clone(true);
      for (final excluded in prose.querySelectorAll('code,pre,.math')) {
        excluded.remove();
      }
      if (_looksLikeEnglishOcrProse(prose.text)) {
        paragraph.attributes['lang'] = 'en';
      }
    }
  }
  final pending = anchors.toList();
  for (final heading in fragment.querySelectorAll('h1,h2,h3,h4,h5,h6')) {
    final key = _headingKey(heading.text);
    final index = pending.indexWhere((anchor) => anchor.$2 == key);
    if (index < 0) continue;
    final anchor = pending.removeAt(index);
    heading.id = anchor.$1;
  }
  for (final reference in fragment.querySelectorAll('sup.footnote-ref a')) {
    reference.attributes['role'] = 'doc-noteref';
  }
  for (final note in fragment.querySelectorAll('.footnotes li')) {
    note.attributes['role'] = 'doc-footnote';
  }
  for (final backlink in fragment.querySelectorAll('a.footnote-backref')) {
    backlink.attributes['role'] = 'doc-backlink';
  }
  // Markdown footnote labels are scoped to a physical page, unlike the
  // continuous publication section. Prevent repeated labels from colliding.
  for (final element in fragment.querySelectorAll('[id]')) {
    if (element.id.startsWith('fn-') || element.id.startsWith('fnref-')) {
      element.id = 'ocr-page-${page + 1}-${element.id}';
    }
  }
  for (final link in fragment.querySelectorAll('a[href]')) {
    final href = link.attributes['href']!;
    if (href.startsWith('#fn-') || href.startsWith('#fnref-')) {
      link.attributes['href'] = '#ocr-page-${page + 1}-${href.substring(1)}';
    }
  }
  for (final paragraph in fragment.querySelectorAll('p')) {
    var excluded = false;
    for (
      var parent = paragraph.parent;
      parent != null;
      parent = parent.parent
    ) {
      if (const {
            'blockquote',
            'pre',
            'ul',
            'ol',
            'dl',
            'table',
          }.contains(parent.localName) ||
          parent.classes.contains('footnotes')) {
        excluded = true;
        break;
      }
    }
    if (excluded || paragraph.querySelector('img,.math-display') != null) {
      continue;
    }
    final lines = paragraph.innerHtml.split(RegExp(r'<br\s*/?>'));
    int visible(String line) => html
        .parseFragment(line)
        .text!
        .replaceAll(RegExp(r'\s'), '')
        .runes
        .length;
    if (lines.length > 1 &&
        lines.map(visible).fold<int>(0, (sum, n) => sum + n) >= 48 &&
        lines.take(lines.length - 1).any((line) => visible(line) >= 24)) {
      for (final br in paragraph.querySelectorAll('br')) {
        br.replaceWith(dom.Text(' '));
      }
    }
  }
  return fragment.outerHtml;
}

bool _looksLikeEnglishOcrProse(String text) {
  final letters = RegExp(r'\p{L}', unicode: true).allMatches(text).length;
  final ascii = RegExp(r'[A-Za-z]').allMatches(text).length;
  if (letters == 0 || ascii < 20 || ascii * 100 < letters * 85) return false;
  final words = RegExp(
    r'\b[A-Za-z]+\b',
  ).allMatches(text.toLowerCase()).map((m) => m[0]!).toList();
  if (words.length < 5) return false;
  const cues = {
    'the',
    'and',
    'of',
    'to',
    'is',
    'are',
    'was',
    'were',
    'with',
    'from',
    'for',
    'this',
    'that',
    'these',
    'those',
    'which',
    'have',
    'has',
    'will',
    'can',
    'not',
    'into',
    'their',
    'there',
    'when',
    'between',
    'through',
    'about',
    'because',
    'than',
  };
  return words.where(cues.contains).toSet().length >= 2;
}

class _OcrMathSyntax extends md.InlineSyntax {
  _OcrMathSyntax()
    : super(r'\$\$([^$]+)\$\$|\$([^$\n]+)\$|\\\((.+?)\\\)|\\\[([\s\S]+?)\\\]');
  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final display = match[1] != null || match[4] != null;
    final value = match[1] ?? match[2] ?? match[3] ?? match[4]!;
    final element = md.Element.text('span', value.trim());
    element.attributes['class'] = display
        ? 'math math-display'
        : 'math math-inline';
    parser.addNode(element);
    return true;
  }
}
