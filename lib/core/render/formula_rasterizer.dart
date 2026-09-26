import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart' as fw;
import 'package:flutter/rendering.dart';
import 'package:flutter_math_fork/flutter_math.dart' as fm;
import '../ir/ir.dart';
import '../ir/inline_content.dart';
import '../semantic_layout/formula_validation.dart';

class FormulaRaster {
  final String href;
  final ui.Image image;
  final double width, height, baseline;
  const FormulaRaster(
    this.href,
    this.image,
    this.width,
    this.height,
    this.baseline,
  );
}

class _MathBoundary extends RenderRepaintBoundary {
  double? baseline;
  @override
  void performLayout() {
    super.performLayout();
    baseline = child?.getDistanceToBaseline(
      TextBaseline.alphabetic,
      onlyReal: true,
    );
  }
}

/// Rasterizes Flutter math into the reader's existing Canvas/image pipeline.
/// Live page rasters are never evicted underneath retained page frames. Once
/// the bounded session budget is exhausted new formulas use their originals.
class FormulaRasterizer {
  static const em = 32.0;
  final Map<String, FormulaRaster> _cache = {};
  final Set<String> _failed = {};
  final Map<String, Future<FormulaRaster?>> _pending = {};
  int _bytes = 0;
  bool _disposed = false;
  static String key(MathInline value, int color) =>
      'torto-formula:${sha256.convert(utf8.encode(jsonEncode([value.latex, value.display, value.equationNumber, color])))}';
  FormulaRaster? lookup(MathInline value, int color) =>
      _cache[key(value, color)];
  ui.Image? image(String href) => _cache[href]?.image;
  Future<FormulaRaster?> render(MathInline value, int color) async {
    final href = key(value, color);
    if (_disposed || _failed.contains(href)) return null;
    if (_cache.containsKey(href)) return _cache[href];
    return _pending
        .putIfAbsent(href, () => _render(value, color, href))
        .whenComplete(() => _pending.remove(href));
  }

  Future<FormulaRaster?> _render(
    MathInline value,
    int color,
    String href,
  ) async {
    if (_bytes >= 32 * 1024 * 1024 || formulaError(value.latex) != null) {
      _failed.add(href);
      return null;
    }
    final boundary = _MathBoundary();
    final pipeline = PipelineOwner();
    final focus = fw.FocusManager();
    final owner = fw.BuildOwner(focusManager: focus);
    final view = RenderView(
      view: ui.PlatformDispatcher.instance.views.first,
      configuration: const ViewConfiguration(
        logicalConstraints: BoxConstraints.tightFor(width: 4096, height: 1024),
        physicalConstraints: BoxConstraints.tightFor(width: 4096, height: 1024),
        devicePixelRatio: 1,
      ),
      child: RenderPositionedBox(alignment: Alignment.topLeft, child: boundary),
    );
    pipeline.rootNode = view;
    view.prepareInitialFrame();
    var failed = false;
    fw.Widget formula = fm.Math.tex(
      value.latex,
      settings: formulaParserSettings,
      mathStyle: value.display ? fm.MathStyle.display : fm.MathStyle.text,
      textStyle: fw.TextStyle(fontSize: em, color: ui.Color(color)),
      onErrorFallback: (_) {
        failed = true;
        return const fw.SizedBox.shrink();
      },
    );
    if (value.display) {
      formula = fw.Padding(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
        child: formula,
      );
    }
    final number = value.equationNumber;
    if (number != null && number.isNotEmpty) {
      formula = fw.Row(
        mainAxisSize: fw.MainAxisSize.min,
        children: [
          formula,
          fw.Padding(
            padding: const EdgeInsets.only(left: 16),
            child: fw.Text(
              number,
              style: fw.TextStyle(fontSize: em * 0.8, color: ui.Color(color)),
            ),
          ),
        ],
      );
    }
    final element = fw.RenderObjectToWidgetAdapter<RenderBox>(
      container: boundary,
      child: fw.Directionality(
        textDirection: ui.TextDirection.ltr,
        child: formula,
      ),
    ).attachToRenderTree(owner);
    try {
      owner.buildScope(element);
      pipeline.flushLayout();
      pipeline.flushCompositingBits();
      pipeline.flushPaint();
      final size = boundary.size;
      if (failed ||
          size.isEmpty ||
          !size.width.isFinite ||
          !size.height.isFinite ||
          size.width >= 4096 ||
          size.height >= 1024) {
        _failed.add(href);
        return null;
      }
      final baseline = boundary.baseline ?? size.height * .8;
      final scale = math.min(
        2.0,
        math.sqrt(4 * 1024 * 1024 / (size.width * size.height)),
      );
      // Do not leave a temporary render tree attached across an async gap:
      // system-font callbacks must never target a half-torn-down tree.
      final image = boundary.toImageSync(pixelRatio: scale);
      if (_disposed ||
          _bytes + image.width * image.height * 4 > 32 * 1024 * 1024) {
        image.dispose();
        return null;
      }
      final raster = FormulaRaster(
        href,
        image,
        size.width,
        size.height,
        baseline,
      );
      _cache[href] = raster;
      _bytes += image.width * image.height * 4;
      return raster;
    } on Object {
      _failed.add(href);
      return null;
    } finally {
      pipeline.rootNode = null;
      fw.RenderObjectToWidgetAdapter<RenderBox>(
        container: boundary,
        child: const fw.SizedBox.shrink(),
      ).attachToRenderTree(owner, element);
      owner.buildScope(element);
      owner.finalizeTree();
      view.dispose();
      pipeline.dispose();
      focus.dispose();
    }
  }

  Future<void> prepare(Section section, int color) async {
    final math = <MathInline>[];
    for (final block in section.blocks) {
      mapBlockContent(
        block,
        (text) {
          math.addAll(text.inlines.whereType<MathInline>());
          return text;
        },
        image: (image) {
          if (image.formula != null) {
            math.add(image.formula!);
            math.add(
              MathInline(
                image.formula!.latex,
                display: true,
                equationNumber: image.formula!.equationNumber,
                originalImage: image.href,
              ),
            );
          }
          return image;
        },
      );
    }
    for (final value in math) {
      if (_disposed) return;
      await render(value, color);
    }
  }

  void dispose() {
    _disposed = true;
    for (final entry in _cache.values) {
      entry.image.dispose();
    }
    _cache.clear();
  }
}
