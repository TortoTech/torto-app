import 'block.dart';

/// Reading position, JSON-compatible with torto's LocatorV1
/// (crates/publication). Restoration prefers [source] over progression so
/// that typography and viewport changes do not move the reader.
class LocatorV1 {
  static const int currentVersion = 1;

  final String publicationId;

  /// Root-relative href of the current section.
  final String href;

  /// Spine index of the current section (torto's `position`).
  final int position;

  /// 0..1 progress within the current section.
  final double progression;

  /// 0..1 progress within the whole book.
  final double totalProgression;

  /// Precise source anchor of the first visible text, when available.
  final SourceRange? source;

  const LocatorV1({
    required this.publicationId,
    required this.href,
    required this.position,
    this.progression = 0,
    this.totalProgression = 0,
    this.source,
  });

  Map<String, dynamic> toJson() => {
        'version': currentVersion,
        'publication_id': publicationId,
        'href': href,
        'position': position,
        'progression': progression,
        'total_progression': totalProgression,
        if (source != null) 'source': source!.toJson(),
      };

  factory LocatorV1.fromJson(Map<String, dynamic> json) {
    final version = json['version'] as int? ?? currentVersion;
    if (version != currentVersion) {
      throw FormatException('Unsupported locator version: $version');
    }
    return LocatorV1(
      publicationId: json['publication_id'] as String,
      href: json['href'] as String? ?? '',
      position: json['position'] as int? ?? 0,
      progression: (json['progression'] as num?)?.toDouble() ?? 0,
      totalProgression: (json['total_progression'] as num?)?.toDouble() ?? 0,
      source: json['source'] == null
          ? null
          : SourceRange.fromJson(json['source'] as Map<String, dynamic>),
    );
  }
}
