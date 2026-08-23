import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/ir/style.dart' show LinkRole;
import '../../core/layout/layout_types.dart';
import '../../core/render/page_painter.dart';
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

  const ReaderPage({
    super.key,
    required this.file,
    this.controller,
    this.preferencesStore,
  });

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

enum _TurnPhase { idle, dragging, animating }

enum _TurnDirection { previous, next }

class _ReaderPageState extends State<ReaderPage> with TickerProviderStateMixin {
  static const ReaderStyle _baseStyle = ReaderStyle(
    baseFontSize: 18,
    lineHeight: 1.5,
    marginTop: 32,
    marginBottom: 32,
    marginLeft: 24,
    marginRight: 24,
  );
  static const _background = Color(0xFFFAF8F3);
  static const _foreground = Color(0xFF000000);

  ReaderController? _controller;
  late final ReaderPreferencesStore _preferencesStore;
  ReaderStyle _style = _baseStyle;
  bool _ownsController = false;
  bool _opening = false;
  bool _overlayVisible = false;
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  _TurnPhase _turnPhase = _TurnPhase.idle;
  _TurnDirection? _turnDirection;

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
    _preferencesStore = widget.preferencesStore ?? ReaderPreferencesStore();
  }

  void _startOpen(LayoutViewport viewport) {
    final controller = widget.controller ?? ReaderController();
    _controller = controller;
    _ownsController = widget.controller == null;
    if (controller.opened) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {});
        _schedulePeekPreparation();
      });
      return;
    }
    if (_opening) return;
    _opening = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final mode = await _preferencesStore.loadTypesettingMode();
        if (!mounted) return;
        _style = _baseStyle.copyWith(typesettingMode: mode);
        await controller.open(widget.file, viewport, _style);
        // open() may finish before the ListenableBuilder below ever
        // entered the tree (the first build returns the plain spinner),
        // so its notifyListeners() reached no one. Rebuild to swap in
        // the real reader now that a controller exists.
        if (mounted) setState(() {});
        _schedulePeekPreparation();
      } catch (error, stackTrace) {
        debugPrint('Could not open ${widget.file.path}: $error\n$stackTrace');
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open this book.')),
        );
        Navigator.of(context).pop();
      } finally {
        _opening = false;
      }
    });
  }

  @override
  void dispose() {
    _peekTimer?.cancel();
    _turnAnimation?.dispose();
    if (_ownsController) _controller?.dispose();
    super.dispose();
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
    final controller = _controller;
    if (controller == null ||
        controller.busy ||
        _turnPhase != _TurnPhase.idle) {
      return;
    }
    final link = controller.currentPage?.linkAt(details.localPosition);
    if (link != null) {
      unawaited(_activateLink(controller, link));
      return;
    }
    final fraction = details.localPosition.dx / width;
    if (fraction < 0.3) {
      if (_overlayVisible) setState(() => _overlayVisible = false);
      controller.prevPage().then((_) => _schedulePeekPreparation());
    } else if (fraction > 0.7) {
      if (_overlayVisible) setState(() => _overlayVisible = false);
      controller.nextPage().then((_) => _schedulePeekPreparation());
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('无法读取脚注内容')));
        return;
      }
      await showModalBottomSheet<void>(
        context: context,
        backgroundColor: _background,
        showDragHandle: true,
        builder: (context) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (note.marker.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Text(
                      '脚注 ${note.marker}',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                SelectableText(
                  note.text,
                  style: const TextStyle(fontSize: 17, height: 1.55),
                ),
              ],
            ),
          ),
        ),
      );
      return;
    }

    final navigated = await controller.goToHref(link.href);
    if (!mounted) return;
    if (navigated) {
      _schedulePeekPreparation();
    } else {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('暂时无法打开此引用')));
    }
  }

  // ---- Drag-driven page turning -------------------------------------------

  void _onDragStart(DragStartDetails _, ReaderController controller) {
    final continuingRapidTurn = _turnPhase == _TurnPhase.animating;
    if (continuingRapidTurn) {
      // Complete the stable endpoint first, then let this pointer sequence
      // immediately control the following page. Ignoring it made fast
      // readers perceive every other swipe as lost.
      _finishTurn(controller);
    }
    if ((!continuingRapidTurn && controller.busy) ||
        _turnPhase != _TurnPhase.idle) {
      return;
    }
    _peekTimer?.cancel();
    setState(() {
      _turnPhase = _TurnPhase.dragging;
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
    final targetReady = controller.peekPage(pageOffset) != null;
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
    final pageOffset = direction == _TurnDirection.next ? 1 : -1;
    final hasTarget = controller.canPeek(pageOffset);
    final expectedVelocitySign = direction == _TurnDirection.next ? -1.0 : 1.0;
    final fling = velocity.abs() > 350 && velocity.sign == expectedVelocitySign;
    final draggedFar = _dragExtent.abs() > width * 0.25;
    _animateTurn(hasTarget && (fling || draggedFar), controller, width);
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
    final to = commit
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

    if (!committed || direction == null) {
      if (mounted) setState(() {});
      _schedulePeekPreparation();
      return;
    }
    final turn = direction == _TurnDirection.next
        ? controller.nextPage()
        : controller.prevPage();
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
    if (!mounted) return;
    setState(() {
      _turnPhase = _TurnPhase.idle;
      _turnDirection = null;
      _dragExtent = 0;
      _visualOffset = 0;
      _animationFrom = 0;
      _animationTo = 0;
      _animationCommits = false;
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
        ? const ColoredBox(color: _background)
        : PageWidget(
            page: layout,
            imageResolver: imageResolver,
            background: _background,
            foreground: _foreground,
          );

    Widget ridingPage(PageLayout? layout, double left) => Positioned(
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
        child: page(layout),
      ),
    );

    if (direction == _TurnDirection.previous) {
      return Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          Positioned.fill(child: page(current)),
          ridingPage(neighbour, -width + offset),
        ],
      );
    }

    return Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        Positioned.fill(child: page(neighbour)),
        ridingPage(current, offset),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: _background,
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
                    return const Center(child: CircularProgressIndicator());
                  }
                  return ListenableBuilder(
                    listenable: controller,
                    builder: (context, _) =>
                        _buildReader(controller!, constraints),
                  );
                },
              ),
            ),
          ),
          if (_overlayVisible) ...[_buildReaderHeader(), _buildReaderFooter()],
        ],
      ),
    );
  }

  Widget _buildReaderHeader() => Positioned(
    top: 0,
    left: 0,
    right: 0,
    child: Material(
      key: const Key('reader-header'),
      color: _background,
      elevation: 2,
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 56,
          child: Row(
            children: [
              IconButton(
                key: const Key('reader-back-button'),
                icon: const Icon(Icons.arrow_back),
                tooltip: '返回书架',
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _buildReaderFooter() => Positioned(
    bottom: 0,
    left: 0,
    right: 0,
    child: Material(
      key: const Key('reader-footer'),
      color: _background,
      elevation: 2,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 56,
          child: Row(
            children: [
              IconButton(
                key: const Key('reader-toc-button'),
                icon: const Icon(Icons.format_list_bulleted),
                tooltip: '目录',
                onPressed: () => _scaffoldKey.currentState?.openDrawer(),
              ),
              IconButton(
                key: const Key('reader-style-button'),
                icon: const Icon(Icons.text_format),
                tooltip: '版式',
                onPressed: _showTypesettingSheet,
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Future<void> _showTypesettingSheet() async {
    final controller = _controller;
    if (controller == null || controller.busy) return;
    final selected = await showModalBottomSheet<TypesettingMode>(
      context: context,
      backgroundColor: _background,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  '版式',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                ),
              ),
              _typesettingChoice(
                context,
                TypesettingMode.unified,
                '统一版式',
                '统一正文、标题、段落、列表和表格的排版',
              ),
              _typesettingChoice(
                context,
                TypesettingMode.book,
                '跟随书籍',
                '保留书籍自带的字号、行距、缩进和颜色',
              ),
            ],
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

  Widget _buildReader(ReaderController controller, BoxConstraints constraints) {
    final page = controller.currentPage;
    final width = constraints.maxWidth;
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (details) => _handleTap(details, width),
            onHorizontalDragStart: (details) =>
                _onDragStart(details, controller),
            onHorizontalDragUpdate: (details) =>
                _onDragUpdate(details, controller, width),
            onHorizontalDragEnd: (details) =>
                _onDragEnd(details, controller, width),
            onHorizontalDragCancel: () => _onDragCancel(controller, width),
            child: _turnDirection != null
                ? _buildTurnScene(controller, width)
                : (page == null
                      ? const SizedBox.expand()
                      : PageWidget(
                          page: page,
                          imageResolver: controller.resolveImage,
                          background: _background,
                          foreground: _foreground,
                        )),
          ),
        ),
        if (controller.busy) const Center(child: CircularProgressIndicator()),
      ],
    );
  }
}
