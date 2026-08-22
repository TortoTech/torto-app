/// Comic Book Zip (`.cbz`) → [DirectBookSource].
///
/// Dart port of torto's `crates/formats/src/cbz.rs`: every supported image
/// in the archive (name-sorted) becomes one full-page section; optional
/// `ComicInfo.xml` supplies title/author/language metadata; the first page
/// doubles as the cover.
library;

import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:xml/xml.dart';

import '../html_ir/tolerant_xml.dart';
import '../ir/ir.dart';
import 'direct_book_source.dart';

/// Images above this size are rejected, mirroring torto's cap.
const int _maxImageBytes = 64 * 1024 * 1024;

class _ImageEntry {
  final ArchiveFile file;
  final String name;
  final String extension;
  final String mediaType;

  const _ImageEntry(this.file, this.name, this.extension, this.mediaType);
}

class _ComicMetadata {
  final String? title;
  final List<String> authors;
  final String? language;

  const _ComicMetadata({this.title, this.authors = const [], this.language});
}

/// Opens a CBZ from its raw file bytes. Throws [FormatException] when the
/// archive is unreadable or holds no supported images.
Future<DirectBookSource> openCbz(Uint8List bytes, String fileName) async {
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes);
  } catch (error) {
    throw FormatException('CBZ 压缩包无法读取: $error');
  }

  final images = <_ImageEntry>[];
  ArchiveFile? comicInfo;
  for (final file in archive.files) {
    if (!file.isFile) continue;
    final name = file.name;
    if (name.toLowerCase() == 'comicinfo.xml') comicInfo = file;
    final imageType = _imageTypeFromName(name);
    if (imageType != null) {
      images.add(_ImageEntry(file, name, imageType.$1, imageType.$2));
    }
  }
  images.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  if (images.isEmpty) {
    throw const FormatException('CBZ 压缩包中没有支持的图片');
  }

  final metadata = comicInfo == null
      ? const _ComicMetadata()
      : _readComicInfo(comicInfo);

  final resources = <SourceResource>[];
  final sections = <SourceSection>[];
  for (var page = 0; page < images.length; page++) {
    final image = images[page];
    final Uint8List? decoded;
    try {
      decoded = image.file.readBytes();
    } catch (error) {
      throw FormatException('CBZ 图片 ${image.name} 无法解压: $error');
    }
    if (decoded == null) {
      throw FormatException('CBZ 图片 ${image.name} 无法解压');
    }
    if (decoded.length > _maxImageBytes) {
      throw FormatException('CBZ 图片 ${image.name} 超过 64 MiB 限制');
    }
    final resourcePath =
        'Images/page-${(page + 1).toString().padLeft(5, '0')}.${image.extension}';
    resources.add(
      SourceResource(
        path: resourcePath,
        mediaType: image.mediaType,
        bytes: decoded,
      ),
    );
    sections.add(
      SourceSection(
        title: image.name,
        content: ImageSectionContent(
          resourcePath: resourcePath,
          alt: image.name,
        ),
      ),
    );
  }

  final title = metadata.title != null && metadata.title!.trim().isNotEmpty
      ? metadata.title!
      : _titleFromFileName(fileName);

  return DirectBookSource.open(
    SourceBook(
      id: sha256.convert(bytes).toString(),
      metadata: BookMetadata(
        title: title,
        authors: metadata.authors,
        languages: [
          if ((metadata.language ?? '').isNotEmpty) metadata.language!,
        ],
      ),
      sections: sections,
      resources: resources,
      coverPath: resources.first.path,
    ),
  );
}

/// `ComicInfo.xml` fields we care about; a malformed document is ignored
/// (fail-soft to file-name metadata).
_ComicMetadata _readComicInfo(ArchiveFile entry) {
  try {
    final bytes = entry.readBytes();
    if (bytes == null) return const _ComicMetadata();
    final document = tryParseXmlTolerant(decodeXmlBytes(bytes));
    if (document == null) return const _ComicMetadata();
    String? field(String name) {
      final lowerName = name.toLowerCase();
      for (final node
          in document.rootElement.descendants.whereType<XmlElement>()) {
        if (node.name.local.toLowerCase() == lowerName) {
          final value = node.descendants
              .whereType<XmlText>()
              .map((text) => text.value)
              .join()
              .trim();
          if (value.isNotEmpty) return value;
        }
      }
      return null;
    }

    final writers = field('Writer');
    return _ComicMetadata(
      title: field('Title'),
      authors: writers == null
          ? const []
          : [
              for (final writer in writers.split(RegExp('[,;]')))
                if (writer.trim().isNotEmpty) writer.trim(),
            ],
      language: field('LanguageISO'),
    );
  } catch (_) {
    return const _ComicMetadata();
  }
}

(String, String)? _imageTypeFromName(String name) {
  final lower = name.toLowerCase();
  if (lower.startsWith('__macosx/')) return null;
  final dot = lower.lastIndexOf('.');
  if (dot < 0 || dot == lower.length - 1) return null;
  return switch (lower.substring(dot + 1)) {
    'jpg' || 'jpeg' => ('jpg', 'image/jpeg'),
    'png' => ('png', 'image/png'),
    'gif' => ('gif', 'image/gif'),
    'webp' => ('webp', 'image/webp'),
    'bmp' => ('bmp', 'image/bmp'),
    _ => null,
  };
}

String _titleFromFileName(String fileName) {
  var name = fileName.replaceAll('\\', '/');
  name = name.substring(name.lastIndexOf('/') + 1);
  final dot = name.lastIndexOf('.');
  if (dot > 0) name = name.substring(0, dot);
  return name.isEmpty ? '未命名漫画' : name;
}
