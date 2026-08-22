/// MOBI/KF8 container internals.
///
/// Dart port of torto's `crates/formats/src/kf8.rs`: record-0 header, EXTH
/// metadata, PalmDOC and HUFF/CDIC decompression, MOBI6 chapter splitting,
/// and the KF8 reconstruction pipeline (FDST flows, SKEL/FRAG sections,
/// INDX/TAGX/CNCX indexes, NCX table of contents, `kindle:` resource URIs).
library;

import 'dart:convert';
import 'dart:typed_data';

import '../cp1252.dart';
import '../direct_book_source.dart' show SourceResource, SourceTocEntry;
import 'mobi_binary.dart';

const int _maxUncompressedText = 512 * 1024 * 1024;
const int _invalidIndex = 0xffffffff;

class Kf8Book {
  final List<Kf8Section> sections;
  final List<SourceTocEntry> tableOfContents;
  final List<SourceResource> resources;

  const Kf8Book(this.sections, this.tableOfContents, this.resources);
}

class Kf8Section {
  final String title;
  final String html;

  /// Index into the SKEL array this section came from (TOC remapping key).
  final int sourceIndex;

  const Kf8Section(this.title, this.html, this.sourceIndex);
}

class MobiMetadata {
  final String? title;
  final List<String> authors;
  final List<String> languages;
  final String? coverPath;

  const MobiMetadata({
    this.title,
    this.authors = const [],
    this.languages = const [],
    this.coverPath,
  });
}

class Mobi6Book {
  final List<Mobi6Section> sections;
  final List<SourceResource> resources;

  /// `recindex` value → resource path (image src rewriting).
  final Map<int, String> imageSources;

  const Mobi6Book(this.sections, this.resources, this.imageSources);
}

class Mobi6Section {
  final String title;
  final String html;

  const Mobi6Section(this.title, this.html);
}

class _Header {
  final int compression;
  final int textRecords;
  final int encoding;
  final int version;
  final int resourceStart;
  final int huffStart;
  final int huffCount;
  final int trailingFlags;
  final int ncx;
  final int fdst;
  final int frag;
  final int skel;

  const _Header({
    required this.compression,
    required this.textRecords,
    required this.encoding,
    required this.version,
    required this.resourceStart,
    required this.huffStart,
    required this.huffCount,
    required this.trailingFlags,
    required this.ncx,
    required this.fdst,
    required this.frag,
    required this.skel,
  });

  static _Header parse(Uint8List record) {
    if (String.fromCharCodes(bytesOf(record, 16, 4)) != 'MOBI') {
      throw const FormatException('missing MOBI header');
    }
    return _Header(
      compression: u16At(record, 0),
      textRecords: u16At(record, 8),
      encoding: u32At(record, 28),
      version: u32At(record, 36),
      resourceStart: u32At(record, 108),
      huffStart: u32At(record, 112),
      huffCount: u32At(record, 116),
      trailingFlags: optionalU32(record, 240) ?? 0,
      ncx: optionalU32(record, 244) ?? _invalidIndex,
      fdst: optionalU32(record, 192) ?? _invalidIndex,
      frag: optionalU32(record, 248) ?? _invalidIndex,
      skel: optionalU32(record, 252) ?? _invalidIndex,
    );
  }
}

class _Context {
  final Pdb pdb;
  final int base;
  final _Header header;

  const _Context(this.pdb, this.base, this.header);

  static _Context primary(Uint8List bytes) {
    final pdb = Pdb.open(bytes);
    return _Context(pdb, 0, _Header.parse(pdb.record(0)));
  }

  /// KF8 view: a v8 record 0, or the KF8 half of a hybrid file.
  static _Context open(Uint8List bytes) {
    final primary = _Context.primary(bytes);
    if (primary.header.version >= 8) return primary;
    final boundary = _hybridBoundary(primary.pdb.record(0));
    if (boundary == null) {
      throw const FormatException(
        'MOBI container does not contain a KF8 header',
      );
    }
    final header = _Header.parse(primary.pdb.record(boundary));
    if (header.version < 8) {
      throw const FormatException(
        'hybrid boundary does not point to a KF8 header',
      );
    }
    return _Context(primary.pdb, boundary, header);
  }

  Uint8List relativeRecord(int index) => pdb.record(base + index);

  Uint8List loadText() {
    final decompressor = _Decompressor.forHeader(this);
    final output = BytesBuilder(copy: false);
    for (var index = 0; index < header.textRecords; index++) {
      final record = _removeTrailingEntries(
        relativeRecord(index + 1),
        header.trailingFlags,
      );
      final decoded = decompressor.decompress(record);
      if (output.length + decoded.length > _maxUncompressedText) {
        throw const FormatException(
          'KF8 text exceeds the 512 MiB safety limit',
        );
      }
      output.add(decoded);
    }
    return output.takeBytes();
  }

  /// FDST flow table: (start, end) byte ranges within the raw text.
  List<(int, int)> loadFdst() {
    final index = _validIndex(header.fdst);
    final record = relativeRecord(index);
    if (String.fromCharCodes(bytesOf(record, 0, 4)) != 'FDST') {
      throw const FormatException('invalid FDST record');
    }
    final count = u32At(record, 8);
    return [
      for (var entry = 0; entry < count; entry++)
        (u32At(record, 12 + entry * 8), u32At(record, 12 + entry * 8 + 4)),
    ];
  }
}

/// Whether [bytes] contains a KF8 (v8) header, primary or hybrid.
bool isKf8(Uint8List bytes) {
  try {
    _Context.open(bytes);
    return true;
  } on FormatException {
    return false;
  }
}

/// Exposed for tests (mirrors the Rust unit tests' direct access).
Uint8List decompressPalmDocForTest(Uint8List data) =>
    const _PalmDocDecompressor().decompress(data);

/// Exposed for tests (mirrors the Rust unit tests' direct access).
bool isNavigationDocumentForTest(String html) => _isNavigationDocument(html);

// ------------------------------------------------------------------ metadata

MobiMetadata kf8Metadata(Uint8List bytes) {
  final context = _Context.primary(bytes);
  final record = context.pdb.record(0);
  final headerLength = u32At(record, 20);
  final titleOffset = u32At(record, 84);
  final titleLength = u32At(record, 88);
  String? title;
  try {
    final value = decodeMobiText(
      bytesOf(record, titleOffset, titleLength),
      context.header.encoding,
    );
    if (value.trim().isNotEmpty) title = value;
  } on FormatException {
    // Title range outside the record: fall through to EXTH.
  }
  final authors = <String>[];
  final languages = <String>[];
  int? coverOffset;
  int? thumbnailOffset;
  if ((optionalU32(record, 128) ?? 0) & 0x40 != 0) {
    final exthStart = 16 + headerLength;
    for (final entry in _parseExth(record, exthStart)) {
      switch (entry.kind) {
        case 100:
          _pushMetadataText(authors, entry.data, context.header.encoding);
        case 201:
          coverOffset = _uintFromBytes(entry.data);
        case 202:
          thumbnailOffset = _uintFromBytes(entry.data);
        case 503:
          final value = decodeMobiText(entry.data, context.header.encoding);
          if (value.trim().isNotEmpty) title = value;
        case 524:
          _pushMetadataText(languages, entry.data, context.header.encoding);
      }
    }
  }
  if (languages.isEmpty) {
    final language = _mobiLocale(record);
    if (language != null) languages.add(language);
  }
  final invalid = _invalidIndex;
  final offset = (coverOffset != null && coverOffset != invalid)
      ? coverOffset
      : ((thumbnailOffset != null && thumbnailOffset != invalid)
            ? thumbnailOffset
            : null);
  String? coverPath;
  if (offset != null) {
    try {
      coverPath = _resourcePath(context, offset + 1);
    } on FormatException {
      // Cover record missing/unreadable: keep the book without a cover.
    }
  }
  return MobiMetadata(
    title: title == null ? null : decodeHtmlEntities(title.trim()),
    authors: [
      for (final value in authors)
        if (decodeHtmlEntities(value.trim()).isNotEmpty)
          decodeHtmlEntities(value.trim()),
    ],
    languages: languages,
    coverPath: coverPath,
  );
}

class _ExthEntry {
  final int kind;
  final Uint8List data;

  const _ExthEntry(this.kind, this.data);
}

List<_ExthEntry> _parseExth(Uint8List record, int start) {
  if (String.fromCharCodes(bytesOf(record, start, 4)) != 'EXTH') {
    throw const FormatException('invalid EXTH header');
  }
  final length = u32At(record, start + 4);
  final count = u32At(record, start + 8);
  if (length < 12 || count > 4096) {
    throw const FormatException('invalid EXTH size');
  }
  final end = start + length;
  bytesOf(record, start, length);
  var position = start + 12;
  final entries = <_ExthEntry>[];
  for (var i = 0; i < count; i++) {
    if (position + 8 > end) {
      throw const FormatException('truncated EXTH entry');
    }
    final kind = u32At(record, position);
    final entryLength = u32At(record, position + 4);
    if (entryLength < 8 || position + entryLength > end) {
      throw const FormatException('invalid EXTH entry length');
    }
    entries.add(
      _ExthEntry(kind, bytesOf(record, position + 8, entryLength - 8)),
    );
    position += entryLength;
  }
  return entries;
}

void _pushMetadataText(List<String> values, Uint8List data, int encoding) {
  final value = decodeMobiText(
    data,
    encoding,
  ).replaceAll(RegExp(r'^[\u0000 \r\n\t]+|[\u0000 \r\n\t]+$'), '');
  if (value.isNotEmpty) values.add(value);
}

/// MOBI locale field → BCP-47-ish language tag (subset of torto's table).
String? _mobiLocale(Uint8List record) {
  if (record.length < 96) return null;
  final region = record[94] >> 2;
  return switch (record[95]) {
    1 => 'ar',
    2 => 'bg',
    3 => 'ca',
    4 => switch (region) {
      1 => 'zh-TW',
      2 => 'zh-CN',
      3 => 'zh-HK',
      4 => 'zh-SG',
      _ => 'zh',
    },
    5 => 'cs',
    6 => 'da',
    7 => 'de',
    8 => 'el',
    9 => switch (region) {
      1 => 'en-US',
      2 => 'en-GB',
      3 => 'en-AU',
      4 => 'en-CA',
      _ => 'en',
    },
    10 => 'es',
    11 => 'fi',
    12 => 'fr',
    13 => 'he',
    14 => 'hu',
    16 => 'it',
    17 => 'ja',
    18 => 'ko',
    19 => 'nl',
    20 => 'no',
    21 => 'pl',
    22 => 'pt',
    24 => 'ro',
    25 => 'ru',
    27 => 'sk',
    29 => 'sv',
    30 => 'th',
    31 => 'tr',
    33 => 'id',
    34 => 'uk',
    39 => 'lt',
    42 => 'vi',
    57 => 'hi',
    _ => null,
  };
}

String? _resourcePath(_Context context, int id) {
  final absolute = context.base + context.header.resourceStart + (id - 1);
  final record = context.pdb.record(absolute);
  final imageType = sniffImageType(record);
  return imageType == null ? null : 'Images/kindle-$id.${imageType.$1}';
}

/// Record-0 EXTH offset of the KF8 half in a hybrid file (entry kind 121).
int? _hybridBoundary(Uint8List record) {
  final flags = optionalU32(record, 128) ?? 0;
  if (flags & 0x40 == 0) return null;
  final exthStart = 16 + u32At(record, 20);
  if (String.fromCharCodes(bytesOf(record, exthStart, 4)) != 'EXTH') {
    return null;
  }
  final count = u32At(record, exthStart + 8);
  var position = exthStart + 12;
  for (var i = 0; i < count; i++) {
    final kind = u32At(record, position);
    final length = u32At(record, position + 4);
    if (length < 8) {
      throw const FormatException('invalid EXTH record length');
    }
    if (kind == 121) {
      return _uintFromBytes(bytesOf(record, position + 8, length - 8));
    }
    position += length;
  }
  return null;
}

// -------------------------------------------------------------------- mobi6

Mobi6Book parseMobi6(Uint8List bytes) {
  final context = _Context.primary(bytes);
  if (context.header.version >= 8 ||
      _hybridBoundary(context.pdb.record(0)) != null) {
    throw const FormatException('MOBI container contains KF8 content');
  }
  final raw = context.loadText();
  final filePositions = _findNumericAttributes(raw, 'filepos');
  final ranges = _splitMobi6Sections(raw);
  final sections = <Mobi6Section>[];
  for (final range in ranges) {
    final sectionRaw = bytesOf(raw, range.$1, range.$2 - range.$1);
    final anchors = [
      for (final position in filePositions)
        if (position >= range.$1 && position < range.$2)
          (position - range.$1, position),
    ];
    final anchored = _insertFileposAnchors(sectionRaw, anchors);
    final html = decodeMobiText(anchored, context.header.encoding);
    if (html.trim().isEmpty) continue;
    final title =
        _extractDocumentTitle(html) ?? 'Chapter ${sections.length + 1}';
    sections.add(Mobi6Section(title, html));
  }
  if (sections.isEmpty) {
    throw const FormatException('MOBI6 book has no readable content sections');
  }

  final resources = <SourceResource>[];
  final imageSources = <int, String>{};
  final start = context.base + context.header.resourceStart;
  for (
    var absoluteIndex = start;
    absoluteIndex < context.pdb.length;
    absoluteIndex++
  ) {
    final record = context.pdb.record(absoluteIndex);
    final imageType = sniffImageType(record);
    if (imageType == null) continue;
    final id = absoluteIndex - start + 1;
    final path = 'Images/kindle-$id.${imageType.$1}';
    imageSources[id] = path;
    resources.add(
      SourceResource(
        path: path,
        mediaType: imageType.$2,
        bytes: Uint8List.fromList(record),
      ),
    );
  }
  return Mobi6Book(sections, resources, imageSources);
}

/// Byte offsets of every numeric `filepos="…"` attribute, sorted, deduped.
List<int> _findNumericAttributes(Uint8List data, String name) {
  final needle = name.codeUnits;
  final values = <int>[];
  var search = 0;
  bool isAlnum(int byte) =>
      (byte >= 0x30 && byte <= 0x39) ||
      (byte >= 0x41 && byte <= 0x5A) ||
      (byte >= 0x61 && byte <= 0x7A);
  bool isSpace(int byte) => byte == 0x20 || (byte >= 0x09 && byte <= 0x0D);
  while (search + needle.length <= data.length) {
    var start = -1;
    for (var i = search; i + needle.length <= data.length; i++) {
      var match = true;
      for (var j = 0; j < needle.length; j++) {
        var byte = data[i + j];
        if (byte >= 0x41 && byte <= 0x5A) byte += 0x20; // to lowercase
        if (byte != needle[j]) {
          match = false;
          break;
        }
      }
      if (match) {
        start = i;
        break;
      }
    }
    if (start < 0) break;
    search = start + needle.length;
    if (start > 0 && isAlnum(data[start - 1])) continue;
    var position = search;
    while (position < data.length && isSpace(data[position])) {
      position++;
    }
    if (position >= data.length || data[position] != 0x3D /* = */ ) continue;
    position++;
    while (position < data.length && isSpace(data[position])) {
      position++;
    }
    var quote = 0;
    if (position < data.length &&
        (data[position] == 0x27 || data[position] == 0x22)) {
      quote = data[position];
      position++;
    }
    final valueStart = position;
    while (position < data.length &&
        data[position] >= 0x30 &&
        data[position] <= 0x39) {
      position++;
    }
    if (position > valueStart &&
        (quote == 0 || position >= data.length || data[position] == quote)) {
      var value = 0;
      for (var i = valueStart; i < position; i++) {
        value = value * 10 + (data[i] - 0x30);
        if (value > 0xffffffff) value = 0xffffffff; // clamp, not fatal
      }
      values.add(value);
    }
  }
  final unique = values.toSet().toList()..sort();
  return unique;
}

/// Chapter ranges split on `<mbp:pagebreak/>` (byte offsets).
List<(int, int)> _splitMobi6Sections(Uint8List data) {
  final ranges = <(int, int)>[];
  var sectionStart = 0;
  var position = 0;
  while (true) {
    final tagStart = _indexOfByte(data, 0x3C /* < */, position);
    if (tagStart < 0) break;
    final tagEnd = _indexOfByte(data, 0x3E /* > */, tagStart);
    if (tagEnd < 0) break;
    // Tag name = first run of non-space bytes after '<', ignoring '/'.
    var i = tagStart + 1;
    while (i < tagEnd && _isHtmlSpaceOrSlash(data[i])) {
      i++;
    }
    final nameStart = i;
    while (i < tagEnd && !_isHtmlSpaceOrSlash(data[i])) {
      i++;
    }
    final name = String.fromCharCodes(data.sublist(nameStart, i)).toLowerCase();
    if (name == 'mbp:pagebreak' || name == 'pagebreak') {
      if (sectionStart < tagStart) ranges.add((sectionStart, tagStart));
      sectionStart = tagEnd + 1;
    }
    position = tagEnd + 1;
  }
  if (sectionStart < data.length) ranges.add((sectionStart, data.length));
  if (ranges.isEmpty && data.isNotEmpty) ranges.add((0, data.length));
  return ranges;
}

bool _isHtmlSpaceOrSlash(int byte) =>
    byte == 0x20 ||
    byte == 0x09 ||
    byte == 0x0A ||
    byte == 0x0C ||
    byte == 0x0D ||
    byte == 0x2F /* / */;

int _indexOfByte(Uint8List data, int byte, int from) {
  for (var i = from < 0 ? 0 : from; i < data.length; i++) {
    if (data[i] == byte) return i;
  }
  return -1;
}

Uint8List _insertFileposAnchors(Uint8List data, List<(int, int)> anchors) {
  final output = BytesBuilder(copy: false);
  var copied = 0;
  for (final (offset, position) in anchors) {
    if (offset > data.length || offset < copied) {
      throw const FormatException('invalid MOBI6 file position');
    }
    output.add(bytesOf(data, copied, offset - copied));
    output.add(utf8.encode('<a id="filepos$position"></a>'));
    copied = offset;
  }
  output.add(bytesOf(data, copied, data.length - copied));
  return output.takeBytes();
}

// ---------------------------------------------------------------------- kf8

Kf8Book parseKf8(Uint8List bytes) {
  final context = _Context.open(bytes);
  final raw = context.loadText();
  final flowTable = _loadFdstOrNull(context);
  final skeletons = _parseSkeletons(context);
  final fragments = _parseFragments(context);
  final toc = _parseTocOrNull(context, skeletons, fragments);

  final resolvedAnchors = <String, String>{};
  var rawSections = _reconstructSections(
    raw,
    context.header.encoding,
    skeletons,
    fragments,
    toc.titles,
    toc.fragmentAnchors,
    resolvedAnchors,
  );
  if (rawSections.isEmpty) {
    throw const FormatException('KF8 book has no readable content sections');
  }

  final sectionMap = List<int?>.filled(skeletons.length, null);
  for (var i = 0; i < rawSections.length; i++) {
    sectionMap[rawSections[i].sourceIndex] = i;
  }
  final tableOfContents = _remapTocEntries(
    toc.entries,
    sectionMap,
    resolvedAnchors,
  );

  final resources = <SourceResource>[];
  final resourcePaths = <_ResourceKey, String>{};
  _loadEmbeddedImages(context, resources, resourcePaths);
  _loadFlowResources(raw, flowTable, rawSections, resources, resourcePaths);

  rawSections = [
    for (final section in rawSections)
      Kf8Section(
        section.title,
        _replaceResourceUris(section.html, resourcePaths),
        section.sourceIndex,
      ),
  ];
  return Kf8Book(rawSections, tableOfContents, resources);
}

List<(int, int)> _loadFdstOrNull(_Context context) {
  try {
    return context.loadFdst();
  } on FormatException {
    return const [];
  }
}

class _Skeleton {
  final int fragmentCount;
  final int offset;
  final int length;

  const _Skeleton(this.fragmentCount, this.offset, this.length);
}

class _Fragment {
  final int insertOffset;
  final int index;
  final int offset;
  final int length;

  const _Fragment(this.insertOffset, this.index, this.offset, this.length);
}

List<_Skeleton> _parseSkeletons(_Context context) {
  final index = _parseIndex(context, _validIndex(context.header.skel));
  return [
    for (final entry in index.entries)
      () {
        final range = _requiredTag(entry.tags, 6, 'SKEL range');
        return _Skeleton(
          _requiredTag(entry.tags, 1, 'SKEL fragment count')[0],
          range[0],
          range[1],
        );
      }(),
  ];
}

List<_Fragment> _parseFragments(_Context context) {
  final index = _parseIndex(context, _validIndex(context.header.frag));
  return [
    for (final entry in index.entries)
      () {
        final range = _requiredTag(entry.tags, 6, 'FRAG range');
        return _Fragment(
          int.tryParse(entry.name) ??
              (throw const FormatException('invalid FRAG insertion offset')),
          _requiredTag(entry.tags, 4, 'FRAG index')[0],
          range[0],
          range[1],
        );
      }(),
  ];
}

List<Kf8Section> _reconstructSections(
  Uint8List raw,
  int encoding,
  List<_Skeleton> skeletons,
  List<_Fragment> fragments,
  Map<int, String> tocTitles,
  Map<int, List<_FragmentAnchor>> fragmentAnchors,
  Map<String, String> resolvedAnchors,
) {
  final sections = <Kf8Section>[];
  var fragmentStart = 0;
  for (var sectionIndex = 0; sectionIndex < skeletons.length; sectionIndex++) {
    final skeleton = skeletons[sectionIndex];
    final fragmentEnd = fragmentStart + skeleton.fragmentCount;
    if (fragmentEnd > fragments.length) {
      throw const FormatException('SKEL references missing FRAG entries');
    }
    final sectionFragments = fragments.sublist(fragmentStart, fragmentEnd);
    fragmentStart = fragmentEnd;
    if (sectionFragments.isEmpty) continue;

    final fragmentLength = sectionFragments.fold<int>(
      0,
      (sum, fragment) => sum + fragment.length,
    );
    final sectionLength = skeleton.length + fragmentLength;
    final sectionRaw = bytesOf(raw, skeleton.offset, sectionLength);
    final document = BytesBuilder(copy: false)
      ..add(bytesOf(sectionRaw, 0, skeleton.length));

    for (final fragment in sectionFragments) {
      final insert = fragment.insertOffset - skeleton.offset;
      if (insert < 0) {
        throw const FormatException('FRAG insertion precedes its skeleton');
      }
      if (insert > document.length) {
        throw const FormatException(
          'FRAG insertion points outside its skeleton',
        );
      }
      final start = skeleton.length + fragment.offset;
      final fragmentRaw = bytesOf(sectionRaw, start, fragment.length);
      _resolveFragmentAnchors(
        fragmentRaw,
        encoding,
        fragmentAnchors[fragment.index],
        resolvedAnchors,
      );
      final built = document.takeBytes();
      document
        ..clear()
        ..add(bytesOf(built, 0, insert))
        ..add(fragmentRaw)
        ..add(bytesOf(built, insert, built.length - insert));
    }

    final html = decodeMobiText(
      document.takeBytes(),
      encoding,
    ).replaceAll('\u0000', '');
    if (html.trim().isEmpty || _isNavigationDocument(html)) continue;
    final title =
        _extractDocumentTitle(html) ??
        tocTitles[sectionIndex] ??
        'Chapter ${sections.length + 1}';
    sections.add(Kf8Section(title, html, sectionIndex));
  }
  return sections;
}

void _resolveFragmentAnchors(
  Uint8List raw,
  int encoding,
  List<_FragmentAnchor>? anchors,
  Map<String, String> resolved,
) {
  if (anchors == null) return;
  for (final anchor in anchors) {
    if (anchor.offset > raw.length) continue;
    final tail = decodeMobiText(
      Uint8List.sublistView(raw, anchor.offset),
      encoding,
    );
    final value = _firstFragmentIdentifier(tail);
    if (value != null) resolved[anchor.id] = value;
  }
}

/// First `id`/`name`/`aid` attribute value in [value] (after a whitespace).
String? _firstFragmentIdentifier(String value) {
  final bytes = value.codeUnits;
  var position = 0;
  while (position < bytes.length) {
    if (bytes[position] != 0x20 &&
        !(bytes[position] >= 0x09 && bytes[position] <= 0x0D)) {
      position++;
      continue;
    }
    position++;
    final nameStart = position;
    while (position < bytes.length &&
        ((bytes[position] >= 0x41 && bytes[position] <= 0x5A) ||
            (bytes[position] >= 0x61 && bytes[position] <= 0x7A))) {
      position++;
    }
    if (position == nameStart) continue;
    final name = value.substring(nameStart, position).toLowerCase();
    if (name != 'id' && name != 'name' && name != 'aid') continue;
    while (position < bytes.length &&
        (bytes[position] == 0x20 ||
            (bytes[position] >= 0x09 && bytes[position] <= 0x0D))) {
      position++;
    }
    if (position >= bytes.length || bytes[position] != 0x3D /* = */ ) continue;
    position++;
    while (position < bytes.length &&
        (bytes[position] == 0x20 ||
            (bytes[position] >= 0x09 && bytes[position] <= 0x0D))) {
      position++;
    }
    if (position >= bytes.length) return null;
    final quote = bytes[position];
    if (quote != 0x27 && quote != 0x22) continue;
    position++;
    final valueStart = position;
    while (position < bytes.length && bytes[position] != quote) {
      position++;
    }
    if (position > bytes.length) return null;
    final identifier = value.substring(valueStart, position).trim();
    if (identifier.isNotEmpty) return identifier;
  }
  return null;
}

List<SourceTocEntry> _remapTocEntries(
  List<SourceTocEntry> entries,
  List<int?> sectionMap,
  Map<String, String> resolvedAnchors,
) {
  final remapped = <SourceTocEntry>[];
  for (final entry in entries) {
    final children = _remapTocEntries(
      entry.children,
      sectionMap,
      resolvedAnchors,
    );
    final hash = entry.href.indexOf('#');
    final path = hash < 0 ? entry.href : entry.href.substring(0, hash);
    final fragmentText = hash < 0 ? null : entry.href.substring(hash + 1);
    var sourceIndex = -1;
    if (path.startsWith('Text/section-') && path.endsWith('.xhtml')) {
      final number = int.tryParse(
        path.substring('Text/section-'.length, path.length - '.xhtml'.length),
      );
      if (number != null && number >= 1) sourceIndex = number - 1;
    }
    if (sourceIndex < 0 ||
        sourceIndex >= sectionMap.length ||
        sectionMap[sourceIndex] == null) {
      remapped.addAll(children);
      continue;
    }
    final fragment = fragmentText == null || fragmentText.isEmpty
        ? ''
        : '#${resolvedAnchors[fragmentText] ?? fragmentText}';
    remapped.add(
      SourceTocEntry(
        label: entry.label,
        href: 'Text/section-${sectionMap[sourceIndex]! + 1}.xhtml$fragment',
        children: children,
      ),
    );
  }
  return remapped;
}

bool _isNavigationDocument(String html) {
  final lower = html.toLowerCase();
  const semantics = [
    'epub:type="toc"',
    "epub:type='toc'",
    'role="doc-toc"',
    "role='doc-toc'",
    'epub:type="landmarks"',
    "epub:type='landmarks'",
    'epub:type="page-list"',
    "epub:type='page-list'",
  ];
  if (!semantics.any(lower.contains)) return false;
  final bodyStart = lower.indexOf('<body');
  if (bodyStart < 0) return false;
  final bodyOpenEnd = lower.indexOf('>', bodyStart);
  if (bodyOpenEnd < 0) return false;
  final contentStart = bodyOpenEnd + 1;
  final bodyClose = lower.lastIndexOf('</body>');
  if (bodyClose < contentStart) return false;
  final body = lower.substring(contentStart, bodyClose).trim();
  final navEnd = body.lastIndexOf('</nav>');
  return body.startsWith('<nav') &&
      navEnd >= 0 &&
      body.substring(navEnd + '</nav>'.length).trim().isEmpty;
}

class _ParsedToc {
  final Map<int, String> titles;
  final List<SourceTocEntry> entries;
  final Map<int, List<_FragmentAnchor>> fragmentAnchors;

  const _ParsedToc(this.titles, this.entries, this.fragmentAnchors);
}

class _FragmentAnchor {
  final int offset;
  final String id;

  const _FragmentAnchor(this.offset, this.id);
}

class _FlatTocEntry {
  final int originalIndex;
  final String label;
  final int section;
  final int? parent;
  final int headingLevel;
  final String anchorId;

  const _FlatTocEntry(
    this.originalIndex,
    this.label,
    this.section,
    this.parent,
    this.headingLevel,
    this.anchorId,
  );
}

_ParsedToc _parseTocOrNull(
  _Context context,
  List<_Skeleton> skeletons,
  List<_Fragment> fragments,
) {
  try {
    return _parseToc(context, skeletons, fragments);
  } on FormatException {
    return const _ParsedToc({}, [], {});
  }
}

_ParsedToc _parseToc(
  _Context context,
  List<_Skeleton> skeletons,
  List<_Fragment> fragments,
) {
  final index = _parseIndex(context, _validIndex(context.header.ncx));
  final ranges = <(int, int)>[];
  var start = 0;
  for (final skeleton in skeletons) {
    final end = start + skeleton.fragmentCount;
    ranges.add((start, end));
    start = end;
  }

  final titles = <int, String>{};
  final flat = <_FlatTocEntry>[];
  final fragmentAnchors = <int, List<_FragmentAnchor>>{};
  for (
    var originalIndex = 0;
    originalIndex < index.entries.length;
    originalIndex++
  ) {
    final entry = index.entries[originalIndex];
    final position = entry.tags[6];
    if (position == null || position.isEmpty) continue;
    final fragmentId = position[0];
    final fragmentOffset = position.length > 1 ? position[1] : 0;
    final labelOffset = entry.tags[3]?.firstOrNull;
    if (labelOffset == null) continue;
    final label = index.cncx[labelOffset];
    if (label == null || label.trim().isEmpty) continue;
    var section = -1;
    for (var i = 0; i < ranges.length; i++) {
      final (from, to) = ranges[i];
      var found = false;
      for (var j = from; j < to; j++) {
        if (fragments[j].index == fragmentId) {
          found = true;
          break;
        }
      }
      if (found) {
        section = i;
        break;
      }
    }
    if (section < 0) continue;
    final trimmed = label.trim();
    final anchorId =
        'kf8-${fragmentId.toRadixString(16)}-${fragmentOffset.toRadixString(16)}';
    titles.putIfAbsent(section, () => trimmed);
    final anchors = fragmentAnchors.putIfAbsent(fragmentId, () => []);
    if (!anchors.any((anchor) => anchor.offset == fragmentOffset)) {
      anchors.add(_FragmentAnchor(fragmentOffset, anchorId));
    }
    flat.add(
      _FlatTocEntry(
        originalIndex,
        trimmed,
        section,
        entry.tags[21]?.firstOrNull,
        entry.tags[4]?.firstOrNull ?? 0,
        anchorId,
      ),
    );
  }
  final visiting = <int>{};
  final roots = <SourceTocEntry>[];
  for (var i = 0; i < flat.length; i++) {
    if (flat[i].headingLevel == 0 || flat[i].parent == null) {
      roots.add(_buildTocEntry(i, flat, visiting));
    }
  }
  return _ParsedToc(titles, roots, fragmentAnchors);
}

SourceTocEntry _buildTocEntry(
  int index,
  List<_FlatTocEntry> entries,
  Set<int> visiting,
) {
  if (!visiting.add(index)) {
    throw const FormatException('cyclic KF8 table of contents');
  }
  final entry = entries[index];
  final children = <SourceTocEntry>[];
  for (var i = 0; i < entries.length; i++) {
    if (entries[i].parent == entry.originalIndex) {
      children.add(_buildTocEntry(i, entries, visiting));
    }
  }
  visiting.remove(index);
  return SourceTocEntry(
    label: entry.label,
    href: 'Text/section-${entry.section + 1}.xhtml#${entry.anchorId}',
    children: children,
  );
}

class _IndexData {
  final List<_IndexEntry> entries;
  final Map<int, String> cncx;

  const _IndexData(this.entries, this.cncx);
}

class _IndexEntry {
  final String name;
  final Map<int, List<int>> tags;

  const _IndexEntry(this.name, this.tags);
}

_IndexData _parseIndex(_Context context, int index) {
  final main = context.relativeRecord(index);
  final header = _IndexHeader.parse(main);
  final tagxStart = header.length;
  if (String.fromCharCodes(bytesOf(main, tagxStart, 4)) != 'TAGX') {
    throw const FormatException('invalid TAGX section');
  }
  final tagxLength = u32At(main, tagxStart + 4);
  final controlBytes = u32At(main, tagxStart + 8);
  if (tagxLength < 12 || (tagxLength - 12) % 4 != 0) {
    throw const FormatException('invalid TAGX length');
  }
  final tagTable = <List<int>>[];
  for (
    var position = tagxStart + 12;
    position < tagxStart + tagxLength;
    position += 4
  ) {
    final values = bytesOf(main, position, 4);
    tagTable.add([values[0], values[1], values[2], values[3]]);
  }

  final cncx = <int, String>{};
  for (var cncxIndex = 0; cncxIndex < header.cncxRecords; cncxIndex++) {
    final record = context.relativeRecord(
      index + header.indexRecords + cncxIndex + 1,
    );
    var position = 0;
    while (position < record.length) {
      final entryOffset = position;
      final (length, consumed) = variableLength(record, position);
      position += consumed;
      final value = bytesOf(record, position, length);
      position += length;
      cncx[cncxIndex * 0x10000 + entryOffset] = decodeMobiText(
        value,
        header.encoding,
      );
    }
  }

  final entries = <_IndexEntry>[];
  for (var recordIndex = 0; recordIndex < header.indexRecords; recordIndex++) {
    final record = context.relativeRecord(index + 1 + recordIndex);
    final sub = _IndexHeader.parse(record);
    for (var entryIndex = 0; entryIndex < sub.entries; entryIndex++) {
      final idxtOffset = sub.idxt + 4 + entryIndex * 2;
      final entryOffset = u16At(record, idxtOffset);
      final nameLength = bytesOf(record, entryOffset, 1)[0];
      final nameStart = entryOffset + 1;
      final name = String.fromCharCodes(bytesOf(record, nameStart, nameLength));
      final start = nameStart + nameLength;
      var controlIndex = 0;
      var position = start + controlBytes;
      final tagSpecs = <(int, int?, int?, int)>[];

      for (final tagSpec in tagTable) {
        final (tag, valueCount, mask, end) = (
          tagSpec[0],
          tagSpec[1],
          tagSpec[2],
          tagSpec[3],
        );
        if (end & 1 != 0) {
          controlIndex++;
          continue;
        }
        final control = bytesOf(record, start + controlIndex, 1)[0];
        final value = control & mask;
        if (value == mask) {
          if (_countBits(mask) > 1) {
            final (byteCount, consumed) = variableLength(record, position);
            position += consumed;
            tagSpecs.add((tag, null, byteCount, valueCount));
          } else {
            tagSpecs.add((tag, 1, null, valueCount));
          }
        } else {
          tagSpecs.add((tag, value >> _trailingZeros(mask), null, valueCount));
        }
      }

      final tags = <int, List<int>>{};
      for (final (tag, valueCount, byteCount, valuesPerEntry) in tagSpecs) {
        final values = <int>[];
        if (valueCount != null) {
          final count = valueCount * valuesPerEntry;
          for (var i = 0; i < count; i++) {
            final (value, consumed) = variableLength(record, position);
            position += consumed;
            values.add(value);
          }
        } else {
          var consumedTotal = 0;
          final limit = byteCount ?? 0;
          while (consumedTotal < limit) {
            final (value, consumed) = variableLength(record, position);
            position += consumed;
            consumedTotal += consumed;
            values.add(value);
          }
          if (consumedTotal != limit) {
            throw const FormatException('TAGX values exceed their byte range');
          }
        }
        tags[tag] = values;
      }
      entries.add(_IndexEntry(name, tags));
    }
  }
  return _IndexData(entries, cncx);
}

class _IndexHeader {
  final int length;
  final int idxt;
  final int entries;
  final int encoding;
  final int indexRecords;
  final int cncxRecords;

  const _IndexHeader(
    this.length,
    this.idxt,
    this.entries,
    this.encoding,
    this.indexRecords,
    this.cncxRecords,
  );

  static _IndexHeader parse(Uint8List record) {
    if (String.fromCharCodes(bytesOf(record, 0, 4)) != 'INDX') {
      throw const FormatException('invalid INDX record');
    }
    return _IndexHeader(
      u32At(record, 4),
      u32At(record, 20),
      u32At(record, 24),
      u32At(record, 28),
      u32At(record, 24),
      u32At(record, 52),
    );
  }
}

List<int> _requiredTag(Map<int, List<int>> tags, int tag, String description) {
  final values = tags[tag];
  if (values == null || values.isEmpty) {
    throw FormatException('missing $description');
  }
  if (tag == 6 && values.length < 2) {
    throw FormatException('incomplete $description');
  }
  return values;
}

int _countBits(int value) {
  var count = 0;
  while (value != 0) {
    count += value & 1;
    value >>= 1;
  }
  return count;
}

int _trailingZeros(int value) {
  if (value == 0) return 64;
  var zeros = 0;
  while (value & 1 == 0) {
    zeros++;
    value >>= 1;
  }
  return zeros;
}

// ---------------------------------------------------------------- resources

void _loadEmbeddedImages(
  _Context context,
  List<SourceResource> resources,
  Map<_ResourceKey, String> paths,
) {
  final resourceStart = context.base + context.header.resourceStart;
  for (
    var absoluteIndex = resourceStart;
    absoluteIndex < context.pdb.length;
    absoluteIndex++
  ) {
    final record = context.pdb.record(absoluteIndex);
    final imageType = sniffImageType(record);
    if (imageType == null) continue;
    final id = absoluteIndex - resourceStart + 1;
    final path = 'Images/kindle-$id.${imageType.$1}';
    paths[_ResourceKey.embed(id)] = path;
    resources.add(
      SourceResource(
        path: path,
        mediaType: imageType.$2,
        bytes: Uint8List.fromList(record),
      ),
    );
  }
}

void _loadFlowResources(
  Uint8List raw,
  List<(int, int)> flowTable,
  List<Kf8Section> sections,
  List<SourceResource> resources,
  Map<_ResourceKey, String> paths,
) {
  final references = <_ResourceReference>{};
  for (final section in sections) {
    for (final reference in _findResourceReferences(section.html)) {
      if (reference.kind == _ResourceKind.flow) references.add(reference);
    }
  }
  for (final reference in references) {
    if (reference.mime != 'image/svg+xml') continue;
    if (reference.id >= flowTable.length) continue;
    final (start, end) = flowTable[reference.id];
    if (end > raw.length || start > end) {
      throw const FormatException(
        'KF8 flow resource points outside decompressed text',
      );
    }
    final path = 'Images/flow-${reference.id}.svg';
    paths[_ResourceKey.flow(reference.id)] = path;
    resources.add(
      SourceResource(
        path: path,
        mediaType: 'image/svg+xml',
        bytes: Uint8List.fromList(bytesOf(raw, start, end - start)),
      ),
    );
  }
}

enum _ResourceKeyKind { embed, flow }

class _ResourceKey {
  final _ResourceKeyKind kind;
  final int id;

  const _ResourceKey.embed(this.id) : kind = _ResourceKeyKind.embed;
  const _ResourceKey.flow(this.id) : kind = _ResourceKeyKind.flow;

  @override
  bool operator ==(Object other) =>
      other is _ResourceKey && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);
}

enum _ResourceKind { embed, flow }

class _ResourceReference {
  final _ResourceKind kind;
  final int id;
  final String? mime;

  const _ResourceReference(this.kind, this.id, this.mime);

  @override
  bool operator ==(Object other) =>
      other is _ResourceReference &&
      other.kind == kind &&
      other.id == id &&
      other.mime == mime;

  @override
  int get hashCode => Object.hash(kind, id, mime);
}

List<_ResourceReference> _findResourceReferences(String value) {
  final references = <_ResourceReference>[];
  var searchFrom = 0;
  while (true) {
    final start = value.indexOf('kindle:', searchFrom);
    if (start < 0) break;
    final reference = _parseResourceUri(value, start);
    if (reference != null) references.add(reference.$2);
    searchFrom = start + 'kindle:'.length;
  }
  return references;
}

String _replaceResourceUris(String value, Map<_ResourceKey, String> paths) {
  final output = StringBuffer();
  var copied = 0;
  var searchFrom = 0;
  while (true) {
    final start = value.indexOf('kindle:', searchFrom);
    if (start < 0) break;
    final parsed = _parseResourceUri(value, start);
    if (parsed == null) {
      searchFrom = start + 'kindle:'.length;
      continue;
    }
    final (end, reference) = parsed;
    final key = reference.kind == _ResourceKind.embed
        ? _ResourceKey.embed(reference.id)
        : _ResourceKey.flow(reference.id);
    final path = paths[key];
    if (path != null) {
      output
        ..write(value.substring(copied, start))
        ..write('../')
        ..write(path);
      copied = end;
    }
    searchFrom = end;
  }
  if (copied == 0) return value;
  output.write(value.substring(copied));
  return output.toString();
}

(int, _ResourceReference)? _parseResourceUri(String value, int start) {
  final suffixStart = start + 'kindle:'.length;
  if (suffixStart > value.length) return null;
  final suffix = value.substring(suffixStart);
  _ResourceKind kind;
  int prefixLength;
  if (suffix.startsWith('embed:')) {
    kind = _ResourceKind.embed;
    prefixLength = 'embed:'.length;
  } else if (suffix.startsWith('flow:')) {
    kind = _ResourceKind.flow;
    prefixLength = 'flow:'.length;
  } else {
    return null;
  }
  final idStart = suffixStart + prefixLength;
  var idEnd = value.length;
  for (var i = idStart; i < value.length; i++) {
    final code = value.codeUnitAt(i);
    final isAlnum =
        (code >= 0x30 && code <= 0x39) ||
        (code >= 0x41 && code <= 0x5A) ||
        (code >= 0x61 && code <= 0x7A);
    if (!isAlnum) {
      idEnd = i;
      break;
    }
  }
  if (idEnd == idStart) return null;
  final id = int.tryParse(value.substring(idStart, idEnd), radix: 32);
  if (id == null) return null;
  var end = idEnd;
  String? mime;
  if (value.substring(idEnd).startsWith('?mime=')) {
    final mimeStart = idEnd + '?mime='.length;
    end = value.length;
    for (var i = mimeStart; i < value.length; i++) {
      final character = value[i];
      if (character == ' ' ||
          character == '\t' ||
          character == '\n' ||
          character == "'" ||
          character == '"' ||
          character == '<' ||
          character == '>' ||
          character == ')' ||
          character == ']') {
        end = i;
        break;
      }
    }
    mime = value.substring(mimeStart, end);
  }
  return (end, _ResourceReference(kind, id, mime));
}

// ------------------------------------------------------------- decompression

sealed class _Decompressor {
  static _Decompressor forHeader(_Context context) {
    return switch (context.header.compression) {
      1 => const _NoneDecompressor(),
      2 => const _PalmDocDecompressor(),
      17480 => _HuffDecoder(context),
      _ => throw FormatException(
        'unsupported MOBI compression type ${context.header.compression}',
      ),
    };
  }

  Uint8List decompress(Uint8List data);
}

class _NoneDecompressor implements _Decompressor {
  const _NoneDecompressor();

  @override
  Uint8List decompress(Uint8List data) => data;
}

class _PalmDocDecompressor implements _Decompressor {
  const _PalmDocDecompressor();

  @override
  Uint8List decompress(Uint8List data) {
    var buffer = Uint8List(data.length * 4 + 64);
    var length = 0;

    void ensure(int extra) {
      if (length + extra <= buffer.length) return;
      var capacity = buffer.length;
      while (capacity < length + extra) {
        capacity *= 2;
      }
      final grown = Uint8List(capacity);
      grown.setRange(0, length, buffer);
      buffer = grown;
    }

    var index = 0;
    while (index < data.length) {
      final byte = data[index++];
      if (byte == 0) {
        ensure(1);
        buffer[length++] = 0;
      } else if (byte <= 8) {
        if (index + byte > data.length) {
          throw const FormatException('truncated PalmDOC literal run');
        }
        ensure(byte);
        for (var i = 0; i < byte; i++) {
          buffer[length++] = data[index + i];
        }
        index += byte;
      } else if (byte <= 0x7f) {
        ensure(1);
        buffer[length++] = byte;
      } else if (byte <= 0xbf) {
        if (index >= data.length) {
          throw const FormatException('truncated PalmDOC back-reference');
        }
        final next = data[index++];
        final pair = (byte << 8) | next;
        final distance = (pair & 0x3fff) >> 3;
        final copyLength = (pair & 7) + 3;
        if (distance == 0 || distance > length) {
          throw const FormatException('invalid PalmDOC back-reference');
        }
        ensure(copyLength);
        // The window grows while copying: overlapping runs repeat.
        for (var i = 0; i < copyLength; i++) {
          buffer[length] = buffer[length - distance];
          length++;
        }
      } else {
        ensure(2);
        buffer[length++] = 0x20;
        buffer[length++] = byte ^ 0x80;
      }
      if (length > _maxUncompressedText) {
        throw const FormatException(
          'PalmDOC record exceeds the text safety limit',
        );
      }
    }
    return Uint8List.sublistView(buffer, 0, length);
  }
}

class _HuffDecoder implements _Decompressor {
  /// (found, code length, value) per top byte.
  final List<(bool, int, int)> table1 = List.generate(
    256,
    (_) => (false, 0, 0),
  );
  final List<(int, int)> table2 = List.generate(33, (_) => (0, 0));
  final List<_DictionaryEntry> dictionary = [];

  _HuffDecoder(_Context context) {
    if (context.header.huffCount < 2) {
      throw const FormatException(
        'HUFF/CDIC compression has no dictionary records',
      );
    }
    final huff = context.relativeRecord(context.header.huffStart);
    if (String.fromCharCodes(bytesOf(huff, 0, 4)) != 'HUFF') {
      throw const FormatException('invalid HUFF record');
    }
    final table1Offset = u32At(huff, 8);
    final table2Offset = u32At(huff, 12);
    for (var index = 0; index < 256; index++) {
      final value = u32At(huff, table1Offset + index * 4);
      table1[index] = (value & 0x80 != 0, value & 0x1f, value >> 8);
    }
    for (var index = 1; index < 33; index++) {
      final offset = table2Offset + (index - 1) * 8;
      table2[index] = (u32At(huff, offset), u32At(huff, offset + 4));
    }

    for (
      var recordIndex = 1;
      recordIndex < context.header.huffCount;
      recordIndex++
    ) {
      final record = context.relativeRecord(
        context.header.huffStart + recordIndex,
      );
      if (String.fromCharCodes(bytesOf(record, 0, 4)) != 'CDIC') {
        throw const FormatException('invalid CDIC record');
      }
      final headerLength = u32At(record, 4);
      final totalEntries = u32At(record, 8);
      final codeLength = u32At(record, 12);
      if (codeLength >= 32) {
        throw const FormatException('invalid CDIC code length');
      }
      var remaining = totalEntries - dictionary.length;
      if (remaining < 0) remaining = 0;
      final window = 1 << codeLength;
      final count = window < remaining ? window : remaining;
      final payload = Uint8List.sublistView(record, headerLength);
      for (var entryIndex = 0; entryIndex < count; entryIndex++) {
        final offset = u16At(payload, entryIndex * 2);
        final descriptor = u16At(payload, offset);
        final length = descriptor & 0x7fff;
        dictionary.add(
          _DictionaryEntry(
            Uint8List.fromList(bytesOf(payload, offset + 2, length)),
            descriptor & 0x8000 != 0,
          ),
        );
      }
    }
  }

  @override
  Uint8List decompress(Uint8List data) => _decompress(data, 0);

  Uint8List _decompress(Uint8List data, int depth) {
    if (depth > 64) {
      throw const FormatException('HUFF/CDIC dictionary recursion is too deep');
    }
    final bitLength = data.length * 8;
    var bit = 0;
    final output = BytesBuilder(copy: false);
    while (bit < bitLength) {
      final bits = _read32Bits(data, bit);
      final (found, initialLength, initialValue) = table1[bits >> 24];
      var codeLength = initialLength;
      var value = initialValue;
      if (!found) {
        while (codeLength <= 32 &&
            (bits >> (32 - codeLength)) < table2[codeLength].$1) {
          codeLength++;
        }
        if (codeLength > 32) {
          throw const FormatException('invalid HUFF code');
        }
        value = table2[codeLength].$2;
      }
      bit += codeLength;
      if (bit > bitLength) break;
      final prefix = bits >> (32 - codeLength);
      if (value < prefix) {
        throw const FormatException('invalid HUFF dictionary code');
      }
      final code = value - prefix;
      if (code >= dictionary.length) {
        throw const FormatException('HUFF dictionary code is out of bounds');
      }
      Uint8List expanded;
      final entry = dictionary[code];
      if (entry.decoded) {
        expanded = entry.data;
      } else {
        expanded = _decompress(entry.data, depth + 1);
        dictionary[code] = _DictionaryEntry(expanded, true);
      }
      output.add(expanded);
      if (output.length > _maxUncompressedText) {
        throw const FormatException(
          'HUFF/CDIC output exceeds the text safety limit',
        );
      }
    }
    return output.takeBytes();
  }
}

class _DictionaryEntry {
  final Uint8List data;
  final bool decoded;

  const _DictionaryEntry(this.data, this.decoded);
}

int _read32Bits(Uint8List data, int bit) {
  final start = bit ~/ 8;
  var value = 0;
  for (var index = start; index < start + 5; index++) {
    value = (value << 8) | (index < data.length ? data[index] : 0);
  }
  final shift = 8 - (bit & 7);
  return (value >> shift) & 0xffffffff;
}

/// Strips the MOBI extra-data trailer described by [flags].
Uint8List _removeTrailingEntries(Uint8List data, int flags) {
  var view = data;
  var strip = flags >> 1;
  while (strip != 0) {
    if (strip & 1 != 0) {
      final length = variableLengthFromEnd(view);
      if (length == 0 || length > view.length) {
        throw const FormatException('invalid trailing MOBI entry');
      }
      view = Uint8List.sublistView(view, 0, view.length - length);
    }
    strip >>= 1;
  }
  if (flags & 1 != 0) {
    if (view.isEmpty) {
      throw const FormatException('missing MOBI multibyte trailer');
    }
    final length = (view.last & 3) + 1;
    if (length > view.length) {
      throw const FormatException('invalid MOBI multibyte trailer');
    }
    view = Uint8List.sublistView(view, 0, view.length - length);
  }
  return view;
}

int _validIndex(int value) {
  if (value == _invalidIndex) {
    throw const FormatException('required KF8 index is missing');
  }
  return value;
}

int _uintFromBytes(Uint8List data) {
  if (data.isEmpty || data.length > 4) {
    throw const FormatException('invalid big-endian integer width');
  }
  var value = 0;
  for (final byte in data) {
    value = (value << 8) | byte;
  }
  return value;
}

// -------------------------------------------------------------------- text

String decodeMobiText(Uint8List data, int encoding) {
  if (encoding == 1252) return decodeCp1252(data);
  return utf8.decode(data, allowMalformed: true);
}

String decodeHtmlEntities(String value) => value
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&#160;', ' ')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&amp;', '&');

String? _extractDocumentTitle(String html) {
  final lower = html.toLowerCase();
  for (final tag in const ['title', 'h1', 'h2']) {
    final open = lower.indexOf('<$tag');
    if (open < 0) continue;
    final openEnd = lower.indexOf('>', open);
    if (openEnd < 0) continue;
    final contentStart = openEnd + 1;
    final close = lower.indexOf('</$tag>', contentStart);
    if (close < 0) continue;
    final title = _stripTags(html.substring(contentStart, close));
    if (title.trim().isNotEmpty) return title.trim();
  }
  return null;
}

String _stripTags(String value) {
  final buffer = StringBuffer();
  var inTag = false;
  for (final character in value.split('')) {
    if (character == '<') {
      inTag = true;
    } else if (character == '>') {
      inTag = false;
    } else if (!inTag) {
      buffer.write(character);
    }
  }
  return buffer
      .toString()
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'");
}

/// Image type from magic bytes: (extension, media type), or null.
(String, String)? sniffImageType(Uint8List data) {
  bool startsWith(List<int> prefix, [int offset = 0]) {
    if (data.length < offset + prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (data[offset + i] != prefix[i]) return false;
    }
    return true;
  }

  if (startsWith([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
    return ('png', 'image/png');
  }
  if (startsWith([0xFF, 0xD8, 0xFF])) return ('jpg', 'image/jpeg');
  if (startsWith([0x47, 0x49, 0x46, 0x38])) return ('gif', 'image/gif');
  if (startsWith([0x42, 0x4D])) return ('bmp', 'image/bmp');
  if (startsWith([0x52, 0x49, 0x46, 0x46]) &&
      startsWith([0x57, 0x45, 0x42, 0x50], 8)) {
    return ('webp', 'image/webp');
  }
  return null;
}
