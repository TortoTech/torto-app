import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../../core/formats/formats.dart';
import '../../core/html_ir/package_path.dart';
import '../../core/ir/ir.dart';
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
  bool _tocTranslationInFlight = false;
  int _translationGeneration = 0;
  String? translationError;
  final Map<int, String> _translatedTocLabels = {};

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
    _viewport = viewport;
    _style = style;
    final fileName = _baseName(file.path);
    final format = BookFormat.fromFileName(fileName);
    _format = format;
    final BookSource source;
    if (format == BookFormat.epub) {
      source = await EpubBookSource.fromFileInBackground(
        file.path,
        publicationIdHint: publicationIdHint,
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
    _resourceSource = source;
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

    final locator = await progressStore.load(_book.id);
    final count = _book.sectionCount;
    var start = 0;
    if (locator != null && count > 0) {
      start = locator.position.clamp(0, count - 1);
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
      opened = true;
    } finally {
      busy = false;
      notifyListeners();
    }
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
    translationEnabled = true;
    source
      ..mode = translation.mode
      ..targetLanguageCode = languageCode
      ..enabled = true;
    notifyListeners();
    _queueVisibleTranslation();
    _queueTocTranslation();
    return true;
  }

  void retryTranslation() {
    if (!translationEnabled) return;
    translationError = null;
    _queueVisibleTranslation();
    _queueTocTranslation();
  }

  void _queueVisibleTranslation() {
    if (!translationEnabled || _translationInFlight || busy) return;
    final source = _translationSource;
    final settings = _activeAiSettings;
    final page = currentPage;
    if (source == null || settings == null || page == null) return;
    final visibleNodes = <String>{};
    for (final item in page.items) {
      final nodeId = switch (item) {
        TextPlacement(:final nodeId) => nodeId,
        TableCellPlacement(:final nodeId) => nodeId,
        _ => '',
      };
      if (nodeId.isNotEmpty) visibleNodes.add(nodeId);
    }
    if (visibleNodes.isEmpty) return;
    final generation = _translationGeneration;
    final requestedSection = sectionIndex;
    _translationInFlight = true;
    translationError = null;
    notifyListeners();
    unawaited(() async {
      var succeeded = false;
      try {
        final blocks = await source.untranslatedBlocksForNodes(
          requestedSection,
          visibleNodes,
        );
        if (blocks.isEmpty) return;
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
        );
        if (generation != _translationGeneration || !translationEnabled) return;
        await source.storeBatch(requestedSection, results);
        if (generation != _translationGeneration || !translationEnabled) return;
        succeeded = true;
        if (sectionIndex == requestedSection && !busy) {
          await _refreshCurrentSectionPreservingPosition();
        }
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
          notifyListeners();
          if (succeeded && translationEnabled) {
            _queueVisibleTranslation();
          }
        }
      }
    }());
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
            item.nodeId == anchor.node &&
            item.textOffsetAtStart <= anchor.textOffset) {
          match = index;
        } else if (item is TableCellPlacement && item.nodeId == anchor.node) {
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
  /// Anchor rule: map the saved `source.start` (node id + UTF-16 offset) to
  /// the section-wide text offset, then take the LAST page whose first text
  /// starts at or before that offset — i.e. the page whose text range
  /// contains (or reaches) the anchor. Falls back to
  /// `progression × page count` when the anchor node is gone.
  Future<int> _restorePageIndex(int section, LocatorV1 locator) async {
    final pages = _sections[section] ?? const [];
    if (pages.isEmpty) return 0;

    final anchor = locator.source?.start;
    if (anchor != null) {
      final parsed = await _source!.parseSection(section);
      var textStart = 0.0;
      double? targetOffset;
      for (final block in parsed.blocks) {
        switch (block) {
          case TextBlock():
            if (block.nodeId == anchor.node) {
              targetOffset = textStart + anchor.textOffset;
            }
            textStart += block.plainText.length;
          case TableBlock():
            for (final row in block.rows) {
              for (final cell in row.cells) {
                if (cell.nodeId == anchor.node) {
                  targetOffset = textStart + anchor.textOffset;
                }
                textStart += cell.plainText.length;
              }
            }
          case FigureBlock():
            for (final caption in block.captions) {
              if (caption.nodeId == anchor.node) {
                targetOffset = textStart + anchor.textOffset;
              }
              textStart += caption.plainText.length;
            }
          default:
            continue;
        }
        if (targetOffset != null) break;
      }
      if (targetOffset != null) {
        var match = 0;
        for (var i = 0; i < pages.length; i++) {
          double? pageStart;
          for (final item in pages[i].items) {
            switch (item) {
              case TextPlacement():
                pageStart = item.sectionTextOffset + item.textOffsetAtStart;
              case TableCellPlacement():
                pageStart = item.sectionTextOffset;
              default:
                continue;
            }
            break;
          }
          if (pageStart == null) continue;
          if (pageStart <= targetOffset + 0.5) {
            match = i;
          } else {
            break;
          }
        }
        return match;
      }
    }

    final maxIndex = pages.length - 1;
    return (locator.progression * maxIndex).round().clamp(0, maxIndex);
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
    if (busy || !opened || _peekPreparing) return;
    _peekPreparing = true;
    try {
      var paginatedAny = false;
      for (final direction in const [-1, 1]) {
        while (true) {
          final section = _peekCoordinate(direction).$1;
          if (section < 0 || _sections.containsKey(section)) break;
          await _paginate(section);
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
    final section = await _source!.parseSection(index);
    await Future.wait([
      _decodeSectionImages(section),
      EnglishHyphenator.instance.ensureLoadedForSection(
        section,
        publicationLanguage: _style.publicationLanguage,
      ),
    ]);
    await Future<void>.delayed(Duration.zero);
    final pages = _engine.paginate(
      section,
      _viewport,
      _style,
      imageSizeResolver: _imageSize,
      coverHref: _book.coverHref,
      renditionLayout: _book.metadata.layout,
    );
    if (generation != _paginationGeneration) {
      _disposePages(pages);
      return _sections[index] ?? const [];
    }
    _sections[index] = pages;
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
    for (final block in section.blocks) {
      switch (block) {
        case ImageBlock():
          if (!_images.containsKey(block.href)) hrefs.add(block.href);
        case FigureBlock():
          for (final image in block.images) {
            if (!_images.containsKey(image.href)) hrefs.add(image.href);
          }
        default:
          continue;
      }
    }
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
    final anchor = page?.firstAnchor;
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
  void dispose() {
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

String? _textForSourceNode(Section section, String nodeId) {
  return _textForSourceNodeInBlocks(section.blocks, nodeId);
}

String? _textForSourceNodeInBlocks(List<Block> blocks, String nodeId) {
  for (final block in blocks) {
    switch (block) {
      case TextBlock():
        if (block.nodeId == nodeId) return _readableInlineText(block.inlines);
      case TableBlock():
        for (final row in block.rows) {
          for (final cell in row.cells) {
            if (cell.nodeId == nodeId) return _readableInlineText(cell.inlines);
          }
        }
      case FigureBlock():
        for (final caption in block.captions) {
          if (caption.nodeId == nodeId) {
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
