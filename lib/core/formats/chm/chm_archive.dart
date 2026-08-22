/// CHM (ITSF) archive reader.
///
/// Replaces torto's `libchm` binding with a pure-Dart implementation:
/// parses the ITSF header and PMGL directory, and — for compressed files —
/// decompresses the whole `MSCompressed` content stream in one sequential
/// LZX pass (torto reads every entry up front, so a one-shot decompression
/// with the same size caps is equivalent and simpler).
library;

import 'dart:typed_data';

import 'lzx.dart';

const int _maxEntries = 20000;
const int _maxEntryBytes = 64 * 1024 * 1024;
const int _maxTotalBytes = 512 * 1024 * 1024;

const String _controlDataName = '::DataSpace/Storage/MSCompressed/ControlData';
const String _contentName = '::DataSpace/Storage/MSCompressed/Content';
const String _resetTableName =
    '::DataSpace/Storage/MSCompressed/Transform/'
    '{7fc28940-9d31-11d0-9b27-00a0c91e9c7c}/InstanceData/ResetTable';

class ChmEntry {
  /// Normalized path: no leading '/', '/' separators, original case.
  final String path;
  final int section;
  final int offset;
  final int length;

  const ChmEntry(this.path, this.section, this.offset, this.length);
}

class ChmArchive {
  final Uint8List _bytes;
  final int _dataOffset;

  /// All entries (including meta files like `#SYSTEM`), by lowercase path.
  final Map<String, ChmEntry> _entries;

  // Compressed-content state, used on first section-1 read.
  final ChmEntry? _contentEntry;
  final int _windowBits;
  final int _resetBlockCount;
  final List<int> _blockStarts;
  final int _blockLength;
  final int _uncompressedLength;
  final int _compressedLength;
  Uint8List? _content;

  ChmArchive._(
    this._bytes,
    this._dataOffset,
    this._entries,
    this._contentEntry,
    this._windowBits,
    this._resetBlockCount,
    this._blockStarts,
    this._blockLength,
    this._uncompressedLength,
    this._compressedLength,
  );

  static ChmArchive open(Uint8List bytes) {
    if (bytes.length < 0x60) throw const FormatException('truncated CHM');
    if (_magic(bytes, 0) != 'ITSF') {
      throw const FormatException('not a CHM (ITSF) file');
    }
    final version = _u32(bytes, 4);
    if (version != 2 && version != 3) {
      throw FormatException('unsupported CHM version $version');
    }
    final dirOffset = _u64(bytes, 0x48);
    final dirLen = _u64(bytes, 0x50);
    final dataOffset = version == 3 ? _u64(bytes, 0x58) : dirOffset + dirLen;
    if (dirOffset + dirLen > bytes.length || dataOffset > bytes.length) {
      throw const FormatException('truncated CHM directory');
    }

    // ITSP directory preamble at dirOffset: header_len@8, block_len@0x10.
    // Directory chunks start after the ITSP header (chmlib: dir_offset +=
    // header_len, dir_len -= header_len).
    if (dirOffset + 0x54 > bytes.length || _magic(bytes, dirOffset) != 'ITSP') {
      throw const FormatException('invalid CHM directory header');
    }
    final itspHeaderLength = _u32(bytes, dirOffset + 8);
    final blockLen = _u32(bytes, dirOffset + 0x10);
    if (blockLen <= 0x14 || itspHeaderLength < 0x54) {
      throw const FormatException('invalid CHM directory block size');
    }
    final chunkBase = dirOffset + itspHeaderLength;
    final chunkSpan = dirLen - itspHeaderLength;
    if (chunkSpan <= 0 || chunkBase + chunkSpan > bytes.length) {
      throw const FormatException('truncated CHM directory');
    }

    // Walk every directory chunk; PMGL leaves carry the entries (chunks are
    // stored in order, so a sequential scan equals the linked walk). Entry
    // integers (name length, section, offset, length) are "cword"
    // variable-length encoded: high-bit bytes continue, 7 bits each.
    final entries = <String, ChmEntry>{};
    final chunkCount = chunkSpan ~/ blockLen;
    for (var chunk = 0; chunk < chunkCount; chunk++) {
      final base = chunkBase + chunk * blockLen;
      if (base + blockLen > bytes.length) break;
      if (_magic(bytes, base) != 'PMGL') continue;
      final freeSpace = _u32(bytes, base + 4);
      if (freeSpace > blockLen - 0x14) {
        throw const FormatException('invalid CHM directory chunk');
      }
      var position = base + 0x14;
      final end = base + blockLen - freeSpace;
      while (position < end) {
        final nameLength = _cword(bytes, position, (v, c) => position = c);
        if (nameLength > end - position) {
          throw const FormatException('invalid CHM directory entry');
        }
        final name = String.fromCharCodes(
          bytes.sublist(position, position + nameLength),
        );
        position += nameLength;
        final section = _cword(bytes, position, (v, c) => position = c);
        final offset = _cword(bytes, position, (v, c) => position = c);
        final length = _cword(bytes, position, (v, c) => position = c);
        final normalized = name.startsWith('/')
            ? name.substring(1).replaceAll('\\', '/')
            : name.replaceAll('\\', '/');
        if (normalized.isEmpty || normalized.endsWith('/')) continue;
        if (entries.length >= _maxEntries) {
          throw const FormatException('CHM entry count exceeds 20000');
        }
        entries[normalized.toLowerCase()] = ChmEntry(
          normalized,
          section,
          offset,
          length,
        );
      }
    }
    if (entries.isEmpty) {
      throw const FormatException('CHM contains no readable entries');
    }

    // Compressed-content setup: all three control entries must be present.
    final control = entries[_controlDataName.toLowerCase()];
    final content = entries[_contentName.toLowerCase()];
    final reset = entries[_resetTableName.toLowerCase()];
    if (control != null && content != null && reset != null) {
      final controlBytes = _readRaw(bytes, dataOffset, control);
      final compressed = _parseCompressionControl(controlBytes);
      final resetBytes = _readRaw(bytes, dataOffset, reset);
      final table = _parseResetTable(resetBytes);
      return ChmArchive._(
        bytes,
        dataOffset,
        entries,
        content,
        compressed.$1,
        compressed.$2,
        table.blockStarts,
        table.blockLength,
        table.uncompressedLength,
        table.compressedLength,
      );
    }
    return ChmArchive._(
      bytes,
      dataOffset,
      entries,
      null,
      0,
      0,
      const [],
      0,
      0,
      0,
    );
  }

  /// Normal file entries for the publication's resource set: skips meta
  /// streams (`#SYSTEM`, `$WW…`, `::DataSpace/…`) and directories.
  Iterable<ChmEntry> get fileEntries => _entries.values.where(
    (entry) =>
        !entry.path.startsWith('#') &&
        !entry.path.startsWith(r'$') &&
        !entry.path.startsWith(':'),
  );

  /// All raw entry paths (lowercase-sorted), for diagnostics and tests.
  List<String> get allEntryPaths =>
      [for (final entry in _entries.values) entry.path]..sort();

  ChmEntry? find(String path) => _entries[path.toLowerCase()];

  /// Reads the full bytes of [entry] (throws [FormatException] on bounds
  /// violations or oversize entries).
  Uint8List read(ChmEntry entry) {
    if (entry.length > _maxEntryBytes) {
      throw FormatException('CHM entry ${entry.path} exceeds 64 MiB');
    }
    if (entry.section == 0) {
      return _readRaw(_bytes, _dataOffset, entry);
    }
    final content = _ensureContent();
    if (entry.offset + entry.length > content.length) {
      throw const FormatException('CHM entry outside compressed content');
    }
    return Uint8List.sublistView(
      content,
      entry.offset,
      entry.offset + entry.length,
    );
  }

  /// The `#SYSTEM` metadata fields by code (0=contents, 2=default topic,
  /// 3=title); empty when absent or unreadable.
  Map<int, String> systemInfo() {
    final entry = _entries['#system'];
    if (entry == null) return const {};
    final Uint8List bytes;
    try {
      bytes = _readRaw(_bytes, _dataOffset, entry);
    } on FormatException {
      return const {};
    }
    final values = <int, String>{};
    var position = 4;
    while (position + 4 <= bytes.length) {
      final code = bytes[position] | (bytes[position + 1] << 8);
      final length = bytes[position + 2] | (bytes[position + 3] << 8);
      position += 4;
      if (position + length > bytes.length) break;
      var end = position;
      while (end < position + length && bytes[end] != 0) {
        end++;
      }
      values[code] = String.fromCharCodes(bytes.sublist(position, end));
      position += length;
    }
    return values;
  }

  Uint8List _ensureContent() {
    final cached = _content;
    if (cached != null) return cached;
    final contentEntry = _contentEntry;
    if (contentEntry == null) {
      throw const FormatException(
        'CHM entry requires a missing compressed section',
      );
    }
    if (_uncompressedLength > _maxTotalBytes) {
      throw const FormatException('CHM expanded content exceeds 512 MiB');
    }
    final lzx = LzxDecoder(_windowBits);
    final output = BytesBuilder(copy: false);
    for (var block = 0; block < _blockStarts.length; block++) {
      if (block % _resetBlockCount == 0) lzx.reset();
      final start = _blockStarts[block];
      final end = block + 1 < _blockStarts.length
          ? _blockStarts[block + 1]
          : _compressedLength;
      final blockStart = _dataOffset + contentEntry.offset + start;
      if (end < start || blockStart + (end - start) > _bytes.length) {
        throw const FormatException('CHM compressed block out of range');
      }
      final compressed = Uint8List.sublistView(
        _bytes,
        blockStart,
        blockStart + (end - start),
      );
      output.add(lzx.decompress(compressed, _blockLength));
    }
    final full = output.takeBytes();
    if (full.length < _uncompressedLength) {
      throw const FormatException('CHM content shorter than declared');
    }
    return _content = Uint8List.sublistView(full, 0, _uncompressedLength);
  }

  static String _magic(Uint8List bytes, int offset) =>
      String.fromCharCodes(bytes.sublist(offset, offset + 4));

  /// Variable-length integer (chmlib `_chm_parse_cword`); [advance] receives
  /// the byte position past the last consumed byte.
  static int _cword(
    Uint8List bytes,
    int offset,
    void Function(int value, int consumedEnd) advance,
  ) {
    var accumulator = 0;
    var position = offset;
    while (position < bytes.length && bytes[position] >= 0x80) {
      accumulator = (accumulator << 7) | (bytes[position] & 0x7f);
      position++;
    }
    if (position >= bytes.length) {
      throw const FormatException('truncated CHM directory integer');
    }
    final value = (accumulator << 7) + bytes[position];
    advance(value, position + 1);
    return value;
  }

  static int _u32(Uint8List bytes, int offset) =>
      bytes[offset] |
      (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 24);

  static int _u64(Uint8List bytes, int offset) =>
      _u32(bytes, offset) | (_u32(bytes, offset + 4) << 32);

  static Uint8List _readRaw(Uint8List bytes, int dataOffset, ChmEntry entry) {
    final start = dataOffset + entry.offset;
    if (start < 0 || start + entry.length > bytes.length) {
      throw FormatException('CHM entry ${entry.path} outside the file');
    }
    return Uint8List.sublistView(bytes, start, start + entry.length);
  }

  /// (windowBits, resetBlockCount).
  static (int, int) _parseCompressionControl(Uint8List bytes) {
    if (bytes.length < 0x18 || _magic(bytes, 4) != 'LZXC') {
      throw const FormatException('invalid CHM LZXC control data');
    }
    final version = _u32(bytes, 8);
    var resetInterval = _u32(bytes, 12);
    var windowSize = _u32(bytes, 16);
    final windowsPerReset = _u32(bytes, 20);
    if (version == 2) {
      resetInterval *= 0x8000;
      windowSize *= 0x8000;
    }
    if (windowSize == 0 || resetInterval == 0) {
      throw const FormatException('invalid CHM compression parameters');
    }
    var windowBits = 0;
    var size = windowSize;
    while (size > 1) {
      size >>= 1;
      windowBits++;
    }
    if (1 << windowBits != windowSize || windowBits < 15 || windowBits > 21) {
      throw const FormatException('invalid CHM LZX window size');
    }
    final resetBlockCount =
        (resetInterval ~/ (windowSize ~/ 2)) * windowsPerReset;
    if (resetBlockCount <= 0) {
      throw const FormatException('invalid CHM reset interval');
    }
    return (windowBits, resetBlockCount);
  }
}

class _ResetTable {
  final int uncompressedLength;
  final int compressedLength;
  final List<int> blockStarts;
  final int blockLength;

  const _ResetTable(
    this.uncompressedLength,
    this.compressedLength,
    this.blockStarts,
    this.blockLength,
  );
}

_ResetTable _parseResetTable(Uint8List bytes) {
  if (bytes.length < 0x28 || ChmArchive._u32(bytes, 0) != 2) {
    throw const FormatException('invalid CHM reset table');
  }
  final blockCount = ChmArchive._u32(bytes, 4);
  final tableOffset = ChmArchive._u32(bytes, 12);
  final uncompressedLength = ChmArchive._u64(bytes, 16);
  final compressedLength = ChmArchive._u64(bytes, 24);
  final blockLength = ChmArchive._u64(bytes, 32);
  if (blockCount > 1 << 20 || blockLength == 0 || blockLength > 1 << 24) {
    throw const FormatException('invalid CHM reset table geometry');
  }
  if (tableOffset + blockCount * 8 > bytes.length) {
    throw const FormatException('truncated CHM reset table');
  }
  final starts = [
    for (var i = 0; i < blockCount; i++)
      ChmArchive._u64(bytes, tableOffset + i * 8),
  ];
  return _ResetTable(uncompressedLength, compressedLength, starts, blockLength);
}
