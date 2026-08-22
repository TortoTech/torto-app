import 'package:flutter/services.dart';

const MethodChannel pdfCoverChannel = MethodChannel('torto/pdf-cover');

class NativePdfInfo {
  final int pageCount;

  const NativePdfInfo(this.pageCount);
}

Future<NativePdfInfo?> inspectPdf(String filePath) async {
  try {
    final result = await pdfCoverChannel.invokeMapMethod<String, Object?>(
      'inspect',
      {'path': filePath},
    );
    final pageCount = result?['pageCount'];
    return pageCount is int && pageCount > 0 ? NativePdfInfo(pageCount) : null;
  } on MissingPluginException {
    return null;
  } on PlatformException {
    return null;
  }
}

/// Renders the first PDF page as a shelf thumbnail on supported platforms.
Future<Uint8List?> renderPdfCover(String filePath) async {
  return _renderPdfPage(filePath, pageIndex: 0, maxDimension: 384);
}

/// Renders one PDF page for the fixed-layout reader.
Future<Uint8List?> renderPdfPage(String filePath, int pageIndex) async {
  return _renderPdfPage(filePath, pageIndex: pageIndex, maxDimension: 2048);
}

Future<Uint8List?> _renderPdfPage(
  String filePath, {
  required int pageIndex,
  required int maxDimension,
}) async {
  try {
    return await pdfCoverChannel.invokeMethod<Uint8List>('renderPage', {
      'path': filePath,
      'pageIndex': pageIndex,
      'maxDimension': maxDimension,
    });
  } on MissingPluginException {
    return null;
  } on PlatformException {
    return null;
  }
}
