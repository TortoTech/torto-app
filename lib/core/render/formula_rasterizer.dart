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

class FormulaMetrics {
  final String href;
  final double width, height, baseline;
  const FormulaMetrics(this.href, this.width, this.height, this.baseline);
}

class FormulaRaster extends FormulaMetrics {
  final ui.Image image;
  const FormulaRaster(
    String href,
    this.image,
    double width,
    double height,
    double baseline,
  ) : super(href, width, height, baseline);
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
/// Dimensions stay stable; the reader retains visible textures and reclaims
/// off-screen pixels within a bounded session budget.
class FormulaRasterizer {
  static const em = 32.0;
  final Map<String, FormulaRaster> _cache = {};
  final Map<String, FormulaMetrics> _geometry = {};
  final Map<String, (MathInline, int)> _recipes = {};
  final Set<String> _failed = {};
  final Map<String, Future<FormulaRaster?>> _pending = {};
  Set<String>? _visible;
  int _bytes = 0;
  bool _disposed = false;
  static String key(MathInline value, int color) =>
      'torto-formula:${sha256.convert(utf8.encode(jsonEncode([value.latex, value.display, value.equationNumber, color])))}';
  FormulaMetrics? lookup(MathInline value, int color) =>
      _cache[key(value, color)] ?? _geometry[key(value, color)];
  bool owns(String href) => _recipes.containsKey(href);
  Future<FormulaRaster?> renderHref(
    String href, {
    int maxDimension = 8192,
  }) async {
    final recipe = _recipes[href];
    return recipe == null
        ? null
        : render(recipe.$1, recipe.$2, maxDimension: maxDimension);
  }

  Future<FormulaMetrics?> measure(MathInline value, int color) async {
    if (_failed.contains(key(value, color))) return null;
    final cached = lookup(value, color);
    if (cached != null) return cached;
    if (_disposed || _geometry.length >= 4096) return null;
    return _render(value, color, key(value, color), pixels: false);
  }

  void retainVisible(Set<String> hrefs) {
    _visible = hrefs;
  }

  void _makeRoom(int bytes, String current) {
    if (_visible == null) return;
    for (final href in _cache.keys.toList()) {
      if (_bytes + bytes <= 32 * 1024 * 1024) break;
      if (href == current || _visible!.contains(href)) continue;
      final image = _cache.remove(href)!.image;
      _bytes -= image.width * image.height * 4;
      image.dispose();
    }
  }

  ui.Image? image(String href) => _cache[href]?.image;
  Future<FormulaRaster?> render(
    MathInline value,
    int color, {
    int maxDimension = 8192,
  }) async {
    final href = key(value, color);
    if (_disposed || _failed.contains(href)) return null;
    final cached = _cache[href];
    if (cached != null &&
        math.max(cached.image.width, cached.image.height) >=
            math
                .min(maxDimension, math.max(cached.width, cached.height) * 2)
                .floor()) {
      return cached;
    }
    return _pending
        .putIfAbsent(
          href,
          () async =>
              await _render(value, color, href, maxDimension: maxDimension)
                  as FormulaRaster?,
        )
        .whenComplete(() => _pending.remove(href));
  }

  Future<FormulaMetrics?> _render(
    MathInline value,
    int color,
    String href, {
    bool pixels = true,
    int maxDimension = 8192,
  }) async {
    if (formulaError(value.latex) != null) {
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
      final metrics = FormulaMetrics(href, size.width, size.height, baseline);
      if (_disposed) return null;
      _geometry[href] = metrics;
      _recipes[href] = (value, color);
      if (!pixels) return metrics;
      pipeline.flushCompositingBits();
      pipeline.flushPaint();
      final scale = math.min(
        math.min(2.0, maxDimension / math.max(size.width, size.height)),
        math.sqrt(4 * 1024 * 1024 / (size.width * size.height)),
      );
      // Do not leave a temporary render tree attached across an async gap:
      // system-font callbacks must never target a half-torn-down tree.
      final image = boundary.toImageSync(pixelRatio: scale);
      _makeRoom(image.width * image.height * 4, href);
      final previous = _cache[href];
      final previousBytes = previous == null
          ? 0
          : previous.image.width * previous.image.height * 4;
      if (_disposed ||
          _bytes - previousBytes + image.width * image.height * 4 >
              32 * 1024 * 1024) {
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
      _bytes += image.width * image.height * 4 - previousBytes;
      previous?.image.dispose();
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

  Future<void> prepare(
    Section section,
    int color, {
    bool deferPixels = false,
    bool Function()? shouldCancel,
  }) async {
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
      if (_disposed || (shouldCancel?.call() ?? false)) return;
      final href = key(value, color);
      if (deferPixels) {
        if (!_geometry.containsKey(href) && _geometry.length < 4096) {
          await _render(value, color, href, pixels: false);
          await Future<void>.delayed(Duration.zero);
        }
      } else {
        await render(value, color);
      }
    }
  }

  void dispose() {
    _disposed = true;
    for (final entry in _cache.values) {
      entry.image.dispose();
    }
    _cache.clear();
    _geometry.clear();
    _recipes.clear();
  }
}
