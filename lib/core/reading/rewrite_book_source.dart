import 'dart:typed_data';
import '../ir/ir.dart';

/// Session-only display rewrites. Original resources, metadata and anchors remain authoritative.
class RewriteBookSource implements BookSource {
  final BookSource inner;
  final Map<int, Map<String, String>> replacements = {};
  final Map<int, (Section, Section)> _cache = {};
  RewriteBookSource(this.inner);
  @override
  Book get book => inner.book;
  @override
  Future<Uint8List?> resource(String href) => inner.resource(href);
  void set(int unit, Map<String, String> values) {
    replacements[unit] = {...replacements[unit] ?? {}, ...values};
    _cache.remove(unit);
  }

  void clear() {
    replacements.clear();
    _cache.clear();
  }

  @override
  Future<Section> parseSection(int index) async {
    final section = await inner.parseSection(index),
        values = replacements[index];
    if (values == null || values.isEmpty) return section;
    final cached = _cache[index];
    if (cached != null && identical(cached.$1, section)) return cached.$2;
    final changed = Section(
      id: section.id,
      spineIndex: section.spineIndex,
      href: section.href,
      anchors: section.anchors,
      blocks: [
        for (final block in section.blocks)
          if (block is TextBlock && values.containsKey(block.nodeId))
            TextBlock(
              nodeId: '${block.nodeId}@rewrite',
              kind: block.kind,
              style: block.style,
              source: block.source,
              inlines: [TextRun(values[block.nodeId]!)],
            )
          else
            block,
      ],
    );
    _cache[index] = (section, changed);
    return changed;
  }
}
