import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import '../../ir/ir.dart';
import '../../layout/focus_layout.dart';
import '../desktop_ir_codec.dart';
import 'pdf_reflow_source.dart';
import 'native_store.dart';

Future<PdfNativeBookSource?> loadPdfNativeBookSource(
  BookSource original,
  Directory root,
) => withNativeStore(root, () => _loadNative(original, root));

Future<PdfNativeBookSource?> _loadNative(
  BookSource original,
  Directory root,
) async {
  await recoverNativePair(root);
  if (!await File('${root.path}/native-pdf.zip').exists()) return null;
  String? preference;
  try {
    preference =
        jsonDecode(await File('${root.path}/pdf-source.json').readAsString())
            as String?;
  } catch (_) {
    try {
      if (jsonDecode(
            await File('${root.path}/view-mode.json').readAsString(),
          ) ==
          'reflow') {
        preference = 'ocr';
      }
    } catch (_) {
      /* No prior explicit OCR choice. */
    }
  }
  if (preference == 'ocr') return null;
  final prepared = await _prepareNativeInWorker(
    root.path,
    original.book.id,
    original.book.sectionCount,
  );
  final source = PdfNativeBookSource(
    original,
    Directory(prepared.$1),
    prepared.$2,
    root,
  );
  if (preference == 'original') source.mode = PdfOcrViewMode.original;
  return source;
}

Future<(String, Map<String, dynamic>)> _prepareNativeInWorker(
  String root,
  String id,
  int pages,
) => Isolate.run(() => _prepareNative(root, id, pages));

Future<Section> _readNativeInWorker(
  String directory,
  List<int> group,
  int index,
  Map<String, String> paths,
) => Isolate.run(() {
  final codec = DesktopIrCodec(
    resolve: (href) {
      final path = paths[href.split('#').first];
      if (path == null) return href;
      return href.contains('#')
          ? '$path#${href.split('#').skip(1).join('#')}'
          : path;
    },
  );
  final parts = <Section>[];
  for (final chunk in group) {
    final value = DesktopIrCodec.map(
      jsonDecode(File('$directory/sections/$chunk.json').readAsStringSync()),
    );
    parts.add(codec.section(value['section'], index));
  }
  return Section(
    id: parts.first.id,
    href: parts.first.href,
    spineIndex: index,
    blocks: parts.expand((s) => s.blocks).toList(),
    anchors: parts.expand((s) => s.anchors).toList(),
  );
});

bool _safeNativeName(String name) =>
    name == 'manifest.json' ||
    RegExp(r'^sections/[0-9]+\.json$').hasMatch(name) ||
    RegExp(r'^resources/[A-Za-z0-9_.-]+$').hasMatch(name) &&
        !name.endsWith('/.') &&
        !name.endsWith('/..');

(String, Map<String, dynamic>) _prepareNative(
  String root,
  String id,
  int pages,
) {
  final cache = Directory('$root/native');
  cache.createSync(recursive: true);
  final archiveStat = File('$root/native-pdf.zip').statSync();
  final stamp =
      '${archiveStat.size}:${archiveStat.modified.microsecondsSinceEpoch}';
  final pointer = File('${cache.path}/current.json');
  try {
    final saved = DesktopIrCodec.map(jsonDecode(pointer.readAsStringSync()));
    final hash = saved['hash'];
    if (saved['stamp'] == stamp &&
        hash is String &&
        RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) {
      final directory = '${cache.path}/$hash';
      final manifest = DesktopIrCodec.map(
        jsonDecode(File('$directory/manifest.json').readAsStringSync()),
      );
      final book = DesktopIrCodec().book(manifest['book']);
      if (book.id == id &&
          DesktopIrCodec.list(manifest['page_targets']).length == pages &&
          manifest['version'] is int &&
          (manifest['version'] as int) >= 12 &&
          (manifest['version'] as int) <= 14 &&
          List.generate(
            book.sectionCount,
            (i) => File('$directory/sections/$i.json').existsSync(),
          ).every((v) => v)) {
        return (directory, manifest);
      }
    }
  } catch (_) {
    /* Fall back to validated extraction. */
  }
  final staging = Directory(
    '$root/native/staging-${DateTime.now().microsecondsSinceEpoch}',
  );
  staging.createSync();
  final snapshot = File('${staging.path}/payload.zip');
  try {
    File('$root/native-pdf.zip').copySync(snapshot.path);
  } catch (_) {
    staging.deleteSync(recursive: true);
    rethrow;
  }
  final digest = _FileDigest();
  final converter = sha256.startChunkedConversion(digest);
  final reader = snapshot.openSync();
  try {
    while (true) {
      final bytes = reader.readSync(64 * 1024);
      if (bytes.isEmpty) break;
      converter.add(bytes);
    }
  } finally {
    reader.closeSync();
  }
  converter.close();
  final generation = Directory('${cache.path}/${digest.value}');
  final input = InputFileStream(snapshot.path);
  var inputClosed = false;
  try {
    final decoder = ZipDecoder();
    final archive = decoder.decodeStream(input);
    // Archive collapses duplicate filenames; inspect the physical ZIP entries.
    final physicalNames = <String>{};
    for (final header in decoder.directory.fileHeaders) {
      if (!physicalNames.add(header.filename.toLowerCase())) {
        throw const FormatException('Duplicate native PDF archive entry');
      }
    }
    final names = <String>{};
    var total = 0;
    for (final entry in archive) {
      if (entry.name == 'sections/' || entry.name == 'resources/') continue;
      total += entry.size;
      if (!entry.isFile ||
          entry.isSymbolicLink ||
          !_safeNativeName(entry.name) ||
          !names.add(entry.name.toLowerCase()) ||
          entry.size > 64 * 1024 * 1024 ||
          total > 768 * 1024 * 1024) {
        throw const FormatException('Invalid native PDF archive');
      }
    }
    final manifestBytes = archive.find('manifest.json')?.readBytes();
    if (manifestBytes == null || manifestBytes.length > 8 * 1024 * 1024) {
      throw const FormatException('Missing native PDF manifest');
    }
    final manifest = DesktopIrCodec.map(jsonDecode(utf8.decode(manifestBytes)));
    final version = manifest['version'];
    final rawBook = DesktopIrCodec.map(manifest['book']);
    final original = DesktopIrCodec.map(manifest['original']);
    final codec = DesktopIrCodec(), book = codec.book(rawBook);
    if (version is! int ||
        version < 12 ||
        version > 14 ||
        book.id != id ||
        original['id'] != id ||
        book.spine.isEmpty ||
        book.spine.length > 10000 ||
        DesktopIrCodec.list(manifest['page_targets']).length != pages) {
      throw const FormatException(
        'Native PDF identity or version does not match',
      );
    }
    for (final resource in DesktopIrCodec.list(manifest['resources'])) {
      if (resource is! String ||
          !_safeNativeName(resource) ||
          !resource.startsWith('resources/') ||
          archive.find(resource) == null) {
        throw const FormatException('Missing native PDF resource');
      }
    }
    final fragments = <String, Set<String>>{};
    for (var i = 0; i < book.spine.length; i++) {
      final bytes = archive.find('sections/$i.json')?.readBytes();
      if (bytes == null || bytes.length > 32 * 1024 * 1024) {
        throw const FormatException('Missing native PDF section');
      }
      final wrapper = DesktopIrCodec.map(jsonDecode(utf8.decode(bytes)));
      final section = codec.section(wrapper['section'], i);
      if (section.id != book.spine[i].id ||
          section.href != book.spine[i].href) {
        throw const FormatException('Native PDF section identity mismatch');
      }
      fragments[section.href] = section.anchors.map((a) => a.fragment).toSet();
      final provenance = wrapper['provenance_resource'];
      if (provenance != null &&
          !DesktopIrCodec.list(manifest['resources']).contains(provenance)) {
        throw const FormatException('Undeclared native PDF mapping');
      }
    }
    // Validate all targets before publishing a generation. Reading this source
    // never mutates an older generation that a retained reader still owns.
    for (final raw in DesktopIrCodec.list(manifest['page_targets'])) {
      final target = DesktopIrCodec.string(raw);
      final parts = target.split('#');
      if (!fragments.containsKey(parts.first) ||
          parts.length > 2 ||
          parts.length == 2 && !fragments[parts.first]!.contains(parts.last)) {
        throw const FormatException('Invalid native PDF page target');
      }
    }
    if (!generation.existsSync()) {
      for (final entry in archive) {
        if (!entry.isFile) continue;
        final outputFile = File('${staging.path}/${entry.name}');
        outputFile.parent.createSync(recursive: true);
        final output = OutputFileStream(outputFile.path);
        try {
          entry.writeContent(output);
        } finally {
          output.closeSync();
        }
        // The archive package currently ignores its verify flag. Check the
        // extracted stream ourselves without holding a whole resource in RAM.
        final extracted = outputFile.openSync();
        var crc = 0, length = 0;
        try {
          while (true) {
            final bytes = extracted.readSync(64 * 1024);
            if (bytes.isEmpty) break;
            length += bytes.length;
            crc = getCrc32(bytes, crc);
          }
        } finally {
          extracted.closeSync();
        }
        if (length != entry.size || crc != entry.crc32) {
          throw const FormatException('Corrupt native PDF archive entry');
        }
      }
      input.closeSync();
      inputClosed = true;
      snapshot.deleteSync();
      staging.renameSync(generation.path);
    }
    final pending = File('${pointer.path}.part');
    pending.writeAsStringSync(
      jsonEncode({'stamp': stamp, 'hash': digest.value}),
      flush: true,
    );
    if (pointer.existsSync()) pointer.deleteSync();
    pending.renameSync(pointer.path);
    return (generation.path, manifest);
  } finally {
    if (!inputClosed) input.closeSync();
    // This is a uniquely created staging directory directly under the cache.
    if (staging.existsSync()) staging.deleteSync(recursive: true);
  }
}

class _FileDigest implements Sink<Digest> {
  String? value;
  @override
  void add(Digest digest) {
    value = digest.toString();
  }

  @override
  void close() {}
}

class PdfNativeBookSource implements PdfReflowSource {
  @override
  final BookSource original;
  final Directory generation, root;
  final Map<String, dynamic> manifest;
  final List<List<int>> _groups = [];
  final Map<String, int> _owners = {};
  final Map<int, Section> _cache = {};
  late final DesktopIrCodec _codec;
  late final Book _rawBook;
  late final List<String> _targets;
  @override
  late final Book reflowBook;
  @override
  List<TocEntry> get originalToc => original.book.toc;
  @override
  String get label => 'Local text';
  @override
  PdfOcrViewMode mode = PdfOcrViewMode.reflow;
  bool _disposed = false;

  PdfNativeBookSource(
    this.original,
    this.generation,
    this.manifest,
    this.root,
  ) {
    final raw = DesktopIrCodec.map(manifest['book']);
    _rawBook = DesktopIrCodec().book(raw);
    for (final (index, item) in DesktopIrCodec.list(raw['sections']).indexed) {
      final continuation =
          (DesktopIrCodec.map(item)['properties'] as List? ?? []).contains(
            'rebook-continuation-section',
          );
      if (_groups.isEmpty || !continuation) _groups.add([]);
      _groups.last.add(index);
      _owners[_rawBook.spine[index].href] = _groups.length - 1;
    }
    String resolve(String href) {
      final group = _owners[href.split('#').first];
      if (group == null) return href;
      final path = _rawBook.spine[_groups[group].first].href;
      return href.contains('#')
          ? '$path#${href.split('#').skip(1).join('#')}'
          : path;
    }

    _codec = DesktopIrCodec(resolve: resolve);
    final decoded = _codec.book(raw);
    reflowBook = Book(
      spineAliases: {
        for (final (groupIndex, chunks) in _groups.indexed)
          for (final chunk in chunks) _rawBook.spine[chunk].id: groupIndex,
      },
      id: decoded.id,
      metadata: decoded.metadata,
      spine: [
        for (final (index, group) in _groups.indexed)
          SpineItem(
            id: _rawBook.spine[group.first].id,
            index: index,
            href: _rawBook.spine[group.first].href,
          ),
      ],
      toc: _retargetToc(decoded.toc),
      coverHref: decoded.coverHref,
    );
    _targets = DesktopIrCodec.list(
      manifest['page_targets'],
    ).map(DesktopIrCodec.string).map(resolve).toList();
  }
  List<TocEntry> _retargetToc(List<TocEntry> values) => [
    for (final t in values)
      TocEntry(
        label: t.label,
        href: t.href,
        spineIndex: _owners[t.href.split('#').first],
        children: _retargetToc(t.children),
      ),
  ];
  @override
  Book get book => mode == PdfOcrViewMode.reflow ? reflowBook : original.book;
  @override
  int sectionForPage(int page) =>
      _owners[_targets[page.clamp(0, _targets.length - 1)].split('#').first]!;
  @override
  String reflowTarget(int page) => _targets[page.clamp(0, _targets.length - 1)];
  @override
  int physicalPage(int section, SourceAnchor? anchor, Section? content) {
    if (mode == PdfOcrViewMode.original) return section;
    var physical = List.generate(
      _targets.length,
      (i) => i,
    ).indexWhere((i) => sectionForPage(i) == section);
    physical = physical < 0 ? 0 : physical;
    if (anchor == null || content == null) return physical;
    final nodes = [
      for (final block in content.blocks)
        for (final range in FocusUnitBuilder.sources(block)) range.start,
    ];
    final at = nodes.indexWhere(
      (n) => n.spine == anchor.spine && n.node == anchor.node,
    );
    for (final marker in content.anchors) {
      final page = RegExp(r'^pdf-page-([0-9]+)$').firstMatch(marker.fragment);
      final offset = nodes.indexWhere(
        (n) => n.spine == marker.source.spine && n.node == marker.source.node,
      );
      if (page != null &&
          offset >= 0 &&
          offset <= at &&
          (offset < at || marker.source.textOffset <= anchor.textOffset)) {
        physical = int.parse(page[1]!) - 1;
      }
    }
    return physical.clamp(0, _targets.length - 1);
  }

  @override
  Future<String?> targetForLocator(LocatorV1 locator) async {
    final path = locator.href.split('#').first;
    if (book.spine.any((s) => s.href == path)) return null;
    final physical = original.book.spine.indexWhere((s) => s.href == path);
    if (physical >= 0) return reflowTarget(physical);
    final group = _owners[path];
    if (group == null) return null;
    final oldMode = mode;
    try {
      mode = PdfOcrViewMode.reflow;
      final page = physicalPage(
        group,
        locator.source?.start,
        await _section(group),
      );
      return oldMode == PdfOcrViewMode.original
          ? original.book.spine[page].href
          : reflowTarget(page);
    } finally {
      mode = oldMode;
    }
  }

  @override
  Future<void> saveMode() => File('${root.path}/pdf-source.json')
      .writeAsString(
        jsonEncode(mode == PdfOcrViewMode.original ? 'original' : 'native'),
      )
      .then((_) {});
  @override
  Future<Section> parseSection(int index) {
    if (_disposed) throw StateError('Native PDF source is disposed');
    return mode == PdfOcrViewMode.original
        ? original.parseSection(index)
        : _section(index);
  }

  Future<Section> _section(int index) async {
    final cached = _cache.remove(index);
    if (cached != null) {
      _cache[index] = cached;
      return cached;
    }
    final paths = {
      for (final path in _owners.keys)
        path: _rawBook.spine[_groups[_owners[path]!].first].href,
    };
    final result = await _readNativeInWorker(
      generation.path,
      _groups[index],
      index,
      paths,
    );
    if (_disposed) throw StateError('Native PDF source is disposed');
    _cache[index] = result;
    while (_cache.length > 3) {
      _cache.remove(_cache.keys.first);
    }
    return result;
  }

  @override
  Future<Uint8List?> resource(String href) async {
    if (_disposed) return null;
    if (!_safeNativeName(href) || !href.startsWith('resources/')) {
      return original.resource(href);
    }
    final file = File('${generation.path}/$href');
    return await file.exists() ? file.readAsBytes() : null;
  }

  @override
  Future<ui.Image?> rasterResource(
    String href, {
    int maxDimension = 2048,
  }) async {
    if (!_safeNativeName(href) || !href.startsWith('resources/')) {
      return original is RasterResourceSource
          ? (original as RasterResourceSource).rasterResource(
              href,
              maxDimension: maxDimension,
            )
          : null;
    }
    final bytes = await resource(href);
    if (bytes == null) return null;
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final codec = await ui.instantiateImageCodecWithSize(
      buffer,
      getTargetSize: (width, height) {
        final longest = width > height ? width : height;
        if (longest <= maxDimension) return const ui.TargetImageSize();
        return ui.TargetImageSize(
          width: (width * maxDimension / longest).round().clamp(
            1,
            maxDimension,
          ),
          height: (height * maxDimension / longest).round().clamp(
            1,
            maxDimension,
          ),
        );
      },
    );
    try {
      return (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _cache.clear();
    if (original is DisposableBookSource) {
      (original as DisposableBookSource).dispose();
    }
  }
}
