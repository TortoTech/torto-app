import 'package:uuid/uuid.dart';

/// Monotonic time controls duration; wall time and offset only allocate dates.
/// There is deliberately no user-facing timer or pause button.
class ReadingTracker {
  static const int _idleMs = 300000;
  final void Function(Map<String, dynamic> data) write;
  String _session = const Uuid().v4();
  int? _last;
  int _activity = 0, _pending = 0, _start = 0, _offset = 0;
  double _from = 0, _progress = 0;
  bool _active = false;
  ReadingTracker(this.write);
  void tick({
    required int monotonicMs,
    required int wallMs,
    required int offsetSeconds,
    required bool eligible,
    required bool activity,
    required double progress,
  }) {
    final last = _last ?? monotonicMs;
    final elapsed = monotonicMs - last;
    if (_last == null) _activity = monotonicMs;
    if (_active && eligible && elapsed >= 0 && elapsed <= 5000) {
      final remaining = (_idleMs - (last - _activity)).clamp(0, _idleMs);
      final amount = elapsed.clamp(0, remaining);
      if (_pending == 0) {
        _start = wallMs - amount;
        _offset = offsetSeconds;
        _from = _progress;
      }
      _pending += amount;
    }
    if (activity) _activity = monotonicMs;
    final active = eligible && monotonicMs - _activity < _idleMs;
    _progress = progress.clamp(0, 1);
    if (_pending >= 15000 || !active || elapsed > 5000) flush();
    if (_active && (!active || elapsed > 5000)) _session = const Uuid().v4();
    _active = active;
    _last = monotonicMs;
  }

  void flush() {
    if (_pending == 0) return;
    write({
      'session': _session,
      'start': _start,
      'end': _start + _pending,
      'offset': _offset,
      'from': _from,
      'to': _progress,
    });
    _pending = 0;
  }
}
