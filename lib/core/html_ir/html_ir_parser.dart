/// HTML/XHTML → Reading IR parser.
///
/// Dart port of torto's `crates/html`: parses one spine section document
/// into IR blocks, applying a deliberately small owned subset of CSS
/// (element / .class / #id selectors, a fixed property list).
library;

import 'dart:math' as math;

import 'package:xml/xml.dart';

import '../ir/ir.dart';
import 'package_path.dart';
import 'tolerant_xml.dart';

/// Parses XHTML section documents into IR [Section]s.
class HtmlIrParser {
  const HtmlIrParser();

  /// Parses [xhtml] (one spine section). [href] is the section's
  /// root-relative package path; [basePath] its root-relative directory,
  /// used to resolve relative links and image sources. [spineIndex] is used
  /// for source anchors. [loadStylesheet] receives canonical root-relative
  /// paths resolved from authored `<link rel="stylesheet">` elements.
  ///
  /// Never throws: unrecoverable markup yields a section with empty blocks.
  Section parse({
    required int spineIndex,
    required String href,
    required String xhtml,
    required String basePath,
    SectionParseHints hints = const SectionParseHints(),
    String? Function(String href)? loadStylesheet,
    bool Function(String href)? isDecorativeSeparatorImage,
  }) {
    try {
      final document = tryParseXmlTolerant(xhtml);
      if (document == null) {
        return Section(spineIndex: spineIndex, href: href, blocks: const []);
      }
      return _SectionParser(
        spineIndex,
        href,
        basePath,
        document,
        hints,
        loadStylesheet,
        isDecorativeSeparatorImage,
      ).run();
    } catch (_) {
      return Section(spineIndex: spineIndex, href: href, blocks: const []);
    }
  }
}

/// Publication-level hints that one isolated HTML resource cannot infer.
class SectionParseHints {
  final bool noteSection;

  const SectionParseHints({this.noteSection = false});
}

/// Lowercase local name of an element, namespace-agnostic.
String _name(XmlElement element) => element.name.local.toLowerCase();

/// Attribute lookup: exact (qualified) name first, then case-insensitive
/// match on local names (handles `epub:type`, `xlink:href`, …).
String? _attr(XmlElement element, String name) {
  final direct = element.getAttribute(name);
  if (direct != null) return direct;
  for (final attribute in element.attributes) {
    if (attribute.name.local.toLowerCase() == name) return attribute.value;
  }
  return null;
}

Map<XmlElement, LinkRole> _classifyFootnoteLinks(
  XmlDocument document,
  String sectionHref,
  String baseDir,
) {
  final anchors = document.descendants
      .whereType<XmlElement>()
      .where((element) => _name(element) == 'a')
      .toList();
  final roles = Map<XmlElement, LinkRole>.identity();
  for (final anchor in anchors) {
    final explicit = _explicitLinkRole(anchor);
    if (explicit != null) roles[anchor] = explicit;
  }

  // Older EPUBs often expose no semantics at all. Torto recognizes a
  // reciprocal pair such as ref -> note and note -> ref when both compact
  // markers match, then uses surrounding prose to determine the direction.
  final byFragment = <String, XmlElement>{};
  for (final element in document.descendants.whereType<XmlElement>()) {
    final fragment = _nodeFragment(element);
    if (fragment != null) byFragment[fragment] = element;
  }
  final sectionPath = splitPackageFragment(sectionHref).$1;
  for (final anchor in anchors) {
    final sourceFragment = _nodeFragment(anchor);
    final rawTarget = _attr(anchor, 'href');
    if (sourceFragment == null || rawTarget == null) continue;
    final target = _resolveDocumentLink(sectionHref, baseDir, rawTarget);
    final (targetPath, targetFragment) = splitPackageFragment(target);
    if (targetPath != sectionPath || targetFragment == null) continue;
    final targetNode = byFragment[targetFragment];
    if (targetNode == null) continue;

    XmlElement? counterpart;
    final candidates = <XmlElement>[
      targetNode,
      ...targetNode.descendants.whereType<XmlElement>(),
    ];
    for (final candidate in candidates) {
      if (_name(candidate) != 'a' || identical(candidate, anchor)) continue;
      final candidateHref = _attr(candidate, 'href');
      if (candidateHref == null ||
          !_matchingFootnoteMarkers(anchor, candidate)) {
        continue;
      }
      final resolved = _resolveDocumentLink(
        sectionHref,
        baseDir,
        candidateHref,
      );
      final (path, fragment) = splitPackageFragment(resolved);
      if (path == sectionPath && fragment == sourceFragment) {
        counterpart = candidate;
        break;
      }
    }
    if (counterpart == null) continue;

    final anchorHasProse = _linkHasPrecedingBlockText(anchor);
    final counterpartHasProse = _linkHasPrecedingBlockText(counterpart);
    final reference = anchorHasProse && !counterpartHasProse
        ? anchor
        : (!anchorHasProse && counterpartHasProse ? counterpart : anchor);
    final backlink = identical(reference, anchor) ? counterpart : anchor;
    roles.putIfAbsent(reference, () => LinkRole.footnoteReference);
    roles.putIfAbsent(backlink, () => LinkRole.footnoteBacklink);
  }
  return roles;
}

LinkRole? _explicitLinkRole(XmlElement anchor) {
  for (final value in [
    _attr(anchor, 'type'),
    _attr(anchor, 'role'),
    _attr(anchor, 'rel'),
  ]) {
    for (final token in (value ?? '').split(RegExp(r'\s+'))) {
      switch (token.toLowerCase()) {
        case 'noteref' || 'doc-noteref':
          return LinkRole.footnoteReference;
        case 'backlink' || 'doc-backlink':
          return LinkRole.footnoteBacklink;
      }
    }
  }
  return null;
}

String? _nodeFragment(XmlElement element) {
  final fragment = (_attr(element, 'id') ?? _attr(element, 'name'))?.trim();
  return fragment == null || fragment.isEmpty ? null : fragment;
}

String _resolveDocumentLink(
  String sectionHref,
  String baseDir,
  String rawHref,
) {
  final trimmed = rawHref.trim();
  return trimmed.startsWith('#')
      ? '$sectionHref$trimmed'
      : resolvePackageHref(baseDir, trimmed);
}

bool _matchingFootnoteMarkers(XmlElement left, XmlElement right) {
  String? marker(XmlElement element) {
    final text = element.descendants
        .whereType<XmlText>()
        .map((node) => node.value)
        .join();
    return _normalizeFootnoteMarker(text)?.toLowerCase();
  }

  final leftMarker = marker(left);
  return leftMarker != null && leftMarker == marker(right);
}

String? _normalizeFootnoteMarker(String marker) {
  final normalized = marker
      .trim()
      .replaceFirst(RegExp(r'[.．]+$'), '')
      .trim()
      .replaceFirst(RegExp(r'^[\[\(（【]+'), '')
      .replaceFirst(RegExp(r'[\]\)）】]+$'), '')
      .replaceFirst(RegExp(r'[.．]+$'), '')
      .trim();
  if (normalized.isEmpty ||
      normalized.runes.length > 8 ||
      normalized.contains(RegExp(r'\s'))) {
    return null;
  }
  return normalized;
}

bool _linkHasPrecedingBlockText(XmlElement link) {
  XmlElement? block = link.parentElement;
  while (block != null && !_isBlockBoundary(_name(block))) {
    block = block.parentElement;
  }
  if (block == null) return false;
  for (final node in block.descendants) {
    if (identical(node, link)) break;
    if (node is XmlText && node.value.trim().isNotEmpty) return true;
  }
  return false;
}

bool _isWhitespaceRune(int rune) =>
    rune == 0x20 ||
    (rune >= 0x09 && rune <= 0x0D) ||
    rune == 0xA0 ||
    (rune >= 0x2000 && rune <= 0x200A) ||
    rune == 0x2028 ||
    rune == 0x2029 ||
    rune == 0x202F ||
    rune == 0x205F ||
    rune == 0x3000 ||
    rune == 0xFEFF;

const Set<String> _skippedElements = {
  'script',
  'style',
  'head',
  'nav',
  'title',
  'meta',
  'link',
};

/// Elements that close an open text run inside a mixed-content container.
bool _isBlockBoundary(String name) =>
    _transparentContainers.contains(name) ||
    const {
      'blockquote',
      'cite',
      'dd',
      'dl',
      'dt',
      'figcaption',
      'footer',
      'h1',
      'h2',
      'h3',
      'h4',
      'h5',
      'h6',
      'hr',
      'img',
      'image',
      'li',
      'ol',
      'p',
      'pre',
      'table',
      'ul',
    }.contains(name);

const Set<String> _transparentContainers = {
  'address',
  'article',
  'aside',
  'body',
  'center',
  'div',
  'figure',
  'footer',
  'header',
  'main',
  'section',
};

bool _isStructuredContainer(String name) =>
    name == 'ul' || name == 'ol' || name == 'dl';

const _semanticListMarkers = {'•', '◦', '▪', '‣', '»'};

bool _hasExplicitParagraphListMarker(XmlElement element) {
  for (final descendant in element.descendants.whereType<XmlElement>()) {
    if (_name(descendant) != 'span') continue;
    final classes = (_attr(descendant, 'class') ?? '').split(RegExp(r'\s+'));
    if (!classes.any((name) => name.toLowerCase() == 'enumerator')) continue;
    final marker = descendant.descendants
        .whereType<XmlText>()
        .map((text) => text.value)
        .join()
        .trim();
    if (_semanticListMarkers.contains(marker)) return true;
  }
  return false;
}

void _stripAuthoredListMarker(List<Inline> content) {
  for (var index = 0; index < content.length; index++) {
    final inline = content[index];
    if (inline is! TextRun) continue;
    final trimmed = inline.text.trimLeft();
    if (trimmed.isEmpty) continue;
    final marker = String.fromCharCode(trimmed.runes.first);
    if (!_semanticListMarkers.contains(marker)) continue;
    final remainder = trimmed.substring(marker.length).trimLeft();
    if (remainder.isEmpty) {
      content.removeAt(index);
    } else {
      content[index] = TextRun(
        remainder,
        style: inline.style,
        link: inline.link,
      );
    }
    return;
  }
}

bool _isSemanticFootnoteDefinition(XmlElement element) {
  for (final value in [_attr(element, 'type'), _attr(element, 'role')]) {
    for (final token in (value ?? '').split(RegExp(r'\s+'))) {
      if (const {
        'footnote',
        'doc-footnote',
        'endnote',
        'doc-endnote',
      }.contains(token.toLowerCase())) {
        return true;
      }
    }
  }
  return false;
}

String _nodeText(XmlElement element) => element.descendants
    .whereType<XmlText>()
    .map((node) => node.value)
    .join()
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

bool _isAuthoredSpacingParagraph(XmlElement element) {
  var hasSpacingMarker = false;
  for (final descendant in element.descendants) {
    if (identical(descendant, element)) continue;
    if (descendant is XmlElement) {
      final name = _name(descendant);
      if (const {'img', 'image', 'svg', 'math'}.contains(name)) return false;
      if (name == 'br') hasSpacingMarker = true;
      continue;
    }
    if (descendant is! XmlText) continue;
    for (final rune in descendant.value.runes) {
      if (!_isWhitespaceRune(rune)) return false;
      if (rune == 0x00a0 || rune == 0x3000) hasSpacingMarker = true;
    }
  }
  return hasSpacingMarker;
}

Set<String> _classNames(XmlElement element) => (_attr(element, 'class') ?? '')
    .split(RegExp(r'\s+'))
    .where((value) => value.isNotEmpty)
    .map((value) => value.toLowerCase())
    .toSet();

bool _containsDisplayMath(XmlElement element) =>
    element.descendants.whereType<XmlElement>().any(
      (node) =>
          _name(node) == 'span' && _classNames(node).contains('math-display'),
    );

bool _hasOnlyMathContent(XmlElement element) {
  for (final descendant in element.descendants) {
    if (descendant is XmlText) {
      if (descendant.value.trim().isEmpty) continue;
      final parent = descendant.parentElement;
      if (parent != null && _classNames(parent).contains('math-display')) {
        continue;
      }
      return false;
    }
    if (descendant is! XmlElement) continue;
    final name = _name(descendant);
    if (name == 'br') continue;
    if (name == 'span') {
      final classes = _classNames(descendant);
      if (classes.contains('math') || classes.contains('math-display')) {
        continue;
      }
    }
    return false;
  }
  return true;
}

bool _isInferredFigureCaption(XmlElement element) {
  if (!const {'p', 'div'}.contains(_name(element)) ||
      element.descendants.whereType<XmlElement>().any(
        (node) =>
            !identical(node, element) &&
            const {
              'div',
              'figure',
              'figcaption',
              'img',
              'image',
              'table',
            }.contains(_name(node)),
      )) {
    return false;
  }
  final semantic =
      [_attr(element, 'class'), _attr(element, 'type'), _attr(element, 'role')]
          .whereType<String>()
          .expand((value) => value.split(RegExp(r'\s+')))
          .map((value) => value.replaceAll(RegExp('[-_]'), '').toLowerCase());
  if (semantic.any(
    (value) => const {
      'caption',
      'fcaption',
      'figcaption',
      'figurecaption',
      'doccaption',
      'legend',
      'finure',
      'tushuo',
    }.contains(value),
  )) {
    return true;
  }
  final text = _nodeText(element);
  if (text.isEmpty) return false;
  return RegExp(
    r'^[\s▲△◆◇■□●○※]*(?:图片|图表|插图|图版|表格|图|表|figure|table)\s*[-–—.:：]?[\s]*[0-9一二三四五六七八九十]+',
    caseSensitive: false,
  ).hasMatch(text);
}

bool _hasQuoteSemanticWord(XmlElement element) {
  final classes = (_attr(element, 'class') ?? '').split(RegExp(r'\s+'));
  return classes.any((value) => value.toLowerCase().contains('quote'));
}

bool _isQuoteTextCandidate(XmlElement element) {
  if (!_isBlockBoundary(_name(element)) || _nodeText(element).isEmpty) {
    return false;
  }
  return !element.descendants.whereType<XmlElement>().any(
    (node) => !identical(node, element) && _isBlockBoundary(_name(node)),
  );
}

bool _isNoteSectionLabel(String value) {
  final normalized = value
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[\s\.,:;!?，。！？：；、·—_\-]+'), ' ')
      .trim();
  return RegExp(
    r'^(?:footnotes?|endnotes?|notes?|脚注|尾注|注释|注解)(?:\s+\d+)?$',
  ).hasMatch(normalized);
}

TextBlock _copyTextBlock(
  TextBlock block, {
  TextBlockKind? kind,
  BlockStyle? style,
}) => TextBlock(
  kind: kind ?? block.kind,
  headingLevel: block.headingLevel,
  listOrdered: block.listOrdered,
  listOrdinal: block.listOrdinal,
  listDepth: block.listDepth,
  listMarkerVisible: block.listMarkerVisible,
  inlines: block.inlines,
  style: style ?? block.style,
  source: block.source,
  nodeId: block.nodeId,
);

Block _markFootnoteDefinition(Block block) => switch (block) {
  TextBlock() => _copyTextBlock(block, kind: TextBlockKind.footnoteDefinition),
  QuoteBlock(:final body, :final attribution, :final source) => QuoteBlock(
    body: body
        .map(
          (item) =>
              _copyTextBlock(item, kind: TextBlockKind.footnoteDefinition),
        )
        .toList(growable: false),
    attribution: attribution == null
        ? null
        : _copyTextBlock(attribution, kind: TextBlockKind.footnoteDefinition),
    source: source,
  ),
  _ => block,
};

SourceRange? _combinedTextSource(List<TextBlock> blocks) {
  final sources = blocks.map((block) => block.source).whereType<SourceRange>();
  if (sources.isEmpty) return null;
  final values = sources.toList(growable: false);
  return SourceRange(start: values.first.start, end: values.last.end);
}

SourceRange? _blockSource(Block block) {
  switch (block) {
    case TextBlock(:final source) ||
        ImageBlock(:final source) ||
        FigureBlock(:final source) ||
        QuoteBlock(:final source) ||
        NoteBlock(:final source):
      return source;
    case TableBlock(:final source, :final rows):
      if (source != null) return source;
      for (final row in rows) {
        for (final cell in row.cells) {
          if (cell.source != null) return cell.source;
        }
      }
    default:
      return null;
  }
  return null;
}

SourceRange? _combinedBlockSource(List<Block> blocks) {
  final values = blocks.map(_blockSource).whereType<SourceRange>().toList();
  if (values.isEmpty) return null;
  return SourceRange(start: values.first.start, end: values.last.end);
}

class _QuoteLayoutMetrics {
  const _QuoteLayoutMetrics({
    required this.start,
    required this.end,
    required this.before,
    required this.after,
  });

  final double start;
  final double end;
  final double before;
  final double after;

  bool get hasSymmetricInset {
    const minimumHorizontalInset = 4.0;
    final symmetryTolerance = math.max(4.0, math.max(start, end) * 0.25);
    return start >= minimumHorizontalInset &&
        end >= minimumHorizontalInset &&
        (start - end).abs() <= symmetryTolerance;
  }

  bool compatibleWith(_QuoteLayoutMetrics other) {
    final largestInset = [start, end, other.start, other.end].reduce(math.max);
    final tolerance = math.max(4.0, largestInset * 0.25);
    return (start - other.start).abs() <= tolerance &&
        (end - other.end).abs() <= tolerance;
  }
}

class _SectionParser {
  final int spineIndex;
  final String href;
  final String baseDir;
  final XmlDocument document;
  final SectionParseHints hints;
  final String? Function(String href)? loadStylesheet;
  final bool Function(String href)? isDecorativeSeparatorImage;
  final _StyleSheet styles = _StyleSheet();
  late final Map<XmlElement, LinkRole> _footnoteLinks;
  final List<Block> blocks = [];
  final Map<XmlElement, SourceAnchor> _elementSources = Map.identity();
  final List<double> _paragraphListIndents = [];
  int _nextNode = 0;
  bool _insideNote = false;
  bool _insideQuote = false;

  _SectionParser(
    this.spineIndex,
    this.href,
    this.baseDir,
    this.document,
    this.hints,
    this.loadStylesheet,
    this.isDecorativeSeparatorImage,
  ) {
    _footnoteLinks = _classifyFootnoteLinks(document, href, baseDir);
    for (final element in document.descendants.whereType<XmlElement>()) {
      switch (_name(element)) {
        case 'style':
          styles.addCss(
            element.descendants
                .where((node) => node is XmlText || node is XmlCDATA)
                .map(
                  (node) =>
                      node is XmlText ? node.value : (node as XmlCDATA).value,
                )
                .join(),
          );
        case 'link':
          final stylesheet = (_attr(element, 'rel') ?? '')
              .split(RegExp(r'\s+'))
              .any((token) => token.toLowerCase() == 'stylesheet');
          final rawHref = _attr(element, 'href');
          if (!stylesheet || rawHref == null || rawHref.trim().isEmpty) break;
          final resolved = resolvePackageHref(baseDir, rawHref);
          final (resourceHref, _) = splitPackageFragment(resolved);
          final css = loadStylesheet?.call(resourceHref);
          if (css != null) styles.addCss(css);
      }
    }
  }

  Section run() {
    XmlElement? root;
    for (final element in document.descendants.whereType<XmlElement>()) {
      if (_name(element) == 'body') {
        root = element;
        break;
      }
    }
    root ??= document.rootElement;
    if (hints.noteSection) {
      _parseNoteSectionElements(root.childElements.toList());
    } else {
      _parseChildren(root);
    }
    final anchors = <SectionAnchor>[];
    final seen = <String>{};
    for (final element in document.descendants.whereType<XmlElement>()) {
      final fragment = _nodeFragment(element);
      if (fragment == null || !seen.add(fragment)) continue;
      final source = _sourceForElement(element);
      if (source != null) {
        anchors.add(SectionAnchor(fragment: fragment, source: source));
      }
    }
    return Section(
      spineIndex: spineIndex,
      href: href,
      blocks: blocks,
      anchors: anchors,
    );
  }

  String _allocateNode() => 'n${_nextNode++}';

  SourceRange _sourceFor(String nodeId, int textLength) => SourceRange(
    start: SourceAnchor(spine: spineIndex, node: nodeId, textOffset: 0),
    end: SourceAnchor(spine: spineIndex, node: nodeId, textOffset: textLength),
  );

  // ---------------------------------------------------------------- blocks

  void _parseChildren(XmlElement parent, {int listDepth = 0}) {
    final children = parent.childElements.toList();
    var index = 0;
    while (index < children.length) {
      final child = children[index];
      if (_isCaptionableImageContainer(child) &&
          index + 1 < children.length &&
          _isInferredFigureCaption(children[index + 1])) {
        _parseInferredFigurePair(child, children[index + 1], listDepth);
        index += 2;
        continue;
      }
      if (_isNoteSectionLabel(_nodeText(child)) &&
          children
              .skip(index + 1)
              .any((candidate) => _startsImplicitNoteEntry(candidate))) {
        _parseNoteSectionElements(children.sublist(index));
        break;
      }
      final quoteCount = _tryParseSiblingQuote(children, index);
      if (quoteCount > 0) {
        index += quoteCount;
        continue;
      }
      _parseNode(child, listDepth);
      index++;
    }
  }

  bool _isCaptionableImageContainer(XmlElement element) {
    if (_nodeText(element).isNotEmpty) return false;
    final images =
        <XmlElement>[
              if (_name(element) == 'img' || _name(element) == 'image') element,
              ...element.descendants.whereType<XmlElement>(),
            ]
            .where(
              (node) =>
                  (_name(node) == 'img' || _name(node) == 'image') &&
                  !_isFootnoteReferenceImage(node),
            )
            .toList();
    return images.isNotEmpty &&
        !element.descendants.whereType<XmlElement>().any(
          (node) =>
              !identical(node, element) &&
              const {'figcaption', 'table'}.contains(_name(node)),
        );
  }

  void _parseInferredFigurePair(
    XmlElement image,
    XmlElement caption,
    int listDepth,
  ) {
    final imageStart = blocks.length;
    _parseNode(image, listDepth);
    final parsedAsImages =
        blocks.length > imageStart &&
        blocks.skip(imageStart).every((block) => block is ImageBlock);
    final captionStart = blocks.length;
    _parseNode(caption, listDepth);
    if (!parsedAsImages || blocks.length != captionStart + 1) return;
    final parsedCaption = blocks[captionStart];
    if (parsedCaption is TextBlock &&
        parsedCaption.kind == TextBlockKind.paragraph) {
      blocks[captionStart] = _copyTextBlock(
        parsedCaption,
        kind: TextBlockKind.caption,
      );
    }
  }

  void _parseNoteSectionElements(List<XmlElement> elements) {
    var index = 0;
    while (index < elements.length) {
      final element = elements[index];
      if (_startsImplicitNoteEntry(element)) {
        var end = index + 1;
        while (end < elements.length &&
            !_startsImplicitNoteEntry(elements[end]) &&
            !_isNoteSectionLabel(_nodeText(elements[end]))) {
          end++;
        }
        _parseGroupedNoteElements(
          elements.sublist(index, end),
          NoteBlockKind.section,
        );
        index = end;
        continue;
      }
      _parseGroupedNoteElements([element], NoteBlockKind.section);
      index++;
    }
  }

  void _parseGroupedNoteElements(
    List<XmlElement> elements,
    NoteBlockKind kind,
  ) {
    final start = blocks.length;
    final previous = _insideNote;
    _insideNote = true;
    for (final element in elements) {
      _parseNode(element, 0);
    }
    _insideNote = previous;
    if (blocks.length == start) return;
    final nested = blocks.sublist(start);
    blocks.removeRange(start, blocks.length);
    final marked = kind == NoteBlockKind.definition
        ? nested.map(_markFootnoteDefinition).toList(growable: false)
        : List<Block>.unmodifiable(nested);
    blocks.add(
      NoteBlock(
        kind: kind,
        blocks: marked,
        source: _combinedBlockSource(marked),
      ),
    );
  }

  bool _isImplicitNoteContainer(XmlElement element) {
    if (!const {'div', 'section', 'ol', 'ul'}.contains(_name(element))) {
      return false;
    }
    final semanticName = [_attr(element, 'class'), _attr(element, 'id')]
        .whereType<String>()
        .expand((value) => value.split(RegExp(r'[\s-]+')))
        .map((value) => value.toLowerCase())
        .any(
          (token) => const {
            'footnote',
            'footnotes',
            'endnote',
            'endnotes',
          }.contains(token),
        );
    if (!semanticName) return false;
    final children = element.childElements.toList();
    return children.any(_startsImplicitNoteEntry);
  }

  void _parseImplicitNoteContainer(XmlElement container) {
    final children = container.childElements.toList();
    var index = 0;
    while (index < children.length) {
      if (!_startsImplicitNoteEntry(children[index])) {
        _parseNode(children[index], 0);
        index++;
        continue;
      }
      var end = index + 1;
      while (end < children.length &&
          !_startsImplicitNoteEntry(children[end])) {
        end++;
      }
      _parseGroupedNoteElements(
        children.sublist(index, end),
        NoteBlockKind.definition,
      );
      index = end;
    }
  }

  double _effectiveStartOffset(BlockStyle style) =>
      style.marginStart + style.marginStartFraction * 1000;

  bool _hasDistinctQuoteTypography(XmlElement element) {
    final properties = styles.cascadedProperties(element);
    final parent = element.parentElement;
    final parentProperties = parent == null
        ? null
        : styles.cascadedProperties(parent);

    bool differsFromParent(String name) {
      final value = properties[name]?.trim();
      if (value == null ||
          value.isEmpty ||
          const {'inherit', 'initial', 'unset', 'normal'}.contains(value)) {
        return false;
      }
      return parentProperties?[name]?.trim() != value;
    }

    final declaredAlignment = _blockAlign(
      properties['text-align'] ?? _attr(element, 'align'),
    );
    return differsFromParent('font-family') ||
        differsFromParent('font-style') ||
        differsFromParent('font-weight') ||
        declaredAlignment == BlockAlign.center;
  }

  _QuoteLayoutMetrics _quoteLayoutMetrics(XmlElement element) {
    const referenceWidth = 1000.0;
    final properties = styles.cascadedProperties(element);

    double horizontal(String logical, String physical) {
      final length = _cssHorizontalLength(
        properties[logical] ?? properties[physical],
      );
      if (length == null) return 0;
      return length.$1 + length.$2 * referenceWidth;
    }

    double vertical(String logical, String physical) {
      final length = _cssLength(properties[logical] ?? properties[physical]);
      return length == null || !length.isFinite ? 0 : length;
    }

    return _QuoteLayoutMetrics(
      start:
          horizontal('margin-inline-start', 'margin-left') +
          horizontal('padding-inline-start', 'padding-left'),
      end:
          horizontal('margin-inline-end', 'margin-right') +
          horizontal('padding-inline-end', 'padding-right'),
      before:
          vertical('margin-block-start', 'margin-top') +
          vertical('padding-block-start', 'padding-top'),
      after:
          vertical('margin-block-end', 'margin-bottom') +
          vertical('padding-block-end', 'padding-bottom'),
    );
  }

  _QuoteLayoutMetrics? _groupedQuoteBodyLayout(XmlElement element) {
    const minimumVerticalSpacing = 0.5;
    final layout = _quoteLayoutMetrics(element);
    return layout.hasSymmetricInset &&
            (layout.before > minimumVerticalSpacing ||
                layout.after > minimumVerticalSpacing)
        ? layout
        : null;
  }

  bool _hasSiblingQuoteAttributionRole(
    XmlElement element,
    _QuoteLayoutMetrics bodyLayout,
    TextStyle bodyTextStyle,
  ) {
    final attributionLayout = _quoteLayoutMetrics(element);
    final attributionTextStyle = _textStyleForBlock(
      element,
      TextBlockKind.quoteAttribution,
    );
    return attributionTextStyle.sizeScale + 0.05 < bodyTextStyle.sizeScale ||
        attributionTextStyle.italic != bodyTextStyle.italic ||
        attributionLayout.start + 4 < bodyLayout.start ||
        attributionLayout.end + 4 < bodyLayout.end;
  }

  bool _hasStandaloneQuoteLayout(XmlElement element) {
    const minimumVerticalSpacing = 0.5;
    final layout = _quoteLayoutMetrics(element);
    return layout.hasSymmetricInset &&
        layout.before > minimumVerticalSpacing &&
        layout.after > minimumVerticalSpacing;
  }

  bool _hasVisualBoundary(XmlElement element) {
    final properties = styles.cascadedProperties(element);

    bool visiblePaint(String? value) {
      final normalized = value?.trim() ?? '';
      return normalized.isNotEmpty &&
          !const {
            'none',
            'transparent',
            'inherit',
            'initial',
            'unset',
            '0',
          }.contains(normalized);
    }

    if (const [
      'background',
      'background-color',
      'border',
      'border-left',
      'border-right',
    ].any((name) => visiblePaint(properties[name]))) {
      return true;
    }
    return const [
      'padding-left',
      'padding-right',
      'padding-top',
      'padding-bottom',
      'padding-inline-start',
      'padding-inline-end',
    ].any((name) => (_cssLength(properties[name]) ?? 0) > 0);
  }

  int _tryParseSiblingQuote(List<XmlNode> siblings, int start) {
    const minimumAttributedBodyBlocks = 1;
    const minimumUnattributedBodyBlocks = 2;

    final body = <XmlElement>[];
    _QuoteLayoutMetrics? referenceLayout;
    TextStyle? referenceTextStyle;
    String? referenceTag;
    final stanzaBreakAfter = <int>{};
    int? pendingStanzaBreak;
    var bodyHasDistinctTypography = false;
    var lastBodyConsumed = 0;
    var index = start;
    while (index < siblings.length) {
      final node = siblings[index];
      if (node is XmlText) {
        if (node.value.trim().isEmpty) {
          index++;
          continue;
        }
        break;
      }
      if (node is! XmlElement) {
        index++;
        continue;
      }
      if (_name(node) == 'br' && body.isNotEmpty) {
        pendingStanzaBreak = body.length - 1;
        index++;
        continue;
      }
      final candidate = node;
      if (!_isQuoteTextCandidate(candidate)) break;
      final style = _blockStyleFor(candidate);
      if (style.align == BlockAlign.end) {
        if (body.length < minimumAttributedBodyBlocks ||
            referenceLayout == null ||
            referenceTextStyle == null ||
            !_hasSiblingQuoteAttributionRole(
              candidate,
              referenceLayout,
              referenceTextStyle,
            )) {
          break;
        }
        if (pendingStanzaBreak case final pending?) {
          stanzaBreakAfter.add(pending);
        }
        _parseQuoteElements(
          body,
          candidate,
          stanzaBreakAfter: stanzaBreakAfter,
        );
        return index - start + 1;
      }

      final layout = _groupedQuoteBodyLayout(candidate);
      if (layout == null) break;
      final tag = _name(candidate);
      if ((referenceTag != null && tag != referenceTag) ||
          (referenceLayout != null &&
              !layout.compatibleWith(referenceLayout))) {
        break;
      }
      if (pendingStanzaBreak case final pending?) {
        stanzaBreakAfter.add(pending);
        pendingStanzaBreak = null;
      }
      referenceLayout ??= layout;
      referenceTextStyle ??= _textStyleForBlock(
        candidate,
        TextBlockKind.paragraph,
      );
      referenceTag ??= tag;
      body.add(candidate);
      bodyHasDistinctTypography |= _hasDistinctQuoteTypography(candidate);
      index++;
      lastBodyConsumed = index - start;
    }
    if (body.length >= minimumUnattributedBodyBlocks &&
        bodyHasDistinctTypography) {
      _parseQuoteElements(body, null, stanzaBreakAfter: stanzaBreakAfter);
      return lastBodyConsumed;
    }
    return 0;
  }

  bool _tryParseStructuralQuote(XmlElement container) {
    final children = container.childElements.toList();
    if (children.length < 2 ||
        container.children.whereType<XmlText>().any(
          (text) => text.value.trim().isNotEmpty,
        ) ||
        children.any((child) => !_isQuoteTextCandidate(child))) {
      return false;
    }
    final attribution = children.last;
    if (_blockStyleFor(attribution).align != BlockAlign.end) return false;
    final body = children.sublist(0, children.length - 1);
    if (body.any(
      (element) => _blockStyleFor(element).align == BlockAlign.end,
    )) {
      return false;
    }
    final attributionStart = _effectiveStartOffset(_blockStyleFor(attribution));
    final bodyHasRole = body.any((element) {
      final style = _blockStyleFor(element);
      final textStyle = _textStyleForBlock(element, TextBlockKind.paragraph);
      return textStyle.italic ||
          _effectiveStartOffset(style) > attributionStart + 4;
    });
    if (!bodyHasRole || !_hasVisualBoundary(container)) return false;
    _parseQuoteElements(body, attribution);
    return true;
  }

  void _parseQuoteElements(
    List<XmlElement> bodyElements,
    XmlElement? attributionElement, {
    Set<int> stanzaBreakAfter = const {},
    bool semanticBlockquote = false,
  }) {
    final start = blocks.length;
    final previous = _insideQuote;
    _insideQuote = true;
    for (final element in bodyElements) {
      _pushTextBlock(element, TextBlockKind.paragraph, _blockStyleFor(element));
    }
    TextBlock? attribution;
    if (attributionElement != null) {
      final attributionStart = blocks.length;
      _pushTextBlock(
        attributionElement,
        TextBlockKind.paragraph,
        _blockStyleFor(attributionElement),
      );
      if (blocks.length == attributionStart + 1 && blocks.last is TextBlock) {
        attribution = blocks.removeLast() as TextBlock;
      }
    }
    _insideQuote = previous;
    final parsed = blocks.sublist(start);
    blocks.removeRange(start, blocks.length);
    final body = parsed
        .whereType<TextBlock>()
        .map(
          (block) => _copyTextBlock(
            block,
            kind: TextBlockKind.blockquote,
            style: semanticBlockquote
                ? _defaultQuoteStyle(block.style)
                : block.style,
          ),
        )
        .toList();
    final detached = parsed.where((block) => block is! TextBlock).toList();
    if (body.isEmpty) {
      blocks.addAll(detached);
      return;
    }
    for (final index in stanzaBreakAfter) {
      if (index < 0 || index >= body.length) continue;
      final block = body[index];
      body[index] = _copyTextBlock(
        block,
        style: block.style.copyWith(hardBreakAfter: true),
      );
    }
    final resolvedAttribution = attribution == null
        ? null
        : _copyTextBlock(attribution, kind: TextBlockKind.quoteAttribution);
    blocks.addAll(detached);
    blocks.add(
      QuoteBlock(
        body: body,
        attribution: resolvedAttribution,
        source: _combinedTextSource([...body, ?resolvedAttribution]),
      ),
    );
  }

  void _parseNode(XmlElement element, int listDepth) {
    final blockStart = blocks.length;
    final name = _name(element);
    if (_skippedElements.contains(name)) return;
    if (name != 'p') _paragraphListIndents.clear();

    final props = styles.cascadedProperties(element);
    if (_isPageBreak(props['page-break-before'] ?? props['break-before'])) {
      blocks.add(const PageBreakBlock());
    }

    if (!_insideNote && _isSemanticFootnoteDefinition(element)) {
      _parseNoteDefinition(element, listDepth);
      _rememberElementSource(element, blockStart);
      return;
    }
    if (!_insideNote && _isImplicitNoteContainer(element)) {
      _parseImplicitNoteContainer(element);
      _rememberElementSource(element, blockStart);
      return;
    }
    if (!_insideNote && _startsImplicitNoteEntry(element)) {
      _parseNoteDefinition(element, listDepth);
      _rememberElementSource(element, blockStart);
      return;
    }

    switch (name) {
      case 'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6':
        final level = int.tryParse(name.substring(1)) ?? 1;
        final style = _blockStyleFor(
          element,
          const BlockStyle(marginBefore: 32, marginAfter: 8, lineHeight: 1.3),
        );
        _pushTextBlock(
          element,
          TextBlockKind.heading,
          style,
          headingLevel: level,
        );
      case 'p':
        var style = _blockStyleFor(element);
        if (_hasStandaloneQuoteLayout(element) &&
            (_hasQuoteSemanticWord(element) ||
                _hasDistinctQuoteTypography(element))) {
          _parseQuoteElements([element], null);
          break;
        }
        if (!_insideQuote && _isAuthoredSpacingParagraph(element)) {
          blocks.add(
            SeparatorBlock(
              kind: SeparatorKind.spacing,
              inQuote: _insideQuote,
              style: style,
            ),
          );
          break;
        }
        if (_containsDisplayMath(element) && _hasOnlyMathContent(element)) {
          style = style.copyWith(
            align: BlockAlign.center,
            marginBefore: math.max(style.marginBefore, 12),
            marginAfter: math.max(style.marginAfter, 12),
          );
        }
        final hasMarker = _hasExplicitParagraphListMarker(element);
        final markerlessNestedItem =
            !hasMarker &&
            style.indent < -0.5 &&
            _paragraphListIndents.isNotEmpty &&
            style.marginStart + style.marginStartFraction * 1000 >
                _paragraphListIndents.first + 4;
        if (hasMarker || markerlessNestedItem) {
          final depth = _paragraphListDepth(style);
          style = style.copyWith(indent: 0);
          _pushTextBlock(
            element,
            TextBlockKind.listItem,
            style,
            listOrdinal: 1,
            listDepth: depth,
            listMarkerVisible: hasMarker,
            stripAuthoredListMarker: hasMarker,
          );
        } else {
          _paragraphListIndents.clear();
          _pushTextBlock(element, TextBlockKind.paragraph, style);
        }
      case 'blockquote':
        _parseQuote(element);
      case 'pre':
        _pushTextBlock(
          element,
          TextBlockKind.preformatted,
          _blockStyleFor(element, const BlockStyle(lineHeight: 1.35)),
          preserveWhitespace: true,
        );
      case 'ul':
        _parseList(element, ordered: false, depth: listDepth);
      case 'ol':
        _parseList(element, ordered: true, depth: listDepth);
      case 'dl':
        _parseDefinitionList(element, listDepth);
      case 'li':
        // Bare <li> outside an enclosing list.
        _emitListItem(element, ordered: false, ordinal: 1, depth: listDepth);
      case 'img' || 'image':
        _pushImage(element);
      case 'hr':
        blocks.add(SeparatorBlock(inQuote: _insideQuote));
      case 'br':
        blocks.add(const LineBreakBlock());
      case 'table':
        _parseTable(element);
      case 'figure':
        _parseFigure(element, listDepth);
      case 'figcaption':
        _pushTextBlock(
          element,
          TextBlockKind.paragraph,
          _blockStyleFor(element),
        );
      default:
        // Transparent container (div/section/article/…) or unknown element:
        // recurse, lifting mixed inline content into paragraphs.
        _parseContainer(element, listDepth);
    }

    if (_isPageBreak(props['page-break-after'] ?? props['break-after'])) {
      blocks.add(const PageBreakBlock());
    }
    _rememberElementSource(element, blockStart);
  }

  void _rememberElementSource(XmlElement element, int blockStart) {
    for (final block in blocks.skip(blockStart)) {
      final source = _firstBlockSource(block);
      if (source != null) {
        _elementSources[element] = source.start;
        return;
      }
    }
  }

  SourceAnchor? _sourceForElement(XmlElement element) {
    XmlElement? current = element;
    while (current != null) {
      final source = _elementSources[current];
      if (source != null) return source;
      current = current.parentElement;
    }
    for (final descendant in element.descendants.whereType<XmlElement>()) {
      final source = _elementSources[descendant];
      if (source != null) return source;
    }
    return null;
  }

  static SourceRange? _firstBlockSource(Block block) {
    switch (block) {
      case TextBlock(:final source) ||
          ImageBlock(:final source) ||
          FigureBlock(:final source) ||
          QuoteBlock(:final source) ||
          NoteBlock(:final source):
        return source;
      case TableBlock(:final source, :final rows):
        if (source != null) return source;
        for (final row in rows) {
          for (final cell in row.cells) {
            if (cell.source != null) return cell.source;
          }
        }
      default:
        return null;
    }
    return null;
  }

  static bool _isPageBreak(String? value) =>
      value == 'always' || value == 'page';

  bool _startsImplicitNoteEntry(XmlElement element) {
    if (!const {
      'p',
      'li',
      'dd',
      'div',
      'aside',
      'section',
    }.contains(_name(element))) {
      return false;
    }
    for (final entry in _footnoteLinks.entries) {
      if (entry.value != LinkRole.footnoteBacklink) continue;
      var current = entry.key.parentElement;
      while (current != null && !identical(current, element)) {
        if (_isBlockBoundary(_name(current))) break;
        current = current.parentElement;
      }
      if (identical(current, element)) return true;
    }
    return false;
  }

  void _parseNoteDefinition(XmlElement element, int listDepth) {
    final start = blocks.length;
    final previous = _insideNote;
    _insideNote = true;
    _parseContainer(element, listDepth);
    _insideNote = previous;
    if (blocks.length == start) return;
    final nested = blocks.sublist(start);
    blocks.removeRange(start, blocks.length);
    final marked = nested.map(_markFootnoteDefinition).toList(growable: false);
    blocks.add(
      NoteBlock(
        kind: NoteBlockKind.definition,
        blocks: marked,
        source: _combinedBlockSource(marked),
      ),
    );
  }

  void _parseQuote(XmlElement quote) {
    final children = <XmlElement>[];
    final stanzaBreakAfter = <int>{};
    for (final child in quote.childElements) {
      if (_name(child) == 'br' && children.isNotEmpty) {
        stanzaBreakAfter.add(children.length - 1);
      } else if (_isQuoteTextCandidate(child) ||
          const {'cite', 'footer'}.contains(_name(child))) {
        children.add(child);
      }
    }
    if (children.isEmpty) {
      final start = blocks.length;
      final previous = _insideQuote;
      _insideQuote = true;
      _pushTextBlock(
        quote,
        TextBlockKind.blockquote,
        _defaultQuoteStyle(_blockStyleFor(quote)),
      );
      _insideQuote = previous;
      final parsed = blocks.sublist(start);
      blocks.removeRange(start, blocks.length);
      final body = parsed.whereType<TextBlock>().toList(growable: false);
      blocks.addAll(parsed.where((block) => block is! TextBlock));
      if (body.isNotEmpty) {
        blocks.add(QuoteBlock(body: body, source: _combinedTextSource(body)));
      }
      return;
    }

    final last = children.last;
    final lastIsAttribution =
        const {'cite', 'footer'}.contains(_name(last)) ||
        (children.length > 1 && _blockStyleFor(last).align == BlockAlign.end);
    _parseQuoteElements(
      lastIsAttribution ? children.sublist(0, children.length - 1) : children,
      lastIsAttribution ? last : null,
      stanzaBreakAfter: stanzaBreakAfter,
      semanticBlockquote: true,
    );
  }

  void _parseDefinitionList(XmlElement list, int depth) {
    for (final child in list.childElements) {
      switch (_name(child)) {
        case 'dt':
          _pushDefinitionEntry(child, TextBlockKind.definitionTerm, depth);
        case 'dd':
          _pushDefinitionEntry(
            child,
            TextBlockKind.definitionDescription,
            depth,
          );
          for (final nested in child.childElements.where(
            (node) => _name(node) == 'dl',
          )) {
            _parseDefinitionList(nested, depth + 1);
          }
        case 'dl':
          _parseDefinitionList(child, depth + 1);
      }
    }
  }

  static BlockStyle _defaultQuoteStyle(BlockStyle style) {
    final effective = style.marginStart + style.marginStartFraction * 1000;
    return effective.abs() <= 0.001 ? style.copyWith(marginStart: 24) : style;
  }

  void _pushDefinitionEntry(XmlElement element, TextBlockKind kind, int depth) {
    var style = _blockStyleFor(element);
    final semanticIndent =
        24.0 * (depth + (kind == TextBlockKind.definitionDescription ? 1 : 0));
    style = style.copyWith(
      indent: 0,
      marginStart: math.max(style.marginStart, semanticIndent),
    );
    final textStyle = _textStyleForBlock(element, kind);
    final collector = _InlineCollector(preserveWhitespace: false);
    for (final child in element.children) {
      if (child is XmlElement && _name(child) == 'dl') continue;
      if (child is XmlElement &&
          _isBlockBoundary(_name(child)) &&
          collector.content.isNotEmpty) {
        collector.pushBreakIfNeeded();
      }
      _collectInlineNode(child, textStyle, null, collector);
    }
    collector.finish();
    if (collector.content.isNotEmpty) {
      _emitTextBlock(kind, style, collector.content, listDepth: depth);
    }
    for (final image in _descendantImages(element, skipNestedLists: true)) {
      _pushImage(image);
    }
  }

  /// Handles containers with mixed inline and block children: inline runs
  /// between block-level children are collected into paragraphs.
  void _parseContainer(XmlElement container, int listDepth) {
    if (_tryParseStructuralQuote(container)) return;
    final hasOnlyBlockChildren = container.children.every(
      (node) => node is XmlElement
          ? _isBlockBoundary(_name(node))
          : node is XmlText && node.value.trim().isEmpty,
    );
    if (hasOnlyBlockChildren) {
      _parseChildren(container, listDepth: listDepth);
      return;
    }
    final style = _blockStyleFor(container);
    final textStyle = _textStyleForBlock(container, TextBlockKind.paragraph);
    var collector = _InlineCollector(preserveWhitespace: false);

    void flush() {
      collector.finish();
      if (collector.content.isEmpty) return;
      _emitTextBlock(TextBlockKind.paragraph, style, collector.content);
      collector = _InlineCollector(preserveWhitespace: false);
    }

    final children = container.children.toList();
    var index = 0;
    while (index < children.length) {
      final child = children[index];
      if (child is XmlElement && _isBlockBoundary(_name(child))) {
        flush();
        final quoteCount = _tryParseSiblingQuote(children, index);
        if (quoteCount > 0) {
          index += quoteCount;
          continue;
        }
        _parseNode(child, listDepth);
        index++;
        continue;
      }
      if (child is XmlElement && _hasDescendantImage(child)) {
        flush();
        _pushTextBlock(child, TextBlockKind.paragraph, style);
        index++;
        continue;
      }
      _collectInlineNode(child, textStyle, null, collector);
      index++;
    }
    flush();
  }

  void _parseList(
    XmlElement list, {
    required bool ordered,
    required int depth,
  }) {
    final items = list.childElements
        .where((item) => _name(item) == 'li')
        .toList();
    final reversed = ordered && _attr(list, 'reversed') != null;
    var ordinal =
        int.tryParse(_attr(list, 'start') ?? '') ??
        (reversed ? items.length : 1);
    for (final item in items) {
      final blockStart = blocks.length;
      final explicit = int.tryParse(_attr(item, 'value') ?? '');
      if (explicit != null) ordinal = explicit;
      _emitListItem(item, ordered: ordered, ordinal: ordinal, depth: depth);
      _rememberElementSource(item, blockStart);
      ordinal += reversed ? -1 : 1;
    }
  }

  int _paragraphListDepth(BlockStyle style) {
    const indentTolerance = 4.0;
    const fractionReferenceWidth = 1000.0;
    final indent =
        style.marginStart + style.marginStartFraction * fractionReferenceWidth;
    if (_paragraphListIndents.isEmpty) {
      _paragraphListIndents.add(indent);
      return 0;
    }

    final previous = _paragraphListIndents.last;
    if (indent > previous + indentTolerance) {
      _paragraphListIndents.add(indent);
    } else {
      final knownLevel = _paragraphListIndents.lastIndexWhere(
        (known) => (indent - known).abs() <= indentTolerance,
      );
      if (knownLevel >= 0) {
        _paragraphListIndents.removeRange(
          knownLevel + 1,
          _paragraphListIndents.length,
        );
      } else {
        final parent = _paragraphListIndents.lastIndexWhere(
          (known) => known < indent,
        );
        if (parent >= 0) {
          _paragraphListIndents.removeRange(
            parent + 1,
            _paragraphListIndents.length,
          );
          _paragraphListIndents.add(indent);
        } else {
          _paragraphListIndents
            ..clear()
            ..add(indent);
        }
      }
    }
    return _paragraphListIndents.length - 1;
  }

  void _emitListItem(
    XmlElement item, {
    required bool ordered,
    required int ordinal,
    required int depth,
  }) {
    // List indentation is resolved from the active reader font in layout.
    // Baking a fixed 24 px offset here made it get applied a second time and
    // caused deeply nested lists to collapse into a very narrow column.
    final style = _blockStyleFor(item);
    final textStyle = _textStyleForBlock(item, TextBlockKind.listItem);
    final collector = _InlineCollector(preserveWhitespace: false);
    for (final child in item.children) {
      if (child is XmlElement && _isStructuredContainer(_name(child))) {
        continue;
      }
      if (child is XmlElement &&
          _isBlockBoundary(_name(child)) &&
          collector.content.isNotEmpty) {
        collector.pushBreakIfNeeded();
      }
      _collectInlineNode(child, textStyle, null, collector);
    }
    collector.finish();
    if (collector.content.isNotEmpty) {
      _emitTextBlock(
        TextBlockKind.listItem,
        style,
        collector.content,
        listOrdered: ordered,
        listOrdinal: ordinal,
        listDepth: depth,
      );
    }
    final images = _descendantImages(
      item,
      skipNestedLists: true,
    ).toList(growable: false);
    for (var index = 0; index < images.length; index++) {
      _pushImage(
        images[index],
        containerMarginBefore: collector.content.isEmpty && index == 0
            ? style.marginBefore
            : null,
        containerMarginAfter:
            collector.content.isEmpty && index + 1 == images.length
            ? style.marginAfter
            : null,
      );
    }
    for (final child in item.childElements) {
      if (_isStructuredContainer(_name(child))) {
        _parseNode(child, depth + 1);
      }
    }
  }

  void _parseTable(XmlElement table) {
    final parsedRows = <TableRow>[];
    for (final row in table.descendants.whereType<XmlElement>()) {
      if (_name(row) != 'tr' || _nearestTableAncestor(row) != table) {
        continue;
      }
      final parsedCells = <TableCell>[];
      for (final cell in row.childElements) {
        final cellName = _name(cell);
        if (cellName != 'td' && cellName != 'th') continue;
        var textStyle = _textStyleForBlock(cell, TextBlockKind.paragraph);
        if (cellName == 'th' && !textStyle.bold) {
          textStyle = _copyTextStyle(textStyle, bold: true);
        }
        final collector = _InlineCollector(preserveWhitespace: false);
        for (final child in cell.children) {
          if (child is XmlElement &&
              _isBlockBoundary(_name(child)) &&
              collector.content.isNotEmpty) {
            collector.pushBreakIfNeeded();
          }
          _collectInlineNode(
            child,
            textStyle,
            null,
            collector,
            preserveBlockBoundaries: true,
          );
        }
        collector.finish();
        final nodeId = _allocateNode();
        final textLength = collector.content.fold<int>(
          0,
          (length, inline) =>
              length + (inline is TextRun ? inline.text.length : 1),
        );
        parsedCells.add(
          TableCell(
            inlines: List.unmodifiable(collector.content),
            header: cellName == 'th',
            columnSpan: _positiveSpan(_attr(cell, 'colspan')),
            rowSpan: _positiveSpan(_attr(cell, 'rowspan')),
            authoredAlignment: _tableCellAlignment(cell),
            style: _blockStyleFor(cell),
            source: _sourceFor(nodeId, textLength),
            nodeId: nodeId,
          ),
        );
        _elementSources[cell] = SourceAnchor(
          spine: spineIndex,
          node: nodeId,
          textOffset: 0,
        );
      }
      if (parsedCells.isNotEmpty) {
        parsedRows.add(TableRow(List.unmodifiable(parsedCells)));
      }
    }
    if (parsedRows.isNotEmpty) {
      final nodeId = _allocateNode();
      blocks.add(
        TableBlock(
          rows: List.unmodifiable(parsedRows),
          style: _blockStyleFor(table),
          source: _sourceFor(nodeId, 0),
        ),
      );
    }
  }

  static int _positiveSpan(String? raw) =>
      (int.tryParse(raw ?? '') ?? 1).clamp(1, 64).toInt();

  BlockAlign? _tableCellAlignment(XmlElement cell) {
    final inherited = _inheritedTextAlignment(cell);
    if (inherited != null) return inherited;
    for (final descendant in cell.descendants.whereType<XmlElement>()) {
      if (!_isBlockBoundary(_name(descendant))) continue;
      final declared = _declaredTextAlignment(descendant);
      if (declared != null) return declared;
    }
    return null;
  }

  static XmlElement? _nearestTableAncestor(XmlElement element) {
    var current = element.parentElement;
    while (current != null) {
      if (_name(current) == 'table') return current;
      current = current.parentElement;
    }
    return null;
  }

  bool _hasDescendantImage(XmlElement element) =>
      element.descendants.whereType<XmlElement>().any(
        (node) =>
            !identical(node, element) &&
            (_name(node) == 'img' || _name(node) == 'image') &&
            !_isFootnoteReferenceImage(node),
      );

  bool _isFootnoteReferenceImage(XmlElement image) {
    var ancestor = image.parentElement;
    while (ancestor != null) {
      if (_name(ancestor) == 'a' &&
          _footnoteLinks[ancestor] == LinkRole.footnoteReference) {
        return true;
      }
      ancestor = ancestor.parentElement;
    }
    return false;
  }

  String _footnoteReferenceImageMarker(XmlElement image) {
    String? firstNonEmpty(Iterable<String?> values) {
      for (final value in values) {
        final trimmed = value?.trim();
        if (trimmed != null && trimmed.isNotEmpty) return trimmed;
      }
      return null;
    }

    final accessibleText = firstNonEmpty([
      _attr(image, 'alt'),
      _attr(image, 'title'),
      _attr(image, 'aria-label'),
    ]);
    final noteText = firstNonEmpty([
      _attr(image, 'zy-footnote'),
      accessibleText,
    ]);
    if (noteText?.contains('译者注') ?? false) return '译';
    return accessibleText == null
        ? '注'
        : (_normalizeFootnoteMarker(accessibleText) ?? '注');
  }

  Iterable<XmlElement> _descendantImages(
    XmlElement element, {
    bool skipNestedLists = false,
  }) {
    bool underNestedList(XmlElement node) {
      if (!skipNestedLists) return false;
      var current = node.parentElement;
      while (current != null && !identical(current, element)) {
        if (_isStructuredContainer(_name(current))) return true;
        current = current.parentElement;
      }
      return false;
    }

    return element.descendants.whereType<XmlElement>().where(
      (node) =>
          !identical(node, element) &&
          (_name(node) == 'img' || _name(node) == 'image') &&
          !underNestedList(node) &&
          !_isFootnoteReferenceImage(node),
    );
  }

  void _pushTextBlock(
    XmlElement element,
    TextBlockKind kind,
    BlockStyle style, {
    int headingLevel = 0,
    bool preserveWhitespace = false,
    bool listOrdered = false,
    int listOrdinal = 0,
    int listDepth = 0,
    bool listMarkerVisible = true,
    bool stripAuthoredListMarker = false,
  }) {
    final nestedAlignment = _soleContentBlockAlignment(element);
    if (nestedAlignment != null) {
      style = style.copyWith(
        align: nestedAlignment,
        authoredAlignment: nestedAlignment,
      );
    }
    final textStyle = _textStyleForBlock(
      element,
      kind,
      headingLevel: headingLevel,
    );
    final collector = _InlineCollector(preserveWhitespace: preserveWhitespace);
    _collectInline(element, textStyle, null, collector);
    collector.finish();
    if (stripAuthoredListMarker) {
      _stripAuthoredListMarker(collector.content);
    }
    if (collector.content.isNotEmpty) {
      _emitTextBlock(
        kind,
        style,
        collector.content,
        headingLevel: headingLevel,
        listOrdered: listOrdered,
        listOrdinal: listOrdinal,
        listDepth: listDepth,
        listMarkerVisible: listMarkerVisible,
      );
    }
    final images = _descendantImages(element).toList(growable: false);
    for (var index = 0; index < images.length; index++) {
      _pushImage(
        images[index],
        containerMarginBefore: collector.content.isEmpty && index == 0
            ? style.marginBefore
            : null,
        containerMarginAfter:
            collector.content.isEmpty && index + 1 == images.length
            ? style.marginAfter
            : null,
      );
    }
  }

  void _emitTextBlock(
    TextBlockKind kind,
    BlockStyle style,
    List<Inline> inlines, {
    int headingLevel = 0,
    bool listOrdered = false,
    int listOrdinal = 0,
    int listDepth = 0,
    bool listMarkerVisible = true,
  }) {
    final nodeId = _allocateNode();
    // Source range spans the block's normalized plain text (UTF-16 units;
    // Dart String.length is already UTF-16 code units).
    var textLength = 0;
    for (final inline in inlines) {
      textLength += switch (inline) {
        TextRun(:final text) => text.length,
        BreakInline() => 1,
        MathInline(:final latex) => latex.length,
      };
    }
    blocks.add(
      TextBlock(
        kind: kind,
        headingLevel: kind == TextBlockKind.heading ? headingLevel : 0,
        listOrdered: listOrdered,
        listOrdinal: listOrdinal,
        listDepth: listDepth,
        listMarkerVisible: listMarkerVisible,
        inlines: inlines,
        style: style,
        source: _sourceFor(nodeId, textLength),
        nodeId: nodeId,
      ),
    );
  }

  void _parseFigure(XmlElement figure, int listDepth) {
    final captionNodes = figure.descendants
        .whereType<XmlElement>()
        .where(
          (node) =>
              _name(node) == 'figcaption' &&
              !_hasNamedAncestor(node, figure, 'figure'),
        )
        .toList();
    final imageNodes = figure.descendants
        .whereType<XmlElement>()
        .where(
          (node) =>
              (_name(node) == 'img' || _name(node) == 'image') &&
              !_hasNamedAncestor(node, figure, 'figure') &&
              !_hasNamedAncestor(node, figure, 'figcaption'),
        )
        .toList();
    final unsupportedCaption = captionNodes.any(
      (caption) => caption.descendants.whereType<XmlElement>().any(
        (node) =>
            const {'figure', 'img', 'image', 'table'}.contains(_name(node)),
      ),
    );
    if (imageNodes.isEmpty || unsupportedCaption) {
      _parseContainer(figure, listDepth);
      return;
    }

    final figureNodeId = _allocateNode();
    final figureSource = _sourceFor(figureNodeId, 0);
    var captionPosition = CaptionPosition.after;
    for (final node in figure.descendants.whereType<XmlElement>()) {
      if (_hasNamedAncestor(node, figure, 'figure')) continue;
      final name = _name(node);
      if (name == 'figcaption') {
        captionPosition = CaptionPosition.before;
        break;
      }
      if ((name == 'img' || name == 'image') &&
          !_hasNamedAncestor(node, figure, 'figcaption')) {
        captionPosition = CaptionPosition.after;
        break;
      }
    }

    final images = <ImageBlock>[];
    for (final element in imageNodes) {
      final image = _imageBlockFor(
        element,
        source: images.isEmpty ? figureSource : null,
      );
      if (image == null) continue;
      images.add(image);
      if (image.source != null) {
        _elementSources[element] = image.source!.start;
      }
    }
    if (images.isEmpty) return;

    final captions = <TextBlock>[];
    for (final caption in captionNodes) {
      final blockStart = blocks.length;
      _parseContainer(caption, listDepth);
      final parsed = blocks.sublist(blockStart);
      blocks.removeRange(blockStart, blocks.length);
      final captionStart = captions.length;
      for (final block in parsed) {
        if (block is! TextBlock) continue;
        captions.add(
          TextBlock(
            kind: TextBlockKind.caption,
            inlines: block.inlines,
            style: block.style,
            source: block.source,
            nodeId: block.nodeId,
          ),
        );
      }
      if (captions.length > captionStart &&
          captions[captionStart].source != null) {
        _elementSources[caption] = captions[captionStart].source!.start;
      }
    }

    blocks.add(
      FigureBlock(
        images: images,
        captions: captions,
        captionPosition: captionPosition,
        style: _blockStyleFor(figure),
        source: figureSource,
      ),
    );
  }

  static bool _hasNamedAncestor(XmlElement node, XmlElement root, String name) {
    var current = node.parentElement;
    while (current != null && !identical(current, root)) {
      if (_name(current) == name) return true;
      current = current.parentElement;
    }
    return false;
  }

  void _pushImage(
    XmlElement element, {
    double? containerMarginBefore,
    double? containerMarginAfter,
  }) {
    final image = _imageBlockFor(
      element,
      containerMarginBefore: containerMarginBefore,
      containerMarginAfter: containerMarginAfter,
    );
    if (image == null) return;
    final alt = image.alt.trim().toLowerCase();
    final genericAlt =
        alt.isEmpty ||
        const {'image', 'ornament', 'separator', 'divider'}.contains(alt);
    var linked = false;
    XmlElement? ancestor = element.parentElement;
    while (ancestor != null) {
      if (_name(ancestor) == 'a' && _attr(ancestor, 'href') != null) {
        linked = true;
        break;
      }
      ancestor = ancestor.parentElement;
    }
    if (!_insideQuote &&
        !linked &&
        genericAlt &&
        (isDecorativeSeparatorImage?.call(image.href) ?? false)) {
      blocks.add(SeparatorBlock(kind: SeparatorKind.ornament, image: image));
    } else {
      blocks.add(image);
    }
  }

  ImageBlock? _imageBlockFor(
    XmlElement element, {
    SourceRange? source,
    double? containerMarginBefore,
    double? containerMarginAfter,
  }) {
    final src = _attr(element, 'src') ?? _attr(element, 'href');
    if (src == null || src.trim().isEmpty) return null;
    final imageSource = source ?? _sourceFor(_allocateNode(), 0);
    return ImageBlock(
      href: resolvePackageHref(baseDir, src),
      alt: _attr(element, 'alt') ?? '',
      style: _imageStyleFor(
        element,
        containerMarginBefore: containerMarginBefore,
        containerMarginAfter: containerMarginAfter,
      ),
      source: imageSource,
    );
  }

  // --------------------------------------------------------------- inlines

  void _collectInline(
    XmlNode node,
    TextStyle inherited,
    String? link,
    _InlineCollector collector, {
    bool preserveBlockBoundaries = false,
  }) {
    for (final child in node.children) {
      _collectInlineNode(
        child,
        inherited,
        link,
        collector,
        preserveBlockBoundaries: preserveBlockBoundaries,
      );
    }
  }

  void _collectInlineNode(
    XmlNode node,
    TextStyle inherited,
    String? link,
    _InlineCollector collector, {
    bool preserveBlockBoundaries = false,
  }) {
    if (node is XmlText) {
      collector.pushText(node.value, inherited, link);
      return;
    }
    if (node is XmlCDATA) {
      collector.pushText(node.value, inherited, link);
      return;
    }
    if (node is! XmlElement) return;
    final name = _name(node);
    if (name == 'br') {
      collector.pushBreak();
      return;
    }
    if (name == 'img' || name == 'image') {
      if (inherited.linkRole == LinkRole.footnoteReference && link != null) {
        collector.pushFootnoteReferenceMarker(
          _footnoteReferenceImageMarker(node),
          inherited,
          link,
        );
      }
      return;
    }
    if (name == 'script' || name == 'style') {
      return;
    }
    if (preserveBlockBoundaries && _isBlockBoundary(name)) {
      collector.pushBreakIfNeeded();
    }

    var style = inherited;
    switch (name) {
      case 'b' || 'strong':
        style = _copyTextStyle(style, bold: true);
      case 'i' || 'em' || 'cite':
        style = _copyTextStyle(style, italic: true);
      case 'u' || 'ins':
        style = _copyTextStyle(style, underline: true);
      case 's' || 'strike' || 'del':
        style = _copyTextStyle(style, strikethrough: true);
      case 'sup':
        style = _copyTextStyle(
          style,
          baseline: TextBaselineShift.superscript,
          sizeScale: style.sizeScale * 0.75,
        );
      case 'sub':
        style = _copyTextStyle(
          style,
          baseline: TextBaselineShift.subscript,
          sizeScale: style.sizeScale * 0.75,
        );
      case 'small':
        style = _copyTextStyle(style, sizeScale: style.sizeScale * 0.85);
      case 'big':
        style = _copyTextStyle(style, sizeScale: style.sizeScale * 1.2);
    }
    final classes = (_attr(node, 'class') ?? '')
        .split(RegExp(r'\s+'))
        .map((value) => value.toLowerCase());
    if (classes.any((value) => value == 'footnote' || value == 'footnote1')) {
      style = _copyTextStyle(style, inlineRole: InlineRole.footnote);
    }
    style = _applyCssTextProperties(
      style,
      styles.cascadedProperties(node),
      inheritedSize: inherited.sizeScale,
    );

    if (name == 'span' && classes.any((value) => value == 'math')) {
      final latex = node.descendants
          .whereType<XmlText>()
          .map((text) => text.value)
          .join()
          .trim();
      if (latex.isNotEmpty) {
        collector.pushMath(
          latex,
          display: classes.any((value) => value == 'math-display'),
          sizeScale: style.sizeScale,
        );
      }
      return;
    }

    var childLink = link;
    if (name == 'a') {
      final rawHref = _attr(node, 'href');
      if (rawHref != null && rawHref.trim().isNotEmpty) {
        childLink = _resolveLink(rawHref);
      }
      final linkRole = _footnoteLinks[node];
      if (linkRole != null) {
        style = _copyTextStyle(style, linkRole: linkRole);
      }
    }
    _collectInline(
      node,
      style,
      childLink,
      collector,
      preserveBlockBoundaries: preserveBlockBoundaries,
    );
  }

  String _resolveLink(String rawHref) {
    final trimmed = rawHref.trim();
    if (trimmed.startsWith('#')) return '$href$trimmed';
    return resolvePackageHref(baseDir, trimmed);
  }

  // ---------------------------------------------------------------- styles

  BlockAlign? _declaredTextAlignment(XmlElement element) => _blockAlign(
    styles.cascadedProperties(element)['text-align'] ?? _attr(element, 'align'),
  );

  BlockAlign? _inheritedTextAlignment(XmlElement element) {
    BlockAlign? alignment;
    for (final ancestor in _chain(element)) {
      alignment = _declaredTextAlignment(ancestor) ?? alignment;
    }
    return alignment;
  }

  BlockAlign? _soleContentBlockAlignment(XmlElement element) {
    var container = element;
    while (true) {
      XmlElement? soleElement;
      for (final child in container.children) {
        if ((child is XmlText && child.value.trim().isNotEmpty) ||
            (child is XmlCDATA && child.value.trim().isNotEmpty)) {
          return null;
        }
        if (child is XmlElement) {
          if (soleElement != null) return null;
          soleElement = child;
        }
      }
      final child = soleElement;
      if (child == null) return null;
      final display = styles.cascadedProperties(child)['display'];
      final establishesBlockBox = const {
        'block',
        'inline-block',
        'flow-root',
        'list-item',
        'table-cell',
      }.contains(display?.split(RegExp(r'\s+')).firstOrNull);
      if (establishesBlockBox) return _inheritedTextAlignment(child);
      container = child;
    }
  }

  /// Element chain from the document root down to (and including) [element].
  static List<XmlElement> _chain(XmlElement element) {
    final chain = <XmlElement>[];
    XmlElement? current = element;
    while (current != null) {
      chain.add(current);
      current = current.parentElement;
    }
    return chain.reversed.toList();
  }

  BlockStyle _blockStyleFor(
    XmlElement element, [
    BlockStyle base = BlockStyle.normal,
  ]) {
    var align = base.align;
    var authoredAlignment = base.authoredAlignment;
    var marginBefore = base.marginBefore;
    var marginAfter = base.marginAfter;
    var marginStart = base.marginStart;
    var marginStartFraction = base.marginStartFraction;
    var indent = base.indent;
    var lineHeight = base.lineHeight;

    for (final ancestor in _chain(element)) {
      final isSelf = identical(ancestor, element);
      final props = styles.cascadedProperties(ancestor);
      // Reading IR flattens nested boxes: accumulate the start-side offset
      // contributed by every containing box.
      for (final value in [
        _firstOf(props, const ['margin-inline-start', 'margin-left']),
        _firstOf(props, const ['padding-inline-start', 'padding-left']),
      ]) {
        final length = _cssHorizontalLength(value);
        if (length == null) continue;
        marginStart += length.$1;
        marginStartFraction += length.$2;
      }
      final declaredAlign = _blockAlign(
        props['text-align'] ?? _attr(ancestor, 'align'),
      );
      if (declaredAlign != null) {
        align = declaredAlign;
        authoredAlignment = declaredAlign;
      }
      final textIndent = _cssLength(props['text-indent']);
      if (textIndent != null) indent = textIndent;
      final cssLineHeight = _cssLineHeight(props['line-height']);
      if (cssLineHeight != null) lineHeight = cssLineHeight;
      if (isSelf) {
        final top = _cssLength(props['margin-top']);
        if (top != null) marginBefore = top;
        final bottom = _cssLength(props['margin-bottom']);
        if (bottom != null) marginAfter = bottom;
      }
    }

    return BlockStyle(
      align: align,
      authoredAlignment: authoredAlignment,
      marginBefore: marginBefore,
      marginAfter: marginAfter,
      marginStart: marginStart,
      marginStartFraction: marginStartFraction,
      indent: indent,
      lineHeight: lineHeight,
    );
  }

  static BlockAlign? _blockAlign(String? value) =>
      switch (value?.trim().toLowerCase()) {
        'center' => BlockAlign.center,
        'right' || 'end' => BlockAlign.end,
        'justify' => BlockAlign.justify,
        'left' || 'start' => BlockAlign.start,
        _ => null,
      };

  TextStyle _textStyleForBlock(
    XmlElement element,
    TextBlockKind kind, {
    int headingLevel = 0,
  }) {
    var style = TextStyle.plain;
    for (final ancestor in _chain(element)) {
      final inheritedSize = style.sizeScale;
      if (identical(ancestor, element)) {
        style = _applySemanticBlockStyle(style, kind, headingLevel);
      }
      style = _applyCssTextProperties(
        style,
        styles.cascadedProperties(ancestor),
        inheritedSize: inheritedSize,
      );
    }
    return style;
  }

  static TextStyle _applySemanticBlockStyle(
    TextStyle style,
    TextBlockKind kind,
    int headingLevel,
  ) {
    switch (kind) {
      case TextBlockKind.heading:
        final scale = switch (headingLevel) {
          1 => 1.5,
          2 => 1.3,
          3 => 1.15,
          _ => 1.05,
        };
        return _copyTextStyle(
          style,
          bold: true,
          sizeScale: style.sizeScale * scale,
        );
      case TextBlockKind.preformatted:
        return _copyTextStyle(style, sizeScale: style.sizeScale * 0.9);
      case TextBlockKind.definitionTerm:
        return _copyTextStyle(style, bold: true);
      default:
        return style;
    }
  }

  ImageStyle _imageStyleFor(
    XmlElement element, {
    double? containerMarginBefore,
    double? containerMarginAfter,
  }) {
    ImageLength? width = _imageLength(_attr(element, 'width'));
    ImageLength? height = _imageLength(_attr(element, 'height'));
    ImageLength? maxWidth;
    ImageLength? maxHeight;
    final props = styles.cascadedProperties(element);
    width = _imageLength(props['width']) ?? width;
    height = _imageLength(props['height']) ?? height;
    maxWidth = _imageLength(props['max-width']);
    maxHeight = _imageLength(props['max-height']);
    final authoredMarginBefore = _cssLength(props['margin-top']) ?? 0;
    final authoredMarginAfter = _cssLength(props['margin-bottom']) ?? 0;
    return ImageStyle(
      width: width,
      height: height,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
      marginBefore: math.max(authoredMarginBefore, containerMarginBefore ?? 0),
      marginAfter: math.max(authoredMarginAfter, containerMarginAfter ?? 0),
    );
  }

  static String? _firstOf(Map<String, String> props, List<String> names) {
    for (final name in names) {
      final value = props[name];
      if (value != null) return value;
    }
    return null;
  }
}

TextStyle _copyTextStyle(
  TextStyle base, {
  bool? bold,
  bool? italic,
  bool? underline,
  bool? strikethrough,
  double? sizeScale,
  int? color,
  TextBaselineShift? baseline,
  LinkRole? linkRole,
  InlineRole? inlineRole,
}) {
  return TextStyle(
    bold: bold ?? base.bold,
    italic: italic ?? base.italic,
    underline: underline ?? base.underline,
    strikethrough: strikethrough ?? base.strikethrough,
    sizeScale: sizeScale ?? base.sizeScale,
    color: color ?? base.color,
    baseline: baseline ?? base.baseline,
    linkRole: linkRole ?? base.linkRole,
    inlineRole: inlineRole ?? base.inlineRole,
  );
}

/// Applies the supported inline CSS properties of one element onto [base].
TextStyle _applyCssTextProperties(
  TextStyle base,
  Map<String, String> props, {
  double? inheritedSize,
}) {
  var style = base;
  final fontSize = _cssScale(props['font-size']);
  if (fontSize != null) {
    style = _copyTextStyle(
      style,
      sizeScale: (inheritedSize ?? style.sizeScale) * fontSize,
    );
  }
  final fontWeight = props['font-weight'];
  if (fontWeight != null) {
    style = _copyTextStyle(
      style,
      bold:
          fontWeight == 'bold' ||
          fontWeight == 'bolder' ||
          (int.tryParse(fontWeight) ?? 0) >= 600,
    );
  }
  final fontStyle = props['font-style'];
  if (fontStyle != null) {
    style = _copyTextStyle(
      style,
      italic: fontStyle == 'italic' || fontStyle == 'oblique',
    );
  }
  final decoration = props['text-decoration-line'] ?? props['text-decoration'];
  if (decoration != null) {
    style = _copyTextStyle(
      style,
      underline: decoration.contains('underline'),
      strikethrough: decoration.contains('line-through'),
    );
  }
  final color = _cssColor(props['color']);
  if (color != null) style = _copyTextStyle(style, color: color);
  switch (props['vertical-align']?.trim()) {
    case 'super':
      style = _copyTextStyle(style, baseline: TextBaselineShift.superscript);
    case 'sub':
      style = _copyTextStyle(style, baseline: TextBaselineShift.subscript);
    case 'baseline':
      style = _copyTextStyle(style, baseline: TextBaselineShift.none);
  }
  return style;
}

// ---------------------------------------------------------------------------
// Inline collection
// ---------------------------------------------------------------------------

class _InlineCollector {
  final bool preserveWhitespace;
  final List<Inline> content = [];
  bool _lastWasSpace = true;

  _InlineCollector({required this.preserveWhitespace});

  void pushText(String text, TextStyle style, String? link) {
    final normalized = preserveWhitespace ? text : _collapse(text);
    if (normalized.isEmpty) return;
    final last = content.isEmpty ? null : content.last;
    if (last is TextRun && last.style == style && last.link == link) {
      content[content.length - 1] = TextRun(
        last.text + normalized,
        style: style,
        link: link,
      );
    } else {
      content.add(TextRun(normalized, style: style, link: link));
    }
  }

  void pushFootnoteReferenceMarker(
    String marker,
    TextStyle style,
    String link,
  ) {
    if (!preserveWhitespace && content.isNotEmpty) {
      final last = content.last;
      if (last is TextRun) {
        final trimmed = last.text.replaceFirst(RegExp(r'[ \u00a0]+$'), '');
        if (trimmed.isEmpty) {
          content.removeLast();
        } else if (trimmed.length != last.text.length) {
          content[content.length - 1] = TextRun(
            trimmed,
            style: last.style,
            link: last.link,
          );
        }
      }
      _lastWasSpace = false;
    }
    pushText(marker, style, link);
  }

  String _collapse(String text) {
    final buf = StringBuffer();
    for (final rune in text.runes) {
      if (_isWhitespaceRune(rune)) {
        if (!_lastWasSpace) {
          buf.write(' ');
          _lastWasSpace = true;
        }
      } else {
        buf.writeCharCode(rune);
        _lastWasSpace = false;
      }
    }
    return buf.toString();
  }

  void pushBreak() {
    content.add(const BreakInline());
    _lastWasSpace = true;
  }

  void pushMath(
    String latex, {
    required bool display,
    required double sizeScale,
  }) {
    final normalized = latex.trim();
    if (normalized.isEmpty) return;
    content.add(MathInline(normalized, display: display, sizeScale: sizeScale));
    _lastWasSpace = false;
  }

  void pushBreakIfNeeded() {
    if (content.isEmpty || content.last is BreakInline) return;
    pushBreak();
  }

  void finish() {
    final last = content.isEmpty ? null : content.last;
    if (last is TextRun) {
      final trimmed = last.text.replaceAll(RegExp(' +\$'), '');
      if (trimmed.length != last.text.length) {
        content[content.length - 1] = TextRun(
          trimmed,
          style: last.style,
          link: last.link,
        );
      }
    }
    content.removeWhere((inline) => inline is TextRun && inline.text.isEmpty);
  }
}

// ---------------------------------------------------------------------------
// CSS subset
// ---------------------------------------------------------------------------

class _StyleRule {
  final _SimpleSelector selector;
  final int specificity;
  final int order;
  final List<MapEntry<String, String>> declarations;

  _StyleRule(this.selector, this.specificity, this.order, this.declarations);
}

class _StyleSheet {
  final List<_StyleRule> rules = [];
  int _nextOrder = 0;

  void addCss(String css) {
    final cleaned = _stripCssComments(css);
    var cursor = 0;
    while (true) {
      final open = cleaned.indexOf('{', cursor);
      if (open < 0) break;
      final close = _matchingBrace(cleaned, open);
      if (close == null) break;
      final prelude = cleaned.substring(cursor, open).trim();
      if (!prelude.startsWith('@')) {
        final declarations = _parseDeclarations(
          cleaned.substring(open + 1, close),
        );
        for (final rawSelector in prelude.split(',')) {
          final selector = _SimpleSelector.parse(rawSelector);
          if (selector == null) continue;
          rules.add(
            _StyleRule(
              selector,
              selector.specificity,
              _nextOrder,
              declarations,
            ),
          );
        }
        _nextOrder++;
      }
      cursor = close + 1;
    }
  }

  /// All properties applying to [element]: matching rules sorted by
  /// (specificity, source order), then the inline `style` attribute.
  Map<String, String> cascadedProperties(XmlElement element) {
    final matching =
        rules.where((rule) => rule.selector.matches(element)).toList()
          ..sort((a, b) {
            final bySpecificity = a.specificity.compareTo(b.specificity);
            return bySpecificity != 0
                ? bySpecificity
                : a.order.compareTo(b.order);
          });
    final props = <String, String>{};
    for (final rule in matching) {
      _insertDeclarations(props, rule.declarations);
    }
    final inline = _attr(element, 'style');
    if (inline != null) {
      _insertDeclarations(props, _parseDeclarations(inline));
    }
    return props;
  }
}

class _SimpleSelector {
  final String? tag;
  final String? id;
  final List<String> classes;

  _SimpleSelector({this.tag, this.id, this.classes = const []});

  int get specificity =>
      (id != null ? 100 : 0) + classes.length * 10 + (tag != null ? 1 : 0);

  static _SimpleSelector? parse(String raw) {
    var rest = raw.trim();
    if (rest.isEmpty) return null;
    for (final rune in rest.runes) {
      if (_isWhitespaceRune(rune) ||
          '>+~[:*'.contains(String.fromCharCode(rune))) {
        return null;
      }
    }
    String? tag;
    String? id;
    final classes = <String>[];
    if (!rest.startsWith('.') && !rest.startsWith('#')) {
      final (identifier, tail) = _takeIdentifier(rest);
      if (identifier == null) return null;
      tag = identifier.toLowerCase();
      rest = tail;
    }
    while (rest.isNotEmpty) {
      final kind = rest[0];
      final (identifier, tail) = _takeIdentifier(rest.substring(1));
      if (identifier == null) return null;
      switch (kind) {
        case '.':
          classes.add(identifier);
        case '#':
          id = identifier;
        default:
          return null;
      }
      rest = tail;
    }
    return _SimpleSelector(tag: tag, id: id, classes: classes);
  }

  static (String?, String) _takeIdentifier(String input) {
    var end = 0;
    while (end < input.length) {
      final code = input.codeUnitAt(end);
      final ok =
          (code >= 0x30 && code <= 0x39) ||
          (code >= 0x41 && code <= 0x5A) ||
          (code >= 0x61 && code <= 0x7A) ||
          code == 0x2D ||
          code == 0x5F;
      if (!ok) break;
      end++;
    }
    if (end == 0) return (null, input);
    return (input.substring(0, end), input.substring(end));
  }

  bool matches(XmlElement element) {
    final elementTag = tag;
    if (elementTag != null && _name(element) != elementTag) return false;
    final selectorId = id;
    if (selectorId != null && _attr(element, 'id') != selectorId) return false;
    if (classes.isEmpty) return true;
    final elementClasses = (_attr(element, 'class') ?? '')
        .split(RegExp(r'\s+'))
        .where((c) => c.isNotEmpty)
        .toSet();
    return classes.every(elementClasses.contains);
  }
}

String _stripCssComments(String css) {
  final buf = StringBuffer();
  var remaining = css;
  while (true) {
    final start = remaining.indexOf('/*');
    if (start < 0) break;
    buf.write(remaining.substring(0, start));
    final end = remaining.indexOf('*/', start + 2);
    if (end < 0) return buf.toString();
    remaining = remaining.substring(end + 2);
  }
  buf.write(remaining);
  return buf.toString();
}

int? _matchingBrace(String css, int open) {
  var depth = 0;
  for (var i = open; i < css.length; i++) {
    switch (css[i]) {
      case '{':
        depth++;
      case '}':
        depth--;
        if (depth == 0) return i;
    }
  }
  return null;
}

List<MapEntry<String, String>> _parseDeclarations(String body) {
  final out = <MapEntry<String, String>>[];
  for (final declaration in body.split(';')) {
    final colon = declaration.indexOf(':');
    if (colon < 0) continue;
    final name = declaration.substring(0, colon).trim().toLowerCase();
    var value = declaration.substring(colon + 1).trim();
    if (value.toLowerCase().endsWith('!important')) {
      value = value.substring(0, value.length - '!important'.length).trim();
    }
    value = value.toLowerCase();
    if (name.isEmpty || value.isEmpty) continue;
    out.add(MapEntry(name, value));
  }
  return out;
}

void _insertDeclarations(
  Map<String, String> props,
  List<MapEntry<String, String>> declarations,
) {
  for (final entry in declarations) {
    if (entry.key == 'margin') {
      final sides = _boxSides(entry.value);
      if (sides != null) {
        props['margin-top'] = sides[0];
        props['margin-right'] = sides[1];
        props['margin-bottom'] = sides[2];
        props['margin-left'] = sides[3];
      }
    } else if (entry.key == 'padding') {
      final sides = _boxSides(entry.value);
      if (sides != null) {
        props['padding-top'] = sides[0];
        props['padding-right'] = sides[1];
        props['padding-bottom'] = sides[2];
        props['padding-left'] = sides[3];
      }
    } else if (const {
      'margin-inline',
      'padding-inline',
      'margin-block',
      'padding-block',
    }.contains(entry.key)) {
      final sides = _axisSides(entry.value);
      if (sides != null) {
        final separator = entry.key.indexOf('-');
        final prefix = entry.key.substring(0, separator);
        final axis = entry.key.substring(separator + 1);
        props['$prefix-$axis-start'] = sides.$1;
        props['$prefix-$axis-end'] = sides.$2;
      }
    } else {
      props[entry.key] = entry.value;
    }
  }
}

/// CSS box shorthand → [top, right, bottom, left].
List<String>? _boxSides(String value) {
  final values = value
      .split(RegExp(r'\s+'))
      .where((v) => v.isNotEmpty)
      .toList();
  return switch (values.length) {
    1 => [values[0], values[0], values[0], values[0]],
    2 => [values[0], values[1], values[0], values[1]],
    3 => [values[0], values[1], values[2], values[1]],
    4 => [values[0], values[1], values[2], values[3]],
    _ => null,
  };
}

(String, String)? _axisSides(String value) {
  final values = value
      .split(RegExp(r'\s+'))
      .where((item) => item.isNotEmpty)
      .toList(growable: false);
  return switch (values) {
    [final both] => (both, both),
    [final start, final end] => (start, end),
    _ => null,
  };
}

const double _baseFontSize = 16.0;

/// Absolute CSS length → logical px (16px base font size).
double? _cssLength(String? value) {
  if (value == null) return null;
  final v = value.trim();
  if (v.isEmpty) return null;
  String number;
  double scale;
  if (v.endsWith('px')) {
    number = v.substring(0, v.length - 2);
    scale = 1.0;
  } else if (v.endsWith('rem')) {
    number = v.substring(0, v.length - 3);
    scale = _baseFontSize;
  } else if (v.endsWith('em')) {
    number = v.substring(0, v.length - 2);
    scale = _baseFontSize;
  } else if (v.endsWith('pt')) {
    number = v.substring(0, v.length - 2);
    scale = 96.0 / 72.0;
  } else {
    number = v;
    scale = 1.0;
  }
  final parsed = double.tryParse(number.trim());
  return parsed == null ? null : parsed * scale;
}

(double, double)? _cssHorizontalLength(String? value) {
  if (value == null) return null;
  final normalized = value.trim();
  if (normalized.endsWith('%')) {
    final percent = double.tryParse(
      normalized.substring(0, normalized.length - 1).trim(),
    );
    if (percent == null || !percent.isFinite) return null;
    return (0, percent / 100);
  }
  final pixels = _cssLength(normalized);
  return pixels == null || !pixels.isFinite ? null : (pixels, 0);
}

/// Font-size value → scale factor (px absolute vs 16px base; em/% multiply).
double? _cssScale(String? value) {
  if (value == null) return null;
  final v = value.trim();
  if (v.isEmpty) return null;
  if (v.endsWith('%')) {
    final parsed = double.tryParse(v.substring(0, v.length - 1).trim());
    return parsed == null ? null : parsed / 100.0;
  }
  if (v.endsWith('rem')) {
    return double.tryParse(v.substring(0, v.length - 3).trim());
  }
  if (v.endsWith('em')) {
    return double.tryParse(v.substring(0, v.length - 2).trim());
  }
  if (v.endsWith('px')) {
    final parsed = double.tryParse(v.substring(0, v.length - 2).trim());
    return parsed == null ? null : parsed / _baseFontSize;
  }
  return null;
}

/// Line-height value → multiplier of the natural line height.
double? _cssLineHeight(String? value) {
  if (value == null) return null;
  final v = value.trim();
  double? parsed;
  if (v.endsWith('em')) {
    parsed = double.tryParse(v.substring(0, v.length - 2).trim());
  } else if (v.endsWith('%')) {
    final p = double.tryParse(v.substring(0, v.length - 1).trim());
    parsed = p == null ? null : p / 100.0;
  } else if (v.endsWith('px')) {
    final p = double.tryParse(v.substring(0, v.length - 2).trim());
    parsed = p == null ? null : p / _baseFontSize;
  } else {
    parsed = double.tryParse(v);
  }
  if (parsed == null || parsed < 0.8 || parsed > 4.0) return null;
  return parsed;
}

/// CSS color (#rgb, #rgba, #rrggbb, #rrggbbaa, rgb(), rgba()) → ARGB int.
int? _cssColor(String? value) {
  if (value == null) return null;
  final v = value.trim();
  if (v.startsWith('#')) {
    final hex = v.substring(1);
    int? component(int start, [bool short = false]) {
      final raw = hex.substring(start, start + (short ? 1 : 2));
      return int.tryParse(short ? raw + raw : raw, radix: 16);
    }

    try {
      return switch (hex.length) {
        3 =>
          0xFF000000 |
              (component(0, true)! << 16) |
              (component(1, true)! << 8) |
              component(2, true)!,
        4 =>
          (component(3, true)! << 24) |
              (component(0, true)! << 16) |
              (component(1, true)! << 8) |
              component(2, true)!,
        6 =>
          0xFF000000 |
              (component(0)! << 16) |
              (component(2)! << 8) |
              component(4)!,
        8 =>
          (component(6)! << 24) |
              (component(0)! << 16) |
              (component(2)! << 8) |
              component(4)!,
        _ => null,
      };
    } catch (_) {
      return null;
    }
  }
  final match = RegExp(r'^rgba?\(([^)]*)\)$').firstMatch(v);
  if (match != null) {
    final parts = match
        .group(1)!
        .split(RegExp(r'[,\s/]+'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.length >= 3) {
      final r = int.tryParse(parts[0]);
      final g = int.tryParse(parts[1]);
      final b = int.tryParse(parts[2]);
      var a = 255;
      if (parts.length >= 4) {
        final alpha = double.tryParse(parts[3]);
        if (alpha != null) a = (alpha * 255).round().clamp(0, 255);
      }
      if (r != null && g != null && b != null) {
        return (a << 24) | (r << 16) | (g << 8) | b;
      }
    }
  }
  return null;
}

/// Image dimension value (px or %) → [ImageLength]; null for auto/none.
ImageLength? _imageLength(String? value) {
  if (value == null) return null;
  final v = value.trim();
  if (v.isEmpty || v == 'auto' || v == 'none') return null;
  if (v.endsWith('%')) {
    final parsed = double.tryParse(v.substring(0, v.length - 1).trim());
    if (parsed == null || !parsed.isFinite) return null;
    return ImageLength.fraction(math.max(0, parsed / 100.0));
  }
  final pixels = _cssLength(v);
  if (pixels == null || !pixels.isFinite) return null;
  return ImageLength.pixels(math.max(0, pixels));
}
