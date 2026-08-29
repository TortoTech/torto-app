import 'dart:math' as math;

/// One renderer-shaped cluster, addressed in the source string's UTF-16 units.
class MeasuredCluster {
  final int start;
  final int end;
  final double advance;
  final double em;
  final bool ordinaryBaseline;
  final bool footnoteReference;

  const MeasuredCluster({
    required this.start,
    required this.end,
    required this.advance,
    required this.em,
    this.ordinaryBaseline = true,
    this.footnoteReference = false,
  });
}

class OptimizedLine {
  final int startCluster;
  final int endCluster;
  final double naturalWidth;
  final double adjustmentRatio;
  final double badness;

  const OptimizedLine({
    required this.startCluster,
    required this.endCluster,
    required this.naturalWidth,
    required this.adjustmentRatio,
    required this.badness,
  });
}

class ParagraphPlan {
  final List<OptimizedLine> lines;

  /// Extra trailing spacing applied after each measured cluster.
  final List<double> adjustments;

  const ParagraphPlan({required this.lines, required this.adjustments});
}

class _Item {
  final double width;
  final double stretch;
  final double shrink;
  final double boundaryWidthAfter;
  final double boundaryShrinkAfter;
  final double lineEndAdjustment;
  final bool breakAfter;
  final bool trimmable;
  final bool justifiableAfter;

  const _Item({
    required this.width,
    required this.stretch,
    required this.shrink,
    required this.boundaryWidthAfter,
    required this.boundaryShrinkAfter,
    required this.lineEndAdjustment,
    required this.breakAfter,
    required this.trimmable,
    required this.justifiableAfter,
  });
}

class _Prefix {
  final double width;
  final double stretch;
  final double shrink;
  final double boundaryWidth;
  final double boundaryShrink;
  final int justifiable;

  const _Prefix({
    this.width = 0,
    this.stretch = 0,
    this.shrink = 0,
    this.boundaryWidth = 0,
    this.boundaryShrink = 0,
    this.justifiable = 0,
  });
}

class _CandidateLine {
  final int start;
  final int measuredEnd;
  final int end;
  final double ratio;
  final double badness;
  final double naturalWidth;
  final double difference;
  final double stretch;
  final double shrink;
  final int justifiable;
  final bool last;

  const _CandidateLine({
    required this.start,
    required this.measuredEnd,
    required this.end,
    required this.ratio,
    required this.badness,
    required this.naturalWidth,
    required this.difference,
    required this.stretch,
    required this.shrink,
    required this.justifiable,
    required this.last,
  });
}

/// Unicode-aware whole-paragraph optimization for supported LTR prose.
///
/// Flutter remains responsible for shaping. This class only chooses legal
/// breakpoints and distributes whitespace/CJK boundary adjustments.
class ParagraphOptimizer {
  static const double _mixedScriptSpacingEm = 0.25;
  static const double _mixedScriptShrinkEm = 0.125;
  static const double _epsilon = 0.001;

  const ParagraphOptimizer();

  ParagraphPlan? plan({
    required String text,
    required List<MeasuredCluster> clusters,
    required double lineWidth,
    required double firstLineIndent,
    required double defaultEm,
  }) {
    if (text.isEmpty ||
        clusters.isEmpty ||
        !lineWidth.isFinite ||
        lineWidth <= 0 ||
        !defaultEm.isFinite ||
        defaultEm <= 0 ||
        !_supportedLtrProse(text)) {
      return null;
    }
    var expected = 0;
    for (final cluster in clusters) {
      if (cluster.start != expected ||
          cluster.end <= cluster.start ||
          cluster.end > text.length ||
          !cluster.advance.isFinite ||
          cluster.advance < 0 ||
          !cluster.em.isFinite ||
          cluster.em <= 0) {
        return null;
      }
      expected = cluster.end;
    }
    if (expected != text.length) return null;

    final items = <_Item>[];
    for (var index = 0; index < clusters.length; index++) {
      final cluster = clusters[index];
      final source = text.substring(cluster.start, cluster.end);
      final first = source.runes.first;
      final last = source.runes.last;
      final punctuation = _punctuation(cluster, first, last);
      var boundaryWidth = 0.0;
      var boundaryShrink = 0.0;
      var justifiable = false;
      final next = index + 1 < clusters.length ? clusters[index + 1] : null;
      if (next != null) {
        final nextSource = text.substring(next.start, next.end);
        final nextFirst = nextSource.runes.first;
        final nextLast = nextSource.runes.last;
        if (_mixedScriptBoundary(cluster, last, next, nextFirst)) {
          boundaryWidth += _mixedScriptSpacingEm * cluster.em;
          boundaryShrink += _mixedScriptShrinkEm * cluster.em;
        }
        final nextPunctuation = _punctuation(next, nextFirst, nextLast);
        if (punctuation.$1 > 0 || punctuation.$2 > 0) {
          if (nextPunctuation.$1 > 0 || nextPunctuation.$2 > 0) {
            boundaryWidth -= math.min(
              punctuation.$2 + nextPunctuation.$1,
              cluster.em * 0.5,
            );
          }
        }
        justifiable =
            _isCjkJustification(last) &&
            _isCjkJustification(nextFirst) &&
            !cluster.footnoteReference &&
            !next.footnoteReference;
      }
      final whitespace = source.runes.every(_isWhitespace);
      final breakableSpace = source.runes.every(_isBreakableSpace);
      final breakAfter =
          index == clusters.length - 1 ||
          _legalBreakAfter(text, clusters, index, last);
      items.add(
        _Item(
          width: cluster.advance,
          stretch: whitespace ? cluster.advance * 0.5 : 0,
          shrink: whitespace ? cluster.advance * 0.33 : 0,
          boundaryWidthAfter: boundaryWidth,
          boundaryShrinkAfter: boundaryShrink,
          lineEndAdjustment: -punctuation.$2,
          breakAfter: breakAfter,
          trimmable: breakableSpace,
          justifiableAfter: justifiable,
        ),
      );
    }

    final prefix = <_Prefix>[const _Prefix()];
    for (final item in items) {
      final previous = prefix.last;
      prefix.add(
        _Prefix(
          width: previous.width + item.width,
          stretch: previous.stretch + item.stretch,
          shrink: previous.shrink + item.shrink,
          boundaryWidth: previous.boundaryWidth + item.boundaryWidthAfter,
          boundaryShrink: previous.boundaryShrink + item.boundaryShrinkAfter,
          justifiable: previous.justifiable + (item.justifiableAfter ? 1 : 0),
        ),
      );
    }
    final breakpoints = <int>[0];
    for (var index = 0; index < items.length; index++) {
      if (items[index].breakAfter) breakpoints.add(index + 1);
    }
    if (breakpoints.last != items.length) breakpoints.add(items.length);

    final best = List<double>.filled(breakpoints.length, double.infinity);
    final predecessor = List<int?>.filled(breakpoints.length, null);
    final selected = List<_CandidateLine?>.filled(breakpoints.length, null);
    best[0] = 0;
    for (
      var endCandidate = 1;
      endCandidate < breakpoints.length;
      endCandidate++
    ) {
      final end = breakpoints[endCandidate];
      for (
        var startCandidate = endCandidate - 1;
        startCandidate >= 0;
        startCandidate--
      ) {
        final start = breakpoints[startCandidate];
        if (_cannotFit(
          items,
          prefix,
          start,
          end,
          lineWidth - (start == 0 ? firstLineIndent : 0),
        )) {
          break;
        }
        final line = _measureLine(
          items,
          prefix,
          start,
          end,
          lineWidth,
          firstLineIndent,
          defaultEm,
        );
        if (line == null) continue;
        if (line.naturalWidth - line.shrink >
            lineWidth - (start == 0 ? firstLineIndent : 0) + _epsilon) {
          break;
        }
        if (!best[startCandidate].isFinite) continue;
        final demerit = math.pow(10 + line.badness, 2).toDouble();
        final total = best[startCandidate] + demerit;
        if (total < best[endCandidate]) {
          best[endCandidate] = total;
          predecessor[endCandidate] = startCandidate;
          selected[endCandidate] = line;
        }
      }
    }
    if (!best.last.isFinite) return null;
    final chosen = <_CandidateLine>[];
    var cursor = breakpoints.length - 1;
    while (cursor != 0) {
      final line = selected[cursor];
      final previous = predecessor[cursor];
      if (line == null || previous == null) return null;
      chosen.add(line);
      cursor = previous;
    }
    final ordered = chosen.reversed.toList(growable: false);
    final adjustments = List<double>.filled(items.length, 0);
    for (final line in ordered) {
      _applyAdjustments(items, line, adjustments);
    }
    return ParagraphPlan(
      lines: [
        for (final line in ordered)
          OptimizedLine(
            startCluster: line.start,
            endCluster: line.end,
            naturalWidth: line.naturalWidth,
            adjustmentRatio: line.ratio,
            badness: line.badness,
          ),
      ],
      adjustments: adjustments,
    );
  }

  bool _cannotFit(
    List<_Item> items,
    List<_Prefix> prefix,
    int start,
    int end,
    double target,
  ) {
    var measuredEnd = end;
    while (measuredEnd > start && items[measuredEnd - 1].trimmable) {
      measuredEnd--;
    }
    if (measuredEnd <= start) return false;
    final itemWidth = prefix[measuredEnd].width - prefix[start].width;
    final boundaryWidth = measuredEnd - start < 2
        ? 0.0
        : prefix[measuredEnd - 1].boundaryWidth - prefix[start].boundaryWidth;
    final boundaryShrink = measuredEnd - start < 2
        ? 0.0
        : prefix[measuredEnd - 1].boundaryShrink - prefix[start].boundaryShrink;
    final shrink =
        prefix[measuredEnd].shrink - prefix[start].shrink + boundaryShrink;
    final minimum =
        itemWidth +
        boundaryWidth +
        items[measuredEnd - 1].lineEndAdjustment -
        shrink;
    return minimum > target + _epsilon;
  }

  _CandidateLine? _measureLine(
    List<_Item> items,
    List<_Prefix> prefix,
    int start,
    int end,
    double lineWidth,
    double firstLineIndent,
    double em,
  ) {
    var measuredEnd = end;
    while (measuredEnd > start && items[measuredEnd - 1].trimmable) {
      measuredEnd--;
    }
    if (measuredEnd <= start) return null;
    final itemWidth = prefix[measuredEnd].width - prefix[start].width;
    final boundaryWidth = measuredEnd - start < 2
        ? 0.0
        : prefix[measuredEnd - 1].boundaryWidth - prefix[start].boundaryWidth;
    final boundaryShrink = measuredEnd - start < 2
        ? 0.0
        : prefix[measuredEnd - 1].boundaryShrink - prefix[start].boundaryShrink;
    final justifiable = measuredEnd - start < 2
        ? 0
        : prefix[measuredEnd - 1].justifiable - prefix[start].justifiable;
    final natural =
        itemWidth + boundaryWidth + items[measuredEnd - 1].lineEndAdjustment;
    final stretch = prefix[measuredEnd].stretch - prefix[start].stretch;
    final shrink =
        prefix[measuredEnd].shrink - prefix[start].shrink + boundaryShrink;
    final target = lineWidth - (start == 0 ? firstLineIndent : 0);
    final difference = target - natural;
    final last = end == items.length;
    if (target + _epsilon < natural - shrink) return null;
    final cost = _adjustmentCost(
      difference,
      stretch,
      shrink,
      justifiable,
      em,
      last,
    );
    if (cost == null) return null;
    return _CandidateLine(
      start: start,
      measuredEnd: measuredEnd,
      end: end,
      ratio: cost.$1,
      badness: cost.$2,
      naturalWidth: natural,
      difference: difference,
      stretch: stretch,
      shrink: shrink,
      justifiable: justifiable,
      last: last,
    );
  }

  (double, double)? _adjustmentCost(
    double difference,
    double stretch,
    double shrink,
    int justifiable,
    double em,
    bool last,
  ) {
    if (last && difference >= 0) return (0, 0);
    final double ratio;
    if (difference.abs() <= _epsilon) {
      ratio = 0;
    } else if (difference < 0) {
      if (shrink <= _epsilon) return null;
      ratio = difference / shrink;
    } else if (stretch > _epsilon) {
      final naturalRatio = difference / stretch;
      ratio = naturalRatio <= 1 || justifiable == 0
          ? naturalRatio
          : 1 + (difference - stretch) / justifiable / (em * 0.5);
    } else if (justifiable > 0) {
      ratio = 1 + difference / justifiable / (em * 0.5);
    } else {
      return null;
    }
    if (!ratio.isFinite || ratio < -1) return null;
    return (ratio, (100 * math.pow(ratio.abs(), 3)).toDouble());
  }

  void _applyAdjustments(
    List<_Item> items,
    _CandidateLine line,
    List<double> adjustments,
  ) {
    for (var index = line.start; index + 1 < line.measuredEnd; index++) {
      adjustments[index] += items[index].boundaryWidthAfter;
    }
    adjustments[line.measuredEnd - 1] +=
        items[line.measuredEnd - 1].lineEndAdjustment;
    if (line.difference.abs() <= _epsilon ||
        (line.last && line.difference >= 0)) {
      return;
    }
    if (line.difference < 0) {
      final ratio = line.difference / line.shrink;
      for (var index = line.start; index < line.measuredEnd; index++) {
        adjustments[index] += items[index].shrink * ratio;
        if (index + 1 < line.measuredEnd) {
          adjustments[index] += items[index].boundaryShrinkAfter * ratio;
        }
      }
      return;
    }
    final stretchAmount = line.justifiable == 0
        ? line.difference
        : math.min(line.difference, line.stretch);
    if (line.stretch > _epsilon) {
      final ratio = stretchAmount / line.stretch;
      for (var index = line.start; index < line.measuredEnd; index++) {
        adjustments[index] += items[index].stretch * ratio;
      }
    }
    final remainder = line.difference - stretchAmount;
    if (remainder > _epsilon && line.justifiable > 0) {
      final perBoundary = remainder / line.justifiable;
      for (var index = line.start; index + 1 < line.measuredEnd; index++) {
        if (items[index].justifiableAfter) {
          adjustments[index] += perBoundary;
        }
      }
    }
  }

  bool _legalBreakAfter(
    String text,
    List<MeasuredCluster> clusters,
    int index,
    int currentLast,
  ) {
    final current = text.substring(clusters[index].start, clusters[index].end);
    if (current.runes.every(_isBreakableSpace) || currentLast == 0x200b) {
      return true;
    }
    if (currentLast == 0x00a0 || currentLast == 0x2060) return false;
    if (index + 1 >= clusters.length) return true;
    final nextText = text.substring(
      clusters[index + 1].start,
      clusters[index + 1].end,
    );
    final nextFirst = nextText.runes.first;
    if (_isOpeningPunctuation(currentLast, true) ||
        _isClosingPunctuation(nextFirst, true) ||
        _isCombiningOrVariation(nextFirst)) {
      return false;
    }
    if (_isCjkScript(currentLast) || _isCjkScript(nextFirst)) return true;
    return const {0x2d, 0x2010, 0x2013, 0x2014}.contains(currentLast);
  }

  (double, double) _punctuation(MeasuredCluster cluster, int first, int last) {
    final fullWidthQuote = cluster.advance >= cluster.em * 0.75;
    final leading = _isOpeningPunctuation(first, fullWidthQuote)
        ? cluster.advance * 0.5
        : (_isCenteredPunctuation(first) ? cluster.advance * 0.25 : 0.0);
    final trailing = _isClosingPunctuation(last, fullWidthQuote)
        ? cluster.advance * 0.5
        : (_isCenteredPunctuation(last) ? cluster.advance * 0.25 : 0.0);
    return (leading, trailing);
  }

  bool _mixedScriptBoundary(
    MeasuredCluster left,
    int leftLast,
    MeasuredCluster right,
    int rightFirst,
  ) {
    if (!left.ordinaryBaseline ||
        !right.ordinaryBaseline ||
        left.footnoteReference ||
        right.footnoteReference) {
      return false;
    }
    return (_isCjkScript(leftLast) && _isWestern(rightFirst)) ||
        (_isWestern(leftLast) && _isCjkScript(rightFirst));
  }
}

bool _isWhitespace(int rune) => String.fromCharCode(rune).trim().isEmpty;

bool _isBreakableSpace(int rune) =>
    _isWhitespace(rune) && rune != 0x00a0 && rune != 0x2060;

bool _isCjkScript(int rune) =>
    rune == 0x30fc ||
    (rune >= 0x3040 && rune <= 0x30ff) ||
    (rune >= 0x3400 && rune <= 0x4dbf) ||
    (rune >= 0x4e00 && rune <= 0x9fff) ||
    (rune >= 0x20000 && rune <= 0x323af) ||
    (rune >= 0xac00 && rune <= 0xd7af) ||
    (rune >= 0xf900 && rune <= 0xfaff);

bool _isWestern(int rune) =>
    (rune >= 0x30 && rune <= 0x39) ||
    (rune >= 0x41 && rune <= 0x5a) ||
    (rune >= 0x61 && rune <= 0x7a) ||
    (rune >= 0x00c0 && rune <= 0x024f) ||
    (rune >= 0x0370 && rune <= 0x052f) ||
    const {0x23, 0x24, 0x25, 0x26}.contains(rune);

bool _isCjkJustification(int rune) =>
    _isCjkScript(rune) ||
    _isOpeningPunctuation(rune, true) ||
    _isClosingPunctuation(rune, true) ||
    _isCenteredPunctuation(rune);

bool _isOpeningPunctuation(int rune, bool fullWidthQuote) =>
    const {
      0x300a,
      0x3008,
      0xff08,
      0x300e,
      0x300c,
      0x3010,
      0x3016,
      0x3014,
      0xff3b,
      0xff5b,
    }.contains(rune) ||
    (fullWidthQuote && const {0x201c, 0x2018}.contains(rune));

bool _isClosingPunctuation(int rune, bool fullWidthQuote) =>
    const {
      0xff0c,
      0xff0e,
      0x3002,
      0x3001,
      0xff1a,
      0xff1b,
      0x300b,
      0x3009,
      0xff09,
      0x300f,
      0x300d,
      0x3011,
      0x3017,
      0x3015,
      0xff3d,
      0xff5d,
      0xff1f,
      0xff01,
    }.contains(rune) ||
    (fullWidthQuote && const {0x201d, 0x2019}.contains(rune));

bool _isCenteredPunctuation(int rune) => const {0x00b7, 0x30fb}.contains(rune);

bool _isCombiningOrVariation(int rune) =>
    (rune >= 0x0300 && rune <= 0x036f) ||
    (rune >= 0xfe00 && rune <= 0xfe0f) ||
    (rune >= 0xe0100 && rune <= 0xe01ef) ||
    rune == 0x200d;

bool _supportedLtrProse(String text) => text.runes.every((rune) {
  if (const {0x0a, 0x0d, 0x09}.contains(rune)) return false;
  if ((rune >= 0x0590 && rune <= 0x08ff) ||
      (rune >= 0xfb1d && rune <= 0xfdff) ||
      (rune >= 0xfe70 && rune <= 0xfeff) ||
      (rune >= 0x1ee00 && rune <= 0x1eeff)) {
    return false;
  }
  return true;
});
