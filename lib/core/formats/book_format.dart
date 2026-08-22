/// E-book format detection.
///
/// Dart port of torto's `crates/formats::BookFormat`: detection is by file
/// name (double extension `.fb2.zip` wins over plain `zip`). Formats the app
/// cannot open yet are still detected so callers can say "MOBI is not
/// supported" instead of "unknown file".
library;

enum BookFormat {
  epub('EPUB'),
  mobi('MOBI'),
  azw('AZW'),
  azw3('AZW3'),
  fb2('FB2'),
  fbz('FBZ'),
  cbz('CBZ'),
  chm('CHM'),
  pdf('PDF');

  final String label;

  const BookFormat(this.label);

  /// Detects a supported format from a source file name.
  static BookFormat? fromFileName(String fileName) {
    final lower = fileName.toLowerCase();
    if (lower.endsWith('.fb2.zip')) return BookFormat.fbz;
    final dot = lower.lastIndexOf('.');
    if (dot < 0 || dot == lower.length - 1) return null;
    final extension = lower.substring(dot + 1);
    return switch (extension) {
      'epub' => BookFormat.epub,
      'mobi' => BookFormat.mobi,
      'azw' => BookFormat.azw,
      'azw3' => BookFormat.azw3,
      'fb2' => BookFormat.fb2,
      'fbz' => BookFormat.fbz,
      'cbz' => BookFormat.cbz,
      'chm' => BookFormat.chm,
      'pdf' => BookFormat.pdf,
      _ => null,
    };
  }

  /// Whether [openBook] can currently open this format.
  bool get openable => true;
}

/// File-name suffixes the library accepts on the shelf.
const List<String> supportedBookExtensions = [
  'epub',
  'fb2',
  'fbz',
  'cbz',
  'mobi',
  'azw',
  'azw3',
  'chm',
  'pdf',
];

/// Whether [fileName] is a book the library can hold (used by the shelf
/// listing; `.fb2.zip` is the zip-wrapped FBZ variant).
bool hasSupportedBookExtension(String fileName) {
  final lower = fileName.toLowerCase();
  if (lower.endsWith('.fb2.zip')) return true;
  if (!lower.contains('.')) return false;
  for (final extension in supportedBookExtensions) {
    if (lower.endsWith('.$extension')) return true;
  }
  return false;
}
