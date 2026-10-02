import 'dart:math' as math;
import 'dart:ui';
import '../../core/layout/layout_types.dart';

typedef FocusDestination = ({int active, double offset});

/// Pure navigation policy: a gesture advances one block or one overflow stop.
class FocusNavigation {
  static Duration duration(double distance) =>
      Duration(milliseconds: distance.abs().round().clamp(160, 360));

  static Rect body(FocusUnitLayout unit) => unit.paintBounds.isEmpty
      ? unit.bounds
      : unit.paintBounds.reduce((a, b) => a.expandToInclude(b));

  static ({double top, double bottom, double? imageEnd})? overflow(
    PageLayout page,
    int index,
  ) {
    final rect = body(page.focusUnits[index]);
    final height = page.viewport.height;
    if (rect.height <= height) return null;
    final window = math.min(height, 240.0);
    final images = page.items
        .whereType<ImagePlacement>()
        .where((image) => rect.overlaps(image.rect))
        .toList();
    if (images.length == 1) {
      final image = images.single.rect;
      final captions = page.focusUnits[index].paintBounds
          .where((r) => r.top >= image.bottom - 1)
          .toList();
      if (captions.isNotEmpty) {
        final caption = captions.reduce((a, b) => a.expandToInclude(b));
        if (caption.height <= height) {
          final top =
              (image.height <= height
                      ? image.center.dy - height / 2
                      : image.top - (height - window) / 2)
                  .clamp(0.0, page.scrollExtent);
          final imageEnd = (image.bottom - (height + window) / 2).clamp(
            top,
            page.scrollExtent,
          );
          final bottom = (caption.center.dy - height / 2).clamp(
            imageEnd,
            page.scrollExtent,
          );
          return (
            top: top,
            bottom: bottom,
            imageEnd: image.height <= height ? top : imageEnd,
          );
        }
      }
    }
    final top = (rect.top - (height - window) / 2).clamp(
      0.0,
      page.scrollExtent,
    );
    final bottom = (rect.bottom - (height + window) / 2).clamp(
      top,
      page.scrollExtent,
    );
    return (top: top, bottom: bottom, imageEnd: null);
  }

  static double target(PageLayout page, int index) {
    final unit = page.focusUnits[index];
    final rect = body(unit);
    final stops = overflow(page, index);
    final height = page.viewport.height;
    var y =
        stops?.top ??
        (rect.height > height
            ? rect.top - (height - math.min(height, 240)) / 2
            : rect.top + math.max(240, rect.height) / 2 - height / 2);
    // Center the body when possible while retaining its leading heading.
    if (index == 0 && unit.bounds.top < rect.top) {
      y = math.min(y, math.max(0.0, unit.bounds.top - 28));
    }
    return y.clamp(0.0, page.scrollExtent);
  }

  static FocusDestination step(
    PageLayout page,
    int active,
    double offset,
    int direction,
  ) {
    if (page.focusUnits.isEmpty) return (active: active, offset: offset);
    final height = page.viewport.height;
    final stops = overflow(page, active);
    if (stops != null) {
      final window = math.min(height, 240.0);
      final top = stops.top, bottom = stops.bottom, imageEnd = stops.imageEnd;
      if (imageEnd != null &&
          direction > 0 &&
          offset >= imageEnd - 1 &&
          offset < bottom - 1) {
        return (active: active, offset: bottom);
      }
      if (imageEnd != null && direction < 0 && offset > imageEnd + 1) {
        return (active: active, offset: imageEnd);
      }
      if (direction > 0 && offset < bottom - 1) {
        return (
          active: active,
          offset: math.min(imageEnd ?? bottom, math.max(top, offset) + window),
        );
      }
      if (direction < 0 && offset > top + 1) {
        return (
          active: active,
          offset: math.max(top, math.min(bottom, offset) - window),
        );
      }
    }
    final next = (active + direction).clamp(0, page.focusUnits.length - 1);
    if (next == active) return (active: active, offset: offset);
    var destination = target(page, next);
    final previous = body(page.focusUnits[next]);
    if (direction < 0 && previous.height > height) {
      destination = overflow(page, next)!.bottom;
    }
    return (active: next, offset: destination);
  }
}
