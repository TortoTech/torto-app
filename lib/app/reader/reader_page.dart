import 'dart:async';
import 'dart:io';

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
    if (controller.opened) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        // An injected, already-open controller can render immediately while
        // the persisted presentation preferences are being restored.
        if (mounted) setState(() {});
        await _restorePreferences();
        if (!mounted) return;
        _applySystemUiStyle();
        await controller.updateStyle(_style);
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
        await _restorePreferences();
        if (!mounted) return;
        _applySystemUiStyle();
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
    final mode = await modeFuture;
    final darkMode = appPreferences == null
        ? await _preferencesStore.loadDarkMode()
        : inheritedDarkMode;
    _darkMode = darkMode;
    _style = _themedStyle(_baseStyle.copyWith(typesettingMode: mode), darkMode);
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
    _peekTimer?.cancel();
    _turnAnimation?.dispose();
    if (_ownsController) _controller?.dispose();
    SystemChrome.setSystemUIOverlayStyle(_systemUiStyle(darkMode: false));
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
    if (fraction < 0.2) {
      if (_overlayVisible) setState(() => _overlayVisible = false);
      controller.prevPage().then((_) => _schedulePeekPreparation());
    } else if (fraction > 0.8) {
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.l10n.text('无法读取脚注内容', 'Could not read this footnote'),
            ),
          ),
        );
        return;
      }
      await showReaderFootnoteSheet(
        context,
        text: note.text,
        background: _chromeBackground,
        foreground: _chromeForeground,
        publicationLanguage: controller.publicationLanguage,
      );
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
        ? ColoredBox(color: _background)
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
    final background = _background;
    final foreground = _foreground;
    final systemOverlay = _systemUiStyle(darkMode: _darkMode);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: systemOverlay,
      child: Theme(
        data: _readerThemeData(Theme.of(context), background, foreground),
        child: Scaffold(
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
              if (_overlayVisible) ...[
                _buildReaderHeader(),
                _buildReaderFooter(),
              ],
            ],
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
      color: _chromeBackground,
      surfaceTintColor: Colors.transparent,
      elevation: 2,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 56,
          child: Row(
            children: [
              IconButton(
                key: const Key('reader-toc-button'),
                iconSize: 32,
                constraints: const BoxConstraints.tightFor(
                  width: 64,
                  height: 56,
                ),
                icon: Icon(
                  Icons.format_list_bulleted,
                  color: _chromeForeground,
                ),
                tooltip: context.l10n.text('目录', 'Contents'),
                onPressed: () => _scaffoldKey.currentState?.openDrawer(),
              ),
              IconButton(
                key: const Key('reader-style-button'),
                iconSize: 32,
                constraints: const BoxConstraints.tightFor(
                  width: 64,
                  height: 56,
                ),
                icon: Icon(Icons.text_format, color: _chromeForeground),
                tooltip: context.l10n.text('版式', 'Typesetting'),
                onPressed: _showTypesettingSheet,
              ),
              _buildTranslationButton(),
              IconButton(
                key: const Key('reader-theme-button'),
                iconSize: 32,
                constraints: const BoxConstraints.tightFor(
                  width: 64,
                  height: 56,
                ),
                icon: Icon(
                  _darkMode
                      ? Icons.light_mode_outlined
                      : Icons.dark_mode_outlined,
                  color: _chromeForeground,
                ),
                tooltip: _darkMode
                    ? context.l10n.text('浅色模式', 'Light mode')
                    : context.l10n.text('深色模式', 'Dark mode'),
                onPressed: _toggleColorMode,
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
