/// In-memory [BookSource] for formats that build their publication model
/// directly (FB2, CBZ, …), as opposed to archive-backed sources like EPUB.
///
/// Dart port of torto's `crates/formats/src/source.rs`: sections carry either
/// an HTML fragment (parsed lazily through [HtmlIrParser], same pipeline as
/// EPUB) or a single full-page image; resources live in a path→bytes map.
/// Sections are exposed as a synthetic spine `Text/section-N.xhtml` with a
/// fallback TOC from section titles when the format has no navigation.
library;

import 'dart:typed_data';

import '../html_ir/html_ir_parser.dart';
import '../html_ir/package_path.dart';
import '../ir/ir.dart';
import 'toc_heading_promoter.dart';
import 'image_dimensions.dart';

class SourceResource {
  /// Root-relative resource path (`Images/image-1.png`).
  final String path;

  final String mediaType;
  final Uint8List bytes;

  const SourceResource({
    required this.path,
    required this.mediaType,
    required this.bytes,
  });
}

sealed class SourceSectionContent {
  const SourceSectionContent();
}

/// XHTML body fragment, parsed on demand by [HtmlIrParser].
class HtmlSectionContent extends SourceSectionContent {
  final String html;

  const HtmlSectionContent(this.html);
}

/// A single full-page image (comic page, fixed-layout cover…).
class ImageSectionContent extends SourceSectionContent {
  final String resourcePath;
  final String alt;

  const ImageSectionContent({required this.resourcePath, required this.alt});
}

class SourceSection {
  /// Fallback TOC label; also the shelf/reader-facing chapter name.
  final String title;
  final SourceSectionContent content;

  /// Reading-order sections are linear; notes and other named bodies are not.
  final bool linear;

  const SourceSection({
    required this.title,
    required this.content,
    this.linear = true,
  });
}

class SourceTocEntry {
  final String label;

  /// Section href (possibly with fragment), `Text/section-N.xhtml#anchor`.
  final String href;
  final List<SourceTocEntry> children;

  const SourceTocEntry({
    required this.label,
    required this.href,
    this.children = const [],
  });
}

class SourceBook {
  /// Content identity: SHA-256 of the original file bytes.
  final String id;
  final BookMetadata metadata;
  final List<SourceSection> sections;
  final List<SourceTocEntry> tableOfContents;
  final List<SourceResource> resources;
  final String? coverPath;

  const SourceBook({
    required this.id,
    required this.metadata,
    required this.sections,
    this.tableOfContents = const [],
    this.resources = const [],
    this.coverPath,
  });
}

class DirectBookSource implements BookSource {
  @override
  late final Book book;

  final List<SourceSectionContent> _sections;
  final Map<String, SourceResource> _resources;
  final Map<String, List<TocHeadingHint>> _tocHeadingHints;

  static const HtmlIrParser _parser = HtmlIrParser();

  DirectBookSource._(
    this.book,
    this._sections,
    this._resources,
    this._tocHeadingHints,
  );

  /// Builds the source. Throws [FormatException] when there is no readable
  /// section at all.
  factory DirectBookSource.open(SourceBook source) {
    if (source.sections.isEmpty) {
      throw const FormatException('没有可阅读的正文');
    }

    final spine = <SpineItem>[];
    final fallbackToc = <TocEntry>[];
    final contents = <SourceSectionContent>[];
    for (var index = 0; index < source.sections.length; index++) {
      final section = source.sections[index];
      final href = 'Text/section-${index + 1}.xhtml';
      spine.add(SpineItem(index: index, href: href));
      contents.add(section.content);
      if (section.linear) {
        fallbackToc.add(
          TocEntry(
            label: section.title,
            href: href,
            spineIndex: index,
            children: const [],
          ),
        );
      }
    }

    final toc = promoteSingleTocRoot(
      source.tableOfContents.isEmpty
          ? fallbackToc
          : [
              for (final entry in source.tableOfContents)
                _toTocEntry(entry, spine),
            ],
    );

    final resources = <String, SourceResource>{
      for (final resource in source.resources) resource.path: resource,
    };

    return DirectBookSource._(
      Book(
        id: source.id,
        metadata: source.metadata,
        spine: spine,
        toc: toc,
        coverHref: source.coverPath,
      ),
      contents,
      resources,
      source.metadata.layout == RenditionLayout.reflowable
          ? collectTocHeadingHints(toc)
          : const {},
    );
  }

  @override
  Future<Section> parseSection(int index) async {
    if (index < 0 || index >= _sections.length) {
      throw FormatException('section $index out of range');
    }
    final item = book.spine[index];
    return switch (_sections[index]) {
      HtmlSectionContent(:final html) => promoteTocHeadings(
        _parser.parse(
          spineIndex: index,
          href: item.href,
          xhtml:
              '<html xmlns="http://www.w3.org/1999/xhtml">'
              '<head><title></title></head><body>$html</body></html>',
          basePath: 'Text',
          isDecorativeSeparatorImage: (href) {
            final bytes = _resources[href]?.bytes;
            return bytes != null && isDecorativeSeparatorImage(bytes);
          },
        ),
        _tocHeadingHints[item.href] ?? const [],
      ),
      ImageSectionContent(:final resourcePath, :final alt) => Section(
        spineIndex: index,
        href: item.href,
        blocks: [
          ImageBlock(href: resourcePath, alt: alt, style: ImageStyle.normal),
        ],
      ),
    };
  }

  @override
  Future<Uint8List?> resource(String href) async {
    final (path, _) = splitPackageFragment(href);
    return _resources[path]?.bytes;
  }

  static TocEntry _toTocEntry(SourceTocEntry entry, List<SpineItem> spine) {
    final href = normalizePackagePath(entry.href);
    int? spineIndex;
    final (path, _) = splitPackageFragment(href);
    for (final item in spine) {
      if (item.href == path) {
        spineIndex = item.index;
        break;
      }
    }
    return TocEntry(
      label: entry.label,
      href: href,
      spineIndex: spineIndex,
      children: [for (final child in entry.children) _toTocEntry(child, spine)],
    );
  }
}
