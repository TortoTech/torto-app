import 'block.dart';

/// Book identity: lowercase hex SHA-256 of the exact file bytes, matching
/// torto's webdav-sync-v1 book identity rule.
typedef PublicationId = String;

/// EPUB package-level rendition mode. Reflowable is the safe default for
/// formats that do not declare fixed pagination.
enum RenditionLayout { reflowable, prePaginated }

/// Coarse publication-wide writing-system hint used by unified typesetting.
enum WritingSystem { cjk, latin, other, unknown }

class BookMetadata {
  final String title;
  final List<String> authors;
  final List<String> languages;
  final RenditionLayout layout;

  const BookMetadata({
    this.title = '',
    this.authors = const [],
    this.languages = const [],
    this.layout = RenditionLayout.reflowable,
  });

  /// First declared language, kept as a convenience for typography callers.
  String get language => languages.isEmpty ? '' : languages.first;

  /// Declared language wins; the title is only used when metadata does not
  /// identify a supported writing system. This mirrors torto desktop.
  WritingSystem get writingSystem {
    for (final language in languages) {
      final resolved = _writingSystemFromLanguageTag(language);
      if (resolved != null) return resolved;
    }
    return _writingSystemFromTitle(title);
  }
}

WritingSystem? _writingSystemFromLanguageTag(String language) {
  final normalized = language.trim().replaceAll('_', '-').toLowerCase();
  final subtags = normalized.split('-');
  final primary = subtags.isEmpty ? '' : subtags.first;
  if (primary.isEmpty || primary == 'und') return null;
  final remaining = subtags.skip(1).toSet();
  if (remaining.any(const {'hans', 'hant', 'jpan', 'kore'}.contains)) {
    return WritingSystem.cjk;
  }
  if (remaining.contains('latn')) return WritingSystem.latin;
  if (const {'zh', 'ja', 'ko'}.contains(primary)) return WritingSystem.cjk;
  if (const {
    'af',
    'ca',
    'cs',
    'cy',
    'da',
    'de',
    'en',
    'es',
    'et',
    'eu',
    'fi',
    'fr',
    'ga',
    'gd',
    'gl',
    'hr',
    'hu',
    'id',
    'is',
    'it',
    'lt',
    'lv',
    'ms',
    'mt',
    'nl',
    'no',
    'pl',
    'pt',
    'ro',
    'sk',
    'sl',
    'sq',
    'sv',
    'sw',
    'tr',
    'vi',
  }.contains(primary)) {
    return WritingSystem.latin;
  }
  if (const {
    'ar',
    'be',
    'bg',
    'el',
    'fa',
    'he',
    'hi',
    'mk',
    'ru',
    'sr',
    'th',
    'uk',
    'ur',
  }.contains(primary)) {
    return WritingSystem.other;
  }
  return null;
}

WritingSystem _writingSystemFromTitle(String title) {
  var cjk = 0;
  var latin = 0;
  for (final rune in title.runes) {
    if (_isCjkRune(rune)) {
      cjk++;
    } else if (_isLatinRune(rune)) {
      latin++;
    }
  }
  final total = cjk + latin;
  if (total < 2) return WritingSystem.unknown;
  if (cjk * 100 >= total * 60) return WritingSystem.cjk;
  if (latin * 100 >= total * 60) return WritingSystem.latin;
  return WritingSystem.unknown;
}

bool _isCjkRune(int rune) =>
    (rune >= 0x1100 && rune <= 0x11ff) ||
    (rune >= 0x2e80 && rune <= 0x2fff) ||
    (rune >= 0x3040 && rune <= 0x30ff) ||
    (rune >= 0x3130 && rune <= 0x318f) ||
    (rune >= 0x31a0 && rune <= 0x31ff) ||
    (rune >= 0x3400 && rune <= 0x4dbf) ||
    (rune >= 0x4e00 && rune <= 0x9fff) ||
    (rune >= 0xac00 && rune <= 0xd7af) ||
    (rune >= 0xf900 && rune <= 0xfaff) ||
    (rune >= 0x20000 && rune <= 0x2fa1f);

bool _isLatinRune(int rune) =>
    (rune >= 0x41 && rune <= 0x5a) ||
    (rune >= 0x61 && rune <= 0x7a) ||
    (rune >= 0x00c0 && rune <= 0x024f) ||
    (rune >= 0x1e00 && rune <= 0x1eff) ||
    (rune >= 0xff21 && rune <= 0xff3a) ||
    (rune >= 0xff41 && rune <= 0xff5a);

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
  final SpineItemId id;
  final int index;

  /// Root-relative path of the section document within the package.
  final String href;

  const SpineItem({required this.id, required this.index, required this.href});
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
  int indexOfSpine(SpineItemId id) => spine.indexWhere((item) => item.id == id);
}

/// One spine section's parsed content.
class Section {
  final SpineItemId id;
  final int spineIndex;
  final String href;
  final List<Block> blocks;
  final List<SectionAnchor> anchors;

  const Section({
    required this.id,
    required this.spineIndex,
    required this.href,
    required this.blocks,
    this.anchors = const [],
  });
}

/// An authored HTML `id`/`name` fragment resolved to stable Reading IR.
class SectionAnchor {
  final String fragment;
  final SourceAnchor source;

  const SectionAnchor({required this.fragment, required this.source});
}
