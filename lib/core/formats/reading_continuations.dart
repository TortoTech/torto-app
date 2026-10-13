import 'dart:typed_data';
import 'package:xml/xml.dart';
import '../ir/ir.dart';
import '../ir/inline_content.dart';
import '../layout/focus_layout.dart';

String normalizeContinuationText(String text) =>
    text.replaceAll(RegExp(r'\s+'), '').toLowerCase();

bool repeatsContinuationQuote(String text, String quote) {
  if (text.contains(quote)) return true;
  final wanted = quote.runes.toList();
  if (wanted.length < 96) return false;
  final prefix = String.fromCharCodes(wanted.take(32)),
      source = text.runes.toList();
  var offset = 0, checked = 0;
  while (checked++ < 32) {
    final at = text.indexOf(prefix, offset);
    if (at < 0) return false;
    offset = at + prefix.length;
    final start = text.substring(0, at).runes.length;
    for (
      var length = wanted.length - 24;
      length <= wanted.length + 24 && start + length <= source.length;
      length++
    ) {
      var a = 0, z = 0;
      while (a < wanted.length &&
          a < length &&
          wanted[a] == source[start + a]) {
        a++;
      }
      while (z < wanted.length - a &&
          z < length - a &&
          wanted[wanted.length - 1 - z] == source[start + length - 1 - z]) {
        z++;
      }
      if (a >= 32 &&
          z >= 32 &&
          wanted.length - a - z <= 24 &&
          length - a - z <= 24) {
        return true;
      }
    }
  }
  return false;
}

String? quoteSpreadCandidate(XmlElement root) {
  String name(XmlElement e) => e.name.local.toLowerCase();
  bool role(XmlElement e, Set<String> values) => e.attributes
      .where((a) => const {'type', 'role'}.contains(a.name.local))
      .any((a) => a.value.split(RegExp(r'\s+')).any(values.contains));
  final elements = root.descendants.whereType<XmlElement>();
  if (elements.any(
    (e) =>
        const {
          'h1',
          'h2',
          'h3',
          'h4',
          'h5',
          'h6',
          'nav',
          'table',
          'ul',
          'ol',
          'dl',
          'pre',
        }.contains(name(e)) ||
        role(e, const {
          'epigraph',
          'doc-epigraph',
          'part',
          'dedication',
          'titlepage',
          'footnote',
          'endnote',
          'endnotes',
          'doc-footnote',
          'doc-endnotes',
        }),
  )) {
    return null;
  }
  final buffer = StringBuffer();
  var explicit = true;
  for (final text in root.descendants.whereType<XmlText>()) {
    final ancestors = text.ancestors
        .whereType<XmlElement>()
        .takeWhile((e) => !identical(e, root))
        .toList();
    if (text.value.trim().isEmpty ||
        ancestors.any((e) => const {'script', 'style'}.contains(name(e)))) {
      continue;
    }
    final marked = ancestors.any(
      (e) =>
          name(e) == 'blockquote' ||
          role(e, const {'pullquote', 'doc-pullquote'}),
    );
    if (!marked && !ancestors.any((e) => name(e) == 'p')) return null;
    explicit &= marked;
    buffer.write(text.value);
  }
  final result = normalizeContinuationText(buffer.toString());
  final media =
      elements.where((e) => name(e) == 'p').length == 1 &&
      elements.where((e) => const {'img', 'image'}.contains(name(e))).length >=
          2;
  return result.isNotEmpty &&
          (explicit ||
              result.runes.length >= 96 ||
              media && result.runes.length >= 48)
      ? result
      : null;
}

/// Appends only an unlisted repeated quote spread. Physical source IDs and
/// link destinations remain usable through aliases; caches belong to inner.
class ReadingContinuationSource implements BookSource, DisposableBookSource {
  final Map<int, Section> _cache = {};
  final BookSource inner;
  final List<List<int>> groups;
  @override
  final Book book;
  ReadingContinuationSource._(this.inner, this.groups, this.book);
  static Future<BookSource> open(BookSource source) async {
    final tocTargets = <int, List<String>>{};
    void collect(List<TocEntry> entries) {
      for (final entry in entries) {
        final index = source.book.spine.indexWhere(
          (s) => s.href == entry.href.split('#').first,
        );
        if (index >= 0) (tocTargets[index] ??= []).add(entry.href);
        collect(entry.children);
      }
    }

    collect(source.book.toc);
    final continued = <int>{}, candidateSections = <int, Section>{};
    for (var i = 1; i < source.book.sectionCount; i++) {
      if (tocTargets.containsKey(i) ||
          !tocTargets.containsKey(i - 1) ||
          !source.book.spine[i].linear ||
          !source.book.spine[i - 1].linear) {
        continue;
      }
      final candidate = await source.parseSection(i),
          quote = candidate.continuationQuote;
      if (quote == null || candidate.blocks.any((b) => b is NoteBlock)) {
        continue;
      }
      final previous = await source.parseSection(i - 1);
      final text = previous.blocks
          .where((b) => b is! NoteBlock)
          .expand(blockTexts)
          .toList();
      var start = 0, textOffset = 0;
      for (final target in tocTargets[i - 1]!) {
        if (!target.contains('#')) continue;
        final anchor = previous.anchors
            .where((a) => a.fragment == target.split('#').last)
            .firstOrNull;
        if (anchor == null) {
          start = text.length;
          break;
        }
        final at = text.indexWhere(
          (b) => b.source?.start.node == anchor.source.node,
        );
        if (at >= 0 && at >= start) {
          textOffset = at > start
              ? anchor.source.textOffset
              : anchor.source.textOffset > textOffset
              ? anchor.source.textOffset
              : textOffset;
          start = at;
        }
      }
      final preceding = normalizeContinuationText(
        text
            .skip(start)
            .indexed
            .map(
              (entry) => entry.$1 == 0
                  ? String.fromCharCodes(
                      entry.$2.plainText.runes.skip(textOffset),
                    )
                  : entry.$2.plainText,
            )
            .join(),
      );
      if (repeatsContinuationQuote(preceding, quote)) {
        continued.add(i);
        candidateSections[i] = candidate;
      }
    }
    if (continued.isEmpty) return source;
    final groups = <List<int>>[];
    for (var i = 0; i < source.book.sectionCount; i++) {
      if (!continued.contains(i)) groups.add([]);
      groups.last.add(i);
    }
    final targets = <String, String>{...source.book.hrefTargets};
    for (final group in groups) {
      for (final i in group.skip(1)) {
        final root = source.book.spine[group.first].href,
            child = source.book.spine[i].href;
        targets[child] = '$root#continuation-$i';
        for (final anchor in candidateSections[i]!.anchors) {
          targets['$child#${anchor.fragment}'] =
              '$root#continuation-$i-${anchor.fragment}';
        }
      }
    }
    List<TocEntry> toc(List<TocEntry> entries) => [
      for (final entry in entries)
        TocEntry(
          label: entry.label,
          href: targets[entry.href] ?? entry.href,
          spineIndex: groups.indexWhere(
            (g) => g.any(
              (i) => source.book.spine[i].href == entry.href.split('#').first,
            ),
          ),
          children: toc(entry.children),
        ),
    ];
    return ReadingContinuationSource._(
      source,
      groups,
      Book(
        id: source.book.id,
        metadata: source.book.metadata,
        coverHref: source.book.coverHref,
        toc: toc(source.book.toc),
        hrefTargets: targets,
        spineAliases: {
          for (final (group, items) in groups.indexed)
            for (final i in items) source.book.spine[i].id: group,
        },
        spine: [
          for (final (index, items) in groups.indexed)
            SpineItem(
              id: source.book.spine[items.first].id,
              index: index,
              href: source.book.spine[items.first].href,
              linear: source.book.spine[items.first].linear,
            ),
        ],
      ),
    );
  }

  @override
  Future<Section> parseSection(int index) async {
    final cached = _cache.remove(index);
    if (cached != null) {
      _cache[index] = cached;
      return cached;
    }
    final blocks = <Block>[], anchors = <SectionAnchor>[];
    for (final i in groups[index]) {
      final section = await inner.parseSection(i);
      blocks.addAll(
        section.blocks.map(
          (b) => mapBlockContent(
            b,
            (t) => withInlines(
              t,
              t.inlines,
              nodeId: '${section.id.value}/${t.nodeId}',
            ),
          ),
        ),
      );
      anchors.addAll(
        section.anchors.map(
          (a) => SectionAnchor(
            fragment: i == groups[index].first
                ? a.fragment
                : 'continuation-$i-${a.fragment}',
            source: a.source,
          ),
        ),
      );
      if (i != groups[index].first) {
        final first = section.blocks
            .expand(FocusUnitBuilder.sources)
            .firstOrNull;
        if (first != null) {
          anchors.add(
            SectionAnchor(fragment: 'continuation-$i', source: first.start),
          );
        }
      }
    }
    final result = Section(
      id: book.spine[index].id,
      spineIndex: index,
      href: book.spine[index].href,
      blocks: blocks,
      anchors: anchors,
    );
    _cache[index] = result;
    while (_cache.length > 3) {
      _cache.remove(_cache.keys.first);
    }
    return result;
  }

  @override
  Future<Uint8List?> resource(String href) => inner.resource(href);
  @override
  void dispose() {
    _cache.clear();
    if (inner is DisposableBookSource) {
      (inner as DisposableBookSource).dispose();
    }
  }
}
