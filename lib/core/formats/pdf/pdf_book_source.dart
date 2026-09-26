/// PDF adapter for Torto's format-neutral reading model.
///
/// Parsing, metadata, outlines, text geometry, and graphics interpretation are
/// delegated to the dart-pdf packages. Torto owns only the BookSource adapter,
/// fixed-page resource naming, and reader-facing cache boundary.
library;

import 'dart:typed_data';
import 'dart:isolate';
import 'dart:async';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../../diagnostics.dart';
import 'package:dart_pdf_editor/dart_pdf_editor.dart'
    show
        PdfRenderWorker,
        pdfRenderWorkerPoolSize,
        pdfRenderWorkerCacheBudgetBytes,
        pdfRenderWorkerCacheMaxEntries;
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:pdf_document/pdf_document.dart' as pdf;
import 'package:pdf_graphics/pdf_graphics.dart' as graphics;

import '../../ir/ir.dart';
import 'pdf_rasterizer.dart';
import 'pdf_raster_cache.dart';

const String _coverPath = 'Cover/thumbnail.png';
const int _readerPageDimension = 2048;
const int _coverDimension = 384;

/// Opens a PDF with portable Dart metadata, interpretation and rasterization.
Future<BookSource> openPdf(
  Uint8List bytes,
  String fileName, {
  String? filePath,
  String? titleHint,
  String? publicationIdHint,
  Directory? rasterCacheDirectory,
}) async {
  final data = await ReaderDiagnostics.instance.measure(
    'pdf.open',
    () => Isolate.run(
      () => _parsePdf(bytes, fileName, titleHint, publicationIdHint),
    ),
  );
  pdfRenderWorkerPoolSize = 1;
  pdfRenderWorkerCacheBudgetBytes = 24 * 1024 * 1024;
  pdfRenderWorkerCacheMaxEntries = 3;
  PdfRasterCache? cache;
  try {
    final root =
        rasterCacheDirectory ??
        (filePath == null
            ? null
            : Directory(
                '${(await getTemporaryDirectory()).path}/torto-pdf-raster-v1',
              ));
    if (root != null) cache = PdfRasterCache(root, data.$3);
  } catch (_) {
    /* Cache availability must not determine whether a PDF opens. */
  }
  return PdfBookSource._(
    document: data.$1,
    book: data.$2,
    workerBytes: bytes,
    rasterCache: cache,
  );
}

(pdf.PdfDocument, Book, String) _parsePdf(
  Uint8List bytes,
  String fileName,
  String? titleHint,
  String? publicationIdHint,
) {
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
  final fingerprint = sha256.convert(bytes).toString();
  final publicationId = publicationIdHint?.trim().isNotEmpty == true
      ? publicationIdHint!.trim()
      : fingerprint;

  final spine = [
    for (var index = 0; index < document.pageCount; index++)
      SpineItem(
        index: index,
        href: _sectionPath(index),
        id: SpineItemId('pdf-page-${index + 1}'),
      ),
  ];
  final toc = _promoteSingleTocRoot(
    _outlineEntries(pdf.PdfOutline.of(document).items, spine),
  );

  final book = Book(
    id: publicationId,
    metadata: BookMetadata(
      title: title,
      authors: [if (author.isNotEmpty) author],
    ),
    spine: spine,
    toc: toc,
    coverHref: _coverPath,
  );
  return (document, book, fingerprint);
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
  final Uint8List _workerBytes;
  PdfRenderWorker? _worker;
  final PdfRasterCache? _rasterCache;
  PdfRenderWorker get _portableWorker =>
      _worker ??= PdfRenderWorker.start(_workerBytes);
  final Map<int, graphics.PdfPageText?> _textCache = {};

  PdfBookSource._({
    required pdf.PdfDocument document,
    required this.book,
    required Uint8List workerBytes,
    required PdfRasterCache? rasterCache,
  }) : _document = document,
       _workerBytes = workerBytes,
       _rasterCache = rasterCache;

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
      id: book.spine[index].id,
      spineIndex: index,
      href: book.spine[index].href,
      blocks: [
        ImageBlock(
          href: _pagePath(index),
          alt: 'PDF page ${index + 1}',
          fixedPage: true,
        ),
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
    return _renderPage(pageIndex, maxDimension);
  }

  Future<ui.Image> _renderPage(
    int pageIndex,
    int maxDimension, {
    bool persist = true,
  }) async {
    final cached = await _rasterCache?.read(pageIndex, maxDimension);
    if (_document == null) throw StateError('PDF source has been disposed');
    if (cached != null) {
      try {
        final codec = await ui.instantiateImageCodec(cached);
        try {
          final image = (await codec.getNextFrame()).image;
          if (_document == null) {
            image.dispose();
            throw StateError('PDF source has been disposed');
          }
          ReaderDiagnostics.instance.event('pdf.cache.hit', {
            'page': pageIndex,
            'dimension': maxDimension,
          });
          return image;
        } finally {
          codec.dispose();
        }
      } on Exception {
        await _rasterCache?.remove(pageIndex, maxDimension);
      }
    }
    final image = await rasterizePdfPage(
      _activeDocument.page(pageIndex),
      maxDimension: maxDimension,
      worker: _portableWorker,
      pageIndex: pageIndex,
    );
    if (_document == null) {
      image.dispose();
      throw StateError('PDF source has been disposed');
    }
    if (persist && _rasterCache != null) {
      unawaited(_persistRaster(image.clone(), pageIndex, maxDimension));
    }
    return image;
  }

  Future<void> _persistRaster(
    ui.Image image,
    int pageIndex,
    int dimension,
  ) async {
    final encoded = () async {
      try {
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        return png?.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
      } catch (_) {
        return null;
      } finally {
        image.dispose();
      }
    }();
    await _rasterCache!.writePending(pageIndex, dimension, encoded);
  }

  @override
  Future<Uint8List?> resource(String href) async {
    final pageIndex = href == _coverPath ? 0 : _pageIndexFromHref(href);
    if (pageIndex == null) return null;
    final dimension = href == _coverPath
        ? _coverDimension
        : _readerPageDimension;
    final cached = await _rasterCache?.read(pageIndex, dimension);
    if (_document == null) throw StateError('PDF source has been disposed');
    if (cached != null) return cached;
    final image = await _renderPage(pageIndex, dimension, persist: false);
    try {
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      if (png == null) throw StateError('PDF raster encoding failed');
      final bytes = png.buffer.asUint8List(
        png.offsetInBytes,
        png.lengthInBytes,
      );
      await _rasterCache?.write(pageIndex, dimension, bytes);
      return bytes;
    } finally {
      image.dispose();
    }
  }

  @override
  void dispose() {
    if (_document == null) return;
    _worker?.dispose();
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
