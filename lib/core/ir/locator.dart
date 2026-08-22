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
    'href': _hrefToJson(href),
    'position': position,
    'progression': progression,
    'total_progression': totalProgression,
    if (source != null) 'source': source!.toJson(),
  };

  static Map<String, Object?> _hrefToJson(String href) {
    final separator = href.indexOf('#');
    if (separator < 0) return {'path': href};
    final fragment = href.substring(separator + 1);
    return {
      'path': href.substring(0, separator),
      if (fragment.isNotEmpty) 'fragment': fragment,
    };
  }

  factory LocatorV1.fromJson(Map<String, dynamic> json) {
    final version = json['version'] as int? ?? currentVersion;
    if (version != currentVersion) {
      throw FormatException('Unsupported locator version: $version');
    }
    return LocatorV1(
      publicationId: json['publication_id'] as String,
      href: _hrefFromJson(json['href']),
      position: json['position'] as int? ?? 0,
      progression: (json['progression'] as num?)?.toDouble() ?? 0,
      totalProgression: (json['total_progression'] as num?)?.toDouble() ?? 0,
      source: json['source'] == null
          ? null
          : SourceRange.fromJson(json['source'] as Map<String, dynamic>),
    );
  }

  static String _hrefFromJson(Object? value) {
    if (value is Map) {
      final path = value['path'];
      final fragment = value['fragment'];
      if (path is String && (fragment == null || fragment is String)) {
        return fragment is String && fragment.isNotEmpty
            ? '$path#$fragment'
            : path;
      }
    }
    throw const FormatException('Invalid locator href.');
  }
}
