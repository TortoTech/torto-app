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
  /// for source anchors.
  ///
  /// Never throws: unrecoverable markup yields a section with empty blocks.
  Section parse({
    required int spineIndex,
    required String href,
    required String xhtml,
    required String basePath,
  }) {
    try {
      final document = tryParseXmlTolerant(xhtml);
      if (document == null) {
        return Section(spineIndex: spineIndex, href: href, blocks: const []);
      }
      return _SectionParser(spineIndex, href, basePath, document).run();
    } catch (_) {
      return Section(spineIndex: spineIndex, href: href, blocks: const []);
    }
  }
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
    final normalized = text
        .trim()
        .replaceAll(RegExp(r'^[\[\(（【]+|[\]\)）】]+$'), '')
        .trim();
    if (normalized.isEmpty || normalized.runes.length > 8) return null;
    return normalized.contains(RegExp(r'\s')) ? null : normalized.toLowerCase();
  }

  final leftMarker = marker(left);
  return leftMarker != null && leftMarker == marker(right);
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
      'dd',
      'dl',
      'dt',
      'figcaption',
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

class _SectionParser {
  final int spineIndex;
  final String href;
  final String baseDir;
  final XmlDocument document;
  final _StyleSheet styles = _StyleSheet();
  late final Map<XmlElement, LinkRole> _footnoteLinks;
  final List<Block> blocks = [];
  final Map<XmlElement, SourceAnchor> _elementSources = Map.identity();
  int _nextNode = 0;

  _SectionParser(this.spineIndex, this.href, this.baseDir, this.document) {
    _footnoteLinks = _classifyFootnoteLinks(document, href, baseDir);
    for (final element in document.descendants.whereType<XmlElement>()) {
      if (_name(element) == 'style') {
        styles.addCss(
          element.descendants
              .where((node) => node is XmlText || node is XmlCDATA)
              .map(
                (node) =>
                    node is XmlText ? node.value : (node as XmlCDATA).value,
              )
              .join(),
        );
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
    _parseChildren(root);
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
    for (final child in parent.childElements) {
      _parseNode(child, listDepth);
    }
  }

  void _parseNode(XmlElement element, int listDepth) {
    final blockStart = blocks.length;
    final name = _name(element);
    if (_skippedElements.contains(name)) return;

    final props = styles.cascadedProperties(element);
    if (_isPageBreak(props['page-break-before'] ?? props['break-before'])) {
      blocks.add(const PageBreakBlock());
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
        _pushTextBlock(
          element,
          TextBlockKind.paragraph,
          _blockStyleFor(element),
        );
      case 'blockquote':
        final style = _blockStyleFor(element);
        _pushTextBlock(
          element,
          TextBlockKind.blockquote,
          style.copyWith(indent: style.indent + 24),
        );
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
        // Definition lists degrade to paragraphs for this milestone.
        _parseContainer(element, listDepth);
      case 'li':
        // Bare <li> outside an enclosing list.
        _emitListItem(element, ordered: false, ordinal: 1, depth: listDepth);
      case 'img' || 'image':
        _pushImage(element);
      case 'hr':
        blocks.add(const SeparatorBlock());
      case 'table':
        _parseTable(element);
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
      case TextBlock(:final source) || ImageBlock(:final source):
        return source;
      case TableBlock(:final rows):
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

  /// Handles containers with mixed inline and block children: inline runs
  /// between block-level children are collected into paragraphs.
  void _parseContainer(XmlElement container, int listDepth) {
    final style = _blockStyleFor(container);
    final textStyle = _textStyleForBlock(container, TextBlockKind.paragraph);
    var collector = _InlineCollector(preserveWhitespace: false);

    void flush() {
      collector.finish();
      if (collector.content.isEmpty) return;
      _emitTextBlock(TextBlockKind.paragraph, style, collector.content);
      collector = _InlineCollector(preserveWhitespace: false);
    }

    for (final child in container.children) {
      if (child is XmlElement && _isBlockBoundary(_name(child))) {
        flush();
        _parseNode(child, listDepth);
        continue;
      }
      if (child is XmlElement && _hasDescendantImage(child)) {
        flush();
        _pushTextBlock(child, TextBlockKind.paragraph, style);
        continue;
      }
      _collectInlineNode(child, textStyle, null, collector);
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
    for (final image in _descendantImages(item, skipNestedLists: true)) {
      _pushImage(image);
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
          _collectInlineNode(child, textStyle, null, collector);
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
      blocks.add(
        TableBlock(
          rows: List.unmodifiable(parsedRows),
          style: _blockStyleFor(table),
        ),
      );
    }
  }

  static int _positiveSpan(String? raw) =>
      (int.tryParse(raw ?? '') ?? 1).clamp(1, 64).toInt();

  BlockAlign? _tableCellAlignment(XmlElement cell) {
    final value =
        styles.cascadedProperties(cell)['text-align'] ?? _attr(cell, 'align');
    return switch (value?.trim().toLowerCase()) {
      'center' => BlockAlign.center,
      'right' || 'end' => BlockAlign.end,
      'justify' => BlockAlign.justify,
      'left' || 'start' => BlockAlign.start,
      _ => null,
    };
  }

  static XmlElement? _nearestTableAncestor(XmlElement element) {
    var current = element.parentElement;
    while (current != null) {
      if (_name(current) == 'table') return current;
      current = current.parentElement;
    }
    return null;
  }

  static bool _hasDescendantImage(XmlElement element) =>
      element.descendants.whereType<XmlElement>().any(
        (node) =>
            !identical(node, element) &&
            (_name(node) == 'img' || _name(node) == 'image'),
      );

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
          !underNestedList(node),
    );
  }

  void _pushTextBlock(
    XmlElement element,
    TextBlockKind kind,
    BlockStyle style, {
    int headingLevel = 0,
    bool preserveWhitespace = false,
  }) {
    final textStyle = _textStyleForBlock(
      element,
      kind,
      headingLevel: headingLevel,
    );
    final collector = _InlineCollector(preserveWhitespace: preserveWhitespace);
    _collectInline(element, textStyle, null, collector);
    collector.finish();
    if (collector.content.isNotEmpty) {
      _emitTextBlock(
        kind,
        style,
        collector.content,
        headingLevel: headingLevel,
      );
    }
    for (final image in _descendantImages(element)) {
      _pushImage(image);
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
  }) {
    final nodeId = _allocateNode();
    // Source range spans the block's normalized plain text (UTF-16 units;
    // Dart String.length is already UTF-16 code units).
    var textLength = 0;
    for (final inline in inlines) {
      textLength += switch (inline) {
        TextRun(:final text) => text.length,
        BreakInline() => 1,
      };
    }
    blocks.add(
      TextBlock(
        kind: kind,
        headingLevel: kind == TextBlockKind.heading ? headingLevel : 0,
        listOrdered: listOrdered,
        listOrdinal: listOrdinal,
        listDepth: listDepth,
        inlines: inlines,
        style: style,
        source: _sourceFor(nodeId, textLength),
        nodeId: nodeId,
      ),
    );
  }

  void _pushImage(XmlElement element) {
    final src = _attr(element, 'src') ?? _attr(element, 'href');
    if (src == null || src.trim().isEmpty) return;
    final nodeId = _allocateNode();
    blocks.add(
      ImageBlock(
        href: resolvePackageHref(baseDir, src),
        alt: _attr(element, 'alt') ?? '',
        style: _imageStyleFor(element),
        source: _sourceFor(nodeId, 0),
      ),
    );
  }

  // --------------------------------------------------------------- inlines

  void _collectInline(
    XmlNode node,
    TextStyle inherited,
    String? link,
    _InlineCollector collector,
  ) {
    for (final child in node.children) {
      _collectInlineNode(child, inherited, link, collector);
    }
  }

  void _collectInlineNode(
    XmlNode node,
    TextStyle inherited,
    String? link,
    _InlineCollector collector,
  ) {
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
    if (name == 'img' ||
        name == 'image' ||
        name == 'script' ||
        name == 'style') {
      return;
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
    style = _applyCssTextProperties(style, styles.cascadedProperties(node));

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
    _collectInline(node, style, childLink, collector);
  }

  String _resolveLink(String rawHref) {
    final trimmed = rawHref.trim();
    if (trimmed.startsWith('#')) return '$href$trimmed';
    return resolvePackageHref(baseDir, trimmed);
  }

  // ---------------------------------------------------------------- styles

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
    var marginBefore = base.marginBefore;
    var marginAfter = base.marginAfter;
    var marginStart = base.marginStart;
    var indent = base.indent;
    var lineHeight = base.lineHeight;

    for (final ancestor in _chain(element)) {
      final isSelf = identical(ancestor, element);
      final props = styles.cascadedProperties(ancestor);
      // Reading IR flattens nested boxes: accumulate the start-side offset
      // contributed by every containing box.
      marginStart +=
          _cssLength(
            _firstOf(props, const ['margin-inline-start', 'margin-left']),
          ) ??
          0;
      marginStart +=
          _cssLength(
            _firstOf(props, const ['padding-inline-start', 'padding-left']),
          ) ??
          0;
      switch (props['text-align']) {
        case 'center':
          align = BlockAlign.center;
        case 'right' || 'end':
          align = BlockAlign.end;
        case 'justify':
          align = BlockAlign.justify;
        case 'left' || 'start':
          align = BlockAlign.start;
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
      marginBefore: marginBefore,
      marginAfter: marginAfter,
      marginStart: marginStart,
      indent: indent,
      lineHeight: lineHeight,
    );
  }

  TextStyle _textStyleForBlock(
    XmlElement element,
    TextBlockKind kind, {
    int headingLevel = 0,
  }) {
    var style = TextStyle.plain;
    for (final ancestor in _chain(element)) {
      if (identical(ancestor, element)) {
        style = _applySemanticBlockStyle(style, kind, headingLevel);
      }
      style = _applyCssTextProperties(
        style,
        styles.cascadedProperties(ancestor),
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
      default:
        return style;
    }
  }

  ImageStyle _imageStyleFor(XmlElement element) {
    ImageLength? width = _imageLength(_attr(element, 'width'));
    ImageLength? height = _imageLength(_attr(element, 'height'));
    ImageLength? maxWidth;
    ImageLength? maxHeight;
    final props = styles.cascadedProperties(element);
    width = _imageLength(props['width']) ?? width;
    height = _imageLength(props['height']) ?? height;
    maxWidth = _imageLength(props['max-width']);
    maxHeight = _imageLength(props['max-height']);
    return ImageStyle(
      width: width,
      height: height,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
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
TextStyle _applyCssTextProperties(TextStyle base, Map<String, String> props) {
  var style = base;
  final fontSize = _cssScale(props['font-size']);
  if (fontSize != null) {
    style = _copyTextStyle(style, sizeScale: style.sizeScale * fontSize);
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
        props['margin-bottom'] = sides[2];
        props['margin-left'] = sides[3];
      }
    } else if (entry.key == 'padding') {
      final sides = _boxSides(entry.value);
      if (sides != null) props['padding-left'] = sides[3];
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
