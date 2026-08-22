import 'dart:ui' as ui;

/// Optional capability for sources that can render an image resource directly.
///
/// The regular [BookSource.resource] path returns encoded bytes. Fixed-layout
/// formats such as PDF can implement this interface to hand the reader a
/// ready-to-paint image and avoid an encode/decode round trip.
abstract interface class RasterResourceSource {
  Future<ui.Image?> rasterResource(String href, {required int maxDimension});
}
