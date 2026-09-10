import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:icu4x/icu4x.dart' show WordSegmenter, SentenceSegmenter;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/ir/ir.dart' hide TextStyle;
import '../../core/ir/text_index.dart';
import '../../core/layout/layout_types.dart';
import '../../core/layout/source_offset_map.dart';
import '../../l10n/app_localizations.dart';

enum ReaderSelectionMode { free, word, sentence, paragraph }

final _words = WordSegmenter.auto();
final _sentences = SentenceSegmenter();

/// Public selections use scalar positions; ICU offsets stay inside this adapter.
(int, int) selectionUnit(
  String text,
  int scalarOffset,
  ReaderSelectionMode mode,
) {
  final offset = scalarToUtf16(text, scalarOffset.clamp(0, text.runes.length));
  final (start, end) = _selectionUnitUtf16(text, offset, mode);
  return (utf16ToScalar(text, start), utf16ToScalar(text, end));
}

class ReaderSelection {
  final List<SourceRange> ranges;
  final String quote;
  const ReaderSelection(this.ranges, this.quote);
}

class ReaderPaintMark {
  final SourceRange range;
  final Color color;
  final String? annotationId;
  const ReaderPaintMark(this.range, this.color, [this.annotationId]);
}

/// Use each line's maximum font box for every run on that line. Tight glyph
/// boxes differ across fallback fonts, italics and punctuation.
List<Rect> selectionLineBoxes(ui.Paragraph paragraph, int start, int end) =>
    paragraph
        .getBoxesForRange(start, end, boxHeightStyle: ui.BoxHeightStyle.max)
        .map((box) => box.toRect())
        .toList();

/// The retained paragraphs are the single source of glyph geometry. No second
/// hidden Text widget is laid out for hit-testing or highlight painting.
class _Surface {
  final ui.Paragraph paragraph;
  final Offset origin;
  final Rect clip;
  final String node;
  final String sourceNode;
  final SpineItemId? spine;
  final List<int> mapping;
  final int prefix;
  final List<InlineImageRange> images;
  _Surface(
    this.paragraph,
    this.origin,
    this.clip,
    this.node,
    this.spine,
    this.mapping,
    this.prefix,
    this.images,
    this.sourceNode,
  );
  int toSource(int display) => mapping[display.clamp(0, mapping.length - 1)];
  int toDisplay(int source, {bool end = false}) {
    final map = mapping;
    if (end) {
      final i = map.indexWhere((v) => v >= source);
      return i < 0 ? map.length - 1 : i;
    }
    var last = 0;
    for (var i = 0; i < map.length; i++) {
      if (map[i] > source) break;
      last = i;
    }
    return last;
  }

  List<Rect> boxes(int start, int end) =>
      selectionLineBoxes(paragraph, toDisplay(start), toDisplay(end, end: true))
          .map((b) => b.shift(origin).intersect(clip))
          .where((r) => !r.isEmpty)
          .toList();
}

List<_Surface> _surfaces(PageLayout page) => [
  for (final item in page.items)
    if (item is TextPlacement)
      _Surface(
        item.paragraph,
        Offset(item.x, item.y - item.sliceTop),
        Rect.fromLTWH(item.x, item.y, item.width, item.sliceHeight),
        item.nodeId,
        item.source?.start.spine,
        item.displayToSource,
        item.syntheticPrefixLength,
        item.inlineImages,
        item.source?.start.node ?? item.nodeId,
      )
    else if (item is TableCellPlacement)
      _Surface(
        item.paragraph,
        Offset(item.rect.left + item.padding, item.rect.top + item.padding),
        item.rect.deflate(item.padding),
        item.nodeId,
        item.source?.start.spine,
        item.displayToSource,
        0,
        item.inlineImages,
        item.source?.start.node ?? item.nodeId,
      ),
];

/// UTF-16 boundaries are expanded only at complete grapheme boundaries.
(int, int) _selectionUnitUtf16(
  String text,
  int offset,
  ReaderSelectionMode mode,
) {
  offset = offset.clamp(0, math.max(0, text.length - 1));
  if (mode == ReaderSelectionMode.paragraph) return (0, text.length);
  if (mode == ReaderSelectionMode.sentence ||
      mode == ReaderSelectionMode.word) {
    final breaks = <int>[0];
    if (mode == ReaderSelectionMode.sentence) {
      final iterator = _sentences.segment(text);
      for (var end = iterator.next(); end >= 0; end = iterator.next()) {
        breaks.add(end);
      }
    } else {
      final iterator = _words.segment(text);
      for (var end = iterator.next(); end >= 0; end = iterator.next()) {
        breaks.add(end);
      }
    }
    for (var i = 1; i < breaks.length; i++) {
      if (offset < breaks[i]) return (breaks[i - 1], breaks[i]);
    }
  }
  var start = 0;
  for (final char in text.characters) {
    final end = start + char.length;
    if (offset < end) return (start, end);
    start = end;
  }
  return (0, text.length);
}

class ReaderSelectionLayer extends StatefulWidget {
  final bool wholeParagraphMarks;
  final PageLayout page;
  final List<BookTextNode> nodes;
  final ReaderSelectionMode mode;
  final List<ReaderPaintMark> marks;
  final Widget child;
  final bool canAnnotate;
  final void Function(bool) onSelecting;
  final void Function(ReaderSelection, bool note) onSave;
  final void Function(String) onMarkTap;
  const ReaderSelectionLayer({
    this.wholeParagraphMarks = false,
    super.key,
    required this.page,
    required this.nodes,
    required this.mode,
    required this.child,
    required this.onSelecting,
    required this.onSave,
    this.marks = const [],
    this.canAnnotate = true,
    required this.onMarkTap,
  });
  @override
  State<ReaderSelectionLayer> createState() => ReaderSelectionLayerState();
}

class ReaderSelectionLayerState extends State<ReaderSelectionLayer> {
  String? markAt(Offset point) {
    for (final mark in widget.marks) {
      if (mark.annotationId != null &&
          _boxes(mark.range).any((box) => box.contains(point))) {
        return mark.annotationId;
      }
    }
    return null;
  }

  (int, int)? _start, _end;
  List<_Surface> get _text => _surfaces(widget.page);
  void clear() {
    setState(() {
      _start = null;
      _end = null;
    });
    widget.onSelecting(false);
  }

  @override
  void didUpdateWidget(ReaderSelectionLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.page != widget.page || oldWidget.mode != widget.mode) {
      _start = null;
      _end = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onSelecting(false);
      });
    }
  }

  (int, int)? _hit(Offset position) {
    if (widget.page.linkAt(position)?.footnoteIcon == true) return null;
    final surfaces = _text;
    for (var i = 0; i < widget.nodes.length; i++) {
      final node = widget.nodes[i];
      if (node.text.isEmpty || !node.selectable) continue;
      for (final surface in surfaces.where((s) => s.node == node.displayId)) {
        if (!surface.clip.contains(position)) continue;
        final p = surface.paragraph
            .getPositionForOffset(position - surface.origin)
            .offset;
        // Inline image placeholders are not text-selection targets.
        if (surface.images.any((image) => p >= image.start && p < image.end)) {
          continue;
        }
        final offset = surface.toSource(p);
        return (i, offset.clamp(0, node.text.runes.length - 1));
      }
    }
    return null;
  }

  ReaderSelection? get _selection {
    if (_start == null || _end == null) return null;
    var a = _start!, b = _end!;
    if (a.$1 > b.$1 || a.$1 == b.$1 && a.$2 > b.$2) {
      final temp = a;
      a = b;
      b = temp;
    }
    final ranges = <SourceRange>[], quotes = <String>[];
    for (var index = a.$1; index <= b.$1; index++) {
      final node = widget.nodes[index];
      if (!node.selectable) continue;
      final start = index == a.$1
          ? selectionUnit(node.text, a.$2, widget.mode).$1
          : 0;
      final end = index == b.$1
          ? selectionUnit(node.text, b.$2, widget.mode).$2
          : node.text.runes.length;
      if (end <= start) continue;
      ranges.add(
        SourceRange(
          start: SourceAnchor(
            spine: node.source.start.spine,
            node: node.source.start.node,
            textOffset: start,
          ),
          end: SourceAnchor(
            spine: node.source.start.spine,
            node: node.source.start.node,
            textOffset: end,
          ),
        ),
      );
      quotes.add(sourceSlice(node.text, start, end));
    }
    return ranges.isEmpty ? null : ReaderSelection(ranges, quotes.join('\n'));
  }

  List<Rect> _boxes(SourceRange range) => [
    for (final surface in _text)
      if (surface.sourceNode == range.start.node &&
          surface.spine == range.start.spine)
        ...surface.boxes(
          widget.wholeParagraphMarks ? 0 : range.start.textOffset,
          widget.wholeParagraphMarks
              ? surface.mapping.last
              : range.end.textOffset,
        ),
  ];
  @override
  Widget build(BuildContext context) {
    final selection = _selection;
    final boxes = selection == null
        ? <Rect>[]
        : <Rect>{
            for (final range in selection.ranges) ..._boxes(range),
          }.toList();
    final toolbarWidth = (widget.canAnnotate ? 4 : 2) * 48.0 + 8;
    void move(Offset position, bool start) {
      final hit = _hit(position);
      if (hit != null) {
        setState(() {
          if (start) {
            _start = hit;
          } else {
            _end = hit;
          }
        });
      }
    }

    return GestureDetector(
      onLongPressStart: (d) {
        final hit = _hit(d.localPosition);
        if (hit == null) return;
        setState(() {
          _start = hit;
          _end = hit;
        });
        widget.onSelecting(true);
      },
      onLongPressMoveUpdate: (d) => move(d.localPosition, false),
      onTapUp: selection == null ? null : (_) => clear(),
      child: Stack(
        children: [
          widget.child,
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _SelectionPainter([
                  for (final mark in widget.marks)
                    for (final rect in _boxes(mark.range)) (rect, mark.color),
                  for (final rect in boxes) (rect, const Color(0x555299F5)),
                ]),
              ),
            ),
          ),
          if (boxes.isNotEmpty) ...[
            Positioned(
              left: (boxes.first.center.dx - toolbarWidth / 2).clamp(
                8.0,
                math.max(8.0, widget.page.viewport.width - toolbarWidth - 8),
              ),
              top: (boxes.first.top - 56).clamp(
                8,
                widget.page.viewport.height - 56,
              ),
              child: Material(
                key: const Key('selection-toolbar'),
                elevation: 5,
                borderRadius: BorderRadius.circular(12),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(width: 4),
                    IconButton(
                      constraints: const BoxConstraints.tightFor(
                        width: 48,
                        height: 48,
                      ),
                      tooltip: context.l10n.text('复制', 'Copy'),
                      onPressed: () => Clipboard.setData(
                        ClipboardData(text: selection!.quote),
                      ),
                      icon: const Icon(Icons.copy_outlined),
                    ),
                    if (widget.canAnnotate)
                      IconButton(
                        constraints: const BoxConstraints.tightFor(
                          width: 48,
                          height: 48,
                        ),
                        tooltip: context.l10n.text('高亮', 'Highlight'),
                        onPressed: () => widget.onSave(selection!, false),
                        icon: const Icon(Icons.highlight_outlined),
                      ),
                    if (widget.canAnnotate)
                      IconButton(
                        constraints: const BoxConstraints.tightFor(
                          width: 48,
                          height: 48,
                        ),
                        tooltip: context.l10n.text('批注', 'Note'),
                        onPressed: () => widget.onSave(selection!, true),
                        icon: const Icon(Icons.edit_note_outlined),
                      ),
                    IconButton(
                      constraints: const BoxConstraints.tightFor(
                        width: 48,
                        height: 48,
                      ),
                      tooltip: context.l10n.text('关闭选择', 'Close selection'),
                      onPressed: clear,
                      icon: const Icon(Icons.close),
                    ),
                    const SizedBox(width: 4),
                  ],
                ),
              ),
            ),
            for (final isStart in [true, false])
              Positioned(
                left: ((isStart ? boxes.first.left : boxes.last.right) - 20)
                    .clamp(0, widget.page.viewport.width - 40),
                top: (isStart ? boxes.first.bottom : boxes.last.bottom) - 8,
                child: GestureDetector(
                  onPanUpdate: (d) {
                    final render = context.findRenderObject() as RenderBox;
                    move(
                      render.globalToLocal(d.globalPosition) -
                          const Offset(0, 12),
                      isStart,
                    );
                  },
                  child: const SizedBox(
                    width: 40,
                    height: 40,
                    child: Icon(
                      Icons.circle,
                      size: 18,
                      color: Color(0xFF5299F5),
                    ),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _SelectionPainter extends CustomPainter {
  final List<(Rect, Color)> boxes;
  _SelectionPainter(this.boxes);
  @override
  void paint(Canvas canvas, Size size) {
    for (final box in boxes) {
      canvas.drawRect(box.$1, Paint()..color = box.$2);
    }
  }

  @override
  bool shouldRepaint(_SelectionPainter old) => true;
}
