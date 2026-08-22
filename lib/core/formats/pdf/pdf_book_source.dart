/// PDF → [DirectBookSource].
///
/// torto renders PDF pages with hayro and attaches a glyph text layer
/// (`crates/formats/src/pdf.rs`); the app has no rasterizer, so pages are
/// presented as extracted text through the reflowable pipeline. Structure
/// matches torto: one section per page (`Page N`), /Info metadata, outline
/// table of contents, SHA-256 identity.
library;

import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../ir/ir.dart';
import '../direct_book_source.dart';
import 'pdf_cover.dart';
import 'pdf_document.dart';
import 'pdf_text.dart';

const String _coverPath = 'Cover/thumbnail.png';

/// Opens a PDF from raw bytes. Throws [FormatException] when the file has
/// no pages. Android uses fixed-layout page rasterization; callers without a
/// file path retain the pure-Dart extracted-text fallback.
Future<BookSource> openPdf(
  Uint8List bytes,
  String fileName, {
  String? filePath,
  String? titleHint,
  String? publicationIdHint,
}) async {
  final nativeInfo = filePath == null ? null : await inspectPdf(filePath);
  PdfDocument? document;
  var pages = const <PdfPage>[];
  try {
    document = PdfDocument.open(bytes);
    pages = document.pages;
  } catch (_) {
    if (nativeInfo == null) rethrow;
  }
  final pageCount = nativeInfo?.pageCount ?? pages.length;
  if (pageCount == 0) {
    throw const FormatException('PDF does not contain any pages');
  }

  String? infoTitle;
  String? infoAuthor;
  List<SourceTocEntry> tableOfContents = const [];
  if (document != null) {
    try {
      (infoTitle, infoAuthor) = document.infoMetadata();
      tableOfContents = document.outline();
    } catch (_) {
      // Native fixed-page rendering remains usable without optional metadata.
    }
  }
  final title = titleHint != null && titleHint.trim().isNotEmpty
      ? titleHint.trim()
      : infoTitle != null && infoTitle.trim().isNotEmpty
      ? infoTitle.trim()
      : _titleFromFileName(fileName);
  final authors = [
    if (infoAuthor != null && infoAuthor.trim().isNotEmpty) infoAuthor.trim(),
  ];
  final publicationId = publicationIdHint?.trim().isNotEmpty == true
      ? publicationIdHint!.trim()
      : sha256.convert(bytes).toString();

  if (filePath != null && nativeInfo != null) {
    final descriptor = DirectBookSource.open(
      SourceBook(
        id: publicationId,
        metadata: BookMetadata(title: title, authors: authors),
        sections: [
          for (var index = 0; index < pageCount; index++)
            SourceSection(
              title: 'Page ${index + 1}',
              content: ImageSectionContent(
                resourcePath: _pagePath(index),
                alt: 'PDF page ${index + 1}',
              ),
            ),
        ],
        tableOfContents: tableOfContents,
        coverPath: _coverPath,
      ),
    );
    return _PdfRasterBookSource(
      book: descriptor.book,
      filePath: filePath,
      pageCount: pageCount,
    );
  }

  final fallbackDocument = document!;
  final sections = <SourceSection>[];
  var textPages = 0;
  for (var index = 0; index < pages.length; index++) {
    var paragraphs = const <String>[];
    try {
      paragraphs = extractPageText(
        pages[index].content,
        pages[index].resources,
        fallbackDocument.resolve,
      );
    } on FormatException {
      // A page we cannot interpret renders empty; the reader skips it.
    }
    if (paragraphs.isNotEmpty) textPages++;
    final html = paragraphs
        .map((paragraph) => '<p>${_escapeText(paragraph)}</p>')
        .join();
    sections.add(
      SourceSection(
        title: 'Page ${index + 1}',
        content: HtmlSectionContent(html),
      ),
    );
  }
  if (textPages == 0) {
    throw const FormatException(
      'PDF has no extractable text (scanned or image-only)',
    );
  }

  return DirectBookSource.open(
    SourceBook(
      id: publicationId,
      metadata: BookMetadata(title: title, authors: authors),
      sections: sections,
      tableOfContents: tableOfContents,
    ),
  );
}

class _PdfRasterBookSource implements BookSource {
  @override
  final Book book;
  final String filePath;
  final int pageCount;

  const _PdfRasterBookSource({
    required this.book,
    required this.filePath,
    required this.pageCount,
  });

  @override
  Future<Section> parseSection(int index) async {
    if (index < 0 || index >= pageCount) {
      throw FormatException('PDF page $index is out of range');
    }
    return Section(
      spineIndex: index,
      href: book.spine[index].href,
      blocks: [
        ImageBlock(href: _pagePath(index), alt: 'PDF page ${index + 1}'),
      ],
    );
  }

  @override
  Future<Uint8List?> resource(String href) {
    if (href == _coverPath) return renderPdfCover(filePath);
    final match = RegExp(r'^Pages/page-([0-9]{5})\.png$').firstMatch(href);
    if (match == null) return Future.value();
    final pageIndex = int.parse(match.group(1)!) - 1;
    if (pageIndex < 0 || pageIndex >= pageCount) return Future.value();
    return renderPdfPage(filePath, pageIndex);
  }
}

String _pagePath(int index) =>
    'Pages/page-${(index + 1).toString().padLeft(5, '0')}.png';

String _escapeText(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

String _titleFromFileName(String fileName) {
  var name = fileName.replaceAll('\\', '/');
  name = name.substring(name.lastIndexOf('/') + 1);
  final dot = name.lastIndexOf('.');
  if (dot > 0) name = name.substring(0, dot);
  return name.isEmpty ? '未命名文档' : name;
}
