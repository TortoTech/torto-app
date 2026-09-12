import 'dart:async';
import 'dart:io';
import 'dart:ui' show FrameTiming;
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/ir/text_index.dart';
import '../sync/sync_models.dart';
import 'text_selection_layer.dart';
import 'book_search_page.dart';
import '../statistics/reading_tracker.dart';
import '../statistics/statistics_store.dart';
import '../statistics/statistics_model.dart';
import '../settings/reading_settings_page.dart';
import 'system_reader_fonts.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/ir/style.dart' show LinkRole;
import '../../core/layout/layout_types.dart';
import '../../core/render/page_painter.dart';
import '../../l10n/app_localizations.dart';
import '../settings/ai_providers_page.dart';
import '../settings/app_preferences.dart';
import 'footnote_sheet.dart';
import 'reader_controller.dart';
import 'reader_preferences_store.dart';
import 'toc_drawer.dart';
import 'toc_items.dart';

/// Full-screen reading view: tap zones / swipe to turn pages, center tap
/// toggles minimal navigation controls (back on top, contents on the bottom).
class ReaderPage extends StatefulWidget {
  final File file;

  /// Injectable for tests; a fresh controller is created when omitted.
  final ReaderController? controller;
  final ReaderPreferencesStore? preferencesStore;
  final ReadingStatisticsStore? statisticsStore;
  final Stopwatch? openingStopwatch;

  const ReaderPage({
    super.key,
    required this.file,
    this.controller,
    this.preferencesStore,
    this.statisticsStore,
    this.openingStopwatch,
  });

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

enum _TurnPhase { idle, dragging, animating }

enum _TurnDirection { previous, next }

class _ReaderPageState extends State<ReaderPage>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  final _selectionKey = GlobalKey<ReaderSelectionLayerState>();
  bool _selecting = false;
  bool _showBookEnd = false;
  double _readerWidth = 0;
  bool _completionSaving = false;
  bool _completionMarked = false;
  bool _completionStatusLoading = false;

  Future<void> _refreshCompletionStatus() async {
    final id = _controller?.statisticsBookId ?? '';
    if (id.isEmpty || _completionStatusLoading) return;
    setState(() => _completionStatusLoading = true);
    try {
      final store =
          widget.statisticsStore ?? await ReadingStatisticsStore.instance();
      final known = aggregateStatistics(await store.events());
      if (mounted) {
        setState(
          () => _completionMarked = known[id]?.status == ReadingStatus.finished,
        );
      }
    } catch (error) {
      debugPrint('Could not read completion state: $error');
    } finally {
      if (mounted) setState(() => _completionStatusLoading = false);
    }
  }

  void _openBookEnd() {
    if (!mounted) return;
    setState(() {
      _showBookEnd = true;
      _overlayVisible = false;
    });
    _tickStatistics();
    unawaited(_refreshCompletionStatus());
  }

  Future<void> _nextPageOrEnd(ReaderController controller) async {
    if (!controller.canPeek(1)) {
      _openBookEnd();
      return;
    }
    final before = (controller.sectionIndex, controller.pageIndex);
    await controller.nextPage();
    if (before == (controller.sectionIndex, controller.pageIndex) &&
        !controller.canPeek(1)) {
      if (_turnPhase == _TurnPhase.idle && _readerWidth > 0 && mounted) {
        _animateBoundaryTap(controller, _readerWidth, _TurnDirection.next);
      } else {
        _openBookEnd();
      }
    }
    _schedulePeekPreparation();
  }

  ReaderSelectionMode _selectionMode = ReaderSelectionMode.free;
  PageLayout? _interactionPage;
  List<BookTextNode> _interactionNodes = [];
  List<ReaderPaintMark> _marks = [];
  BookSearchChoice? _searchChoice;
  int _searchIndex = 0;
  Future<void> _loadInteraction(PageLayout page) async {
    try {
      final controller = _controller!;
      if (controller.statisticsBookId.isEmpty) return;
      final nodes = await controller.textNodes(
        controller.sectionIndex,
        displayed: true,
      );
      final visibleIds =
          page.items.whereType<TextPlacement>().map((t) => t.nodeId).toSet()
            ..addAll(
              page.items.whereType<TableCellPlacement>().map((t) => t.nodeId),
            );
      final marks = <ReaderPaintMark>[];
      if (!mounted || _interactionPage != page) return;
      setState(
        () => _interactionNodes = nodes
            .where((n) => visibleIds.contains(n.displayId))
            .toList(),
      );
      {
        await controller.loadAnnotations();
        for (final annotation in controller.annotations) {
          if (!mounted || _interactionPage != page) return;
          final ranges = await controller.resolveAnnotation(annotation);
          if (ranges != null) {
            for (final range in ranges) {
              marks.add(
                ReaderPaintMark(range, const Color(0x55E4B948), annotation.id),
              );
            }
          }
        }
      }
      if (_searchChoice != null) {
        marks.add(
          ReaderPaintMark(
            _searchChoice!.matches[_searchIndex].range,
            const Color(0x7791BDF5),
          ),
        );
      }
      if (!mounted || _interactionPage != page) return;
      setState(() {
        _interactionNodes = nodes
            .where((n) => visibleIds.contains(n.displayId))
            .toList();
        _marks = marks;
      });
    } catch (error) {
      debugPrint('Could not load text interactions: $error');
    }
  }

  Future<void> _chooseSelectionMode() async {
    if (_controller?.translationEnabled == true) return;
    final mode = await showModalBottomSheet<ReaderSelectionMode>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final entry in {
              ReaderSelectionMode.free: context.l10n.text('自由', 'Free'),
              ReaderSelectionMode.word: context.l10n.text('单词', 'Word'),
              ReaderSelectionMode.sentence: context.l10n.text('句子', 'Sentence'),
              ReaderSelectionMode.paragraph: context.l10n.text(
                '段落',
                'Paragraph',
              ),
            }.entries)
              ListTile(
                title: Text(entry.value),
                selected: entry.key == _selectionMode,
                trailing: entry.key == _selectionMode
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => Navigator.pop(context, entry.key),
              ),
          ],
        ),
      ),
    );
    if (mode == null || !mounted) return;
    setState(() => _selectionMode = mode);
    await (await SharedPreferences.getInstance()).setString(
      'reader_selection_mode',
      mode.name,
    );
  }

  Future<void> _searchBook() async {
    final choice = await Navigator.push<BookSearchChoice>(
      context,
      MaterialPageRoute(builder: (_) => BookSearchPage(file: widget.file)),
    );
    if (!mounted || choice == null || choice.matches.isEmpty) return;
    _searchChoice = choice;
    _searchIndex = choice.index;
    await _jumpSearch();
  }

  Future<void> _jumpSearch() async {
    final result = _searchChoice!.matches[_searchIndex];
    await _controller!.goToTextRange(result.range);
    if (mounted) {
      setState(() {
        _interactionPage = null;
        _overlayVisible = false;
      });
    }
  }

  Future<void> _saveSelection(
    ReaderSelection selection,
    bool withNote, {
    AnnotationState? existing,
  }) async {
    if (existing == null && _controller?.translationEnabled == true) {
      try {
        final (ranges, quote) = await _controller!.originalParagraphSelection(
          selection.ranges,
        );
        if (!mounted) return;
        selection = ReaderSelection(ranges, quote);
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                context.l10n.text(
                  '无法定位对应原文段落',
                  'Could not locate the original paragraph',
                ),
              ),
            ),
          );
        }
        return;
      }
    }
    String? note = existing?.note;
    if (withNote) {
      final editor = TextEditingController(text: note);
      note = await showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        builder: (context) => SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              20,
              20,
              MediaQuery.viewInsetsOf(context).bottom + 20,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  selection.quote,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: editor,
                  autofocus: true,
                  minLines: 3,
                  maxLines: 6,
                  decoration: InputDecoration(
                    hintText: context.l10n.text('写下批注', 'Write a note'),
                  ),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, editor.text),
                  child: Text(context.l10n.text('保存', 'Save')),
                ),
              ],
            ),
          ),
        ),
      );
      // The closing route may still be animating with its TextField attached.
      Future<void>.delayed(const Duration(milliseconds: 400), editor.dispose);
      if (note == null) return;
    }
    try {
      await _controller!.saveAnnotation(
        selection.ranges,
        selection.quote,
        note: note,
        previous: existing,
      );
      _selectionKey.currentState?.clear();
      if (mounted) setState(() => _interactionPage = null);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.l10n.text(
                '无法保存此处标记，请重试',
                'Could not save this mark. Try again.',
              ),
            ),
          ),
        );
      }
    }
  }

  Future<void> _annotationActions(String id) async {
    final annotation = _controller!.annotations.firstWhere((a) => a.id == id);
    final action = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(annotation.quote),
                if (annotation.note != null)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(annotation.note!),
                  ),
                ListTile(
                  title: Text(context.l10n.text('编辑批注', 'Edit note')),
                  onTap: () => Navigator.pop(context, 'edit'),
                ),
                ListTile(
                  title: Text(context.l10n.text('删除标记', 'Delete mark')),
                  onTap: () => Navigator.pop(context, 'delete'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'edit') {
      await _saveSelection(
        ReaderSelection(const [], annotation.quote),
        true,
        existing: annotation,
      );
    }
    if (action == 'delete') {
      try {
        await _controller!.saveAnnotation(
          const [],
          annotation.quote,
          previous: annotation,
          delete: true,
        );
        if (mounted) setState(() => _interactionPage = null);
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                context.l10n.text('删除失败，请重试', 'Could not delete. Try again.'),
              ),
            ),
          );
        }
      }
    }
  }

  Future<void> _showAnnotations() async {
    try {
      await _controller!.loadAnnotations();
    } catch (_) {
      return;
    }
    if (!mounted) return;
    final annotations = List<AnnotationState>.of(_controller!.annotations);
    final selected = await showModalBottomSheet<AnnotationState>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .75,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(context.l10n.text('高亮与批注', 'Highlights and notes')),
              ),
              if (annotations.isEmpty)
                Text(
                  context.l10n.text(
                    '长按正文添加高亮或批注',
                    'Long-press text to add highlights or notes',
                  ),
                ),
              Expanded(
                child: ListView.builder(
                  itemCount: annotations.length,
                  itemBuilder: (context, i) {
                    final annotation = annotations[i];
                    return ListTile(
                      title: Text(
                        annotation.quote,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: annotation.note == null
                          ? null
                          : Text(annotation.note!, maxLines: 2),
                      trailing: annotation.conflictOf == null
                          ? null
                          : const Icon(Icons.merge_type),
                      onTap: () => Navigator.pop(context, annotation),
                      onLongPress: () {
                        Navigator.pop(context);
                        _annotationActions(annotation.id);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (selected == null) return;
    final ranges = await _controller!.resolveAnnotation(selected);
    if (!mounted) return;
    if (ranges == null || ranges.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.l10n.text('此标记暂无法定位', 'This mark cannot be located yet'),
          ),
        ),
      );
      await _annotationActions(selected.id);
    } else {
      await _controller!.goToTextRange(ranges.first);
      if (mounted) {
        setState(() {
          _interactionPage = null;
          _overlayVisible = false;
        });
      }
    }
  }

  ReadingTracker? _readingTracker;
  Timer? _statisticsTimer;
  final Stopwatch _statisticsClock = Stopwatch();
  bool _statisticsForeground = true;
  bool _statisticsFootnote = false;
  bool _statisticsDrawer = false;
  final List<Map<String, dynamic>> _statisticsPending = [];
  bool _statisticsWriting = false;
  ReadingStatisticsStore? _statisticsStore;
  String _statisticsBookId = '';

  Future<void> _startStatistics(ReaderController controller) async {
    if (controller.statisticsBookId.isEmpty || _readingTracker != null) return;
    try {
      final store =
          widget.statisticsStore ?? await ReadingStatisticsStore.instance();
      if (!mounted) return;
      _statisticsStore = store;
      _statisticsBookId = controller.statisticsBookId;
      final metadata = controller.statisticsMetadata!;
      final known = aggregateStatistics(await store.events());
      if (mounted) {
        setState(
          () => _completionMarked =
              known[_statisticsBookId]?.status == ReadingStatus.finished,
        );
      }
      if (!known.containsKey(_statisticsBookId)) {
        await store.record(_statisticsBookId, 'Metadata', {
          'title': metadata.title,
          'authors': metadata.authors.join(', '),
          'added': 0,
        });
      }
      if (!mounted) return;
      _statisticsClock.start();
      _readingTracker = ReadingTracker((data) {
        _statisticsPending.add(data);
        unawaited(_writeStatistics());
      });
      _tickStatistics(activity: true);
      _statisticsTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => _tickStatistics(),
      );
    } catch (error) {
      debugPrint('Could not start reading statistics: $error');
    }
  }

  Future<void> _writeStatistics() async {
    if (_statisticsWriting || _statisticsStore == null) return;
    _statisticsWriting = true;
    try {
      while (_statisticsPending.isNotEmpty) {
        await _statisticsStore!.record(
          _statisticsBookId,
          'Reading',
          _statisticsPending.first,
        );
        _statisticsPending.removeAt(0);
      }
    } catch (error) {
      debugPrint('Could not save reading statistics: $error');
    } finally {
      _statisticsWriting = false;
    }
  }

  void _tickStatistics({bool activity = false, bool closing = false}) {
    final now = DateTime.now();
    final controller = _controller;
    _readingTracker?.tick(
      monotonicMs: _statisticsClock.elapsedMilliseconds,
      wallMs: now.millisecondsSinceEpoch,
      offsetSeconds: now.timeZoneOffset.inSeconds,
      eligible:
          !closing &&
          mounted &&
          !_showBookEnd &&
          _statisticsForeground &&
          !_statisticsDrawer &&
          (ModalRoute.of(context)?.isCurrent == true || _statisticsFootnote) &&
          controller?.currentPage != null &&
          controller?.busy == false,
      activity: activity,
      progress: controller?.totalProgression ?? 0,
    );
    if (_statisticsPending.isNotEmpty) unawaited(_writeStatistics());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _statisticsForeground = state == AppLifecycleState.resumed;
    _tickStatistics(activity: _statisticsForeground);
  }

  Future<void> _markFinished() async {
    if (_completionSaving || _completionMarked) return;
    final id = _controller?.statisticsBookId ?? '';
    if (id.isEmpty) return;
    setState(() => _completionSaving = true);
    _readingTracker?.flush();
    try {
      final store =
          widget.statisticsStore ?? await ReadingStatisticsStore.instance();
      await _writeStatistics();
      await store.setStatus(id, ReadingStatus.finished, dayKey(DateTime.now()));
      if (mounted) {
        setState(() => _completionMarked = true);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.l10n.text('已标记为读完', 'Marked as finished')),
          ),
        );
      }
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
      if (mounted) setState(() => _completionSaving = false);
    }
  }

  static const ReaderStyle _baseStyle = ReaderStyle(
    baseFontSize: 20,
    lineHeight: 1.5,
    marginTop: 32,
    marginBottom: 32,
    marginLeft: 24,
    marginRight: 24,
  );
  static const _lightBackground = Color(0xFFFAF8F3);
  static const _lightForeground = Color(0xFF000000);
  static const _darkBackground = Color(0xFF000000);
  static const _darkForeground = Color(0xFF959595);
  static const _darkChromeBackground = Color(0xFF1C1C1C);
  static const _darkChromeForeground = Color(0xFFB4B4B6);

  ReaderController? _controller;
  late final ReaderPreferencesStore _preferencesStore;
  ReaderStyle _style = _baseStyle;
  bool _ownsController = false;
  bool _opening = false;
  bool _overlayVisible = false;
  bool _darkMode = false;
  bool _initialThemeSeeded = false;
  Brightness? _inheritedAppBrightness;
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  Color get _background => Color(_style.background);
  Color get _foreground => Color(_style.foreground);
  Color get _chromeBackground =>
      _darkMode ? _darkChromeBackground : _background;
  Color get _chromeForeground =>
      _darkMode ? _darkChromeForeground : _foreground;

  _TurnPhase _turnPhase = _TurnPhase.idle;
  _TurnDirection? _turnDirection;
  bool _turnFromBookEnd = false;
  bool _turnToBookEnd = false;

  /// Finger travel and its rendered counterpart. Keeping these separate
  /// avoids repeatedly damping an already-damped value at book boundaries.
  double _dragExtent = 0;
  double _visualOffset = 0;

  AnimationController? _turnAnimation;
  double _animationFrom = 0;
  double _animationTo = 0;
  bool _animationCommits = false;

  /// Suppresses the late peek-preparation while gestures/animations are
  /// interacting with the model.
  Timer? _peekTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addTimingsCallback(_logSlowReaderFrames);
    SharedPreferences.getInstance().then((prefs) {
      if (mounted) {
        setState(
          () => _selectionMode = ReaderSelectionMode.values.firstWhere(
            (m) => m.name == prefs.getString('reader_selection_mode'),
            orElse: () => ReaderSelectionMode.free,
          ),
        );
      }
    });
    WidgetsBinding.instance.addObserver(this);
    _statisticsForeground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _preferencesStore = widget.preferencesStore ?? ReaderPreferencesStore();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final brightness = Theme.of(context).brightness;
    final inheritsAppTheme = AppPreferencesScope.maybeOf(context) != null;
    if (!_initialThemeSeeded ||
        (inheritsAppTheme && brightness != _inheritedAppBrightness)) {
      final darkMode = brightness == Brightness.dark;
      _darkMode = darkMode;
      _style = _themedStyle(_style, darkMode);
      _initialThemeSeeded = true;
    }
    _inheritedAppBrightness = inheritsAppTheme ? brightness : null;
  }

  void _startOpen(LayoutViewport viewport) {
    final controller = widget.controller ?? ReaderController();
    _controller = controller;
    _ownsController = widget.controller == null;
    controller.setReaderVisible(true);
    if (controller.opened) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final firstFrameMs = widget.openingStopwatch?.elapsedMilliseconds;
        final restoreWatch = Stopwatch()..start();
        // An injected, already-open controller can render immediately while
        // the persisted presentation preferences are being restored.
        if (mounted) setState(() {});
        await _restorePreferences();
        if (!mounted) return;
        _style = _style.copyWith(
          writingSystem: controller.style.writingSystem,
          publicationLanguage: controller.style.publicationLanguage,
        );
        _applySystemUiStyle();
        await controller.updateStyle(_style);
        await controller.restoreSavedPosition();
        unawaited(_startStatistics(controller));
        if (!mounted) return;
        setState(() {});
        _schedulePeekPreparation();
        debugPrint(
          'TortoReader warm_open first_frame_ms=$firstFrameMs restore_ms=${restoreWatch.elapsedMilliseconds}',
        );
      });
      return;
    }
    if (_opening) return;
    _opening = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final openingWatch = Stopwatch()..start();
        await _restorePreferences();
        final preferencesMilliseconds = openingWatch.elapsedMilliseconds;
        if (!mounted) return;
        _applySystemUiStyle();
        await controller.open(widget.file, viewport, _style);
        _style = controller.style;
        // open() may finish before the ListenableBuilder below ever
        // entered the tree (the first build returns the plain spinner),
        // so its notifyListeners() reached no one. Rebuild to swap in
        // the real reader now that a controller exists.
        if (mounted) setState(() {});
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          debugPrint(
            'TortoReader first_page preferences_ms=$preferencesMilliseconds elapsed_ms=${openingWatch.elapsedMilliseconds}',
          );
          unawaited(_startStatistics(controller));
          _schedulePeekPreparation();
        });
      } catch (error, stackTrace) {
        debugPrint('Could not open ${widget.file.path}: $error\n$stackTrace');
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.l10n.text('无法打开这本书。', 'Could not open this book.'),
            ),
          ),
        );
        Navigator.of(context).pop();
      } finally {
        _opening = false;
      }
    });
  }

  Future<void> _restorePreferences() async {
    final appPreferences = AppPreferencesScope.maybeOf(context);
    final inheritedDarkMode = Theme.of(context).brightness == Brightness.dark;
    final modeFuture = _preferencesStore.loadTypesettingMode();
    final typographyFuture = _preferencesStore.loadTypography();
    final mode = await modeFuture;
    final typography = await typographyFuture;
    await SystemReaderFonts.instance.load([
      typography.cjkPrimaryFont.family,
      typography.otherPrimaryFont.family,
      if (typography.cjkLatinFont != null) typography.cjkLatinFont!.family,
      if (typography.otherCjkFont != null) typography.otherCjkFont!.family,
    ]);
    final darkMode = appPreferences == null
        ? await _preferencesStore.loadDarkMode()
        : inheritedDarkMode;
    _darkMode = darkMode;
    _style = _themedStyle(
      _baseStyle.copyWith(
        baseFontSize: typography.fontSize,
        typesettingMode: mode,
        typography: typography,
      ),
      darkMode,
    );
  }

  static ReaderStyle _themedStyle(ReaderStyle style, bool darkMode) =>
      style.copyWith(
        foreground: darkMode
            ? _darkForeground.toARGB32()
            : _lightForeground.toARGB32(),
        background: darkMode
            ? _darkBackground.toARGB32()
            : _lightBackground.toARGB32(),
      );

  @override
  void dispose() {
    WidgetsBinding.instance.removeTimingsCallback(_logSlowReaderFrames);
    _tickStatistics(closing: true);
    _readingTracker?.flush();
    _statisticsTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _peekTimer?.cancel();
    _turnAnimation?.dispose();
    if (_ownsController) {
      _controller?.dispose();
    } else {
      _controller?.setReaderVisible(false);
    }
    SystemChrome.setSystemUIOverlayStyle(_systemUiStyle(darkMode: false));
    super.dispose();
  }

  void _logSlowReaderFrames(List<FrameTiming> timings) {
    if (_controller == null) return;
    for (final timing in timings) {
      if (timing.buildDuration.inMilliseconds >= 32 ||
          timing.rasterDuration.inMilliseconds >= 32) {
        debugPrint(
          'TortoReader slow_frame build_ms=${timing.buildDuration.inMilliseconds} raster_ms=${timing.rasterDuration.inMilliseconds} turn=${_turnPhase.name} opening=${_controller?.opened != true} translated=${_controller?.translationEnabled}',
        );
      }
    }
  }

  /// Schedules adjacent-section pagination for the next event-loop turn, so
  /// the newly revealed page paints first but rapid consecutive turns do not
  /// wait behind an arbitrary idle delay.
  void _schedulePeekPreparation() {
    _peekTimer?.cancel();
    _peekTimer = Timer(Duration.zero, () {
      final preparation = _controller?.ensurePeek();
      if (preparation != null) {
        unawaited(preparation.catchError((Object _, StackTrace _) {}));
      }
    });
  }

  void _handleTap(TapUpDetails details, double width) {
    if (_selecting) {
      _selectionKey.currentState?.clear();
      return;
    }
    final mark = _selectionKey.currentState?.markAt(details.localPosition);
    if (mark != null) {
      _annotationActions(mark);
      return;
    }
    final controller = _controller;
    if (controller == null ||
        !controller.opened ||
        controller.busy ||
        _turnPhase != _TurnPhase.idle) {
      return;
    }
    final fraction = details.localPosition.dx / width;
    if (_showBookEnd) {
      if (fraction < .2) {
        _animateBoundaryTap(controller, width, _TurnDirection.previous);
      }
      return;
    }
    final link = controller.currentPage?.linkAt(details.localPosition);
    if (link != null) {
      unawaited(_activateLink(controller, link));
      return;
    }
    if (fraction < 0.2) {
      if (_overlayVisible) setState(() => _overlayVisible = false);
      controller.prevPage().then((_) => _schedulePeekPreparation());
    } else if (fraction > 0.8) {
      if (_overlayVisible) setState(() => _overlayVisible = false);
      if (!controller.canPeek(1)) {
        _animateBoundaryTap(controller, width, _TurnDirection.next);
      } else {
        _nextPageOrEnd(controller);
      }
    } else {
      setState(() => _overlayVisible = !_overlayVisible);
    }
  }

  Future<void> _activateLink(
    ReaderController controller,
    TextLinkRange link,
  ) async {
    if (_overlayVisible && mounted) {
      setState(() => _overlayVisible = false);
    }
    if (link.footnoteIcon || link.role == LinkRole.footnoteReference) {
      final inlineNote = link.inlineNote;
      final note = inlineNote == null
          ? await controller.resolveFootnote(link)
          : ReaderFootnote(marker: '', text: inlineNote);
      if (!mounted) return;
      if (note == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.l10n.text('无法读取脚注内容', 'Could not read this footnote'),
            ),
          ),
        );
        return;
      }
      _statisticsFootnote = true;
      try {
        await showReaderFootnoteSheet(
          context,
          text: note.text,
          background: _chromeBackground,
          foreground: _chromeForeground,
          publicationLanguage: controller.publicationLanguage,
          writingSystem: controller.style.writingSystem,
          typography: controller.style.typography,
        );
      } finally {
        _statisticsFootnote = false;
        if (mounted) _tickStatistics(activity: true);
      }
      return;
    }

    final navigated = await controller.goToHref(link.href);
    if (!mounted) return;
    if (navigated) {
      _schedulePeekPreparation();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.l10n.text('暂时无法打开此引用', 'Could not open this reference'),
          ),
        ),
      );
    }
  }

  // ---- Drag-driven page turning -------------------------------------------

  void _animateBoundaryTap(
    ReaderController controller,
    double width,
    _TurnDirection direction,
  ) {
    _onDragStart(DragStartDetails(), controller);
    if (_turnPhase != _TurnPhase.dragging) return;
    _turnDirection = direction;
    _turnToBookEnd =
        !_turnFromBookEnd &&
        direction == _TurnDirection.next &&
        !controller.canPeek(1);
    _animateTurn(true, controller, width);
  }

  bool _turnHasTarget(ReaderController controller) {
    if (_turnFromBookEnd) return _turnDirection == _TurnDirection.previous;
    if (_turnToBookEnd) return controller.currentPage != null;
    return controller.canPeek(_turnDirection == _TurnDirection.next ? 1 : -1);
  }

  void _onDragStart(DragStartDetails _, ReaderController controller) {
    if (_selecting || !controller.opened) return;
    final continuingRapidTurn = _turnPhase == _TurnPhase.animating;
    if (continuingRapidTurn) {
      // Complete the stable endpoint first, then let this pointer sequence
      // immediately control the following page. Ignoring it made fast
      // readers perceive every other swipe as lost.
      _finishTurn(controller);
    }
    if (controller.busy || _turnPhase != _TurnPhase.idle) {
      return;
    }
    _peekTimer?.cancel();
    setState(() {
      _turnPhase = _TurnPhase.dragging;
      controller.setPageTurnActive(true);
      _turnFromBookEnd = _showBookEnd;
      _turnToBookEnd = false;
      _turnDirection = null;
      _dragExtent = 0;
      _visualOffset = 0;
      _overlayVisible = false;
    });
  }

  void _onDragUpdate(
    DragUpdateDetails details,
    ReaderController controller,
    double width,
  ) {
    if (_turnPhase != _TurnPhase.dragging) return;
    final delta = details.delta.dx;
    if (_turnDirection == null && delta != 0) {
      _turnDirection = delta > 0
          ? _TurnDirection.previous
          : _TurnDirection.next;
      _turnToBookEnd =
          !_turnFromBookEnd &&
          _turnDirection == _TurnDirection.next &&
          !controller.canPeek(1);
    }
    final direction = _turnDirection;
    if (direction == null) return;

    var extent = (_dragExtent + delta).clamp(-width, width).toDouble();
    // Reversing can settle to zero, but cannot swap the neighbour page in
    // the middle of one pointer sequence.
    extent = direction == _TurnDirection.next
        ? extent.clamp(-width, 0).toDouble()
        : extent.clamp(0, width).toDouble();

    final pageOffset = direction == _TurnDirection.next ? 1 : -1;
    final targetReady =
        _turnToBookEnd ||
        (_turnFromBookEnd && direction == _TurnDirection.previous) ||
        (!_turnFromBookEnd && controller.peekPage(pageOffset) != null);
    final rendered = targetReady ? extent : _rubberBand(extent, width);
    if (extent == _dragExtent && rendered == _visualOffset) return;
    setState(() {
      _dragExtent = extent;
      _visualOffset = rendered;
    });
  }

  double _rubberBand(double extent, double width) {
    final distance = extent.abs();
    final linearLimit = (width * 0.18).clamp(48.0, 80.0);
    final maxTravel = width * 0.28;
    final rendered = distance <= linearLimit
        ? distance
        : linearLimit + (distance - linearLimit) * 0.18;
    return extent.sign * rendered.clamp(0.0, maxTravel);
  }

  void _onDragEnd(
    DragEndDetails details,
    ReaderController controller,
    double width,
  ) {
    if (_turnPhase != _TurnPhase.dragging) return;
    final direction = _turnDirection;
    if (direction == null) {
      _resetTurn();
      return;
    }
    final velocity = details.primaryVelocity ?? 0;
    final hasTarget = _turnHasTarget(controller);
    final expectedVelocitySign = direction == _TurnDirection.next ? -1.0 : 1.0;
    final fling = velocity.abs() > 350 && velocity.sign == expectedVelocitySign;
    final draggedFar = _dragExtent.abs() > width * 0.25;
    final reversingFling =
        velocity.abs() > 350 && velocity.sign != expectedVelocitySign;
    _animateTurn(
      hasTarget && !reversingFling && (fling || draggedFar),
      controller,
      width,
    );
  }

  void _onDragCancel(ReaderController controller, double width) {
    if (_turnPhase != _TurnPhase.dragging) return;
    _animateTurn(false, controller, width);
  }

  /// Animates to a stable endpoint. Model navigation happens only after a
  /// committed animation has visually reached that endpoint.
  void _animateTurn(bool commit, ReaderController controller, double width) {
    final direction = _turnDirection;
    if (_turnPhase != _TurnPhase.dragging || direction == null) {
      _resetTurn();
      return;
    }
    final from = _visualOffset;
    // Never animate the current page away to reveal a blank, unprepared
    // chapter. Settle it first and let navigation finish loading underneath.
    final previewReady =
        _turnToBookEnd ||
        (_turnFromBookEnd && direction == _TurnDirection.previous) ||
        (!_turnFromBookEnd &&
            controller.peekPage(direction == _TurnDirection.next ? 1 : -1) !=
                null);
    final to = commit && previewReady
        ? (direction == _TurnDirection.next ? -width : width)
        : 0.0;
    _animationCommits = commit;
    if (from == to) {
      if (commit) {
        _finishTurn(controller);
      } else {
        _resetTurn();
      }
      return;
    }

    _turnAnimation?.dispose();
    _animationFrom = from;
    _animationTo = to;
    _turnPhase = _TurnPhase.animating;
    _turnAnimation =
        AnimationController(
            vsync: this,
            duration: Duration(milliseconds: commit ? 140 : 150),
          )
          ..addListener(() {
            if (mounted) setState(() {});
          })
          ..addStatusListener((status) {
            if (status == AnimationStatus.completed) _finishTurn(controller);
          });
    setState(() {});
    _turnAnimation!.forward();
  }

  void _finishTurn(ReaderController controller) {
    final committed = _animationCommits;
    final direction = _turnDirection;
    final fromBookEnd = _turnFromBookEnd;
    final toBookEnd = _turnToBookEnd;
    final animation = _turnAnimation;
    _turnAnimation = null;
    animation?.dispose();

    // Reset before navigation notifies listeners, so the revealed page
    // becomes the stable current page without replaying a stale frame.
    _turnPhase = _TurnPhase.idle;
    _turnDirection = null;
    _dragExtent = 0;
    _visualOffset = 0;
    _animationFrom = 0;
    _animationTo = 0;
    _animationCommits = false;
    _turnFromBookEnd = _turnToBookEnd = false;

    if (!committed || direction == null) {
      controller.setPageTurnActive(false);
      if (mounted) setState(() {});
      _schedulePeekPreparation();
      return;
    }
    if (fromBookEnd || toBookEnd) {
      setState(() {
        _showBookEnd = toBookEnd;
        _overlayVisible = false;
      });
      controller.setPageTurnActive(false);
      _tickStatistics(activity: !toBookEnd);
      if (toBookEnd) unawaited(_refreshCompletionStatus());
      _schedulePeekPreparation();
      return;
    }
    final turn = direction == _TurnDirection.next
        ? _nextPageOrEnd(controller)
        : controller.prevPage();
    controller.setPageTurnActive(false);
    unawaited(
      turn.whenComplete(() {
        if (mounted) setState(() {});
        _schedulePeekPreparation();
      }),
    );
  }

  void _resetTurn() {
    _turnAnimation?.dispose();
    _turnAnimation = null;
    _controller?.setPageTurnActive(false);
    if (!mounted) return;
    setState(() {
      _turnPhase = _TurnPhase.idle;
      _turnDirection = null;
      _dragExtent = 0;
      _visualOffset = 0;
      _animationFrom = 0;
      _animationTo = 0;
      _animationCommits = false;
      _turnFromBookEnd = _turnToBookEnd = false;
    });
    _schedulePeekPreparation();
  }

  double _turnOffset() {
    final animation = _turnAnimation;
    if (_turnPhase != _TurnPhase.animating || animation == null) {
      return _visualOffset;
    }
    final curve = _animationCommits ? Curves.easeOutCubic : Curves.easeOut;
    final t = curve.transform(animation.value);
    return _animationFrom + (_animationTo - _animationFrom) * t;
  }

  /// Forward turns reveal the next page underneath. Backward turns bring
  /// the previous page in from the left above the current page.
  Widget _buildTurnScene(ReaderController controller, double width) {
    final offset = _turnOffset();
    final direction = _turnDirection!;
    final neighbour = controller.peekPage(
      direction == _TurnDirection.next ? 1 : -1,
    );
    final current = controller.currentPage;
    final imageResolver = controller.resolveImage;

    Widget page(PageLayout? layout) => layout == null
        ? ColoredBox(color: _background)
        : PageWidget(
            page: layout,
            imageResolver: imageResolver,
            background: _background,
            foreground: _foreground,
          );

    final currentWidget = _turnFromBookEnd
        ? IgnorePointer(child: _buildBookEndContent(controller))
        : page(current);
    final neighbourWidget = _turnToBookEnd
        ? IgnorePointer(child: _buildBookEndContent(controller))
        : _turnFromBookEnd && direction == _TurnDirection.previous
        ? page(current)
        : page(neighbour);

    Widget ridingPage(Widget content, double left) => Positioned(
      key: const Key('reader-turn-moving-page'),
      left: left,
      top: 0,
      bottom: 0,
      width: width,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          boxShadow: [
            BoxShadow(
              color: Colors.black26,
              blurRadius: 14,
              offset: Offset(4, 0),
            ),
          ],
        ),
        child: content,
      ),
    );

    if (direction == _TurnDirection.previous) {
      return Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          Positioned.fill(child: currentWidget),
          ridingPage(neighbourWidget, -width + offset),
        ],
      );
    }

    return Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        Positioned.fill(child: neighbourWidget),
        ridingPage(currentWidget, offset),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final background = _background;
    final foreground = _foreground;
    final systemOverlay = _systemUiStyle(darkMode: _darkMode);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: systemOverlay,
      child: Theme(
        data: _readerThemeData(Theme.of(context), background, foreground),
        child: PopScope(
          canPop: !_selecting && !_showBookEnd,
          onPopInvokedWithResult: (didPop, result) {
            if (!didPop && _selecting) _selectionKey.currentState?.clear();
            if (!didPop && _showBookEnd) {
              _resetTurn();
              setState(() => _showBookEnd = false);
              _tickStatistics(activity: true);
            }
          },
          child: Scaffold(
            onDrawerChanged: (open) {
              _statisticsDrawer = open;
              _tickStatistics(activity: !open);
            },
            key: _scaffoldKey,
            backgroundColor: background,
            drawer: _buildDrawer(),
            body: Stack(
              children: [
                Positioned.fill(
                  child: SafeArea(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        var controller = _controller;
                        if (controller == null) {
                          _startOpen(
                            LayoutViewport(
                              width: constraints.maxWidth,
                              height: constraints.maxHeight,
                            ),
                          );
                          controller = _controller;
                          if (controller?.opened != true) {
                            return const Center(
                              child: CircularProgressIndicator(),
                            );
                          }
                        }
                        return ListenableBuilder(
                          listenable: controller!,
                          builder: (context, _) =>
                              _buildReader(controller!, constraints),
                        );
                      },
                    ),
                  ),
                ),
                if (_overlayVisible) ...[
                  _buildReaderHeader(),
                  _buildReaderFooter(),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  static SystemUiOverlayStyle _systemUiStyle({required bool darkMode}) =>
      SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: darkMode ? Brightness.light : Brightness.dark,
        statusBarBrightness: darkMode ? Brightness.dark : Brightness.light,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarDividerColor: Colors.transparent,
        systemNavigationBarIconBrightness: darkMode
            ? Brightness.light
            : Brightness.dark,
        systemStatusBarContrastEnforced: false,
        systemNavigationBarContrastEnforced: false,
      );

  void _applySystemUiStyle() {
    SystemChrome.setSystemUIOverlayStyle(_systemUiStyle(darkMode: _darkMode));
  }

  ThemeData _readerThemeData(
    ThemeData base,
    Color background,
    Color foreground,
  ) {
    final brightness = _darkMode ? Brightness.dark : Brightness.light;
    final surface = _darkMode ? _darkChromeBackground : background;
    final onSurface = _darkMode ? _darkChromeForeground : foreground;
    final scheme =
        ColorScheme.fromSeed(
          seedColor: base.colorScheme.primary,
          brightness: brightness,
        ).copyWith(
          surface: surface,
          onSurface: onSurface,
          onSurfaceVariant: onSurface,
        );
    return base.copyWith(
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      canvasColor: background,
      iconTheme: base.iconTheme.copyWith(color: onSurface),
      textTheme: base.textTheme.apply(
        fontFamily: 'sans-serif',
        bodyColor: onSurface,
        displayColor: onSurface,
      ),
      bottomSheetTheme: base.bottomSheetTheme.copyWith(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
      ),
    );
  }

  Widget _buildReaderHeader() => Positioned(
    top: 0,
    left: 0,
    right: 0,
    child: Material(
      key: const Key('reader-header'),
      color: _chromeBackground,
      surfaceTintColor: Colors.transparent,
      elevation: 2,
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 56,
          child: Row(
            children: [
              IconButton(
                key: const Key('reader-back-button'),
                icon: Icon(Icons.arrow_back, color: _chromeForeground),
                tooltip: context.l10n.text('返回书架', 'Back to library'),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              const Spacer(),
              IconButton(
                onPressed: _searchBook,
                icon: Icon(Icons.search, color: _chromeForeground),
                tooltip: context.l10n.text('搜索', 'Search'),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _footerButton(
    String key,
    IconData icon,
    String label,
    VoidCallback? action,
  ) => IconButton(
    key: Key(key),
    iconSize: 32,
    constraints: BoxConstraints.tightFor(
      width: MediaQuery.sizeOf(context).width < 384 ? 48 : 64,
      height: 56,
    ),
    icon: Icon(icon, color: _chromeForeground),
    tooltip: label,
    onPressed: action,
  );

  Widget _buildReaderFooter() => Positioned(
    bottom: 0,
    left: 0,
    right: 0,
    child: Material(
      key: const Key('reader-footer'),
      color: _chromeBackground,
      surfaceTintColor: Colors.transparent,
      elevation: 2,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 56,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _footerButton(
                'reader-toc-button',
                Icons.format_list_bulleted,
                context.l10n.text('目录', 'Contents'),
                () => _scaffoldKey.currentState?.openDrawer(),
              ),
              _footerButton(
                'reader-marks-button',
                Icons.bookmarks_outlined,
                context.l10n.text('批注与高亮', 'Notes and highlights'),
                _showAnnotations,
              ),
              _buildTranslationButton(),
              _footerButton(
                'reader-selection-button',
                Icons.select_all,
                _controller?.translationEnabled == true
                    ? context.l10n.text(
                        '翻译模式固定按段落选择',
                        'Translation uses paragraph selection',
                      )
                    : context.l10n.text('文字选择模式', 'Text selection mode'),
                _controller?.translationEnabled == true
                    ? null
                    : _chooseSelectionMode,
              ),
              _footerButton(
                'reader-style-button',
                Icons.text_format,
                context.l10n.text('字体排版', 'Typography'),
                _showTypesettingSheet,
              ),
              _footerButton(
                'reader-theme-button',
                _darkMode
                    ? Icons.light_mode_outlined
                    : Icons.dark_mode_outlined,
                _darkMode
                    ? context.l10n.text('浅色模式', 'Light mode')
                    : context.l10n.text('深色模式', 'Dark mode'),
                _toggleColorMode,
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _buildTranslationButton() {
    final controller = _controller;
    if (controller == null) return const SizedBox(width: 64, height: 56);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final status = controller.translationStatus;
        final selected = controller.translationEnabled;
        final color = status == ReaderTranslationStatus.error
            ? Theme.of(context).colorScheme.error
            : selected
            ? const Color(0xFF60A5FA)
            : _chromeForeground;
        return IconButton(
          key: const Key('reader-translation-button'),
          iconSize: 32,
          constraints: const BoxConstraints.tightFor(width: 64, height: 56),
          icon: status == ReaderTranslationStatus.translating
              ? SizedBox.square(
                  dimension: 26,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: color,
                  ),
                )
              : Icon(Icons.translate, color: color),
          tooltip: selected
              ? context.l10n.text('关闭翻译', 'Turn translation off')
              : context.l10n.text('开启翻译', 'Turn translation on'),
          onPressed: controller.busy ? null : _toggleTranslation,
        );
      },
    );
  }

  Future<void> _toggleTranslation() async {
    final controller = _controller;
    if (controller == null) return;
    final changed = await controller.toggleTranslation();
    if (mounted && changed) setState(() => _interactionPage = null);
    if (!mounted || changed || controller.translationError == null) return;
    final error = controller.translationError!;
    final localizedError = _localizedTranslationError(error);
    final needsConfiguration =
        error.contains('Configure') ||
        error.contains('Select an AI provider') ||
        error.contains('API Key');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(localizedError),
        action: needsConfiguration
            ? SnackBarAction(
                label: context.l10n.text('去配置', 'Configure'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const AiProvidersPage(),
                  ),
                ),
              )
            : null,
      ),
    );
  }

  String _localizedTranslationError(String error) {
    final l10n = context.l10n;
    if (error.contains('Fixed-layout PDF')) {
      return l10n.text(
        '当前版本暂不支持固定版式 PDF 翻译。',
        'Fixed-layout PDF translation is not supported in this version.',
      );
    }
    if (error.contains('AI provider URL')) {
      return l10n.text(
        '请先配置 AI 提供商接口地址。',
        'Configure the AI provider URL first.',
      );
    }
    if (error.contains('API Key')) {
      return l10n.text(
        '请先配置 AI 提供商 API Key。',
        'Configure the AI provider API Key first.',
      );
    }
    if (error.contains('Select an AI provider')) {
      return l10n.text('请先选择 AI 提供商。', 'Select an AI provider first.');
    }
    if (error.contains('Select a translation model')) {
      return l10n.text('请先选择翻译模型。', 'Select a translation model first.');
    }
    return error;
  }

  Future<void> _toggleColorMode() async {
    final controller = _controller;
    if (controller == null || controller.busy) return;
    final nextDarkMode = !_darkMode;
    final nextStyle = _themedStyle(_style, nextDarkMode);
    setState(() {
      _darkMode = nextDarkMode;
      _style = nextStyle;
    });
    _applySystemUiStyle();
    unawaited(
      (AppPreferencesScope.maybeOf(context) == null
              ? _preferencesStore.saveDarkMode(nextDarkMode)
              : AppPreferencesScope.of(context).setTheme(
                  nextDarkMode
                      ? AppThemePreference.dark
                      : AppThemePreference.light,
                ))
          .catchError((Object error) {
            debugPrint('Could not persist reader color mode: $error');
          }),
    );
    await controller.updateStyle(nextStyle);
    _schedulePeekPreparation();
  }

  Future<void> _showTypesettingSheet() async {
    final controller = _controller;
    if (controller == null || controller.busy) return;
    final selected = await showModalBottomSheet<TypesettingMode>(
      context: context,
      backgroundColor: _chromeBackground,
      builder: (sheetContext) => Theme(
        data: _readerThemeData(Theme.of(context), _background, _foreground),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ListTile(
                  leading: const Icon(Icons.text_fields),
                  title: Text(context.l10n.text('字体与字号', 'Fonts and size')),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _openReadingSettings();
                  },
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    context.l10n.text('版式', 'Typesetting'),
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                _typesettingChoice(
                  sheetContext,
                  TypesettingMode.unified,
                  context.l10n.text('统一版式', 'Unified'),
                  context.l10n.text(
                    '统一正文、标题、段落、列表和表格的排版',
                    'Use consistent styling for body text, headings, lists and tables',
                  ),
                ),
                _typesettingChoice(
                  sheetContext,
                  TypesettingMode.book,
                  context.l10n.text('跟随书籍', 'Follow book'),
                  context.l10n.text(
                    '保留书籍自带的字号、行距、缩进和颜色',
                    'Keep the book’s font size, line height, indentation and colors',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (selected == null || selected == _style.typesettingMode) return;
    final nextStyle = _style.copyWith(typesettingMode: selected);
    setState(() {
      _style = nextStyle;
      _overlayVisible = false;
    });
    try {
      await _preferencesStore.saveTypesettingMode(selected);
    } catch (error) {
      debugPrint('Could not persist reader layout mode: $error');
    }
    await controller.updateStyle(nextStyle);
    _schedulePeekPreparation();
  }

  Future<void> _openReadingSettings() async {
    final controller = _controller;
    if (controller == null) return;
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ReadingSettingsPage(store: _preferencesStore),
      ),
    );
    if (saved != true || !mounted) return;
    final typography = await _preferencesStore.loadTypography();
    final mode = await _preferencesStore.loadTypesettingMode();
    if (!mounted) return;
    final next = controller.style.copyWith(
      typography: typography,
      baseFontSize: typography.fontSize,
      typesettingMode: mode,
    );
    setState(() {
      _style = next;
      _overlayVisible = false;
    });
    await controller.updateStyle(next);
    _schedulePeekPreparation();
  }

  Widget _typesettingChoice(
    BuildContext context,
    TypesettingMode mode,
    String title,
    String subtitle,
  ) => ListTile(
    key: Key('typesetting-${mode.name}'),
    title: Text(title),
    subtitle: Text(subtitle),
    selected: _style.typesettingMode == mode,
    trailing: _style.typesettingMode == mode
        ? const Icon(Icons.check_circle)
        : const Icon(Icons.circle_outlined),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    onTap: () => Navigator.of(context).pop(mode),
  );

  /// Left drawer with the book's table of contents; rebuilt with the
  /// controller so the active row follows page turns.
  Widget? _buildDrawer() {
    final controller = _controller;
    if (controller == null) return null;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final items = flattenToc(controller.toc);
        return TocDrawer(
          annotationsContent: controller.annotations.isEmpty
              ? Center(
                  child: Text(
                    context.l10n.text(
                      '长按正文添加标记',
                      'Long-press text to add marks',
                    ),
                  ),
                )
              : ListView(
                  children: [
                    for (final annotation in controller.annotations)
                      ListTile(
                        title: Text(
                          annotation.quote,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: annotation.note == null
                            ? null
                            : Text(annotation.note!, maxLines: 2),
                        trailing: annotation.conflictOf == null
                            ? null
                            : const Icon(Icons.merge_type),
                        onTap: () async {
                          Navigator.of(context).pop();
                          final ranges = await controller.resolveAnnotation(
                            annotation,
                          );
                          if (!mounted || !context.mounted) return;
                          if (ranges == null || ranges.isEmpty) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  context.l10n.text(
                                    '此标记暂无法定位',
                                    'This mark cannot be located yet',
                                  ),
                                ),
                              ),
                            );
                            _annotationActions(annotation.id);
                          } else {
                            await controller.goToTextRange(ranges.first);
                          }
                        },
                        onLongPress: () {
                          Navigator.of(context).pop();
                          _annotationActions(annotation.id);
                        },
                      ),
                  ],
                ),
          items: items,
          activeId: activeTocId(items, controller.sectionIndex),
          onNavigate: (item) {
            final target = item.spineIndex;
            if (target == null) return;
            Navigator.of(context).pop(); // close the drawer first
            controller.goToSection(target);
          },
        );
      },
    );
  }

  Widget _buildBookEndContent(ReaderController controller) {
    return ColoredBox(
      key: const Key('book-end-swipe'),
      color: _background,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.auto_stories_outlined,
                size: 48,
                color: _chromeForeground,
              ),
              const SizedBox(height: 20),
              Text(
                context.l10n.text('已到书籍结尾', 'End of book'),
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 12),
              Text(
                controller.title,
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 28),
              FilledButton.icon(
                key: const Key('book-end-finish-button'),
                onPressed:
                    _completionSaving ||
                        _completionMarked ||
                        _completionStatusLoading
                    ? null
                    : _markFinished,
                icon: Icon(
                  _completionMarked ? Icons.check_circle : Icons.task_alt,
                ),
                label: Text(
                  _completionMarked
                      ? context.l10n.text('已读完', 'Finished')
                      : context.l10n.text('标记读完', 'Mark as finished'),
                ),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(context.l10n.text('返回书架', 'Back to library')),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildReader(ReaderController controller, BoxConstraints constraints) {
    _readerWidth = constraints.maxWidth;
    final page = controller.currentPage;
    if (page != null && _interactionPage != page) {
      _interactionPage = page;
      _interactionNodes = [];
      _marks = [];
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadInteraction(page);
      });
    }
    final width = constraints.maxWidth;
    return Stack(
      children: [
        Positioned.fill(
          child: Listener(
            onPointerDown: (_) => _tickStatistics(activity: true),
            onPointerSignal: (_) => _tickStatistics(activity: true),
            child: GestureDetector(
              key: const Key('reader-page-gesture'),
              behavior: HitTestBehavior.opaque,
              onTapUp: _selecting
                  ? null
                  : (details) => _handleTap(details, width),
              onHorizontalDragStart: _selecting
                  ? null
                  : (details) => _onDragStart(details, controller),
              onHorizontalDragUpdate: _selecting
                  ? null
                  : (details) => _onDragUpdate(details, controller, width),
              onHorizontalDragEnd: _selecting
                  ? null
                  : (details) => _onDragEnd(details, controller, width),
              onHorizontalDragCancel: _selecting
                  ? null
                  : () => _onDragCancel(controller, width),
              child: _turnDirection != null
                  ? _buildTurnScene(controller, width)
                  : _showBookEnd
                  ? _buildBookEndContent(controller)
                  : (page == null
                        ? const SizedBox.expand()
                        : ReaderSelectionLayer(
                            key: _selectionKey,
                            page: page,
                            nodes: _interactionNodes,
                            mode: controller.translationEnabled
                                ? ReaderSelectionMode.paragraph
                                : _selectionMode,
                            marks: _marks,
                            wholeParagraphMarks: controller.translationEnabled,
                            onSelecting: (value) {
                              if (mounted && value != _selecting) {
                                setState(() {
                                  _selecting = value;
                                  controller.setPageTurnActive(value);
                                  if (value) _overlayVisible = false;
                                });
                              }
                            },
                            onSave: _saveSelection,
                            onMarkTap: _annotationActions,
                            child: PageWidget(
                              page: page,
                              imageResolver: controller.resolveImage,
                              background: _background,
                              foreground: _foreground,
                            ),
                          )),
            ),
          ),
        ),
        if (controller.busy || !controller.opened)
          const Center(child: CircularProgressIndicator()),
        if (_searchChoice != null && !_selecting)
          Positioned(
            top: 0,
            left: 16,
            right: 16,
            child: SafeArea(
              child: Material(
                borderRadius: BorderRadius.circular(12),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: _searchIndex > 0 && !controller.busy
                          ? () {
                              _searchIndex--;
                              _jumpSearch();
                            }
                          : null,
                      icon: const Icon(Icons.chevron_left),
                    ),
                    Expanded(
                      child: Text(
                        '${_searchIndex + 1} / ${_searchChoice!.matches.length}',
                        textAlign: TextAlign.center,
                      ),
                    ),
                    IconButton(
                      onPressed:
                          _searchIndex + 1 < _searchChoice!.matches.length &&
                              !controller.busy
                          ? () {
                              _searchIndex++;
                              _jumpSearch();
                            }
                          : null,
                      icon: const Icon(Icons.chevron_right),
                    ),
                    IconButton(
                      onPressed: () => setState(() {
                        _searchChoice = null;
                        _interactionPage = null;
                      }),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
