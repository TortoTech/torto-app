import 'package:icu4x/icu4x.dart' show LineSegmenter;

/// Supplies legal UTF-16 line-break positions for the Dart layout pipeline.
///
/// ICU4X implements Unicode UAX #14 and returns indices in the same UTF-16
/// coordinate space used by Dart strings and Flutter paragraph APIs.
abstract interface class UnicodeLineBreaker {
  Set<int> breakOpportunities(String text);
}

/// Shared ICU4X line segmenter used by reader paragraphs and footnotes.
///
/// The segmenter is immutable after construction and all layout work happens
/// on the owning Dart isolate, so reusing it avoids rebuilding ICU state for
/// every paragraph.
final class Icu4xLineBreaker implements UnicodeLineBreaker {
  Icu4xLineBreaker._();

  static final Icu4xLineBreaker instance = Icu4xLineBreaker._();

  late final LineSegmenter _segmenter = LineSegmenter.auto();

  @override
  Set<int> breakOpportunities(String text) {
    if (text.isEmpty) return const <int>{};

    final boundaries = <int>{};
    final iterator = _segmenter.segment(text);
    for (
      var boundary = iterator.next();
      boundary >= 0;
      boundary = iterator.next()
    ) {
      // ICU includes the start boundary. It is not a line-end candidate.
      if (boundary > 0 && boundary <= text.length) boundaries.add(boundary);
    }
    // UAX #14 always permits end-of-text. Keep the layout invariant explicit
    // even if an alternative ICU4X data provider is introduced later.
    boundaries.add(text.length);
    return boundaries;
  }
}
