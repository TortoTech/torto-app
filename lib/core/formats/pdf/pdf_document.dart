/// PDF cross-reference and document structure.
///
/// Resolves indirect objects (classic xref tables, xref streams, and
/// object streams), walks the page tree, reads /Info metadata, and builds
/// the outline table of contents (port of torto's `pdf/catalog.rs`).
library;

import 'dart:typed_data';

import '../direct_book_source.dart' show SourceTocEntry;
import 'pdf_decode.dart';
import 'pdf_syntax.dart';

const int _maxOutlineDepth = 64;
const int _maxNameTreeDepth = 64;
const int _maxPageCount = 100000;

class PdfPage {
  /// Raw decoded content stream bytes (all /Contents concatenated).
  final Uint8List content;

  /// Page /Resources dict (inherited from ancestors), or null.
  final PdfObject? resources;

  const PdfPage(this.content, this.resources);
}

class _XrefEntry {
  final int type; // 0 free, 1 offset, 2 objstm
  final int field2;
  final int field3;

  const _XrefEntry(this.type, this.field2, this.field3);
}

class PdfDocument {
  final Uint8List bytes;
  final Map<int, _XrefEntry> _xref = {};
  final Map<int, PdfObject> _cache = {};
  final Map<int, bool> _loading = {};
  PdfDict? _trailer;

  PdfDocument._(this.bytes);

  /// Parses and cross-references a PDF file.
  static PdfDocument open(Uint8List bytes) {
    if (bytes.length < 8 ||
        String.fromCharCodes(bytes.sublist(0, 5)) != '%PDF-') {
      throw const FormatException('not a PDF file');
    }
    final document = PdfDocument._(bytes);
    final startxref = _findStartxref(bytes);
    if (startxref == null) {
      document._scanObjectsLinear();
      return document;
    }
    var visited = <int>{};
    var address = startxref;
    try {
      while (address > 0 && address < bytes.length && visited.add(address)) {
        address = document._readXrefSection(address);
      }
    } on FormatException {
      if (document._xref.isEmpty) rethrow;
    }
    if (document._trailer == null || document._xref.isEmpty) {
      document._scanObjectsLinear();
    }
    return document;
  }

  static int? _findStartxref(Uint8List bytes) {
    final tail = bytes.length > 2048 ? bytes.length - 2048 : 0;
    final marker = 'startxref';
    for (var i = bytes.length - marker.length; i >= tail; i--) {
      var match = true;
      for (var j = 0; j < marker.length; j++) {
        if (bytes[i + j] != marker.codeUnitAt(j)) {
          match = false;
          break;
        }
      }
      if (!match) continue;
      final parser = PdfParser(bytes, i + marker.length);
      final position = parser.readInt();
      return position;
    }
    return null;
  }

  /// Reads one xref section (table or stream); returns the /Prev address.
  int _readXrefSection(int address) {
    final parser = PdfParser(bytes, address);
    parser.skipWhitespaceAndComments();
    if (parser.peekKeyword('xref')) {
      parser.position += 4;
      return _readXrefTable(parser);
    }
    // xref stream: "N G obj << … >> stream …"
    final indirect = _parseIndirectAt(address);
    final object = indirect?.$2;
    if (object is PdfStream) {
      _readXrefStream(object);
      final prev = _trailer?['Prev'];
      if (prev is PdfNum) return prev.asInt;
      return -1;
    }
    throw const FormatException('invalid xref section');
  }

  int _readXrefTable(PdfParser parser) {
    while (true) {
      parser.skipWhitespaceAndComments();
      if (parser.peekKeyword('trailer')) {
        parser.position += 'trailer'.length;
        final trailer = parser.parseObject();
        if (trailer is PdfDict) _mergeTrailer(trailer);
        final prev = _trailer?['Prev'];
        if (prev is PdfNum) return prev.asInt;
        return -1;
      }
      final first = parser.readInt();
      final count = parser.readInt();
      if (first == null || count == null) {
        throw const FormatException('invalid xref subsection');
      }
      for (var i = 0; i < count; i++) {
        final entry = _readXrefEntry(parser);
        if (entry == null) {
          throw const FormatException('truncated xref entry');
        }
        final id = first + i;
        if (_xref.containsKey(id)) continue;
        _xref[id] = entry.type == 0x6E /* n */
            ? _XrefEntry(1, entry.offset, entry.generation)
            : const _XrefEntry(0, 0, 0);
      }
    }
  }

  /// One `nnnnnnnnnn ggggg n` xref-table entry.
  static ({int offset, int generation, int type})? _readXrefEntry(
    PdfParser parser,
  ) {
    parser.skipWhitespaceAndComments();
    if (parser.position >= parser.data.length) return null;
    final offset = parser.readInt();
    final generation = parser.readInt();
    if (offset == null || generation == null) return null;
    parser.skipWhitespaceAndComments();
    if (parser.position >= parser.data.length) return null;
    final type = parser.data[parser.position];
    parser.position++;
    return (offset: offset, generation: generation, type: type);
  }

  void _readXrefStream(PdfStream stream) {
    final dict = stream.dict;
    final size = _intOf(dict['Size']) ?? 0;
    final width = dict['W'];
    if (width is! PdfArray || width.items.length < 3 || size <= 0) {
      throw const FormatException('invalid xref stream');
    }
    final w1 = _intOf(width.items[0]) ?? 0;
    final w2 = _intOf(width.items[1]) ?? 0;
    final w3 = _intOf(width.items[2]) ?? 0;
    var index = [0, size];
    final indexObject = resolveDeep(dict['Index'], resolve);
    if (indexObject is PdfArray && indexObject.items.length >= 2) {
      index = [
        for (final item in indexObject.items)
          if (item is PdfNum) item.asInt,
      ];
    }
    final data = decodeStream(stream, resolve);
    var position = 0;
    int readField(int width) {
      var value = 0;
      for (var i = 0; i < width; i++) {
        value = (value << 8) | (position < data.length ? data[position] : 0);
        position++;
      }
      return value;
    }

    for (var pair = 0; pair + 1 < index.length; pair += 2) {
      final first = index[pair];
      final count = index[pair + 1];
      for (var i = 0; i < count; i++) {
        final type = readField(w1);
        final field2 = readField(w2);
        final field3 = readField(w3);
        final id = first + i;
        if (_xref.containsKey(id)) continue;
        _xref[id] = type == 0
            ? const _XrefEntry(0, 0, 0)
            : type == 2
            ? _XrefEntry(2, field2, field3)
            : _XrefEntry(1, field2, field3);
      }
    }
    _mergeTrailer(stream.dict);
  }

  void _mergeTrailer(PdfDict trailer) {
    final existing = _trailer;
    if (existing == null) {
      _trailer = trailer;
      return;
    }
    _trailer = PdfDict({...existing.entries, ...trailer.entries});
  }

  /// Recovery for files with a broken xref: scan for "N G obj" headers.
  void _scanObjectsLinear() {
    final parser = PdfParser(bytes, 0);
    while (parser.position < bytes.length) {
      final address = parser.position;
      final id = parser.readInt();
      final generation = parser.readInt();
      if (id == null || generation == null) {
        parser.position = address + 1;
        continue;
      }
      parser.skipWhitespaceAndComments();
      if (!parser.peekKeyword('obj')) {
        parser.position = address + 1;
        continue;
      }
      parser.position += 3;
      if (!_xref.containsKey(id) || _xref[id]!.type == 0) {
        _xref[id] = _XrefEntry(1, address, generation);
      }
      // Continue scanning after this object.
      parser.skipPastObject();
    }
  }

  // ------------------------------------------------------------- resolution

  PdfObject? resolve(PdfRef ref) => _resolveId(ref.id);

  PdfObject? _resolveId(int id) {
    final cached = _cache[id];
    if (cached != null) return cached;
    if (_loading[id] == true) return null; // reference cycle
    final entry = _xref[id];
    if (entry == null || entry.type == 0) return null;
    _loading[id] = true;
    try {
      PdfObject? object;
      if (entry.type == 1) {
        final indirect = _parseIndirectAt(entry.field2);
        object = indirect?.$2;
      } else {
        object = _objectInStream(entry.field2, entry.field3);
      }
      if (object != null) _cache[id] = object;
      return object;
    } finally {
      _loading[id] = false;
    }
  }

  (int, PdfObject?)? _parseIndirectAt(int address) {
    if (address <= 0 || address >= bytes.length) return null;
    final parser = PdfParser(bytes, address);
    parser.skipWhitespaceAndComments();
    final id = parser.readInt();
    final generation = parser.readInt();
    if (id == null || generation == null) return null;
    parser.skipWhitespaceAndComments();
    if (!parser.peekKeyword('obj')) return null;
    parser.position += 3;
    final object = parser.parseObject(allowStreams: true);
    if (object == null || object is PdfNull) return null;
    _cache[id] = object;
    return (id, object);
  }

  PdfObject? _objectInStream(int objstmId, int index) {
    final pairs = _loadObjectStream(objstmId);
    if (pairs == null) return null;
    return pairs[index];
  }

  Map<int, Map<int, PdfObject>>? _objstmCache;

  Map<int, PdfObject>? _loadObjectStream(int objstmId) {
    final cache = _objstmCache ??= {};
    final cached = cache[objstmId];
    if (cached != null) return cached;
    final object = _resolveId(objstmId);
    if (object is! PdfStream) return null;
    final count = _intOf(object.dict['N']) ?? 0;
    final first = _intOf(object.dict['First']) ?? 0;
    if (count <= 0 || first <= 0 || count > 100000) return null;
    final data = decodeStream(object, resolve);
    final headerParser = PdfParser(data, 0);
    final offsets = <int, int>{};
    for (var i = 0; i < count; i++) {
      final id = headerParser.readInt();
      final offset = headerParser.readInt();
      if (id == null || offset == null) return null;
      offsets[id] = offset;
    }
    final objects = <int, PdfObject>{};
    offsets.forEach((id, offset) {
      final parser = PdfParser(data, first + offset);
      final parsed = parser.parseObject();
      if (parsed != null && parsed is! PdfNull) {
        objects[id] = parsed;
        _cache[id] = parsed;
      }
    });
    cache[objstmId] = objects;
    return objects;
  }

  static int? _intOf(PdfObject? object) {
    if (object is PdfNum && object.isInteger) return object.asInt;
    return null;
  }

  // -------------------------------------------------------------- structure

  PdfDict? get catalog {
    final root = resolveDeep(_trailer?['Root'], resolve);
    return root is PdfDict ? root : null;
  }

  /// All leaf pages in document order.
  List<PdfPage> get pages {
    final root = resolveDeep(catalog?['Pages'], resolve);
    final pages = <PdfPage>[];
    if (root is PdfDict) {
      _collectPages(root, null, pages, <PdfDict>{});
    }
    return pages;
  }

  void _collectPages(
    PdfDict node,
    PdfObject? inheritedResources,
    List<PdfPage> output,
    Set<PdfDict> seen,
  ) {
    if (output.length >= _maxPageCount || !seen.add(node)) return;
    final type = resolveDeep(node['Type'], resolve);
    final resources = node['Resources'] ?? inheritedResources;
    if (type is PdfName && type.name == 'Page') {
      output.add(PdfPage(_pageContent(node), resources));
      return;
    }
    final kids = resolveDeep(node['Kids'], resolve);
    if (kids is PdfArray) {
      for (final kid in kids.items) {
        final kidDict = resolveDeep(kid, resolve);
        if (kidDict is PdfDict) {
          _collectPages(kidDict, resources, output, seen);
        }
      }
    }
  }

  Uint8List _pageContent(PdfDict page) {
    final contents = resolveDeep(page['Contents'], resolve);
    final streams = <PdfStream>[];
    if (contents is PdfStream) {
      streams.add(contents);
    } else if (contents is PdfArray) {
      for (final item in contents.items) {
        final stream = resolveDeep(item, resolve);
        if (stream is PdfStream) streams.add(stream);
      }
    }
    if (streams.isEmpty) return Uint8List(0);
    final output = BytesBuilder(copy: false);
    for (final stream in streams) {
      try {
        output.add(decodeStream(stream, resolve));
      } on FormatException {
        // A broken content stream yields an empty page, not a dead book.
      }
    }
    return output.takeBytes();
  }

  /// (title, author) from the /Info dictionary.
  (String?, String?) infoMetadata() {
    final info = resolveDeep(_trailer?['Info'], resolve);
    if (info is! PdfDict) return (null, null);
    final title = _textString(info['Title']);
    final author = _textString(info['Author']);
    return (title, author);
  }

  String? _textString(PdfObject? object) {
    final string = resolveDeep(object, resolve);
    return string is PdfString ? decodePdfText(string.bytes) : null;
  }

  /// Outline /Outlines → nested TOC pointing at page sections.
  List<SourceTocEntry> outline() {
    final outlines = resolveDeep(catalog?['Outlines'], resolve);
    if (outlines is! PdfDict) return const [];
    final pageIndices = _pageObjectIndices();
    final namedDestinations = _namedDestinations();
    final reader = _OutlineReader(
      this,
      pageIndices,
      namedDestinations,
      <Object>{},
    );
    final first = resolveDeep(outlines['First'], resolve);
    if (first is! PdfDict) return const [];
    return reader.readLevel(first, 0);
  }

  Map<int, int> _pageObjectIndices() {
    // Assign indices by walking the tree in order; map indirect object ids
    // of leaf page nodes to their page index.
    final indices = <int, int>{};
    final root = resolveDeep(catalog?['Pages'], resolve);
    if (root is PdfDict) {
      _collectPageIds(root, indices, <PdfDict>{});
    }
    return indices;
  }

  void _collectPageIds(PdfDict node, Map<int, int> output, Set<PdfDict> seen) {
    if (output.length >= _maxPageCount || !seen.add(node)) return;
    final kids = resolveDeep(node['Kids'], resolve);
    if (kids is! PdfArray) return;
    for (final kid in kids.items) {
      final kidId = kid is PdfRef ? kid.id : null;
      final kidDict = resolveDeep(kid, resolve);
      if (kidDict is! PdfDict) continue;
      final type = resolveDeep(kidDict['Type'], resolve);
      if (type is PdfName && type.name == 'Page') {
        if (kidId != null) output[kidId] = output.length;
      } else {
        _collectPageIds(kidDict, output, seen);
      }
    }
  }

  /// name → destination object, from /Names/Dests tree and /Dests dict.
  Map<String, PdfObject> _namedDestinations() {
    final destinations = <String, PdfObject>{};
    final catalog = this.catalog;
    if (catalog == null) return destinations;
    final names = resolveDeep(catalog['Names'], resolve);
    final destsTree = resolveDeep(
      names is PdfDict ? names['Dests'] : null,
      resolve,
    );
    if (destsTree is PdfDict) {
      _readNameTree(destsTree, destinations, <PdfDict>{}, 0);
    }
    final dests = resolveDeep(catalog['Dests'], resolve);
    if (dests is PdfDict) {
      dests.entries.forEach((name, value) {
        final key = decodePdfText(Uint8List.fromList(name.codeUnits));
        if (key != null) destinations[key] = value;
      });
    }
    return destinations;
  }

  void _readNameTree(
    PdfDict node,
    Map<String, PdfObject> output,
    Set<PdfDict> seen,
    int depth,
  ) {
    if (depth > _maxNameTreeDepth || !seen.add(node)) return;
    final names = resolveDeep(node['Names'], resolve);
    if (names is PdfArray) {
      for (var i = 0; i + 1 < names.items.length; i += 2) {
        final nameObject = resolveDeep(names.items[i], resolve);
        final destination = resolveDeep(names.items[i + 1], resolve);
        String? name;
        if (nameObject is PdfString) {
          name = decodePdfText(nameObject.bytes);
        } else if (nameObject is PdfName) {
          name = nameObject.name;
        }
        if (name != null && destination != null) output[name] = destination;
      }
    }
    final kids = resolveDeep(node['Kids'], resolve);
    if (kids is PdfArray) {
      for (final kid in kids.items) {
        final kidDict = resolveDeep(kid, resolve);
        if (kidDict is PdfDict) {
          _readNameTree(kidDict, output, seen, depth + 1);
        }
      }
    }
  }
}

class _OutlineReader {
  final PdfDocument document;
  final Map<int, int> pageIndices;
  final Map<String, PdfObject> namedDestinations;
  final Set<Object> seenNodes;

  const _OutlineReader(
    this.document,
    this.pageIndices,
    this.namedDestinations,
    this.seenNodes,
  );

  List<SourceTocEntry> readLevel(PdfDict item, int depth) {
    if (depth > _maxOutlineDepth) return const [];
    final entries = <SourceTocEntry>[];
    PdfDict? current = item;
    while (current != null) {
      final node = current;
      if (!seenNodes.add(node)) break;
      final childFirst = resolveDeep(node['First'], document.resolve);
      final children = childFirst is PdfDict
          ? readLevel(childFirst, depth + 1)
          : const <SourceTocEntry>[];
      final titleObject = resolveDeep(node['Title'], document.resolve);
      final label = titleObject is PdfString
          ? decodePdfText(titleObject.bytes)
          : null;
      final pageIndex = _destination(node);
      if (label != null &&
          label.trim().isNotEmpty &&
          pageIndex != null &&
          pageIndex >= 0) {
        entries.add(
          SourceTocEntry(
            label: label.trim(),
            href: 'Text/section-${pageIndex + 1}.xhtml',
            children: children,
          ),
        );
      } else {
        entries.addAll(children);
      }
      final next = resolveDeep(node['Next'], document.resolve);
      current = next is PdfDict ? next : null;
    }
    return entries;
  }

  int? _destination(PdfDict item) {
    final dest = resolveDeep(item['Dest'], document.resolve);
    if (dest != null) {
      return _resolveDestination(dest, <String>{});
    }
    final action = resolveDeep(item['A'], document.resolve);
    if (action is! PdfDict) return null;
    final actionType = resolveDeep(action['S'], document.resolve);
    if (actionType is! PdfName || actionType.name != 'GoTo') return null;
    final destination = resolveDeep(action['D'], document.resolve);
    if (destination == null) return null;
    return _resolveDestination(destination, <String>{});
  }

  int? _resolveDestination(PdfObject destination, Set<String> seenNames) {
    if (destination is PdfArray) {
      return _pageFromDestinationArray(destination);
    }
    if (destination is PdfDict) {
      final inner = resolveDeep(destination['D'], document.resolve);
      if (inner == null) return null;
      return _resolveDestination(inner, seenNames);
    }
    String? name;
    if (destination is PdfString) {
      name = decodePdfText(destination.bytes);
    } else if (destination is PdfName) {
      name = destination.name;
    }
    if (name == null || !seenNames.add(name)) return null;
    final named = namedDestinations[name];
    if (named == null) return null;
    return _resolveDestination(named, seenNames);
  }

  int? _pageFromDestinationArray(PdfArray destination) {
    if (destination.items.isEmpty) return null;
    final first = resolveDeep(destination.items.first, document.resolve);
    if (first is PdfDict) {
      // Direct page dict: match by identity against resolved page objects.
      for (final entry in pageIndices.entries) {
        if (identical(document._resolveId(entry.key), first)) {
          return entry.value;
        }
      }
      return null;
    }
    if (first is PdfNum && first.isInteger) {
      final index = first.asInt;
      return index >= 0 && index < pageIndices.length ? index : null;
    }
    return null;
  }
}
