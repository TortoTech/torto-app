import 'package:flutter/widgets.dart';

class MediaReferenceScope extends InheritedWidget {
  final Future<void> Function(String)? open;
  const MediaReferenceScope({
    super.key,
    required this.open,
    required super.child,
  });
  static MediaReferenceScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MediaReferenceScope>();
  @override
  bool updateShouldNotify(MediaReferenceScope oldWidget) =>
      open != oldWidget.open;
}
