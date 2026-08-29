import 'package:flutter/material.dart';

import '../../core/linebreak/paragraph_optimizer.dart';
import '../../core/linebreak/unicode_line_breaker.dart';

/// Shows one reader footnote as a full-window-width bottom sheet.
Future<void> showReaderFootnoteSheet(
  BuildContext context, {
  required String text,
  required Color background,
  required Color foreground,
}) {
  final viewport = MediaQuery.sizeOf(context);
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: background,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    constraints: BoxConstraints(
      minWidth: viewport.width,
      maxWidth: viewport.width,
      maxHeight: viewport.height * 0.75,
    ),
    builder: (context) =>
        ReaderFootnoteSheet(text: text, foreground: foreground),
  );
}

class ReaderFootnoteSheet extends StatelessWidget {
  final String text;
  final Color foreground;

  const ReaderFootnoteSheet({
    super.key,
    required this.text,
    required this.foreground,
  });

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: SizedBox(
      width: double.infinity,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 28),
        child: OptimizedJustifiedText(
          text,
          style: TextStyle(color: foreground, fontSize: 17, height: 1.55),
        ),
      ),
    ),
  );
}

/// Plain-text adapter for the same whole-paragraph optimizer used by the
/// reader layout engine. Explicit line breaks and per-cluster spacing keep
/// popup notes consistent with unified body text.
class OptimizedJustifiedText extends StatelessWidget {
  final String text;
  final TextStyle style;

  const OptimizedJustifiedText(this.text, {super.key, required this.style});

  @override
  Widget build(BuildContext context) {
    final paragraphs = text.split(RegExp(r'\r?\n'));
    final lineHeight = (style.fontSize ?? 17) * (style.height ?? 1.0);
    return SelectionArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var index = 0; index < paragraphs.length; index++) ...[
            if (paragraphs[index].isEmpty)
              SizedBox(height: lineHeight)
            else
              _OptimizedParagraphText(paragraphs[index], style: style),
          ],
        ],
      ),
    );
  }
}

class _OptimizedParagraphText extends StatelessWidget {
  final String text;
  final TextStyle style;

  const _OptimizedParagraphText(this.text, {required this.style});

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth;
      if (!width.isFinite || width <= 0) return const SizedBox.shrink();
      final span = _optimizedTextSpan(
        text,
        style,
        width,
        MediaQuery.textScalerOf(context),
      );
      if (span == null) {
        return Text(text, style: style, textAlign: TextAlign.justify);
      }
      return Text.rich(
        span,
        textAlign: TextAlign.left,
        softWrap: false,
        overflow: TextOverflow.visible,
      );
    },
  );
}

TextSpan? _optimizedTextSpan(
  String text,
  TextStyle style,
  double width,
  TextScaler textScaler,
) {
  final ranges = <({int start, int end})>[];
  var offset = 0;
  for (final grapheme in text.characters) {
    final start = offset;
    offset += grapheme.length;
    ranges.add((start: start, end: offset));
  }
  if (ranges.isEmpty) return null;

  final measurement = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    textScaler: textScaler,
    maxLines: 1,
  )..layout(maxWidth: 1000000);
  final clusters = <MeasuredCluster>[];
  for (final range in ranges) {
    final boxes = measurement.getBoxesForSelection(
      TextSelection(baseOffset: range.start, extentOffset: range.end),
    );
    var advance = boxes.fold<double>(
      0,
      (total, box) => total + box.right - box.left,
    );
    if (boxes.isEmpty || !advance.isFinite || advance < 0) {
      final fallback = TextPainter(
        text: TextSpan(
          text: text.substring(range.start, range.end),
          style: style,
        ),
        textDirection: TextDirection.ltr,
        textScaler: textScaler,
        maxLines: 1,
      )..layout();
      advance = fallback.width;
      fallback.dispose();
    }
    clusters.add(
      MeasuredCluster(
        start: range.start,
        end: range.end,
        advance: advance,
        em: textScaler.scale(style.fontSize ?? 17),
      ),
    );
  }
  measurement.dispose();

  final plan = const ParagraphOptimizer().plan(
    text: text,
    clusters: clusters,
    legalBreaks: Icu4xLineBreaker.instance.breakOpportunities(text),
    lineWidth: width,
    firstLineIndent: 0,
    defaultEm: textScaler.scale(style.fontSize ?? 17),
  );
  if (plan == null || plan.lines.length < 2) return null;

  final children = <InlineSpan>[];
  for (var lineIndex = 0; lineIndex < plan.lines.length; lineIndex++) {
    final line = plan.lines[lineIndex];
    final plain = StringBuffer();

    void flushPlain() {
      if (plain.isEmpty) return;
      children.add(TextSpan(text: plain.toString()));
      plain.clear();
    }

    for (var index = line.startCluster; index < line.endCluster; index++) {
      final cluster = clusters[index];
      final value = text.substring(cluster.start, cluster.end);
      final adjustment = plan.adjustments[index];
      if (adjustment.abs() <= 0.0001) {
        plain.write(value);
      } else {
        flushPlain();
        children.add(
          TextSpan(
            text: value,
            style: TextStyle(letterSpacing: adjustment),
          ),
        );
      }
    }
    flushPlain();
    if (lineIndex + 1 < plan.lines.length) {
      children.add(const TextSpan(text: '\n'));
    }
  }
  return TextSpan(style: style, children: children);
}
