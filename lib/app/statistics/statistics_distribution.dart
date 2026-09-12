import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import '../../l10n/app_localizations.dart';
import 'statistics_model.dart';
import 'statistics_period.dart';

String readingTimeLabel(BuildContext context, int ms) {
  final l10n = context.l10n;
  if (ms > 0 && ms < 60000) return l10n.text('不足 1 分', '<1 min');
  final minutes = ms ~/ 60000;
  if (minutes < 60) return l10n.text('$minutes 分', '$minutes min');
  final hours = minutes ~/ 60, rest = minutes % 60;
  return l10n.text(
    '$hours 小时${rest == 0 ? '' : ' $rest 分'}',
    '$hours h${rest == 0 ? '' : ' $rest min'}',
  );
}

class StatisticValue extends StatelessWidget {
  final List<(String, String)> parts;
  final double fontSize;
  final bool compact;
  const StatisticValue(
    this.parts, {
    super.key,
    this.fontSize = 28,
    this.compact = false,
  });
  @override
  Widget build(BuildContext context) => FittedBox(
    fit: BoxFit.scaleDown,
    alignment: Alignment.centerLeft,
    child: Text.rich(
      TextSpan(
        children: [
          for (final part in parts) ...[
            TextSpan(text: part.$1),
            TextSpan(
              text: ' ${part.$2} ',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.normal,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
      style: TextStyle(
        fontSize: fontSize,
        height: compact ? 1 : null,
        fontWeight: FontWeight.w500,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
      textHeightBehavior: compact
          ? const TextHeightBehavior(
              applyHeightToFirstAscent: false,
              applyHeightToLastDescent: false,
            )
          : null,
    ),
  );
}

class ReadingTimeValue extends StatelessWidget {
  final int milliseconds;
  final double fontSize;
  final bool compact;
  const ReadingTimeValue(
    this.milliseconds, {
    super.key,
    this.fontSize = 28,
    this.compact = false,
  });
  @override
  Widget build(BuildContext context) {
    final min = milliseconds ~/ 60000;
    final l10n = context.l10n;
    return StatisticValue(
      [
        if (min >= 60) ('${min ~/ 60}', l10n.text('小时', 'h')),
        if (min < 60 || min % 60 != 0)
          (
            milliseconds > 0 && min == 0 ? '<1' : '${min % 60}',
            l10n.text('分', 'min'),
          ),
      ],
      fontSize: fontSize,
      compact: compact,
    );
  }
}

class ReadingTrend extends StatefulWidget {
  final Map<String, int> daily;
  final DateTime? start;
  final DateTime end;
  final StatisticsPeriod period;
  const ReadingTrend({
    super.key,
    required this.daily,
    this.start,
    required this.end,
    this.period = StatisticsPeriod.month,
  });
  @override
  State<ReadingTrend> createState() => _ReadingTrendState();
}

String distributionTickLabel(double milliseconds, double step) {
  if (milliseconds == 0) return '0';
  final hours = step >= 3600000;
  final value = (milliseconds / (hours ? 3600000 : 60000))
      .toStringAsFixed(2)
      .replaceFirst(RegExp(r'\.?0+$'), '');
  return '$value${hours ? 'h' : 'min'}';
}

String distributionAxisLabel(
  StatisticsPeriod period,
  DateTime date, {
  bool chinese = true,
}) => switch (period) {
  StatisticsPeriod.week =>
    (chinese
        ? ['一', '二', '三', '四', '五', '六', '日']
        : ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'])[date.weekday - 1],
  StatisticsPeriod.month =>
    date.day == 1 || date.day % 5 == 0 ? '${date.day}' : '',
  StatisticsPeriod.year => '${date.month}',
  StatisticsPeriod.all => '${date.year}',
};

class _ReadingTrendState extends State<ReadingTrend> {
  final _tooltip = OverlayPortalController();
  final _plotKey = GlobalKey();
  final _tapGroup = Object();
  final _horizontal = ScrollController();
  ScrollPosition? _vertical;
  int? _selected;
  double _selectedX = 0;

  void _dismiss() {
    if (!_tooltip.isShowing) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _tooltip.isShowing) _tooltip.hide();
      });
    } else {
      _tooltip.hide();
    }
  }

  @override
  void initState() {
    super.initState();
    _horizontal.addListener(_dismiss);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final position = Scrollable.maybeOf(context)?.position;
    if (_vertical != position) {
      _vertical?.removeListener(_dismiss);
      _vertical = position;
      _vertical?.addListener(_dismiss);
    }
  }

  @override
  void didUpdateWidget(ReadingTrend oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.period != widget.period ||
        oldWidget.start != widget.start ||
        oldWidget.end != widget.end) {
      _dismiss();
      _selected = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _horizontal.hasClients) _horizontal.jumpTo(0);
      });
    }
  }

  @override
  void dispose() {
    _vertical?.removeListener(_dismiss);
    _horizontal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final range = widget.start == null
        ? widget.period.range(widget.end)
        : StatisticsRange(widget.start, widget.end);
    final values = widget.period.distribution(range, widget.daily);
    final maximum = values.fold<int>(0, (a, b) => math.max(a, b.milliseconds));
    final step = distributionTickStep(maximum);
    final ceiling = step * 3;
    final colors = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.labelSmall!.copyWith(
      fontSize: 11,
      color: colors.onSurfaceVariant,
    );
    Size measure(String text) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout();
      final size = painter.size;
      painter.dispose();
      return size;
    }

    final ticks = [
      for (var i = 0; i <= 3; i++) distributionTickLabel(step * i, step),
    ];
    final tickSizes = ticks.map(measure).toList();
    final labels = values
        .map(
          (bin) => distributionAxisLabel(
            widget.period,
            bin.date,
            chinese: context.l10n.isChinese,
          ),
        )
        .toList();
    final labelSizes = labels.map(measure).toList();
    final axisWidth = tickSizes.fold<double>(
      0,
      (w, size) => math.max(w, size.width),
    );
    final labelHeight = labelSizes.fold<double>(
      0,
      (h, size) => math.max(h, size.height),
    );
    const top = 24.0, height = 190.0;
    final chartHeight = top + height + math.max(26, labelHeight + 12);
    String dateLabel(StatisticsBin bin) => switch (widget.period) {
      StatisticsPeriod.week ||
      StatisticsPeriod.month => dayKey(bin.date).replaceAll('-', '/'),
      StatisticsPeriod.year => dayKey(
        bin.date,
      ).substring(0, 7).replaceAll('-', '/'),
      StatisticsPeriod.all => '${bin.date.year}',
    };
    return OverlayPortal(
      controller: _tooltip,
      overlayChildBuilder: (overlayContext) {
        final box = _plotKey.currentContext?.findRenderObject() as RenderBox?;
        if (box == null || _selected == null) return const SizedBox.shrink();
        final overlayBox =
            Overlay.of(context).context.findRenderObject() as RenderBox;
        final anchor = overlayBox.globalToLocal(
          box.localToGlobal(Offset(_selectedX, top)),
        );
        final selected = values[_selected!.clamp(0, values.length - 1)];
        return CustomSingleChildLayout(
          delegate: _DistributionTooltipLayout(anchor),
          child: TapRegion(
            groupId: _tapGroup,
            child: Material(
              key: const ValueKey('statistics-distribution-tooltip'),
              elevation: 6,
              color: colors.surfaceContainerHigh,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
                side: BorderSide(color: colors.outlineVariant),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Semantics(
                  liveRegion: true,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        dateLabel(selected),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 6),
                      ReadingTimeValue(selected.milliseconds, fontSize: 22),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
      child: TapRegion(
        groupId: _tapGroup,
        onTapOutside: (_) => _dismiss(),
        child: SizedBox(
          height: chartHeight,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: LayoutBuilder(
                  builder: (context, box) {
                    final minimumSlot = switch (widget.period) {
                      StatisticsPeriod.month => 8.0,
                      StatisticsPeriod.all => 66.0,
                      _ => math.max(
                        28.0,
                        labelSizes.fold<double>(
                              0,
                              (w, s) => math.max(w, s.width),
                            ) +
                            6,
                      ),
                    };
                    final width = math.max(
                      box.maxWidth,
                      values.length * minimumSlot,
                    );
                    final slot = width / values.length;
                    void select(double x) {
                      final index = (x / slot).floor().clamp(
                        0,
                        values.length - 1,
                      );
                      setState(() {
                        _selected = index;
                        _selectedX =
                            ((index + .5) * slot -
                                    (_horizontal.hasClients
                                        ? _horizontal.offset
                                        : 0))
                                .clamp(0, box.maxWidth);
                      });
                      _tooltip.show();
                    }

                    return Stack(
                      key: _plotKey,
                      children: [
                        Positioned(
                          left: 0,
                          right: 0,
                          top: top,
                          height: height,
                          child: CustomPaint(
                            painter: _DistributionGrid(
                              colors.onSurfaceVariant,
                              maximum == 0,
                            ),
                          ),
                        ),
                        if (maximum == 0)
                          Positioned(
                            left: 0,
                            right: 0,
                            top: top,
                            height: height,
                            child: Center(
                              child: Text(
                                context.l10n.text(
                                  '暂无阅读记录',
                                  'No reading records',
                                ),
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                          ),
                        SingleChildScrollView(
                          controller: _horizontal,
                          scrollDirection: Axis.horizontal,
                          child: MouseRegion(
                            onHover: (event) => select(event.localPosition.dx),
                            onExit: (_) => _dismiss(),
                            child: GestureDetector(
                              key: const ValueKey(
                                'statistics-distribution-plot',
                              ),
                              behavior: HitTestBehavior.opaque,
                              onTapDown: (event) =>
                                  select(event.localPosition.dx),
                              onLongPressStart: (event) =>
                                  select(event.localPosition.dx),
                              onLongPressMoveUpdate: (event) =>
                                  select(event.localPosition.dx),
                              onHorizontalDragUpdate: width <= box.maxWidth
                                  ? (event) => select(event.localPosition.dx)
                                  : null,
                              child: SizedBox(
                                width: width,
                                height: chartHeight,
                                child: Stack(
                                  children: [
                                    for (var i = 0; i < values.length; i++)
                                      Positioned(
                                        left: i * slot,
                                        top: 0,
                                        width: slot,
                                        height: chartHeight,
                                        child: Semantics(
                                          label:
                                              '${dateLabel(values[i])} ${readingTimeLabel(context, values[i].milliseconds)}',
                                          button: true,
                                          onTap: () => select((i + .5) * slot),
                                          child: Stack(
                                            children: [
                                              if (values[i].milliseconds > 0)
                                                Positioned(
                                                  left:
                                                      (slot -
                                                          math.min(
                                                            slot * .6,
                                                            48,
                                                          )) /
                                                      2,
                                                  bottom:
                                                      chartHeight -
                                                      top -
                                                      height,
                                                  width: math.min(
                                                    slot * .6,
                                                    48,
                                                  ),
                                                  height: math.max(
                                                    1,
                                                    values[i].milliseconds /
                                                        ceiling *
                                                        height,
                                                  ),
                                                  child: DecoratedBox(
                                                    decoration: BoxDecoration(
                                                      color: colors.primary,
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            3,
                                                          ),
                                                    ),
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    for (var i = 0; i < labels.length; i++)
                                      if (labels[i].isNotEmpty)
                                        Positioned(
                                          left:
                                              ((i + .5) * slot -
                                                      labelSizes[i].width / 2)
                                                  .clamp(
                                                    0,
                                                    math.max(
                                                      0,
                                                      width -
                                                          labelSizes[i].width,
                                                    ),
                                                  ),
                                          top:
                                              top +
                                              height +
                                              16 -
                                              labelSizes[i].height / 2,
                                          child: Text(labels[i], style: style),
                                        ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: axisWidth,
                height: chartHeight,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    for (var i = 0; i <= 3; i++)
                      if (maximum != 0 || i == 0)
                        Positioned(
                          left: 0,
                          top:
                              top +
                              height -
                              i / 3 * height -
                              tickSizes[i].height / 2,
                          child: Text(ticks[i], style: style),
                        ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DistributionTooltipLayout extends SingleChildLayoutDelegate {
  final Offset anchor;
  _DistributionTooltipLayout(this.anchor);
  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(
        maxWidth: math.max(0, math.min(260, constraints.maxWidth - 24)),
        maxHeight: constraints.maxHeight,
      );
  @override
  Offset getPositionForChild(Size size, Size childSize) => Offset(
    (anchor.dx - childSize.width / 2).clamp(
      12,
      math.max(12, size.width - childSize.width - 12),
    ),
    (anchor.dy - childSize.height).clamp(
      12,
      math.max(12, size.height - childSize.height - 12),
    ),
  );
  @override
  bool shouldRelayout(_DistributionTooltipLayout oldDelegate) =>
      oldDelegate.anchor != anchor;
}

class _DistributionGrid extends CustomPainter {
  final Color color;
  final bool empty;
  const _DistributionGrid(this.color, this.empty);
  @override
  void paint(Canvas canvas, Size size) {
    for (var i = 0; i <= 3; i++) {
      if (empty && i > 0) continue;
      final y = size.height - i / 3 * size.height;
      final paint = Paint()
        ..color = color.withValues(alpha: i == 0 ? .25 : .12)
        ..strokeWidth = 1;
      for (double x = 0; x < size.width; x += 8) {
        canvas.drawLine(
          Offset(x, y),
          Offset(math.min(x + 4, size.width), y),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_DistributionGrid oldDelegate) =>
      oldDelegate.color != color || oldDelegate.empty != empty;
}
