/// The Reading IR: format- and renderer-neutral book model.
///
/// Dart port of torto's `crates/publication`. Everything above this layer
/// (layout, render, reader) depends only on these types.
library;

export 'block.dart';
export 'book.dart';
export 'locator.dart';
export 'raster_resource_source.dart';
export 'source.dart';
export 'style.dart';
