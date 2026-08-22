import 'dart:io';
import 'dart:typed_data';

import 'package:pdf_document/pdf_document.dart' as pdf;

import 'pdf_rasterizer.dart';

/// Renders the first page as a shelf thumbnail without a platform channel.
Future<Uint8List?> renderPdfCover(String filePath) async {
  try {
    final bytes = await File(filePath).readAsBytes();
    final document = pdf.PdfDocument.open(bytes);
    if (document.pageCount == 0) return null;
    return await encodePdfPagePng(document.page(0), maxDimension: 384);
  } catch (_) {
    return null;
  } finally {
    clearPdfRasterCache();
  }
}
