import 'dart:math' as math;

enum ReadingStatus { notStarted, reading, finished }

String dayKey(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

class ReadingEvent {
  final String id, device, book;
  final int at;
  final String type;
  final Map<String, dynamic> data;
  const ReadingEvent(
    this.id,
    this.device,
    this.book,
    this.at,
    this.type,
    this.data,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'device': device,
    'book': book,
    'at': at,
    'kind': type == 'Clear' ? 'Clear' : {type: data},
  };
  factory ReadingEvent.fromJson(Map<String, dynamic> json) {
    final kind = json['kind'];
    final type = kind == 'Clear'
        ? 'Clear'
        : kind is Map && kind.length == 1
        ? kind.keys.single as String
        : '';
    final data = type == 'Clear'
        ? <String, dynamic>{}
        : kind is Map && kind[type] is Map
        ? Map<String, dynamic>.from(kind[type] as Map)
        : <String, dynamic>{};
    for (final key in ['id', 'device', 'book']) {
      if (json[key] is! String ||
          (json[key] as String).isEmpty ||
          (json[key] as String).length > 128) {
        throw const FormatException('Invalid statistics identity');
      }
    }
    final at = json['at'];
    if (at is! int || at < 0 || at > 8640000000000000) {
      throw const FormatException('Invalid timestamp');
    }
    switch (type) {
      case 'Reading':
        final start = data['start'], end = data['end'], offset = data['offset'];
        if (start is! int ||
            end is! int ||
            start < 0 ||
            end < start ||
            end > 8640000000000000 ||
            end - start > 60000 ||
            offset is! int ||
            offset.abs() > 86400 ||
            data['session'] is! String ||
            (data['session'] as String).length > 128) {
          throw const FormatException('Invalid reading interval');
        }
        for (final key in ['from', 'to']) {
          if (data[key] is! num || !(data[key] as num).isFinite) {
            throw const FormatException('Invalid progress');
          }
        }
      case 'Status':
        if (!['NotStarted', 'Reading', 'Finished'].contains(data['status'])) {
          throw const FormatException('Invalid status');
        }
        final date = data['finished'];
        if (date != null &&
            (date is! String ||
                DateTime.tryParse(date) == null ||
                dayKey(DateTime.parse(date)) != date)) {
          throw const FormatException('Invalid completion date');
        }
      case 'Metadata':
        if (data['title'] is! String ||
            data['authors'] is! String ||
            data['added'] is! int) {
          throw const FormatException('Invalid metadata');
        }
      case 'Clear':
        break;
      default:
        throw const FormatException('Unsupported statistics event');
    }
    return ReadingEvent(
      json['id'] as String,
      json['device'] as String,
      json['book'] as String,
      at,
      type,
      data,
    );
  }
}

class ReadingInterval {
  final int start, end, offset;
  const ReadingInterval(this.start, this.end, this.offset);
}

List<ReadingInterval> unionIntervals(Iterable<ReadingInterval> input) {
  final sorted = input.toList()
    ..sort((a, b) {
      var result = a.start.compareTo(b.start);
      if (result == 0) result = a.end.compareTo(b.end);
      return result == 0 ? a.offset.compareTo(b.offset) : result;
    });
  final result = <ReadingInterval>[];
  var covered = 0;
  for (final interval in sorted) {
    final start = math.max(covered, interval.start);
    if (interval.end > start) {
      result.add(ReadingInterval(start, interval.end, interval.offset));
    }
    covered = math.max(covered, interval.end);
  }
  return result;
}

int readingDuration(Iterable<ReadingInterval> input) => unionIntervals(
  input,
).fold(0, (sum, interval) => sum + interval.end - interval.start);

Map<String, int> dailyReading(Iterable<ReadingInterval> input) {
  final result = <String, int>{};
  for (final interval in unionIntervals(input)) {
    var start = interval.start;
    while (start < interval.end) {
      final shifted = start + interval.offset * 1000;
      final date = DateTime.fromMillisecondsSinceEpoch(shifted, isUtc: true);
      final midnight =
          DateTime.utc(
            date.year,
            date.month,
            date.day + 1,
          ).millisecondsSinceEpoch -
          interval.offset * 1000;
      final end = math.min(midnight, interval.end);
      final key = dayKey(date);
      result[key] = (result[key] ?? 0) + end - start;
      start = end;
    }
  }
  return result;
}

class BookReadingStats {
  final String id;
  String title = '', authors = '';
  int added = 0;
  int? started, last;
  ReadingStatus status = ReadingStatus.notStarted;
  String? finished;
  double progress = 0;
  final intervals = <ReadingInterval>[];
  final validIntervals = <ReadingInterval>[];
  final sessions = <String, List<ReadingInterval>>{};
  BookReadingStats(this.id);
  int get duration => readingDuration(intervals);
  int get readingDays => dailyReading(validIntervals).length;
}

Map<String, BookReadingStats> aggregateStatistics(
  Iterable<ReadingEvent> source,
) {
  final unique = {for (final event in source) event.id: event};
  final events = unique.values.toList()
    ..sort((a, b) {
      final order = a.at.compareTo(b.at);
      return order == 0 ? a.id.compareTo(b.id) : order;
    });
  final clears = <String, int>{};
  for (var i = 0; i < events.length; i++) {
    if (events[i].type == 'Clear') clears[events[i].book] = i;
  }
  final visible = <ReadingEvent>[
    for (var i = 0; i < events.length; i++)
      if (events[i].type == 'Metadata' || i > (clears[events[i].book] ?? -1))
        events[i],
  ];
  final sessions = <String, int>{};
  for (final e in visible.where((e) => e.type == 'Reading')) {
    final key = '${e.book}/${e.data['session']}';
    sessions[key] =
        (sessions[key] ?? 0) +
        (e.data['end'] as int) -
        (e.data['start'] as int);
  }
  final result = <String, BookReadingStats>{};
  for (final e in visible) {
    final book = result.putIfAbsent(e.book, () => BookReadingStats(e.book));
    final d = e.data;
    switch (e.type) {
      case 'Metadata':
        book.title = d['title'] as String;
        book.authors = d['authors'] as String;
        final added = d['added'] as int;
        if (book.added == 0 || added < book.added) book.added = added;
      case 'Status':
        book.status = switch (d['status']) {
          'Finished' => ReadingStatus.finished,
          'Reading' => ReadingStatus.reading,
          _ => ReadingStatus.notStarted,
        };
        book.finished = d['finished'] as String?;
      case 'Reading':
        final interval = ReadingInterval(
          d['start'] as int,
          d['end'] as int,
          d['offset'] as int,
        );
        book.intervals.add(interval);
        book.sessions
            .putIfAbsent(d['session'] as String, () => [])
            .add(interval);
        book.progress = (d['to'] as num).toDouble().clamp(0, 1);
        if ((sessions['${e.book}/${d['session']}'] ?? 0) >= 30000) {
          book.validIntervals.add(interval);
          book.started = math.min(
            book.started ?? interval.start,
            interval.start,
          );
          book.last = math.max(book.last ?? interval.end, interval.end);
          if (book.status == ReadingStatus.notStarted) {
            book.status = ReadingStatus.reading;
          }
        }
    }
  }
  return result;
}
