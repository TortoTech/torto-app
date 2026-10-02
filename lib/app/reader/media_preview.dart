import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart' as fm;
import '../../l10n/app_localizations.dart';

Future<void> _showMediaOverlay(BuildContext context, WidgetBuilder builder) =>
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: Colors.black.withValues(alpha: .65),
      transitionDuration: const Duration(milliseconds: 160),
      pageBuilder: (context, _, _) => SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(size: constraints.biggest, padding: EdgeInsets.zero),
            child: Material(
              type: MaterialType.transparency,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.pop(context),
                child: InteractiveViewer(
                  minScale: .5,
                  maxScale: 8,
                  clipBehavior: Clip.none,
                  boundaryMargin: const EdgeInsets.all(24),
                  child: SizedBox.expand(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Center(
                        child: GestureDetector(
                          onTap: () {},
                          child: Builder(builder: builder),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

/// The overlay owns no texture: the caller disposes it after this route closes.
Future<void> showReaderImagePreview(
  BuildContext context,
  Future<ui.Image?> image, {
  bool formula = false,
}) => _showMediaOverlay(
  context,
  (context) => FutureBuilder<ui.Image?>(
    future: image,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const SizedBox(
          width: 36,
          height: 36,
          child: CircularProgressIndicator(),
        );
      }
      final raster = snapshot.data;
      if (snapshot.hasError || raster == null) {
        return Text(
          context.l10n.text('无法读取图片', 'Could not load image'),
          style: const TextStyle(color: Colors.white),
        );
      }
      final viewport = MediaQuery.sizeOf(context),
          padding = MediaQuery.paddingOf(context);
      final scale = math.min(
        (viewport.width - 40) / raster.width,
        (viewport.height - padding.vertical - 40) / raster.height,
      );
      Widget content = SizedBox(
        key: const Key('reader-image-preview'),
        width: raster.width * scale,
        height: raster.height * scale,
        child: RawImage(
          image: raster,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.high,
        ),
      );
      if (formula) content = ColoredBox(color: Colors.white, child: content);
      return content;
    },
  ),
);

Future<void> showReaderFormulaPreview(BuildContext context, String latex) =>
    _showMediaOverlay(
      context,
      (context) => ColoredBox(
        key: const Key('reader-formula-preview'),
        color: Colors.white,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.sizeOf(context).width - 80,
              maxHeight: MediaQuery.sizeOf(context).height * .7,
            ),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: fm.Math.tex(
                latex,
                textStyle: const TextStyle(fontSize: 24, color: Colors.black),
                onErrorFallback: (_) =>
                    Text(latex, style: const TextStyle(color: Colors.black)),
              ),
            ),
          ),
        ),
      ),
    );
