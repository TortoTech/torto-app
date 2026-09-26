import 'dart:typed_data';
import '../../diagnostics.dart';
import 'dart:ui' as ui;

import 'package:dart_pdf_editor/dart_pdf_editor.dart'
    show PdfImageCache, PdfPageRenderer, PdfRenderWorker;
import 'package:pdf_document/pdf_document.dart';
import 'pdf_worker_images.dart';

const int _maxDecodedPdfImageBytes = 32 * 1024 * 1024;

/// Renders a PDF page with the pure-Dart PDF graphics stack and Flutter Canvas.
Future<ui.Image> rasterizePdfPage(
  PdfPage page, {
  required int maxDimension,
  PdfRenderWorker? worker,
  int pageIndex = 0,
}) async {
  if (maxDimension <= 0) {
    throw ArgumentError.value(maxDimension, 'maxDimension', 'must be positive');
  }
  final imageCache = PdfImageCache.instance;
  if (imageCache.maxBytes > _maxDecodedPdfImageBytes) {
    imageCache.maxBytes = _maxDecodedPdfImageBytes;
  }
  final size = PdfPageRenderer.pageSize(page);
  final longestSide = size.width > size.height ? size.width : size.height;
  final pixelRatio = longestSide <= 0 ? 1.0 : maxDimension / longestSide;
  if (worker == null) {
    return PdfPageRenderer.renderImage(page, pixelRatio: pixelRatio);
  }
  final commands = await ReaderDiagnostics.instance.measure(
    'pdf.record',
    () => worker.record(pageIndex, imagePixelRatio: pixelRatio),
    {'page': pageIndex},
  );
  // Never repeat a failed worker interpretation on the UI thread.
  if (commands == null) {
    throw const FormatException('PDF page could not be rendered safely.');
  }
  final picture = await ReaderDiagnostics.instance.measure(
    'pdf.replay',
    () => PdfPageRenderer.pictureFromCommands(
      page,
      bindPdfWorkerImages(commands, page.document.cos),
      maxImagePixelRatio: pixelRatio,
    ),
    {'page': pageIndex},
  );
  try {
    return await ReaderDiagnostics.instance.measure(
      'pdf.raster',
      () => PdfPageRenderer.rasterize(picture, size, pixelRatio),
      {'page': pageIndex},
    );
  } finally {
    picture.dispose();
  }
}

/// Releases decoded XObject masters retained by the package-wide PDF cache.
void clearPdfRasterCache() => PdfImageCache.instance.clear();

/// Encodes a rendered page for persistent resources such as shelf covers.
Future<Uint8List> encodePdfPagePng(
  PdfPage page, {
  required int maxDimension,
  PdfRenderWorker? worker,
  int pageIndex = 0,
}) async {
  final image = await rasterizePdfPage(
    page,
    maxDimension: maxDimension,
    worker: worker,
    pageIndex: pageIndex,
  );
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) throw StateError('failed to encode PDF page as PNG');
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    image.dispose();
  }
}
