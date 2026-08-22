import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../../core/formats/formats.dart';
import '../../core/ir/ir.dart';
import '../../core/layout/layout_engine.dart';
import '../../core/layout/layout_types.dart';
import '../progress_store.dart';
import '../sync/derived_data_store.dart';

/// Owns the reading session for one book: the parsed source, paginated
/// sections (prev/current/next cached), page navigation, image decoding,
/// and progress persistence.
class ReaderController extends ChangeNotifier {
  final ProgressStore progressStore;
  final String? titleHint;
  final String? publicationIdHint;
  final LayoutEngine _engine = const LayoutEngine();

  BookSource? _source;
  LayoutViewport _viewport = const LayoutViewport(width: 0, height: 0);
  ReaderStyle _style = const ReaderStyle();

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

  Timer? _saveTimer;
  bool _progressDirty = false;

  ReaderController({
    ProgressStore? progressStore,
    this.titleHint,
    this.publicationIdHint,
  }) : progressStore = progressStore ?? ProgressStore();

  Book get _book => _source!.book;

  List<PageLayout> get currentPages => _sections[sectionIndex] ?? const [];

  PageLayout? get currentPage {
    final pages = currentPages;
    return pageIndex < pages.length ? pages[pageIndex] : null;
  }

  int get sectionCount => _source?.book.sectionCount ?? 0;

  bool _peekPreparing = false;

  /// Table of contents from the book's navigation document (may be empty).
  List<TocEntry> get toc =>
      _derivedToc.isNotEmpty ? _derivedToc : (_source?.book.toc ?? const []);

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
    final bytes = await file.readAsBytes();
    final source = await openBook(
      bytes,
      _baseName(file.path),
      filePath: file.path,
      titleHint: titleHint,
      publicationIdHint: publicationIdHint,
    );
    _source = source;
    _derivedToc = await DerivedDataStore.fromBooksDirectory(
      file.parent,
    ).generatedToc(source.book.id, source.book);
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
  }

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
        if (block is! TextBlock) continue;
        if (block.nodeId == anchor.node) {
          targetOffset = textStart + anchor.textOffset;
          break;
        }
        textStart += block.plainText.length;
      }
      if (targetOffset != null) {
        var match = 0;
        for (var i = 0; i < pages.length; i++) {
          TextPlacement? firstText;
          for (final item in pages[i].items) {
            if (item is TextPlacement) {
              firstText = item;
              break;
            }
          }
          if (firstText == null) continue;
          final pageStart =
              firstText.sectionTextOffset + firstText.textOffsetAtStart;
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
    }
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

    final pagination = _paginateFresh(index);
    _paginations[index] = pagination;
    try {
      return await pagination;
    } finally {
      if (identical(_paginations[index], pagination)) {
        _paginations.remove(index);
      }
    }
  }

  Future<List<PageLayout>> _paginateFresh(int index) async {
    final section = await _source!.parseSection(index);
    await _decodeSectionImages(section);
    await Future<void>.delayed(Duration.zero);
    final pages = _engine.paginate(
      section,
      _viewport,
      _style,
      imageSizeResolver: _imageSize,
    );
    _sections[index] = pages;
    return pages;
  }

  /// Decodes every image referenced by [section]'s blocks into [_images]
  /// (null marks known-missing/undecodable). No-op for cached hrefs.
  Future<void> _decodeSectionImages(Section section) async {
    final hrefs = <String>{
      for (final block in section.blocks)
        if (block is ImageBlock && !_images.containsKey(block.href)) block.href,
    };
    if (hrefs.isEmpty) return;
    await Future.wait(
      hrefs.map((href) async {
        try {
          final bytes = await _source!.resource(href);
          _images[href] = bytes == null
              ? null
              : await decodeImageFromList(bytes);
        } catch (_) {
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

  /// Disposes and drops paginated sections outside [sectionIndex] ± 1.
  /// Each PageLayout of a section is disposed exactly once, which is the
  /// correct eviction for the shared ParagraphDisposalPool.
  void _evictDistantSections() {
    final stale = _sections.keys
        .where((index) => (index - sectionIndex).abs() > 1)
        .toList();
    for (final index in stale) {
      for (final page in _sections.remove(index)!) {
        page.dispose();
      }
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
    _saveTimer?.cancel();
    if (_progressDirty) unawaited(_saveProgress());
    for (final pages in _sections.values) {
      for (final page in pages) {
        page.dispose();
      }
    }
    _sections.clear();
    for (final image in _images.values) {
      image?.dispose();
    }
    _images.clear();
    super.dispose();
  }
}
