/// Format detection and the single entry point for opening book bytes.
///
/// Dart port of torto's `crates/formats` facade (`open_bytes`): detects the
/// format from the file name and dispatches to the matching [BookSource].
library;

import 'dart:typed_data';

import '../ir/ir.dart';
import 'book_format.dart';
import 'cbz_book_source.dart';
import 'chm/chm_book_source.dart';
import 'epub_book_source.dart';
import 'fb2_book_source.dart';
import 'mobi/mobi_book_source.dart';
import 'pdf/pdf_book_source.dart';

/// Opens a book from its raw file bytes. [fileName] is used for format
/// detection (and metadata fallbacks). Throws [FormatException] for
/// unsupported formats and unreadable files.
Future<BookSource> openBook(
  Uint8List bytes,
  String fileName, {
  String? filePath,
  String? titleHint,
  String? publicationIdHint,
}) async {
  final format = BookFormat.fromFileName(fileName);
  if (format == null) {
    throw const FormatException('不支持的电子书格式');
  }
  if (!format.openable) {
    throw FormatException('暂不支持 ${format.label} 格式');
  }
  return switch (format) {
    BookFormat.epub => await EpubBookSource.fromBytes(bytes),
    BookFormat.fb2 || BookFormat.fbz => await openFb2(bytes, fileName),
    BookFormat.cbz => await openCbz(bytes, fileName),
    BookFormat.mobi ||
    BookFormat.azw ||
    BookFormat.azw3 => await openMobi(bytes, fileName),
    BookFormat.chm => await openChm(bytes, fileName),
    BookFormat.pdf => await openPdf(
      bytes,
      fileName,
      filePath: filePath,
      titleHint: titleHint,
      publicationIdHint: publicationIdHint,
    ),
  };
}
