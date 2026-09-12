import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import '../../core/formats/formats.dart';
import '../../core/html_ir/package_path.dart';
import '../../core/ir/ir.dart';
import '../../core/ir/text_index.dart';
import '../sync/sync_models.dart';
import 'annotations_repository.dart';
import '../../core/layout/layout_engine.dart';
import '../../core/layout/layout_types.dart';
import '../../core/linebreak/english_hyphenator.dart';
import '../../core/translation/translation_book_source.dart';
import '../../core/translation/translation_models.dart';
import '../ai/ai_models.dart';
import '../ai/ai_settings_store.dart';
import '../ai/openai_compatible_client.dart';
import '../progress_store.dart';
import '../sync/derived_data_store.dart';

class ReaderFootnote {
  final String marker;
  final String text;

  const ReaderFootnote({required this.marker, required this.text});
}

enum ReaderTranslationStatus { off, translating, on, error }

/// Owns the reading session for one book: the parsed source, paginated
/// sections (prev/current/next cached), page navigation, image decoding,
/// and progress persistence.
class ReaderController extends ChangeNotifier {
  AnnotationsRepository? _annotationsRepository;
  List<AnnotationState> annotations = [];
  Future<void> loadAnnotations() async {
    if (_resourceSource == null) return;
    _annotationsRepository ??= await AnnotationsRepository.open();
    annotations = await _annotationsRepository!.list(_resourceSource!.book.id);
    (int, int, int) order(AnnotationState annotation) {
      if (annotation.ranges.isEmpty) return (1 << 30, 0, 0);
      final anchor = annotation.ranges.first.start;
      final index = _resourceSource!.book.indexOfSpine(anchor.spine);
      return (
        index < 0 ? 1 << 30 : index,
        int.tryParse(anchor.node.replaceFirst('n', '')) ?? 0,
        anchor.textOffset,
      );
    }

    annotations.sort((a, b) {
      final left = order(a), right = order(b);
      final spine = left.$1.compareTo(right.$1);
      if (spine != 0) return spine;
      final node = left.$2.compareTo(right.$2);
      return node == 0 ? left.$3.compareTo(right.$3) : node;
    });
    notifyListeners();
  }

  Future<List<BookTextNode>> textNodes(
    int spine, {
    bool displayed = false,
  }) async {
    final section = await (displayed ? _source! : _resourceSource!)
        .parseSection(spine);
    final key = (spine, displayed);
    final cached = _textNodeCache.remove(key);
    if (cached != null && identical(cached.$1, section)) {
      _textNodeCache[key] = cached;
      return cached.$2;
    }
    final nodes = sectionTextNodes(section, includeNotes: true).toList();
    _textNodeCache[key] = (section, nodes);
    while (_textNodeCache.length > 6) {
      _textNodeCache.remove(_textNodeCache.keys.first);
    }
    return nodes;
  }

  Future<void> saveAnnotation(
    List<SourceRange> ranges,
    String quote, {
    String? note,
    AnnotationState? previous,
    bool delete = false,
  }) async {
    if (_resourceSource == null) return;
    _annotationsRepository ??= await AnnotationsRepository.open();
    final canonical = previous?.ranges ?? ranges;
    if (previous == null) {
      for (final range in canonical) {
        final index = _resourceSource!.book.indexOfSpine(range.start.spine);
        if (index < 0) throw StateError('Unknown source section');
        final nodes = await textNodes(index);
        final node = nodes.firstWhere(
          (n) => n.source.start.node == range.start.node,
        );
        if (!node.selectable ||
            range.end.spine != range.start.spine ||
            range.end.node != range.start.node) {
          throw StateError('This source text cannot be anchored');
        }
        sourceSlice(node.text, range.start.textOffset, range.end.textOffset);
        if (translationEnabled &&
            (range.start.textOffset != node.source.start.textOffset ||
                range.end.textOffset != node.source.end.textOffset)) {
          throw StateError(
            'Translated annotations require the complete original paragraph',
          );
        }
      }
    }
    await _annotationsRepository!.save(
      book: _resourceSource!.book.id,
      ranges: canonical,
      quote: quote,
      note: note,
      previous: previous,
      delete: delete,
    );
    await loadAnnotations();
  }

  Future<(List<SourceRange>, String)> originalParagraphSelection(
    List<SourceRange> displayed,
  ) => resolveOriginalParagraphSelection(_resourceSource!, displayed);

  Future<List<SourceRange>?> resolveAnnotation(
    AnnotationState annotation,
  ) async {
    if (_resourceSource == null) return null;
    final quotes = <String>[];
    try {
      for (final range in annotation.ranges) {
        final index = _resourceSource!.book.indexOfSpine(range.start.spine);
        if (index < 0 ||
            range.start.spine != range.end.spine ||
            range.start.node != range.end.node) {
          return null;
        }
        final node = (await textNodes(
          index,
        )).firstWhere((n) => n.source.start.node == range.start.node);
        quotes.add(
          sourceSlice(node.text, range.start.textOffset, range.end.textOffset),
        );
      }
      String normalize(String text) =>
          text.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (normalize(quotes.join('\n')) == normalize(annotation.quote)) {
        return annotation.ranges;
      }
    } catch (_) {
      /* Never paint a guessed location. */
    }
    if (annotation.ranges.length == 1 && annotation.quote.isNotEmpty) {
      final anchor = annotation.ranges.first.start;
      final index = _resourceSource!.book.indexOfSpine(anchor.spine);
      if (index < 0) return null;
      final matches = <SourceRange>[];
      for (final node in await textNodes(index)) {
        for (final (start, end) in sourceMatches(node.text, annotation.quote)) {
          matches.add(
            SourceRange(
              start: SourceAnchor(
                spine: anchor.spine,
                node: node.source.start.node,
                textOffset: start,
              ),
              end: SourceAnchor(
                spine: anchor.spine,
                node: node.source.start.node,
                textOffset: end,
              ),
            ),
          );
        }
      }
      if (matches.length == 1) return matches;
    }
    return null;
  }

  Future<bool> goToTextRange(SourceRange range) async {
    if (busy || _resourceSource == null) return false;
    final index = _resourceSource!.book.indexOfSpine(range.start.spine);
    if (index < 0) return false;
    if (translationEnabled) await toggleTranslation();
    await goToSection(index);
    final pages = currentPages;
    if (pages.isEmpty) return false;
    pageIndex = _pageForAnchor(pages, range.start, 0);
    notifyListeners();
    return true;
  }

  final ProgressStore progressStore;
  final String? titleHint;
  final String? publicationIdHint;
  final AiSettingsStore aiSettingsStore;
  final OpenAiCompatibleClient translationClient;
  final bool _ownsTranslationClient;
  final LayoutEngine _engine = LayoutEngine(
    hyphenator: EnglishHyphenator.instance,
  );

  BookSource? _source;
  BookSource? _resourceSource;
  TranslationBookSource? _translationSource;
  BookFormat? _format;
  LayoutViewport _viewport = const LayoutViewport(width: 0, height: 0);
  ReaderStyle _style = const ReaderStyle();
  int _paginationGeneration = 0;

  /// Paginated sections, kept only for [sectionIndex] ± 1.
  final Map<int, List<PageLayout>> _sections = {};

  /// Pagination already in progress, shared by foreground navigation and
  /// background peek preparation so a section is never laid out twice.
  final Map<int, Future<List<PageLayout>>> _paginations = {};
  final Map<int, int> _sectionRevisions = {};
  final Map<(int, bool), (Section, List<BookTextNode>)> _textNodeCache = {};
  final Set<int> _translationDirty = {};
  final List<List<PageLayout>> _retiredPages = [];
  Timer? _translationRefreshTimer;
  bool _pageTurnActive = false;
  bool _translationRefreshing = false;
  bool _readerVisible = true;
  bool _disposed = false;

  bool get canReuseSession =>
      !_disposed &&
      opened &&
      !busy &&
      _format == BookFormat.epub &&
      _activeAiSettings == null &&
      !translationEnabled &&
      !_translationRefreshing &&
      !_progressDirty &&
      _source != null;

  void setReaderVisible(bool visible) {
    if (_disposed) return;
    _readerVisible = visible;
    _pageTurnActive = false;
    if (!visible) {
      _translationRefreshTimer?.cancel();
      _saveTimer?.cancel();
    } else {
      _scheduleTranslationRefresh();
    }
  }

  /// A warm session must still respect reading progress received while away.
  Future<void> restoreSavedPosition() async {
    if (_disposed || !opened || _source == null || busy || sectionCount == 0) {
      return;
    }
    final locator = await progressStore.load(_book.id);
    if (locator == null || _disposed) return;
    final anchor = locator.source?.start;
    final identified = anchor == null ? -1 : _book.indexOfSpine(anchor.spine);
    final byHref = _book.spine.indexWhere(
      (item) => item.href == splitPackageFragment(locator.href).$1,
    );
    final target = identified >= 0
        ? identified
        : byHref >= 0
        ? byHref
        : locator.position.clamp(0, sectionCount - 1);
    if (target != sectionIndex) {
      final wasDirty = _progressDirty;
      await goToSection(target);
      // Restoring a received locator is not a new local reading event.
      _saveTimer?.cancel();
      _saveTimer = null;
      _progressDirty = wasDirty;
    }
    if (_disposed || target != sectionIndex) return;
    final restored = await _restorePageIndex(target, locator);
    if (restored != pageIndex) {
      pageIndex = restored;
      notifyListeners();
    }
  }

  /// Decoded images by package href; null values mark known-missing.
  final Map<String, ui.Image?> _images = {};

  int sectionIndex = 0;
  int pageIndex = 0;

  /// True while a section is being paginated/decoded.
  bool busy = false;

  /// True once [open] has completed successfully.
  bool opened = false;

  String title = '';
  List<TocEntry> _derivedToc = const [];
  AiSettings? _activeAiSettings;
  bool translationEnabled = false;
  bool _translationInFlight = false;
  bool _translationRecheckPending = false;
  bool _tocTranslationInFlight = false;
  int _translationGeneration = 0;
  String? translationError;
  final Map<int, String> _translatedTocLabels = {};

  /// Network work can finish during a swipe; applying its layout must wait.
  void setPageTurnActive(bool active) {
    _pageTurnActive = active;
    if (active) {
      _translationRefreshTimer?.cancel();
    } else {
      _scheduleTranslationRefresh();
      if (_translationRecheckPending) _queueVisibleTranslation();
    }
  }

  void _retirePages(List<PageLayout> pages) {
    _retiredPages.add(pages);
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (_retiredPages.remove(pages)) _disposePages(pages);
    });
    SchedulerBinding.instance.scheduleFrame();
  }

  void _scheduleTranslationRefresh() {
    _translationRefreshTimer?.cancel();
    if (!_readerVisible ||
        !translationEnabled ||
        _translationDirty.isEmpty ||
        _pageTurnActive ||
        _translationRefreshing) {
      return;
    }
    _translationRefreshTimer = Timer(const Duration(milliseconds: 250), () {
      unawaited(_applyTranslationUpdates());
    });
  }

  Future<void> _applyTranslationUpdates() async {
    if (!_readerVisible ||
        !opened ||
        !translationEnabled ||
        _pageTurnActive ||
        _translationRefreshing) {
      return;
    }
    if (busy) {
      _scheduleTranslationRefresh();
      return;
    }
    _translationRefreshing = true;
    var changed = false;
    var failed = false;
    try {
      for (final index in _translationDirty.toList()) {
        if (index == sectionIndex) continue;
        final old = _sections.remove(index);
        if (old != null) _retirePages(old);
        _translationDirty.remove(index);
        changed = true;
      }
      final index = sectionIndex;
      if (_translationDirty.contains(index)) {
        final generation = _paginationGeneration;
        final translationGeneration = _translationGeneration;
        final revision = _sectionRevisions[index];
        final pages = await _layoutSection(index);
        if (generation != _paginationGeneration ||
            translationGeneration != _translationGeneration ||
            revision != _sectionRevisions[index] ||
            sectionIndex != index ||
            _pageTurnActive ||
            busy ||
            !opened) {
          _disposePages(pages);
          return;
        }
        // A reader may have navigated while the new layout yielded. Anchor to
        // the latest visible page, never the page that requested translation.
        final anchor = currentPage?.firstAnchor;
        final progression = currentPage?.progression ?? 0;
        final old = _sections[index];
        _sections[index] = pages;
        pageIndex = pages.isEmpty
            ? 0
            : anchor != null
            ? _pageForAnchor(pages, anchor, progression)
            : (progression * (pages.length - 1)).round().clamp(
                0,
                pages.length - 1,
              );
        _translationDirty.remove(index);
        if (old != null) _retirePages(old);
        changed = true;
        _scheduleSave();
      }
    } catch (error, stack) {
      failed = true;
      debugPrint('Could not apply translated layout: $error\n$stack');
      translationError = error.toString();
    } finally {
      _translationRefreshing = false;
      if (opened && _source != null) {
        if (changed || failed) notifyListeners();
        if (!failed) {
          _scheduleTranslationRefresh();
          _queueVisibleTranslation();
        }
        if (changed && !failed) {
          unawaited(ensurePeek().catchError((Object _, StackTrace _) {}));
        }
      }
    }
  }

  Timer? _saveTimer;
  bool _progressDirty = false;

  ReaderController({
    ProgressStore? progressStore,
    this.titleHint,
    this.publicationIdHint,
    AiSettingsStore? aiSettingsStore,
    OpenAiCompatibleClient? translationClient,
  }) : progressStore = progressStore ?? ProgressStore(),
       aiSettingsStore = aiSettingsStore ?? AiSettingsStore(),
       translationClient = translationClient ?? OpenAiCompatibleClient(),
       _ownsTranslationClient = translationClient == null;

  Book get _book => _source!.book;

  List<PageLayout> get currentPages => _sections[sectionIndex] ?? const [];

  PageLayout? get currentPage {
    final pages = currentPages;
    return pageIndex < pages.length ? pages[pageIndex] : null;
  }

  int get sectionCount => _source?.book.sectionCount ?? 0;

  /// Normalized en-US/en-GB fallback selected from publication metadata.
  String get publicationLanguage => _style.publicationLanguage;

  ReaderStyle get style => _style;
  String get statisticsBookId => _source?.book.id ?? '';
  BookMetadata? get statisticsMetadata => _source?.book.metadata;

  bool _peekPreparing = false;

  /// Table of contents from the book's navigation document (may be empty).
  List<TocEntry> get toc {
    final original = _derivedToc.isNotEmpty
        ? _derivedToc
        : (_source?.book.toc ?? const []);
    final settings = _activeAiSettings?.translation;
    if (!translationEnabled ||
        settings?.translateToc != true ||
        _translatedTocLabels.isEmpty) {
      return original;
    }
    var index = 0;
    List<TocEntry> translate(List<TocEntry> entries) => [
      for (final entry in entries)
        TocEntry(
          label: _translatedTocLabels[index++] ?? entry.label,
          href: entry.href,
          spineIndex: entry.spineIndex,
          children: translate(entry.children),
        ),
    ];
    return translate(original);
  }

  ReaderTranslationStatus get translationStatus {
    if (!translationEnabled) return ReaderTranslationStatus.off;
    if (_translationInFlight || _tocTranslationInFlight) {
      return ReaderTranslationStatus.translating;
    }
    if (translationError != null) return ReaderTranslationStatus.error;
    return ReaderTranslationStatus.on;
  }

  double get totalProgression {
    final count = sectionCount;
    if (count == 0) return 0;
    return ((sectionIndex + (currentPage?.progression ?? 0)) / count).clamp(
      0.0,
      1.0,
    );
  }

  /// Synchronous image resolver handed to the render stage.
  ui.Image? resolveImage(String href) => _images[href];

  /// Opens [file], restores the saved position (if any), and paginates the
  /// starting section. Throws when the file is not a readable e-book.
  Future<void> open(
    File file,
    LayoutViewport viewport,
    ReaderStyle style,
  ) async {
    if (_disposed) throw StateError('Reader is closed');
    final openingGeneration = _paginationGeneration;
    _viewport = viewport;
    _style = style;
    final openingWatch = Stopwatch()..start();
    final hintedLocator = publicationIdHint == null
        ? null
        : await progressStore.load(publicationIdHint!);
    final fileName = _baseName(file.path);
    final format = BookFormat.fromFileName(fileName);
    _format = format;
    final BookSource source;
    if (format == BookFormat.epub) {
      source = await EpubBookSource.fromFileInBackground(
        file.path,
        publicationIdHint: publicationIdHint,
        initialLocator: hintedLocator,
      );
    } else {
      final bytes = await file.readAsBytes();
      source = await openBook(
        bytes,
        fileName,
        filePath: file.path,
        titleHint: titleHint,
        publicationIdHint: publicationIdHint,
      );
    }
    if (_disposed || openingGeneration != _paginationGeneration) {
      if (source is DisposableBookSource) {
        (source as DisposableBookSource).dispose();
      }
      throw StateError('Reader was closed while opening');
    }
    _resourceSource = source;
    final sourceMilliseconds = openingWatch.elapsedMilliseconds;
    final translationSource = TranslationBookSource(source);
    _translationSource = translationSource;
    _source = translationSource;
    _style = style.copyWith(
      writingSystem: _book.metadata.writingSystem,
      publicationLanguage: _preferredHyphenationLanguage(
        _book.metadata.languages,
      ),
    );
    _derivedToc = const [];
    title = _book.metadata.title.isEmpty
        ? _fileTitle(file.path)
        : _book.metadata.title;

    final locator = hintedLocator ?? await progressStore.load(_book.id);
    final count = _book.sectionCount;
    var start = 0;
    if (locator != null && count > 0) {
      start = locator.position.clamp(0, count - 1);
      final id = locator.source?.start.spine;
      final identified = id == null ? -1 : _book.indexOfSpine(id);
      final hrefIndex = _book.spine.indexWhere(
        (s) => s.href == splitPackageFragment(locator.href).$1,
      );
      if (identified >= 0) {
        start = identified;
      } else if (hrefIndex >= 0) {
        start = hrefIndex;
      }
    }

    busy = true;
    notifyListeners();
    try {
      // Find the nearest non-empty section, forward from the target first.
      var target = -1;
      for (var i = start; i < count; i++) {
        if ((await _paginate(i)).isNotEmpty) {
          target = i;
          break;
        }
      }
      for (var i = start - 1; target == -1 && i >= 0; i--) {
        if ((await _paginate(i)).isNotEmpty) {
          target = i;
          break;
        }
      }
      if (target == -1) target = start; // empty book; show a blank page

      sectionIndex = target;
      pageIndex = 0;
      if (locator != null && target == start) {
        pageIndex = await _restorePageIndex(target, locator);
      }
      _evictDistantSections();
      if (_disposed) throw StateError('Reader was closed while opening');
      opened = true;
    } finally {
      busy = false;
      notifyListeners();
    }
    debugPrint(
      'TortoReader open source_ms=$sourceMilliseconds total_ms=${openingWatch.elapsedMilliseconds} section=$sectionIndex pages=${currentPages.length}',
    );
    // Generated/OCR TOC metadata is optional for the first paint. Load it
    // after the page is visible so a large metadata file cannot delay opening.
    unawaited(_loadDerivedToc(source, file.parent));
  }

  Future<void> _loadDerivedToc(
    BookSource source,
    Directory booksDirectory,
  ) async {
    final toc = await DerivedDataStore.fromBooksDirectory(
      booksDirectory,
    ).generatedToc(source.book.id, source.book);
    if (!identical(_resourceSource, source) || toc.isEmpty) return;
    _derivedToc = toc;
    if (translationEnabled) {
      _translatedTocLabels.clear();
      _queueTocTranslation();
    }
    notifyListeners();
  }

  /// Applies a presentation change and repaginates around the current
  /// logical position. Parsed publication data and decoded images stay
  /// cached; only layout-dependent pages are rebuilt.
  Future<void> updateStyle(ReaderStyle nextStyle) async {
    if (nextStyle == _style) return;
    _style = nextStyle;
    if (!opened || busy || _source == null) return;

    final currentSection = sectionIndex;
    final progression = currentPage?.progression ?? 0.0;
    final anchor = currentPage?.firstAnchor;
    final staleSections = Map<int, List<PageLayout>>.of(_sections);
    _sections.clear();
    _paginations.clear();
    _paginationGeneration++;
    busy = true;
    notifyListeners();

    // Let the old page leave the render tree before disposing its retained
    // dart:ui paragraphs.
    await Future<void>.delayed(Duration.zero);
    for (final pages in staleSections.values) {
      _disposePages(pages);
    }

    try {
      final pages = await _paginate(currentSection);
      sectionIndex = currentSection;
      pageIndex = pages.isEmpty
          ? 0
          : anchor != null
          ? _pageForAnchor(pages, anchor, progression)
          : (progression * (pages.length - 1)).round().clamp(
              0,
              pages.length - 1,
            );
      _evictDistantSections();
    } finally {
      busy = false;
      notifyListeners();
      _scheduleSave();
    }
  }

  /// Turns the in-memory translation overlay on or off. Translation never
  /// changes the canonical publication and never blocks a page turn.
  Future<bool> toggleTranslation() async {
    if (!opened || busy) return false;
    final source = _translationSource;
    if (source == null) return false;
    translationError = null;
    if (translationEnabled) {
      translationEnabled = false;
      _translationRefreshTimer?.cancel();
      _translationDirty.clear();
      _translationGeneration++;
      source.enabled = false;
      _translationInFlight = false;
      _tocTranslationInFlight = false;
      notifyListeners();
      await _refreshCurrentSectionPreservingPosition();
      return true;
    }
    if (_format == BookFormat.pdf) {
      translationError =
          'Fixed-layout PDF translation is not supported in this version.';
      notifyListeners();
      return false;
    }
    final settings = await aiSettingsStore.load();
    final translation = settings.translation;
    final provider = settings.provider(translation.providerId);
    final error = _translationConfigurationError(provider, translation.model);
    if (error != null) {
      translationError = error;
      notifyListeners();
      return false;
    }
    final languageCode = _targetLanguageCode(
      translation.target,
      ui.PlatformDispatcher.instance.locale.languageCode,
    );
    _activeAiSettings = settings;
    _translationGeneration++;
    _paginationGeneration++;
    _paginations.clear();
    translationEnabled = true;
    source
      ..mode = translation.mode
      ..targetLanguageCode = languageCode
      ..enabled = true;
    for (final index in _sections.keys) {
      if (source.hasTranslations(index)) _translationDirty.add(index);
    }
    _scheduleTranslationRefresh();
    notifyListeners();
    _queueVisibleTranslation();
    _queueTocTranslation();
    return true;
  }

  void retryTranslation() {
    if (!translationEnabled) return;
    translationError = null;
    _scheduleTranslationRefresh();
    _queueVisibleTranslation();
    _queueTocTranslation();
  }

  void _queueVisibleTranslation() {
    if (!translationEnabled || !_readerVisible || _disposed) return;
    if (_translationInFlight ||
        busy ||
        _pageTurnActive ||
        _translationRefreshing ||
        _translationDirty.contains(sectionIndex)) {
      _translationRecheckPending = true;
      _scheduleTranslationRefresh();
      return;
    }
    _translationRecheckPending = false;
    final source = _translationSource;
    final settings = _activeAiSettings;
    final page = currentPage;
    if (source == null || settings == null || page == null) return;
    final visibleNodes = <String>{};
    for (final item in page.items) {
      final nodeId = switch (item) {
        TextPlacement(:final nodeId, :final source) =>
          source?.start.node ?? nodeId,
        TableCellPlacement(:final nodeId, :final source) =>
          source?.start.node ?? nodeId,
        _ => '',
      };
      if (nodeId.isNotEmpty) visibleNodes.add(nodeId);
    }
    if (visibleNodes.isEmpty) return;
    final generation = _translationGeneration;
    final visibleSection = sectionIndex;
    _translationInFlight = true;
    translationError = null;
    unawaited(() async {
      var succeeded = false;
      var requested = false;
      try {
        final candidates = await _translationCandidateNodes(
          visibleSection,
          visibleNodes,
        );
        int? requestedSection;
        List<TranslationBlockInput>? blocks;
        for (final candidate in candidates) {
          final untranslated = await source.untranslatedBlocksForNodes(
            candidate.$1,
            candidate.$2,
          );
          if (untranslated.isEmpty) continue;
          requestedSection = candidate.$1;
          blocks = untranslated;
          break;
        }
        if (requestedSection == null || blocks == null) return;
        if (generation != _translationGeneration || !translationEnabled) return;
        requested = true;
        notifyListeners();
        final translation = settings.translation;
        final provider = settings.provider(translation.providerId)!;
        final results = await translationClient.translateBlocks(
          provider: provider,
          model: translation.model,
          targetLanguage: resolvedTranslationTarget(
            translation.target,
            ui.PlatformDispatcher.instance.locale.languageCode,
          ),
          blocks: blocks,
          reasoningEffort: translation.reasoningEffort,
          validate: (translations) =>
              source.validateBatch(requestedSection!, translations),
        );
        if (generation != _translationGeneration || !translationEnabled) return;
        await source.storeBatch(requestedSection, results);
        if (generation != _translationGeneration || !translationEnabled) return;
        succeeded = true;
        _sectionRevisions.update(
          requestedSection,
          (value) => value + 1,
          ifAbsent: () => 1,
        );
        _paginations.remove(requestedSection);
        _translationDirty.add(requestedSection);
        _scheduleTranslationRefresh();
      } catch (error, stackTrace) {
        debugPrint(
          'Could not translate visible book text: $error\n$stackTrace',
        );
        if (generation == _translationGeneration && translationEnabled) {
          translationError = error.toString();
        }
      } finally {
        if (generation == _translationGeneration) {
          _translationInFlight = false;
          if (requested) notifyListeners();
          if ((succeeded ||
                  _translationRecheckPending ||
                  sectionIndex != visibleSection) &&
              translationEnabled) {
            _queueVisibleTranslation();
          }
        }
      }
    }());
  }

  Future<List<(int, Set<String>)>> _translationCandidateNodes(
    int visibleSection,
    Set<String> visibleNodes,
  ) {
    final source = _resourceSource;
    if (source == null) {
      return Future.value([(visibleSection, visibleNodes)]);
    }
    return linkedFootnoteTranslationCandidates(
      source,
      visibleSection,
      visibleNodes,
    );
  }

  void _queueTocTranslation() {
    final settings = _activeAiSettings;
    if (!translationEnabled ||
        _tocTranslationInFlight ||
        settings == null ||
        !settings.translation.translateToc ||
        _translatedTocLabels.isNotEmpty) {
      return;
    }
    final original = _derivedToc.isNotEmpty ? _derivedToc : _book.toc;
    final labels = <(int, String)>[];
    var tocIndex = 0;
    void collect(List<TocEntry> entries) {
      for (final entry in entries) {
        final index = tocIndex++;
        if (entry.label.trim().isNotEmpty) {
          labels.add((index, entry.label.trim()));
        }
        collect(entry.children);
      }
    }

    collect(original);
    if (labels.isEmpty) return;
    final generation = _translationGeneration;
    _tocTranslationInFlight = true;
    notifyListeners();
    unawaited(() async {
      try {
        final translation = settings.translation;
        final provider = settings.provider(translation.providerId)!;
        final results = await translationClient.translateBlocks(
          provider: provider,
          model: translation.model,
          targetLanguage: resolvedTranslationTarget(
            translation.target,
            ui.PlatformDispatcher.instance.locale.languageCode,
          ),
          reasoningEffort: translation.reasoningEffort,
          blocks: [
            for (final label in labels)
              TranslationBlockInput(
                blockIndex: label.$1,
                nodeId: 'toc-${label.$1}',
                text: label.$2,
              ),
          ],
        );
        if (generation != _translationGeneration || !translationEnabled) return;
        _translatedTocLabels
          ..clear()
          ..addEntries(
            results.map(
              (translation) =>
                  MapEntry(translation.blockIndex, translation.text),
            ),
          );
      } catch (error, stackTrace) {
        debugPrint(
          'Could not translate table of contents: $error\n$stackTrace',
        );
        if (generation == _translationGeneration && translationEnabled) {
          translationError ??= error.toString();
        }
      } finally {
        if (generation == _translationGeneration) {
          _tocTranslationInFlight = false;
          notifyListeners();
        }
      }
    }());
  }

  Future<void> _refreshCurrentSectionPreservingPosition() async {
    if (!opened || busy || _source == null) return;
    final currentSection = sectionIndex;
    final progression = currentPage?.progression ?? 0.0;
    final anchor = currentPage?.firstAnchor;
    final staleSections = Map<int, List<PageLayout>>.of(_sections);
    _sections.clear();
    _paginations.clear();
    _paginationGeneration++;
    busy = true;
    notifyListeners();
    await Future<void>.delayed(Duration.zero);
    for (final pages in staleSections.values) {
      _disposePages(pages);
    }
    try {
      final pages = await _paginate(currentSection);
      sectionIndex = currentSection;
      if (pages.isEmpty) {
        pageIndex = 0;
      } else if (anchor != null) {
        pageIndex = _pageForAnchor(pages, anchor, progression);
      } else {
        pageIndex = (progression * (pages.length - 1)).round().clamp(
          0,
          pages.length - 1,
        );
      }
      _evictDistantSections();
    } finally {
      busy = false;
      notifyListeners();
      _scheduleSave();
    }
  }

  static int _pageForAnchor(
    List<PageLayout> pages,
    SourceAnchor anchor,
    double fallbackProgression,
  ) {
    var match = -1;
    for (var index = 0; index < pages.length; index++) {
      for (final item in pages[index].items) {
        if (item is TextPlacement &&
            item.source?.start.spine == anchor.spine &&
            (item.source?.start.node ?? item.nodeId) == anchor.node &&
            item.textOffsetAtStart + (item.source?.start.textOffset ?? 0) <=
                anchor.textOffset) {
          match = index;
        } else if (item is TableCellPlacement &&
            item.source?.start.spine == anchor.spine &&
            item.nodeId == anchor.node) {
          match = index;
        }
      }
    }
    return match >= 0
        ? match
        : (fallbackProgression * (pages.length - 1)).round().clamp(
            0,
            pages.length - 1,
          );
  }

  static String? _translationConfigurationError(
    AiProviderConfig? provider,
    String model,
  ) {
    if (provider == null) return 'Select an AI provider first.';
    if (provider.baseUrl.trim().isEmpty) {
      return 'Configure the AI provider URL first.';
    }
    if (provider.apiKey.trim().isEmpty) {
      return 'Configure the AI provider API Key first.';
    }
    if (model.trim().isEmpty) return 'Select a translation model first.';
    return null;
  }

  static String _targetLanguageCode(
    TranslationTarget target,
    String systemLanguageCode,
  ) => switch (target) {
    TranslationTarget.system =>
      systemLanguageCode.toLowerCase() == 'zh' ? 'zh-CN' : 'en',
    TranslationTarget.simplifiedChinese => 'zh-CN',
    TranslationTarget.english => 'en',
  };

  /// Chooses the page matching [locator] within an already-paginated section.
  ///
  /// Match stable section/node identity and Unicode-scalar offset against the
  /// retained page slices. Use fractional progress only when no anchor matches.
  Future<int> _restorePageIndex(int section, LocatorV1 locator) async {
    final pages = _sections[section] ?? const [];
    if (pages.isEmpty) return 0;
    final anchor = locator.source?.start;
    if (anchor != null && anchor.spine == _book.spine[section].id) {
      return _pageForAnchor(pages, anchor, locator.progression);
    }
    return (locator.progression * (pages.length - 1)).round().clamp(
      0,
      pages.length - 1,
    );
  }

  /// Relative offset for [peekPage]: -1 = previous page, +1 = next page.
  static const (int, int) _emptyPeek = (-1, -1);

  /// Resolves the (section, page) coordinate [pageOffset] steps away from
  /// the current page, crossing section boundaries when needed.
  ///
  /// A section that has not been paginated yet is treated as *potentially*
  /// non-empty, so peeking past it is allowed (the drag is damped until
  /// [ensurePeek] has materialised the neighbour).
  (int section, int page) _peekCoordinate(int pageOffset) {
    if (!opened || pageOffset == 0) return (sectionIndex, pageIndex);
    final count = sectionCount;
    var section = sectionIndex;
    var page = pageIndex;
    var remaining = pageOffset;
    var guard = count * 2 + 4;
    while (remaining != 0 && guard-- > 0) {
      if (remaining > 0) {
        if (page + 1 < (_sections[section]?.length ?? 0)) {
          page++;
          remaining--;
          continue;
        }
        var next = section + 1;
        // Skip only sections KNOWN to be empty; null (unpaginated) is kept.
        while (next < count && (_sections[next]?.isEmpty ?? false)) {
          next++;
        }
        if (next >= count) return _emptyPeek;
        section = next;
        page = 0;
        remaining--;
      } else {
        if (page > 0) {
          page--;
          remaining++;
          continue;
        }
        var prev = section - 1;
        while (prev >= 0 && (_sections[prev]?.isEmpty ?? false)) {
          prev--;
        }
        if (prev < 0) return _emptyPeek;
        section = prev;
        final pages = _sections[section];
        // Unpaginated neighbour: report its first page coordinate; the
        // actual landing page is resolved once it is paginated.
        page = (pages == null || pages.isEmpty) ? 0 : pages.length - 1;
        remaining++;
      }
    }
    return remaining == 0 ? (section, page) : _emptyPeek;
  }

  /// The page [pageOffset] steps from the current one, or null when that
  /// page is out of range or its section is not yet paginated. Call
  /// [ensurePeek] first so adjacent sections are ready before a drag.
  PageLayout? peekPage(int pageOffset) {
    final (section, page) = _peekCoordinate(pageOffset);
    if (section < 0) return null;
    final pages = _sections[section];
    if (pages == null || page >= pages.length) return null;
    return pages[page];
  }

  /// Whether the page [pageOffset] steps away exists (book bounds check
  /// without paginating).
  bool canPeek(int pageOffset) => _peekCoordinate(pageOffset) != _emptyPeek;

  /// Paginates the adjacent sections needed by [peekPage]. Fire-and-forget
  /// (typically called when the reader becomes idle); [notifyListeners] is
  /// invoked only when something was actually paginated, so the current
  /// page is never rebuilt with a partially-updated model.
  Future<void> ensurePeek() async {
    if (busy ||
        !opened ||
        _peekPreparing ||
        _pageTurnActive ||
        !_readerVisible) {
      return;
    }
    _peekPreparing = true;
    try {
      var paginatedAny = false;
      for (final direction in const [-1, 1]) {
        while (true) {
          final section = _peekCoordinate(direction).$1;
          if (section < 0 || _sections.containsKey(section)) break;
          await _paginate(section);
          if (_pageTurnActive || !opened) break;
          paginatedAny = true;
          // If the section was empty, _peekCoordinate now skips it and the
          // loop prepares the next candidate as well.
        }
      }
      if (paginatedAny) notifyListeners();
    } finally {
      _peekPreparing = false;
    }
  }

  Future<void> nextPage() async {
    if (busy || !opened) return;
    _scheduleTranslationRefresh();
    if (pageIndex + 1 < currentPages.length) {
      pageIndex++;
      notifyListeners();
      _scheduleSave();
      _queueVisibleTranslation();
      return;
    }
    await _stepSection(1);
  }

  Future<void> prevPage() async {
    if (busy || !opened) return;
    _scheduleTranslationRefresh();
    if (pageIndex > 0) {
      pageIndex--;
      notifyListeners();
      _scheduleSave();
      _queueVisibleTranslation();
      return;
    }
    await _stepSection(-1);
  }

  /// Jumps to the first page of [section] (clamped to range), paginating
  /// on demand. Empty target sections fall back to the nearest non-empty
  /// one, forward first — the same rule as [open].
  Future<void> goToSection(int section) async {
    if (busy || !opened) return;
    final count = _book.sectionCount;
    if (count == 0) return;
    final start = section.clamp(0, count - 1);
    busy = true;
    notifyListeners();
    try {
      var target = -1;
      for (var i = start; i < count; i++) {
        if ((await _paginate(i)).isNotEmpty) {
          target = i;
          break;
        }
      }
      for (var i = start - 1; target == -1 && i >= 0; i--) {
        if ((await _paginate(i)).isNotEmpty) {
          target = i;
          break;
        }
      }
      if (target == -1) return; // effectively empty book; stay put
      sectionIndex = target;
      pageIndex = 0;
      _evictDistantSections();
    } finally {
      busy = false;
      notifyListeners();
      _scheduleSave();
      _queueVisibleTranslation();
    }
  }

  /// Resolves and jumps to an internal publication link, including fragments.
  Future<bool> goToHref(String href) async {
    if (busy || !opened || isExternalHref(href)) return false;
    final (path, fragment) = splitPackageFragment(href);
    final target = _book.spine.indexWhere((item) => item.href == path);
    if (target < 0) return false;

    var navigated = false;
    busy = true;
    notifyListeners();
    try {
      final section = await _source!.parseSection(target);
      final pages = await _paginate(target);
      if (pages.isEmpty) return false;
      var targetPage = 0;
      if (fragment != null && fragment.isNotEmpty) {
        final anchor = _anchorByFragment(section, fragment);
        if (anchor != null) {
          final index = pages.indexWhere(
            (page) => page.items.any(
              (item) => switch (item) {
                TextPlacement(:final nodeId) ||
                TableCellPlacement(
                  :final nodeId,
                ) => nodeId == anchor.source.node,
                _ => false,
              },
            ),
          );
          if (index >= 0) targetPage = index;
        }
      }
      sectionIndex = target;
      pageIndex = targetPage;
      _evictDistantSections();
      navigated = true;
      return true;
    } finally {
      busy = false;
      notifyListeners();
      if (navigated) {
        _scheduleSave();
        _queueVisibleTranslation();
      }
    }
  }

  /// Reads a linked footnote without changing the current reading position.
  Future<ReaderFootnote?> resolveFootnote(TextLinkRange link) async {
    if (!opened || isExternalHref(link.href)) return null;
    final (path, fragment) = splitPackageFragment(link.href);
    if (fragment == null || fragment.isEmpty) return null;
    final target = _book.spine.indexWhere((item) => item.href == path);
    if (target < 0) return null;
    final section = await _source!.parseSection(target);
    final anchor = _anchorByFragment(section, fragment);
    if (anchor == null) return null;
    final text = _textForSourceNode(section, anchor.source.node);
    if (text == null || text.trim().isEmpty) return null;
    return ReaderFootnote(
      marker: link.marker,
      text: _withoutFootnoteMarker(text.trim(), link.marker),
    );
  }

  /// Moves to the adjacent non-empty section, paginating on demand.
  /// Forward lands on the first page, backward on the LAST page.
  Future<void> _stepSection(int direction) async {
    busy = true;
    notifyListeners();
    try {
      final count = _book.sectionCount;
      for (
        var i = sectionIndex + direction;
        i >= 0 && i < count;
        i += direction
      ) {
        final pages = await _paginate(i);
        if (pages.isEmpty) continue; // skip zero-page sections
        sectionIndex = i;
        pageIndex = direction > 0 ? 0 : pages.length - 1;
        break;
      }
      _evictDistantSections();
    } finally {
      busy = false;
      notifyListeners();
      _scheduleSave();
      _queueVisibleTranslation();
    }
  }

  /// Parses and paginates section [index] (cached). Images are decoded
  /// BEFORE layout so the engine sees their intrinsic sizes (torto does
  /// the same: raster decode happens before push_image) — otherwise every
  /// image would be laid out as a 1em placeholder square. Yields the event
  /// loop before the synchronous layout work so a busy indicator can paint.
  Future<List<PageLayout>> _paginate(int index) async {
    final cached = _sections[index];
    if (cached != null) return cached;
    final inFlight = _paginations[index];
    if (inFlight != null) return inFlight;

    final generation = _paginationGeneration;
    final pagination = _paginateFresh(index, generation);
    _paginations[index] = pagination;
    try {
      return await pagination;
    } finally {
      if (identical(_paginations[index], pagination)) {
        _paginations.remove(index);
      }
    }
  }

  Future<List<PageLayout>> _paginateFresh(int index, int generation) async {
    final revision = _sectionRevisions[index];
    final pages = await _layoutSection(index);
    if (generation != _paginationGeneration ||
        revision != _sectionRevisions[index]) {
      _disposePages(pages);
      return _sections[index] ?? const [];
    }
    _sections[index] = pages;
    _translationDirty.remove(index);
    return pages;
  }

  Future<List<PageLayout>> _layoutSection(int index) async {
    final source = _source;
    if (source == null) return const [];
    final book = source.book;
    final viewport = _viewport;
    final style = _style;
    final watch = Stopwatch()..start();
    final section = await source.parseSection(index);
    await Future.wait([
      _decodeSectionImages(section),
      EnglishHyphenator.instance.ensureLoadedForSection(
        section,
        publicationLanguage: style.publicationLanguage,
      ),
    ]);
    await Future<void>.delayed(Duration.zero);
    final pages = await _engine.paginateAsync(
      section,
      viewport,
      style,
      imageSizeResolver: _imageSize,
      coverHref: book.coverHref,
      renditionLayout: book.metadata.layout,
      timeSlice: opened
          ? const Duration(milliseconds: 4)
          : const Duration(milliseconds: 10),
      shouldPause: () => opened && (_pageTurnActive || !_readerVisible),
    );
    if (watch.elapsedMilliseconds >= 32) {
      debugPrint(
        'TortoReader layout section=$index pages=${pages.length} elapsed_ms=${watch.elapsedMilliseconds} translated=$translationEnabled',
      );
    }
    return pages;
  }

  static String _preferredHyphenationLanguage(List<String> languages) {
    for (final language in languages) {
      final locale = EnglishHyphenator.localeForLanguageTag(language);
      if (locale != null) return locale.languageTag;
    }
    return '';
  }

  /// Decodes every image referenced by [section]'s blocks into [_images]
  /// (null marks known-missing/undecodable). No-op for cached hrefs.
  Future<void> _decodeSectionImages(Section section) async {
    final hrefs = <String>{};
    void collectInlines(List<Inline> inlines) {
      for (final inline in inlines) {
        if (inline case InlineImageRun(:final image)) {
          if (!_images.containsKey(image.href)) hrefs.add(image.href);
        }
      }
    }

    void collectBlock(Block block) {
      switch (block) {
        case ImageBlock():
          if (!_images.containsKey(block.href)) hrefs.add(block.href);
        case TextBlock(:final inlines):
          collectInlines(inlines);
        case QuoteBlock(:final body, :final attribution):
          for (final text in [...body, ?attribution]) {
            collectInlines(text.inlines);
          }
        case TableBlock(:final rows):
          for (final cell in rows.expand((row) => row.cells)) {
            collectInlines(cell.inlines);
          }
        case FigureBlock(:final images, :final captions):
          for (final image in images) {
            if (!_images.containsKey(image.href)) hrefs.add(image.href);
          }
          for (final caption in captions) {
            collectInlines(caption.inlines);
          }
        case NoteBlock(:final blocks):
          blocks.forEach(collectBlock);
        case SeparatorBlock(:final image):
          if (image != null && !_images.containsKey(image.href)) {
            hrefs.add(image.href);
          }
        case PageBreakBlock() || LineBreakBlock():
          break;
      }
    }

    section.blocks.forEach(collectBlock);
    if (hrefs.isEmpty) return;
    await Future.wait(
      hrefs.map((href) async {
        try {
          final source = _resourceSource!;
          if (source is RasterResourceSource) {
            final rasterSource = source as RasterResourceSource;
            _images[href] = await rasterSource.rasterResource(
              href,
              maxDimension: 2048,
            );
          } else {
            final bytes = await source.resource(href);
            _images[href] = bytes == null
                ? null
                : await _decodeReaderImage(bytes);
          }
        } catch (error, stackTrace) {
          debugPrint(
            'Could not decode reader image $href: $error\n$stackTrace',
          );
          _images[href] = null; // missing or undecodable: render without it
        }
      }),
    );
  }

  ui.Size? _imageSize(String href) {
    final image = _images[href];
    if (image == null) return null;
    return ui.Size(image.width.toDouble(), image.height.toDouble());
  }

  static Future<ui.Image> _decodeReaderImage(Uint8List bytes) async {
    const maxDimension = 2048;
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    // instantiateImageCodecWithSize takes ownership of [buffer] and disposes
    // it after creating the codec. Disposing it again here makes a successful
    // decode look like a failure and leaves image-only pages blank.
    final codec = await ui.instantiateImageCodecWithSize(
      buffer,
      getTargetSize: (width, height) {
        final longest = math.max(width, height);
        if (longest <= maxDimension) return const ui.TargetImageSize();
        final scale = maxDimension / longest;
        return ui.TargetImageSize(
          width: math.max(1, (width * scale).round()),
          height: math.max(1, (height * scale).round()),
        );
      },
    );
    try {
      return (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
  }

  /// Disposes and drops paginated sections outside [sectionIndex] ± 1.
  /// Each PageLayout of a section is disposed exactly once, which is the
  /// correct eviction for the shared ParagraphDisposalPool.
  void _evictDistantSections() {
    final stale = _sections.keys
        .where((index) => (index - sectionIndex).abs() > 1)
        .toList();
    for (final index in stale) {
      _disposePages(_sections.remove(index)!);
    }

    // Image resources used only by evicted sections are often the largest
    // part of a fixed-layout book's memory footprint. Keep exactly the images
    // referenced by the retained current/adjacent page layouts.
    final retainedImages = <String>{
      for (final pages in _sections.values)
        for (final page in pages)
          for (final item in page.items)
            if (item is ImagePlacement) item.href,
    };
    final staleImages = _images.keys
        .where((href) => !retainedImages.contains(href))
        .toList();
    for (final href in staleImages) {
      _images.remove(href)?.dispose();
    }
  }

  static void _disposePages(List<PageLayout> pages) {
    for (final page in pages) {
      page.dispose();
    }
  }

  void _scheduleSave() {
    _progressDirty = true;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), _saveProgress);
  }

  /// Persists the final visible page before the reader is backgrounded or
  /// popped. This avoids losing the last turn while the debounce is pending.
  Future<void> flushProgress() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    if (_progressDirty) await _saveProgress();
  }

  Future<void> _saveProgress() async {
    final source = _source;
    if (source == null) return;
    final book = source.book;
    if (book.sectionCount == 0) return;
    final page = currentPage;
    final progression = page?.progression ?? 0.0;
    final displayedAnchor = page?.firstAnchor;
    // Translation has no character-level original alignment. Persist the
    // canonical paragraph start, never a translated-text offset as original.
    final anchor = displayedAnchor == null
        ? null
        : translationEnabled
        ? SourceAnchor(
            spine: displayedAnchor.spine,
            node: displayedAnchor.node,
            textOffset: 0,
          )
        : displayedAnchor;
    await progressStore.save(
      LocatorV1(
        publicationId: book.id,
        href: book.spine[sectionIndex].href,
        position: sectionIndex,
        progression: progression,
        totalProgression: ((sectionIndex + progression) / book.sectionCount)
            .clamp(0.0, 1.0),
        source: anchor == null ? null : SourceRange(start: anchor, end: anchor),
      ),
    );
    _progressDirty = false;
  }

  static String _baseName(String path) {
    final normalized = path.replaceAll('\\', '/');
    return normalized.substring(normalized.lastIndexOf('/') + 1);
  }

  static String _fileTitle(String path) {
    final normalized = path.replaceAll('\\', '/');
    var name = normalized.substring(normalized.lastIndexOf('/') + 1);
    final dot = name.lastIndexOf('.');
    if (dot > 0) name = name.substring(0, dot);
    return name;
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    opened = false;
    _pageTurnActive = false;
    _translationRefreshTimer?.cancel();
    _translationDirty.clear();
    for (final pages in _retiredPages) {
      _disposePages(pages);
    }
    _retiredPages.clear();
    _textNodeCache.clear();
    _paginationGeneration++;
    _saveTimer?.cancel();
    if (_progressDirty) unawaited(_saveProgress());
    for (final pages in _sections.values) {
      _disposePages(pages);
    }
    _sections.clear();
    for (final image in _images.values) {
      image?.dispose();
    }
    _images.clear();
    final resourceSource = _resourceSource;
    if (resourceSource is DisposableBookSource) {
      (resourceSource as DisposableBookSource).dispose();
    }
    _translationGeneration++;
    _source = null;
    _resourceSource = null;
    _translationSource = null;
    if (_ownsTranslationClient) translationClient.close();
    super.dispose();
  }
}

SectionAnchor? _anchorByFragment(Section section, String fragment) {
  for (final anchor in section.anchors) {
    if (anchor.fragment == fragment) return anchor;
  }
  return null;
}

@visibleForTesting
Future<List<(int, Set<String>)>> linkedFootnoteTranslationCandidates(
  BookSource source,
  int visibleSection,
  Set<String> visibleNodes,
) async {
  final candidates = <int, Set<String>>{
    visibleSection: {...visibleNodes},
  };
  final parsed = <int, Section>{};
  try {
    parsed[visibleSection] = await source.parseSection(visibleSection);
  } catch (_) {
    return candidates.entries
        .map((entry) => (entry.key, entry.value))
        .toList(growable: false);
  }
  final targets = _footnoteTargetsForVisibleNodes(
    parsed[visibleSection]!,
    visibleNodes,
  );
  for (final href in targets) {
    if (isExternalHref(href)) continue;
    final (path, fragment) = splitPackageFragment(href);
    if (fragment == null || fragment.isEmpty) continue;
    final targetSection = source.book.spine.indexWhere(
      (item) => item.href == path,
    );
    if (targetSection < 0) continue;
    Section target;
    try {
      target = parsed[targetSection] ??= await source.parseSection(
        targetSection,
      );
    } catch (_) {
      continue;
    }
    final anchor = _anchorByFragment(target, fragment);
    if (anchor == null) continue;
    final nodes = _translationNodesForFootnoteAnchor(
      target,
      anchor.source.node,
    );
    if (nodes.isNotEmpty) {
      candidates.putIfAbsent(targetSection, () => {}).addAll(nodes);
    }
  }
  return candidates.entries
      .map((entry) => (entry.key, entry.value))
      .toList(growable: false);
}

Set<String> _footnoteTargetsForVisibleNodes(
  Section section,
  Set<String> visibleNodes,
) {
  final targets = <String>{};
  for (final block in section.blocks) {
    _visitBlockText(block, (nodeId, inlines) {
      if (!visibleNodes.contains(nodeId)) return;
      for (final run in inlines.whereType<TextRun>()) {
        if (run.style.linkRole == LinkRole.footnoteReference &&
            run.link != null &&
            run.link!.isNotEmpty) {
          targets.add(run.link!);
        }
      }
    });
  }
  return targets;
}

Set<String> _translationNodesForFootnoteAnchor(
  Section section,
  String anchorNode,
) {
  Block? target;
  for (final block in section.blocks) {
    if (block is NoteBlock && _blockContainsTextNode(block, anchorNode)) {
      target = block;
      break;
    }
  }
  target ??= section.blocks
      .where((block) => _blockContainsTextNode(block, anchorNode))
      .firstOrNull;
  if (target == null) return const <String>{};
  final nodes = <String>{};
  _visitBlockText(target, (nodeId, _) {
    if (nodeId.isNotEmpty) nodes.add(nodeId);
  });
  return nodes;
}

bool _blockContainsTextNode(Block block, String nodeId) {
  var found = false;
  _visitBlockText(block, (candidate, _) {
    if (candidate == nodeId) found = true;
  });
  return found;
}

void _visitBlockText(
  Block block,
  void Function(String nodeId, List<Inline> inlines) visit,
) {
  switch (block) {
    case TextBlock(:final nodeId, :final inlines, :final source):
      visit(source?.start.node ?? nodeId, inlines);
    case QuoteBlock(:final body, :final attribution):
      for (final text in [...body, ?attribution]) {
        visit(text.source?.start.node ?? text.nodeId, text.inlines);
      }
    case TableBlock(:final rows):
      for (final cell in rows.expand((row) => row.cells)) {
        visit(cell.source?.start.node ?? cell.nodeId, cell.inlines);
      }
    case FigureBlock(:final captions):
      for (final caption in captions) {
        visit(caption.source?.start.node ?? caption.nodeId, caption.inlines);
      }
    case NoteBlock(:final blocks):
      for (final child in blocks) {
        _visitBlockText(child, visit);
      }
    case ImageBlock() ||
        SeparatorBlock() ||
        PageBreakBlock() ||
        LineBreakBlock():
      break;
  }
}

String? _textForSourceNode(Section section, String nodeId) {
  return _textForSourceNodeInBlocks(section.blocks, nodeId);
}

String? _textForSourceNodeInBlocks(List<Block> blocks, String nodeId) {
  for (final block in blocks) {
    switch (block) {
      case TextBlock():
        if ((block.source?.start.node ?? block.nodeId) == nodeId) {
          return _readableInlineText(block.inlines);
        }
      case TableBlock():
        for (final row in block.rows) {
          for (final cell in row.cells) {
            if (cell.nodeId == nodeId) return _readableInlineText(cell.inlines);
          }
        }
      case FigureBlock():
        for (final caption in block.captions) {
          if ((caption.source?.start.node ?? caption.nodeId) == nodeId) {
            return _readableInlineText(caption.inlines);
          }
        }
      case QuoteBlock(:final body, :final attribution):
        final text = _textForSourceNodeInBlocks([
          ...body,
          ?attribution,
        ], nodeId);
        if (text != null) return text;
      case NoteBlock(:final blocks):
        final text = _textForSourceNodeInBlocks(blocks, nodeId);
        if (text != null) return text;
      default:
        continue;
    }
  }
  return null;
}

String _readableInlineText(List<Inline> inlines) {
  final buffer = StringBuffer();
  for (final inline in inlines) {
    switch (inline) {
      case TextRun(:final text, :final style):
        if (style.linkRole != LinkRole.footnoteBacklink) buffer.write(text);
      case BreakInline():
        buffer.write('\n');
      case MathInline(:final latex):
        buffer.write(latex);
      case InlineImageRun():
        break;
    }
  }
  return buffer.toString();
}

String _withoutFootnoteMarker(String text, String marker) {
  var result = text.trim();
  final trimmedMarker = marker.trim();
  if (trimmedMarker.isNotEmpty && result.startsWith(trimmedMarker)) {
    result = result.substring(trimmedMarker.length);
  }
  return result.replaceFirst(RegExp(r'^[\s.。．、,，:：;；)）\]】]+'), '').trim();
}
