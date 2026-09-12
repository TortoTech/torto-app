import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../library/library_store.dart';
import '../progress_store.dart';
import '../reader/annotations_repository.dart';
import 'statistics_distribution.dart';
import 'statistics_period.dart';
import 'statistics_model.dart';
import 'statistics_store.dart';
export 'statistics_distribution.dart' show ReadingTrend;

String statisticsDuration(int ms) {
  if (ms > 0 && ms < 60000) return '<1 min';
  final minutes = ms ~/ 60000;
  return minutes < 60
      ? '$minutes min'
      : '${minutes ~/ 60} h ${minutes % 60} min';
}

String statusLabel(BuildContext context, ReadingStatus status) =>
    switch (status) {
      ReadingStatus.notStarted => context.l10n.text('未开始', 'Not started'),
      ReadingStatus.reading => context.l10n.text('在读', 'Reading'),
      ReadingStatus.finished => context.l10n.text('已读完', 'Finished'),
    };

class ReadingStatisticsPage extends StatefulWidget {
  final String? bookId;
  final ReadingStatisticsStore? store;
  final LibraryStore? libraryStore;
  final ProgressStore? progressStore;
  final AnnotationsRepository? annotationsRepository;
  const ReadingStatisticsPage({
    super.key,
    this.bookId,
    this.store,
    this.libraryStore,
    this.progressStore,
    this.annotationsRepository,
  });
  @override
  State<ReadingStatisticsPage> createState() => _ReadingStatisticsPageState();
}

class _ReadingStatisticsPageState extends State<ReadingStatisticsPage> {
  Map<String, BookReadingStats>? _books;
  Map<String, LibraryBook> _library = {};
  String? _error;
  StatisticsPeriod _period = StatisticsPeriod.week;
  int _periodOffset = 0;
  (int, int)? _annotationCounts;
  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      final store = widget.store ?? await ReadingStatisticsStore.instance();
      final library = await (widget.libraryStore ?? LibraryStore()).list();
      await store.registerBooks(library);
      final books = aggregateStatistics(await store.events());
      final progress = await (widget.progressStore ?? ProgressStore()).all();
      for (final book in books.values) {
        book.progress = progress[book.id]?.totalProgression ?? book.progress;
      }
      (int, int)? annotationCounts;
      if (widget.bookId != null &&
          (widget.store == null || widget.annotationsRepository != null)) {
        try {
          final repository =
              widget.annotationsRepository ??
              await AnnotationsRepository.open();
          final annotations = await repository.list(widget.bookId!);
          annotationCounts = (
            annotations.length,
            annotations.where((a) => a.note?.trim().isNotEmpty == true).length,
          );
        } catch (_) {
          // Reading history remains usable when annotations cannot be loaded.
        }
      }
      if (mounted) {
        setState(() {
          _books = books;
          _library = {for (final book in library) book.id: book};
          _error = null;
          _annotationCounts = annotationCounts;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = context.l10n.text(
            '无法读取统计，点击重试',
            'Could not load statistics. Tap to retry.',
          ),
        );
      }
    }
  }

  Widget _cover(String id, {double width = 44}) {
    final bytes = _library[id]?.coverBytes;
    return ClipRRect(
      borderRadius: BorderRadius.circular(5),
      child: SizedBox(
        width: width,
        height: width * 1.4,
        child: bytes == null
            ? ColoredBox(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: const Icon(Icons.menu_book_outlined),
              )
            : Image.memory(
                bytes,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const Icon(Icons.menu_book),
              ),
      ),
    );
  }

  Widget _card(Widget child) => Card(
    elevation: 0,
    color: Theme.of(context).colorScheme.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: BorderSide(
        color: Theme.of(
          context,
        ).colorScheme.outlineVariant.withValues(alpha: .6),
      ),
    ),
    margin: const EdgeInsets.only(bottom: 12),
    child: Padding(padding: const EdgeInsets.all(16), child: child),
  );
  Widget _title(String zh, String en) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Text(
      context.l10n.text(zh, en),
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );
  Widget _metric(String label, Widget value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 6),
      value,
    ],
  );
  Future<void> _openBook(String id) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => ReadingStatisticsPage(
          bookId: id,
          store: widget.store,
          libraryStore: widget.libraryStore,
          progressStore: widget.progressStore,
          annotationsRepository: widget.annotationsRepository,
        ),
      ),
    );
    if (mounted) await _reload();
  }

  Widget _bookRow(BookReadingStats book, int duration) => InkWell(
    onTap: () => _openBook(book.id),
    borderRadius: BorderRadius.circular(8),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          _cover(book.id),
          const SizedBox(width: 14),
          Expanded(
            // Font boxes include uneven ascent/descent space. On-device ink
            // measurements put this mixed-size pair about 2 dp below the
            // cover centre even when its layout box is centred.
            child: Transform.translate(
              offset: Offset(
                0,
                -MediaQuery.textScalerOf(context).scale(20) * .1,
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 44 * 1.4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ReadingTimeValue(duration, fontSize: 20, compact: true),
                    const SizedBox(height: 5),
                    Text(
                      book.title.isEmpty
                          ? context.l10n.text('未知书籍', 'Unknown book')
                          : book.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textHeightBehavior: const TextHeightBehavior(
                        applyHeightToFirstAscent: false,
                        applyHeightToLastDescent: false,
                      ),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        height: 1.2,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Icon(
            Icons.chevron_right,
            size: 18,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ],
      ),
    ),
  );

  String _rangeLabel(StatisticsRange range) {
    final start = range.start, end = range.end;
    if (start == null) {
      return '';
    }
    String short(DateTime d) => dayKey(d).substring(5).replaceAll('-', '/');
    if (_period == StatisticsPeriod.month) {
      return dayKey(start).substring(0, 7).replaceAll('-', '/');
    }
    if (_period == StatisticsPeriod.year) return '${start.year}';
    final left = start.year == DateTime.now().year
        ? short(start)
        : dayKey(start).replaceAll('-', '/');
    final right = start.year == end.year
        ? short(end)
        : dayKey(end).replaceAll('-', '/');
    return '$left ${context.l10n.text('至', '–')} $right';
  }

  Widget _overview() {
    final all = _books!.values.toList();
    final range = _period.range(DateTime.now(), _periodOffset);
    final daily = dailyReading(all.expand((book) => book.intervals));
    final valid = dailyReading(all.expand((book) => book.validIntervals));
    final ranked = longestReading(all, range);
    final finished = all
        .where(
          (book) =>
              book.status == ReadingStatus.finished &&
              book.finished != null &&
              range.contains(book.finished!),
        )
        .length;
    final l10n = context.l10n;
    final metrics = <(String, Widget)>[
      (l10n.text('阅读时长', 'Reading time'), ReadingTimeValue(range.total(daily))),
      (
        l10n.text('阅读', 'Reading days'),
        StatisticValue([
          (
            '${valid.keys.where(range.contains).length}',
            l10n.text('天', 'days'),
          ),
        ]),
      ),
      (
        l10n.text('读过', 'Books read'),
        StatisticValue([('${ranked.length}', l10n.text('本', 'books'))]),
      ),
      (
        l10n.text('读完', 'Finished'),
        StatisticValue([('$finished', l10n.text('本', 'books'))]),
      ),
    ];
    final currentLabel = switch (_period) {
      StatisticsPeriod.week => l10n.text('本周', 'This week'),
      StatisticsPeriod.month => l10n.text('本月', 'This month'),
      StatisticsPeriod.year => l10n.text('今年', 'This year'),
      StatisticsPeriod.all => '',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<StatisticsPeriod>(
          expandedInsets: EdgeInsets.zero,
          showSelectedIcon: false,
          segments: [
            ButtonSegment(
              value: StatisticsPeriod.week,
              label: Text(l10n.text('周', 'Week')),
            ),
            ButtonSegment(
              value: StatisticsPeriod.month,
              label: Text(l10n.text('月', 'Month')),
            ),
            ButtonSegment(
              value: StatisticsPeriod.year,
              label: Text(l10n.text('年', 'Year')),
            ),
            ButtonSegment(
              value: StatisticsPeriod.all,
              label: Text(l10n.text('总', 'All')),
            ),
          ],
          selected: {_period},
          onSelectionChanged: (selection) => setState(() {
            _period = selection.single;
            _periodOffset = 0;
          }),
        ),
        if (_period == StatisticsPeriod.all)
          const SizedBox(height: 16)
        else
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Wrap(
              key: const ValueKey('statistics-period-navigation'),
              alignment: WrapAlignment.start,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (_period != StatisticsPeriod.all)
                  IconButton(
                    tooltip: l10n.text('上一周期', 'Previous period'),
                    icon: const Icon(Icons.chevron_left),
                    onPressed: () => setState(() => _periodOffset--),
                  ),
                Text(
                  _rangeLabel(range),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                if (_period != StatisticsPeriod.all)
                  IconButton(
                    tooltip: l10n.text('下一周期', 'Next period'),
                    icon: const Icon(Icons.chevron_right),
                    onPressed: _periodOffset < 0
                        ? () => setState(() => _periodOffset++)
                        : null,
                  ),
                if (_periodOffset < 0)
                  TextButton(
                    onPressed: () => setState(() => _periodOffset = 0),
                    child: Text(currentLabel),
                  ),
              ],
            ),
          ),
        for (var row = 0; row < 2; row++)
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: _card(
                    _metric(metrics[row * 2].$1, metrics[row * 2].$2),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _card(
                    _metric(metrics[row * 2 + 1].$1, metrics[row * 2 + 1].$2),
                  ),
                ),
              ],
            ),
          ),
        _card(
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _title('阅读时长分布', 'Reading time distribution'),
              ReadingTrend(
                daily: daily,
                period: _period,
                start: range.start,
                end: range.end,
              ),
            ],
          ),
        ),
        _card(
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _title('阅读最久', 'Most time spent reading'),
              if (ranked.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    l10n.text(
                      '这段时间还没有阅读记录',
                      'No reading recorded in this period.',
                    ),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              for (final entry in ranked) _bookRow(entry.book, entry.duration),
            ],
          ),
        ),
      ],
    );
  }

  Widget _detail(BookReadingStats book) {
    final daily = dailyReading(book.intervals);
    String date(int? ms) => ms == null || ms == 0
        ? '—'
        : dayKey(DateTime.fromMillisecondsSinceEpoch(ms)).replaceAll('-', '/');
    final days = daily.keys.toList()..sort((a, b) => b.compareTo(a));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _card(
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _cover(book.id, width: 76),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      book.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(
                        context,
                      ).textTheme.titleMedium?.copyWith(fontSize: 18),
                    ),
                    Text(book.authors),
                    const SizedBox(height: 12),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Text(
                          statusLabel(context, book.status),
                          textHeightBehavior: const TextHeightBehavior(
                            applyHeightToFirstAscent: false,
                            applyHeightToLastDescent: false,
                          ),
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                        if (book.status == ReadingStatus.reading) ...[
                          const SizedBox(width: 10),
                          Text(
                            '${(book.progress.clamp(0, 1) * 100).toStringAsFixed(1)}%',
                            key: const ValueKey('statistics-reading-position'),
                            textHeightBehavior: const TextHeightBehavior(
                              applyHeightToFirstAscent: false,
                              applyHeightToLastDescent: false,
                            ),
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        _card(
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: _metric(
                      context.l10n.text('累计阅读', 'Total reading'),
                      ReadingTimeValue(book.duration),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _metric(
                      context.l10n.text('阅读天数', 'Reading days'),
                      StatisticValue([
                        ('${book.readingDays}', context.l10n.text('天', 'days')),
                      ]),
                    ),
                  ),
                ],
              ),
              if (_annotationCounts != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    context.l10n.text(
                      '${_annotationCounts!.$1} 处高亮 · ${_annotationCounts!.$2} 条批注',
                      '${_annotationCounts!.$1} highlights · ${_annotationCounts!.$2} notes',
                    ),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
            ],
          ),
        ),
        _card(
          Column(
            children: [
              for (final e in {
                context.l10n.text('加入书架', 'Added'): date(book.added),
                context.l10n.text('开始阅读', 'Started'): date(book.started),
                context.l10n.text('最近阅读', 'Last read'): date(book.last),
                context.l10n.text('读完日期', 'Finished'):
                    book.finished?.replaceAll('-', '/') ?? '—',
              }.entries)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Expanded(child: Text(e.key)),
                      const SizedBox(width: 12),
                      Text(
                        e.value,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        _card(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _title('阅读历史', 'Reading history'),
              if (days.isEmpty)
                Text(
                  context.l10n.text('暂无阅读记录', 'No reading records'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              for (final day in days)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Expanded(
                        child: Text(
                          day.replaceAll('-', '/'),
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        readingTimeLabel(context, daily[day]!),
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final detail = widget.bookId != null;
    final book = _books?[widget.bookId];
    return Scaffold(
      appBar: AppBar(
        title: Text(
          detail
              ? context.l10n.text('阅读详情', 'Reading details')
              : context.l10n.text('阅读统计', 'Reading statistics'),
        ),
      ),
      body: _error != null
          ? Center(
              child: TextButton(onPressed: _reload, child: Text(_error!)),
            )
          : _books == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _reload,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(16),
                child: detail
                    ? book == null
                          ? Text(
                              context.l10n.text('暂无阅读记录', 'No reading history'),
                            )
                          : _detail(book)
                    : _overview(),
              ),
            ),
    );
  }
}

class StatisticsSummaryCard extends StatefulWidget {
  final bool active;
  const StatisticsSummaryCard({super.key, this.active = true});
  @override
  State<StatisticsSummaryCard> createState() => _StatisticsSummaryCardState();
}

class _StatisticsSummaryCardState extends State<StatisticsSummaryCard> {
  int? _today, _week;
  int _days = 0;
  @override
  void initState() {
    super.initState();
    if (widget.active) _reload();
  }

  @override
  void didUpdateWidget(StatisticsSummaryCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) _reload();
  }

  Future<void> _reload() async {
    try {
      final books = aggregateStatistics(
        await (await ReadingStatisticsStore.instance()).events(),
      );
      final daily = dailyReading(books.values.expand((b) => b.intervals));
      final valid = dailyReading(books.values.expand((b) => b.validIntervals));
      final today = DateUtils.dateOnly(DateTime.now());
      final from = dayKey(today.subtract(Duration(days: today.weekday - 1)));
      if (mounted) {
        setState(() {
          _today = daily[dayKey(today)] ?? 0;
          _week = daily.entries
              .where(
                (e) =>
                    e.key.compareTo(from) >= 0 &&
                    e.key.compareTo(dayKey(today)) <= 0,
              )
              .fold<int>(0, (sum, e) => sum + e.value);
          _days = valid.keys
              .where(
                (d) =>
                    d.compareTo(from) >= 0 && d.compareTo(dayKey(today)) <= 0,
              )
              .length;
        });
      }
    } catch (_) {
      /* The entry remains usable; the page offers retry. */
    }
  }

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.fromLTRB(16, 4, 16, 12),
    child: ListTile(
      contentPadding: const EdgeInsets.all(20),
      title: Text(context.l10n.text('阅读统计', 'Reading statistics')),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _today == null ? '—' : readingTimeLabel(context, _today!),
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            Text(context.l10n.text('今日阅读', 'Today')),
            const SizedBox(height: 8),
            Text(
              context.l10n.text(
                '本周 ${readingTimeLabel(context, _week ?? 0)} · 阅读 $_days 天',
                'This week ${readingTimeLabel(context, _week ?? 0)} · $_days reading days',
              ),
            ),
          ],
        ),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () async {
        await Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) => const ReadingStatisticsPage(),
          ),
        );
        if (mounted) _reload();
      },
    ),
  );
}
