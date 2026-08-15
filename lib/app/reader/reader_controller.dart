import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../../core/epub/epub_book_source.dart';
import '../../core/ir/ir.dart';
import '../../core/layout/layout_engine.dart';
import '../../core/layout/layout_types.dart';
import '../progress_store.dart';

/// Owns the reading session for one book: the parsed source, paginated
/// sections (prev/current/next cached), page navigation, image decoding,
/// and progress persistence.
class ReaderController extends ChangeNotifier {
  final ProgressStore progressStore;
  final LayoutEngine _engine = const LayoutEngine();

  EpubBookSource? _source;
  LayoutViewport _viewport = const LayoutViewport(width: 0, height: 0);
  ReaderStyle _style = const ReaderStyle();

  /// Paginated sections, kept only for [sectionIndex] ± 1.
  final Map<int, List<PageLayout>> _sections = {};

  /// Decoded images by package href; null values mark known-missing.
  final Map<String, ui.Image?> _images = {};

  int sectionIndex = 0;
  int pageIndex = 0;

  /// True while a section is being paginated/decoded.
  bool busy = false;

  /// True once [open] has completed successfully.
  bool opened = false;

  String title = '';

  Timer? _saveTimer;

  ReaderController({ProgressStore? progressStore})
      : progressStore = progressStore ?? ProgressStore();

  Book get _book => _source!.book;

  List<PageLayout> get currentPages =>
      _sections[sectionIndex] ?? const [];

  PageLayout? get currentPage {
    final pages = currentPages;
    return pageIndex < pages.length ? pages[pageIndex] : null;
  }

  int get sectionCount => _source?.book.sectionCount ?? 0;

  double get totalProgression {
    final count = sectionCount;
    if (count == 0) return 0;
    return ((sectionIndex + (currentPage?.progression ?? 0)) / count)
        .clamp(0.0, 1.0);
  }

  /// Synchronous image resolver handed to the render stage.
  ui.Image? resolveImage(String href) => _images[href];

  /// Opens [file], restores the saved position (if any), and paginates the
  /// starting section. Throws when the file is not a readable EPUB.
  Future<void> open(
      File file, LayoutViewport viewport, ReaderStyle style) async {
    _viewport = viewport;
    _style = style;
    final bytes = await file.readAsBytes();
    final source = await EpubBookSource.fromBytes(bytes);
    _source = source;
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

  /// Moves to the adjacent non-empty section, paginating on demand.
  /// Forward lands on the first page, backward on the LAST page.
  Future<void> _stepSection(int direction) async {
    busy = true;
    notifyListeners();
    try {
      final count = _book.sectionCount;
      for (var i = sectionIndex + direction;
          i >= 0 && i < count;
          i += direction) {
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

  /// Parses and paginates section [index] (cached), then pre-decodes any
  /// images its pages reference. Yields the event loop before the
  /// synchronous layout work so a busy indicator can paint.
  Future<List<PageLayout>> _paginate(int index) async {
    final cached = _sections[index];
    if (cached != null) return cached;
    final section = await _source!.parseSection(index);
    await Future<void>.delayed(Duration.zero);
    final pages = _engine.paginate(
      section,
      _viewport,
      _style,
      imageSizeResolver: _imageSize,
    );
    _sections[index] = pages;
    await _preloadImages(pages);
    return pages;
  }

  ui.Size? _imageSize(String href) {
    final image = _images[href];
    if (image == null) return null;
    return ui.Size(image.width.toDouble(), image.height.toDouble());
  }

  Future<void> _preloadImages(List<PageLayout> pages) async {
    final hrefs = <String>{};
    for (final page in pages) {
      for (final item in page.items) {
        if (item is ImagePlacement && !_images.containsKey(item.href)) {
          hrefs.add(item.href);
        }
      }
    }
    if (hrefs.isEmpty) return;
    await Future.wait(hrefs.map((href) async {
      try {
        final bytes = await _source!.resource(href);
        _images[href] = bytes == null ? null : await decodeImageFromList(bytes);
      } catch (_) {
        _images[href] = null; // missing or undecodable: render without it
      }
    }));
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
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), _saveProgress);
  }

  Future<void> _saveProgress() async {
    final source = _source;
    if (source == null) return;
    final book = source.book;
    if (book.sectionCount == 0) return;
    final page = currentPage;
    final progression = page?.progression ?? 0.0;
    final anchor = page?.firstAnchor;
    await progressStore.save(LocatorV1(
      publicationId: book.id,
      href: book.spine[sectionIndex].href,
      position: sectionIndex,
      progression: progression,
      totalProgression:
          ((sectionIndex + progression) / book.sectionCount).clamp(0.0, 1.0),
      source: anchor == null
          ? null
          : SourceRange(start: anchor, end: anchor),
    ));
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
    for (final pages in _sections.values) {
      for (final page in pages) {
        page.dispose();
      }
    }
    _sections.clear();
    super.dispose();
  }
}
