import 'dart:typed_data';

import 'book.dart';

/// Format/renderer boundary, mirroring torto's `trait BookSource`.
///
/// Implementations parse a container format (EPUB first) and produce the
/// Reading IR lazily, section by section.
abstract class BookSource {
  /// Book-level descriptor: identity, metadata, spine, TOC.
  Book get book;

  /// Parses one spine section into IR blocks. May be called repeatedly;
  /// implementations should cache per section.
  Future<Section> parseSection(int index);

  /// Raw bytes of a package resource by root-relative href (images, CSS…),
  /// or null when missing.
  Future<Uint8List?> resource(String href);
}

/// Optional lifecycle capability for sources that retain heavyweight parser
/// buffers or process-wide caches.
abstract interface class DisposableBookSource {
  void dispose();
}
