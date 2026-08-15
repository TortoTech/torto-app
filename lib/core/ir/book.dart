import 'block.dart';

/// Book identity: lowercase hex SHA-256 of the exact file bytes, matching
/// torto's webdav-sync-v1 book identity rule.
typedef PublicationId = String;

class BookMetadata {
  final String title;
  final List<String> authors;
  final String language;

  const BookMetadata({
    this.title = '',
    this.authors = const [],
    this.language = '',
  });
}

class TocEntry {
  final String label;

  /// Root-relative href of the target section, with optional #fragment.
  final String href;

  /// Spine index of [href]'s path part, when resolvable.
  final int? spineIndex;

  final List<TocEntry> children;

  const TocEntry({
    required this.label,
    this.href = '',
    this.spineIndex,
    this.children = const [],
  });
}

class SpineItem {
  final int index;

  /// Root-relative path of the section document within the package.
  final String href;

  const SpineItem({required this.index, required this.href});
}

class Book {
  final PublicationId id;
  final BookMetadata metadata;
  final List<SpineItem> spine;
  final List<TocEntry> toc;

  /// Root-relative href of the cover image, when known.
  final String? coverHref;

  const Book({
    required this.id,
    required this.metadata,
    required this.spine,
    this.toc = const [],
    this.coverHref,
  });

  int get sectionCount => spine.length;
}

/// One spine section's parsed content.
class Section {
  final int spineIndex;
  final String href;
  final List<Block> blocks;

  const Section({
    required this.spineIndex,
    required this.href,
    required this.blocks,
  });
}
