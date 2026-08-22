/// Pure-Dart PDF adapter for Torto's format-neutral reading model.
///
/// Parsing, metadata, outlines, text geometry, and graphics interpretation are
/// delegated to the dart-pdf packages. Torto owns only the BookSource adapter,
/// fixed-page resource naming, and reader-facing cache boundary.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:pdf_document/pdf_document.dart' as pdf;
import 'package:pdf_graphics/pdf_graphics.dart' as graphics;

import '../../ir/ir.dart';
import 'pdf_rasterizer.dart';

const String _coverPath = 'Cover/thumbnail.png';
const int _readerPageDimension = 2048;
const int _coverDimension = 384;

/// Opens a PDF from raw bytes. [filePath] is retained for the common format
/// dispatcher API, but PDF parsing and rendering no longer depend on it.
Future<BookSource> openPdf(
  Uint8List bytes,
  String fileName, {
  String? filePath,
  String? titleHint,
  String? publicationIdHint,
}) async {
  final pdf.PdfDocument document;
  try {
    document = pdf.PdfDocument.open(bytes);
    if (document.pageCount == 0) {
      throw const FormatException('PDF does not contain any pages');
    }
  } on FormatException {
    rethrow;
  } catch (error) {
    throw FormatException('Invalid or unsupported PDF: $error');
  }

  final info = document.info;
  final hintedTitle = titleHint?.trim() ?? '';
  final metadataTitle = info['Title']?.trim() ?? '';
  final title = hintedTitle.isNotEmpty
      ? hintedTitle
      : metadataTitle.isNotEmpty
      ? metadataTitle
      : _titleFromFileName(fileName);
  final author = info['Author']?.trim() ?? '';
  final publicationId = publicationIdHint?.trim().isNotEmpty == true
      ? publicationIdHint!.trim()
      : sha256.convert(bytes).toString();

  final spine = [
    for (var index = 0; index < document.pageCount; index++)
      SpineItem(index: index, href: _sectionPath(index)),
  ];
  final toc = _promoteSingleTocRoot(
    _outlineEntries(pdf.PdfOutline.of(document).items, spine),
  );

  return PdfBookSource._(
    document: document,
    book: Book(
      id: publicationId,
      metadata: BookMetadata(
        title: title,
        authors: [if (author.isNotEmpty) author],
      ),
      spine: spine,
      toc: toc,
      coverHref: _coverPath,
    ),
  );
}

/// Fixed-layout PDF source, analogous to desktop Torto's PDF catalog adapter.
///
/// Page rasters stay outside the format-neutral IR: sections reference a
/// synthetic image resource, while [RasterResourceSource] supplies the image
/// directly. [pageText] exposes the positioned glyph layer for search and
/// selection without forcing it through reflow pagination.
class PdfBookSource
    implements BookSource, RasterResourceSource, DisposableBookSource {
  static const int _maxTextCacheEntries = 12;

  @override
  final Book book;

  pdf.PdfDocument? _document;
  final Map<int, graphics.PdfPageText?> _textCache = {};

  PdfBookSource._({required pdf.PdfDocument document, required this.book})
    : _document = document;

  pdf.PdfDocument get _activeDocument =>
      _document ?? (throw StateError('PDF source has been disposed'));

  int get pageCount => _activeDocument.pageCount;

  /// Extracts Unicode text plus page-space glyph geometry on demand.
  graphics.PdfPageText? pageText(int pageIndex) {
    _checkPageIndex(pageIndex);
    if (_textCache.containsKey(pageIndex)) {
      final cached = _textCache.remove(pageIndex);
      _textCache[pageIndex] = cached;
      return cached;
    }
    final extracted = () {
      try {
        return graphics.PdfTextExtractor.extract(_activeDocument, pageIndex);
      } catch (_) {
        return null;
      }
    }();
    _textCache[pageIndex] = extracted;
    if (_textCache.length > _maxTextCacheEntries) {
      _textCache.remove(_textCache.keys.first);
    }
    return extracted;
  }

  @override
  Future<Section> parseSection(int index) async {
    _checkPageIndex(index);
    return Section(
      spineIndex: index,
      href: book.spine[index].href,
      blocks: [
        ImageBlock(href: _pagePath(index), alt: 'PDF page ${index + 1}'),
      ],
    );
  }

  @override
  Future<ui.Image?> rasterResource(
    String href, {
    required int maxDimension,
  }) async {
    final pageIndex = _pageIndexFromHref(href);
    if (pageIndex == null) return null;
    return rasterizePdfPage(
      _activeDocument.page(pageIndex),
      maxDimension: maxDimension,
    );
  }

  @override
  Future<Uint8List?> resource(String href) async {
    if (href == _coverPath) {
      return encodePdfPagePng(
        _activeDocument.page(0),
        maxDimension: _coverDimension,
      );
    }
    final pageIndex = _pageIndexFromHref(href);
    if (pageIndex == null) return null;
    // Compatibility path for non-reader consumers. ReaderController uses
    // rasterResource and therefore does not pay this PNG encode/decode cost.
    return encodePdfPagePng(
      _activeDocument.page(pageIndex),
      maxDimension: _readerPageDimension,
    );
  }

  @override
  void dispose() {
    if (_document == null) return;
    _textCache.clear();
    _document = null;
    clearPdfRasterCache();
  }

  int? _pageIndexFromHref(String href) {
    final match = RegExp(r'^Pages/page-([0-9]{5})\.png$').firstMatch(href);
    if (match == null) return null;
    final index = int.parse(match.group(1)!) - 1;
    return index >= 0 && index < pageCount ? index : null;
  }

  void _checkPageIndex(int index) {
    if (index < 0 || index >= pageCount) {
      throw FormatException('PDF page $index is out of range');
    }
  }
}

List<TocEntry> _outlineEntries(
  List<pdf.PdfOutlineItem> items,
  List<SpineItem> spine,
) {
  final entries = <TocEntry>[];
  for (final item in items) {
    final label = item.title.trim();
    if (label.isEmpty) continue;
    final destination = item.destination?.pageIndex;
    final spineIndex =
        destination != null && destination >= 0 && destination < spine.length
        ? destination
        : null;
    entries.add(
      TocEntry(
        label: label,
        href: spineIndex == null ? '' : spine[spineIndex].href,
        spineIndex: spineIndex,
        children: _outlineEntries(item.children, spine),
      ),
    );
  }
  return entries;
}

List<TocEntry> _promoteSingleTocRoot(List<TocEntry> entries) {
  if (entries.length == 1 && entries.single.children.isNotEmpty) {
    return entries.single.children;
  }
  return entries;
}

String _sectionPath(int index) => 'Text/section-${index + 1}.xhtml';

String _pagePath(int index) =>
    'Pages/page-${(index + 1).toString().padLeft(5, '0')}.png';

String _titleFromFileName(String fileName) {
  var name = fileName.replaceAll('\\', '/');
  name = name.substring(name.lastIndexOf('/') + 1);
  final dot = name.lastIndexOf('.');
  if (dot > 0) name = name.substring(0, dot);
  return name.isEmpty ? '未命名文档' : name;
}
