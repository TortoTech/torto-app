import 'dart:io';
import 'dart:typed_data';
import 'pdf_book_source.dart';
import '../../ir/ir.dart';

/// Covers use the same bounded background worker as reader pages.
Future<Uint8List?> renderPdfCover(String filePath) async {
  BookSource? source;
  try {
    source = await openPdf(
      await File(filePath).readAsBytes(),
      filePath,
      filePath: filePath,
    );
    return await source.resource('Cover/thumbnail.png');
  } catch (_) {
    return null;
  } finally {
    if (source is DisposableBookSource) {
      (source as DisposableBookSource).dispose();
    }
  }
}
