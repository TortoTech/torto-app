import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../library/library_store.dart';
import '../progress_store.dart';
import 'statistics_model.dart';
import 'statistics_store.dart';

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
  const ReadingStatisticsPage({
    super.key,
    this.bookId,
    this.store,
    this.libraryStore,
    this.progressStore,
  });
  @override
  State<ReadingStatisticsPage> createState() => _ReadingStatisticsPageState();
}

class _ReadingStatisticsPageState extends State<ReadingStatisticsPage> {
  Map<String, BookReadingStats>? _books;
  Map<String, LibraryBook> _library = {};
  String? _error;
  String _period = '30';
  DateTimeRange? _custom;
  ReadingStatus? _filter;
  String _query = '';
  bool _mutating = false;
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
      if (mounted) {
        setState(() {
          _books = books;
          _library = {for (final book in library) book.id: book};
          _error = null;
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

  DateTime get _end =>
      _period == 'custom' ? _custom!.end : DateUtils.dateOnly(DateTime.now());
  DateTime? get _start => switch (_period) {
    '7' => _end.subtract(const Duration(days: 6)),
    '30' => _end.subtract(const Duration(days: 29)),
    'year' => DateTime(_end.year),
    'custom' => _custom!.start,
    _ => null,
  };
  bool _inRange(String day) =>
      day.compareTo(dayKey(_end)) <= 0 &&
      (_start == null || day.compareTo(dayKey(_start!)) >= 0);

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
    margin: const EdgeInsets.only(bottom: 12),
    child: Padding(padding: const EdgeInsets.all(16), child: child),
  );
  Widget _title(String zh, String en) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Text(
      context.l10n.text(zh, en),
      style: Theme.of(context).textTheme.titleMedium,
    ),
  );
  Widget _metric(String label, String value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 6),
      Text(value, style: Theme.of(context).textTheme.titleLarge),
    ],
  );
  Future<void> _openBook(String id) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => ReadingStatisticsPage(bookId: id),
      ),
    );
    if (mounted) await _reload();
  }

  Widget _bookRow(BookReadingStats book) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: _cover(book.id),
    title: Text(
      book.title.isEmpty
          ? context.l10n.text('未知书籍', 'Unknown book')
          : book.title,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    ),
    subtitle: Text(
      '${statusLabel(context, book.status)} · ${statisticsDuration(book.duration)}',
    ),
    trailing: const Icon(Icons.chevron_right),
    onTap: () => _openBook(book.id),
  );

  Widget _overview() {
    final all = _books!.values.toList();
    final daily = dailyReading(all.expand((book) => book.intervals));
    final valid = dailyReading(all.expand((book) => book.validIntervals));
    final total = daily.entries
        .where((e) => _inRange(e.key))
        .fold<int>(0, (sum, e) => sum + e.value);
    final finished =
        all
            .where(
              (book) =>
                  book.status == ReadingStatus.finished &&
                  book.finished != null &&
                  _inRange(book.finished!),
            )
            .toList()
          ..sort((a, b) => b.finished!.compareTo(a.finished!));
    final filtered =
        all
            .where(
              (book) =>
                  (_filter == null || book.status == _filter) &&
                  '${book.title} ${book.authors}'.toLowerCase().contains(
                    _query.toLowerCase(),
                  ),
            )
            .toList()
          ..sort((a, b) => (b.last ?? 0).compareTo(a.last ?? 0));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          children: [
            for (final entry in {
              '7': context.l10n.text('最近7天', '7 days'),
              '30': context.l10n.text('最近30天', '30 days'),
              'year': context.l10n.text('今年', 'This year'),
              'all': context.l10n.text('全部', 'All time'),
              'custom': context.l10n.text('自定义', 'Custom'),
            }.entries)
              ChoiceChip(
                label: Text(entry.value),
                selected: _period == entry.key,
                onSelected: (_) async {
                  if (entry.key == 'custom') {
                    final dates = await showDateRangePicker(
                      context: context,
                      firstDate: DateTime(1970),
                      lastDate: DateTime.now(),
                      initialDateRange: _custom,
                    );
                    if (dates == null || !mounted) return;
                    setState(() {
                      _custom = dates;
                      _period = 'custom';
                    });
                  } else {
                    setState(() => _period = entry.key);
                  }
                },
              ),
          ],
        ),
        if (_period == 'custom')
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text('${dayKey(_start!)} — ${dayKey(_end)}'),
          ),
        const SizedBox(height: 12),
        _card(
          Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: _metric(
                      context.l10n.text('今日阅读', 'Today'),
                      statisticsDuration(daily[dayKey(DateTime.now())] ?? 0),
                    ),
                  ),
                  Expanded(
                    child: _metric(
                      context.l10n.text('期间阅读时长', 'Reading time'),
                      statisticsDuration(total),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: _metric(
                      context.l10n.text('期间读完', 'Books finished'),
                      '${finished.length}',
                    ),
                  ),
                  Expanded(
                    child: _metric(
                      context.l10n.text('阅读天数', 'Reading days'),
                      '${valid.keys.where(_inRange).length}',
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        _card(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _title('阅读趋势', 'Reading trend'),
              ReadingTrend(daily: daily, start: _start, end: _end),
            ],
          ),
        ),
        if (all.every((b) => b.intervals.isEmpty))
          _card(
            Text(
              context.l10n.text(
                '开始阅读后，这里会记录你的阅读时间。历史时长不会根据阅读进度推算。',
                'Start reading to record your reading time. Past duration is not inferred from progress.',
              ),
            ),
          ),
        _card(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _title('最近读完', 'Recently finished'),
              if (finished.isEmpty)
                Text(
                  context.l10n.text(
                    '这段时间还没有读完的书',
                    'No books finished in this period.',
                  ),
                )
              else
                SizedBox(
                  height: 158,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: math.min(10, finished.length),
                    separatorBuilder: (_, _) => const SizedBox(width: 16),
                    itemBuilder: (_, i) => InkWell(
                      onTap: () => _openBook(finished[i].id),
                      child: SizedBox(
                        width: 88,
                        child: Column(
                          children: [
                            _cover(finished[i].id, width: 70),
                            const SizedBox(height: 8),
                            Text(
                              finished[i].title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        _card(
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _title('书籍阅读记录', 'Books'),
              TextField(
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: context.l10n.text(
                    '搜索书名或作者',
                    'Search title or author',
                  ),
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                children: [
                  ChoiceChip(
                    label: Text(context.l10n.text('全部', 'All')),
                    selected: _filter == null,
                    onSelected: (_) => setState(() => _filter = null),
                  ),
                  for (final status in ReadingStatus.values)
                    ChoiceChip(
                      label: Text(statusLabel(context, status)),
                      selected: _filter == status,
                      onSelected: (_) => setState(() => _filter = status),
                    ),
                ],
              ),
              if (filtered.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    context.l10n.text('没有匹配的书籍', 'No matching books'),
                  ),
                ),
              for (final book in filtered) _bookRow(book),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _edit(BookReadingStats book) async {
    var status = book.status;
    var finished = DateTime.tryParse(book.finished ?? '') ?? DateTime.now();
    final save = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  context.l10n.text('编辑阅读状态', 'Edit reading status'),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 16),
                DropdownButton<ReadingStatus>(
                  isExpanded: true,
                  value: status,
                  items: [
                    for (final s in ReadingStatus.values)
                      DropdownMenuItem(
                        value: s,
                        child: Text(statusLabel(context, s)),
                      ),
                  ],
                  onChanged: (v) => update(() => status = v!),
                ),
                if (status == ReadingStatus.finished)
                  ListTile(
                    title: Text(context.l10n.text('读完日期', 'Finished on')),
                    subtitle: Text(dayKey(finished)),
                    trailing: const Icon(Icons.calendar_today_outlined),
                    onTap: () async {
                      final date = await showDatePicker(
                        context: context,
                        firstDate: DateTime(1970),
                        lastDate: DateTime.now(),
                        initialDate: finished.isAfter(DateTime.now())
                            ? DateTime.now()
                            : finished,
                      );
                      if (date != null && context.mounted) {
                        update(() => finished = date);
                      }
                    },
                  ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: Text(context.l10n.text('保存', 'Save')),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (save == true) {
      await _mutate(
        (store) => store.setStatus(book.id, status, dayKey(finished)),
      );
    }
  }

  Future<void> _mutate(
    Future<void> Function(ReadingStatisticsStore) action,
  ) async {
    if (_mutating) return;
    setState(() => _mutating = true);
    try {
      await action(widget.store ?? await ReadingStatisticsStore.instance());
      await _reload();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.l10n.text('保存失败，请重试', 'Could not save. Try again.'),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _mutating = false);
    }
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          context.l10n.text('清空本书统计？', 'Clear this book’s statistics?'),
        ),
        content: Text(
          context.l10n.text(
            '阅读时间与完成记录将被清空，并在云同步时传播到其他设备。书籍、阅读位置和批注会保留。',
            'Reading time and completion history will be cleared across devices on cloud sync. The book, reading position and annotations remain.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.text('取消', 'Cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              context.l10n.text('确认清空', 'Clear'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _mutate((store) => store.clear(widget.bookId!));
    }
  }

  Widget _detail(BookReadingStats book) {
    final daily = dailyReading(book.intervals);
    String date(int? ms) => ms == null || ms == 0
        ? '—'
        : dayKey(DateTime.fromMillisecondsSinceEpoch(ms));
    final sessions = book.sessions.values.toList()
      ..sort((a, b) => b.first.start.compareTo(a.first.start));
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
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    Text(book.authors),
                    const SizedBox(height: 12),
                    Text(
                      statusLabel(context, book.status),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    LinearProgressIndicator(value: book.progress.clamp(0, 1)),
                    const SizedBox(height: 6),
                    Text(
                      context.l10n.text(
                        '当前阅读位置 ${(book.progress * 100).toStringAsFixed(1)}%',
                        'Current position ${(book.progress * 100).toStringAsFixed(1)}%',
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        _card(
          Row(
            children: [
              Expanded(
                child: _metric(
                  context.l10n.text('累计阅读', 'Total reading'),
                  statisticsDuration(book.duration),
                ),
              ),
              Expanded(
                child: _metric(
                  context.l10n.text('阅读天数', 'Reading days'),
                  '${book.readingDays}',
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
                context.l10n.text('读完日期', 'Finished'): book.finished ?? '—',
              }.entries)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  child: Row(
                    children: [
                      Expanded(child: Text(e.key)),
                      Text(e.value),
                    ],
                  ),
                ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _mutating ? null : () => _edit(book),
                  icon: const Icon(Icons.edit_outlined),
                  label: Text(
                    context.l10n.text('编辑阅读状态', 'Edit reading status'),
                  ),
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
              ReadingTrend(daily: daily, end: DateTime.now()),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(context.l10n.text('每日明细', 'Daily details')),
                children: [
                  for (final day in days)
                    ListTile(
                      title: Text(day),
                      trailing: Text(statisticsDuration(daily[day]!)),
                    ),
                ],
              ),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(context.l10n.text('阅读会话', 'Reading sessions')),
                children: [
                  if (sessions.isEmpty)
                    ListTile(
                      title: Text(
                        context.l10n.text('暂无阅读会话', 'No reading sessions yet'),
                      ),
                    ),
                  for (final session in sessions.take(100))
                    ListTile(
                      title: Text(
                        DateTime.fromMillisecondsSinceEpoch(
                          session.first.start + session.first.offset * 1000,
                          isUtc: true,
                        ).toString().substring(0, 16),
                      ),
                      trailing: Text(
                        statisticsDuration(readingDuration(session)),
                      ),
                    ),
                  if (sessions.length > 100)
                    Text(
                      context.l10n.text(
                        '显示最近100次会话',
                        'Showing the latest 100 sessions',
                      ),
                    ),
                ],
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
        actions: [
          if (detail)
            PopupMenuButton<String>(
              onSelected: (_) => _clear(),
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'clear',
                  child: Text(context.l10n.text('清空本书统计', 'Clear statistics')),
                ),
              ],
            ),
        ],
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

class ReadingTrend extends StatefulWidget {
  final Map<String, int> daily;
  final DateTime? start;
  final DateTime end;
  const ReadingTrend({
    super.key,
    required this.daily,
    this.start,
    required this.end,
  });
  @override
  State<ReadingTrend> createState() => _ReadingTrendState();
}

class _ReadingTrendState extends State<ReadingTrend> {
  int? _selected;
  @override
  Widget build(BuildContext context) {
    final end = DateTime.utc(widget.end.year, widget.end.month, widget.end.day);
    final start = widget.start;
    final count = start == null
        ? 30
        : (end
                      .difference(
                        DateTime.utc(start.year, start.month, start.day),
                      )
                      .inDays +
                  1)
              .clamp(1, 30);
    final days = List.generate(
      count,
      (i) => dayKey(end.subtract(Duration(days: count - 1 - i))),
    );
    final values = [for (final day in days) widget.daily[day] ?? 0];
    final maximum = values.fold<int>(1, math.max);
    final selected = (_selected ?? count - 1).clamp(0, count - 1);
    final color = Theme.of(context).colorScheme.primary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('${days[selected]} · ${statisticsDuration(values[selected])}'),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, box) => GestureDetector(
            onTapDown: (d) => setState(
              () => _selected = (d.localPosition.dx / box.maxWidth * count)
                  .floor()
                  .clamp(0, count - 1),
            ),
            onHorizontalDragUpdate: (d) => setState(
              () => _selected = (d.localPosition.dx / box.maxWidth * count)
                  .floor()
                  .clamp(0, count - 1),
            ),
            child: SizedBox(
              height: 126,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (var i = 0; i < count; i++)
                    Expanded(
                      child: Semantics(
                        label: '${days[i]} ${statisticsDuration(values[i])}',
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 2),
                          child: Container(
                            height: math.max(3, values[i] / maximum * 120),
                            decoration: BoxDecoration(
                              color: values[i] == 0
                                  ? Theme.of(
                                      context,
                                    ).colorScheme.surfaceContainerHighest
                                  : color.withValues(
                                      alpha: i == selected ? 1 : 0.55,
                                    ),
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(days.first.substring(5)),
            Text(days.last.substring(5)),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          context.l10n.text(
            '显示所选期间末尾$count天，点击查看每日时长',
            'Last $count days of the period. Tap for daily time.',
          ),
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
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
              _today == null ? '—' : statisticsDuration(_today!),
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            Text(context.l10n.text('今日阅读', 'Today')),
            const SizedBox(height: 8),
            Text(
              context.l10n.text(
                '本周 ${statisticsDuration(_week ?? 0)} · 阅读 $_days 天',
                'This week ${statisticsDuration(_week ?? 0)} · $_days reading days',
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
