import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/layout/layout_types.dart';
import '../../core/render/page_painter.dart';
import 'reader_controller.dart';

/// Full-screen reading view: tap zones / swipe to turn pages, center tap
/// toggles a minimal overlay (title + close on top, position on the bottom).
class ReaderPage extends StatefulWidget {
  final File file;

  /// Injectable for tests; a fresh controller is created when omitted.
  final ReaderController? controller;

  const ReaderPage({super.key, required this.file, this.controller});

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  static const ReaderStyle _style = ReaderStyle(
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
  bool _ownsController = false;
  bool _overlayVisible = false;

  void _startOpen(LayoutViewport viewport) {
    final controller = widget.controller ?? ReaderController();
    _controller = controller;
    _ownsController = widget.controller == null;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await controller.open(widget.file, viewport, _style);
      } catch (_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open this book.')),
        );
        Navigator.of(context).pop();
      }
    });
  }

  @override
  void dispose() {
    if (_ownsController) _controller?.dispose();
    super.dispose();
  }

  void _handleTap(TapUpDetails details, double width) {
    final controller = _controller;
    if (controller == null) return;
    final fraction = details.localPosition.dx / width;
    if (fraction < 0.3) {
      controller.prevPage();
    } else if (fraction > 0.7) {
      controller.nextPage();
    } else {
      setState(() => _overlayVisible = !_overlayVisible);
    }
  }

  void _handleSwipe(DragEndDetails details) {
    final controller = _controller;
    if (controller == null) return;
    final velocity = details.primaryVelocity ?? 0;
    if (velocity < 0) {
      controller.nextPage(); // swipe left → forward
    } else if (velocity > 0) {
      controller.prevPage();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _background,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            var controller = _controller;
            if (controller == null) {
              _startOpen(LayoutViewport(
                width: constraints.maxWidth,
                height: constraints.maxHeight,
              ));
              controller = _controller;
              return const Center(child: CircularProgressIndicator());
            }
            return ListenableBuilder(
              listenable: controller,
              builder: (context, _) => _buildReader(controller!, constraints),
            );
          },
        ),
      ),
    );
  }

  Widget _buildReader(ReaderController controller, BoxConstraints constraints) {
    final page = controller.currentPage;
    final percent = (controller.totalProgression * 100).round();
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            onTapUp: (details) => _handleTap(details, constraints.maxWidth),
            onHorizontalDragEnd: _handleSwipe,
            child: page == null
                ? const SizedBox.expand()
                : PageWidget(
                    page: page,
                    imageResolver: controller.resolveImage,
                    background: _background,
                    foreground: _foreground,
                  ),
          ),
        ),
        if (controller.busy)
          const Center(child: CircularProgressIndicator()),
        if (_overlayVisible) ...[
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Material(
              color: _background,
              elevation: 2,
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  Expanded(
                    child: Text(
                      controller.title,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 16),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Material(
              color: _background,
              elevation: 2,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Text(
                  'section ${controller.sectionIndex + 1}/${controller.sectionCount} · $percent%',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
