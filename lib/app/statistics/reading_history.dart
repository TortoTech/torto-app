import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

/// Daily totals share number columns, so changing digit counts do not move units.
/// Filtering is presentation-only: sub-minute time still contributes to totals.
class ReadingHistory extends StatelessWidget {
  final Map<String, int> daily;
  const ReadingHistory({super.key, required this.daily});

  @override
  Widget build(BuildContext context) {
    final days = daily.keys.where((day) => daily[day]! >= 60000).toList()
      ..sort((a, b) => b.compareTo(a));
    if (days.isEmpty) {
      return Text(
        context.l10n.text(
          '暂无满 1 分钟的阅读记录',
          'No days with at least one minute of reading.',
        ),
        style: Theme.of(context).textTheme.bodySmall,
      );
    }
    final style = Theme.of(context).textTheme.bodyMedium?.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    Widget cell(String text, {bool number = false, double left = 4}) => Padding(
      padding: EdgeInsets.fromLTRB(left, 12, 0, 12),
      child: Text(
        text,
        style: style,
        textAlign: number ? TextAlign.right : TextAlign.left,
      ),
    );
    return Table(
      defaultVerticalAlignment: TableCellVerticalAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      columnWidths: const {
        0: FlexColumnWidth(),
        1: IntrinsicColumnWidth(),
        2: IntrinsicColumnWidth(),
        3: IntrinsicColumnWidth(),
        4: IntrinsicColumnWidth(),
      },
      children: [
        for (final day in days)
          TableRow(
            key: ValueKey(day),
            children: [
              cell(day.replaceAll('-', '/'), left: 0),
              cell('${daily[day]! ~/ 3600000}', number: true, left: 12),
              cell(context.l10n.text('小时', 'h')),
              cell('${daily[day]! ~/ 60000 % 60}', number: true, left: 8),
              cell(context.l10n.text('分', 'min')),
            ],
          ),
      ],
    );
  }
}
