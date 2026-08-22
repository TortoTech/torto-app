/// Binary readers for the Palm database (PDB) MOBI container.
///
/// Dart port of the low-level half of torto's `crates/formats/src/kf8.rs`:
/// bounds-checked big-endian reads, MOBI variable-width integers, and the
/// PDB record table. All readers throw [FormatException] on truncation.
library;

import 'dart:typed_data';

/// Reads [length] bytes at [offset]; throws when out of bounds.
Uint8List bytesOf(Uint8List data, int offset, int length) {
  final end = offset + length;
  if (offset < 0 || end > data.length) {
    throw const FormatException('truncated binary structure');
  }
  // The copy keeps callers from slicing huge records repeatedly.
  return Uint8List.sublistView(data, offset, end);
}

int u16At(Uint8List data, int offset) {
  bytesOf(data, offset, 2);
  return (data[offset] << 8) | data[offset + 1];
}

int u32At(Uint8List data, int offset) {
  bytesOf(data, offset, 4);
  return (data[offset] << 24) |
      (data[offset + 1] << 16) |
      (data[offset + 2] << 8) |
      data[offset + 3];
}

/// Null when [offset] is beyond the record (optional header fields).
int? optionalU32(Uint8List data, int offset) {
  try {
    return u32At(data, offset);
  } on FormatException {
    return null;
  }
}

/// Forward MOBI variable-width integer at [start]: 7 bits per byte, most
/// significant first, terminated by a byte with the high bit set (at most
/// four bytes). Returns (value, consumed byte count).
(int, int) variableLength(Uint8List data, int start) {
  if (start >= data.length) {
    throw FormatException(
      'truncated variable-length integer at byte $start of ${data.length}',
    );
  }
  var value = 0;
  final available = (data.length - start).clamp(0, 4);
  for (var length = 1; length <= available; length++) {
    final byte = data[start + length - 1];
    value = (value << 7) | (byte & 0x7f);
    if (byte & 0x80 != 0) return (value, length);
  }
  return (value, available);
}

/// The trailing variable-width integer at the very end of [data] (used by
/// the MOBI extra-data trailer): scans the last ≤4 bytes, restarting at
/// every high-bit byte.
int variableLengthFromEnd(Uint8List data) {
  var value = 0;
  final start = data.length <= 4 ? 0 : data.length - 4;
  for (var i = start; i < data.length; i++) {
    final byte = data[i];
    if (byte & 0x80 != 0) value = 0;
    value = (value << 7) | (byte & 0x7f);
  }
  return value;
}

/// Palm database record table (`BOOKMOBI`).
class Pdb {
  final Uint8List bytes;
  final List<int> offsets;

  Pdb._(this.bytes, this.offsets);

  static Pdb open(Uint8List bytes) {
    if (bytes.length < 78 ||
        String.fromCharCodes(bytes.sublist(60, 68)) != 'BOOKMOBI') {
      throw const FormatException('not a Palm database MOBI container');
    }
    final count = u16At(bytes, 76);
    final tableLength = count * 8 + 78;
    if (tableLength > bytes.length) {
      throw const FormatException('truncated PDB record table');
    }
    final offsets = <int>[];
    for (var index = 0; index < count; index++) {
      final offset = u32At(bytes, 78 + index * 8);
      if (offset < tableLength || offset > bytes.length) {
        throw const FormatException('invalid PDB record offset');
      }
      if (offsets.isNotEmpty && offsets.last > offset) {
        throw const FormatException('PDB record offsets are not ordered');
      }
      offsets.add(offset);
    }
    if (offsets.isEmpty) {
      throw const FormatException('PDB contains no records');
    }
    return Pdb._(bytes, offsets);
  }

  int get length => offsets.length;

  Uint8List record(int index) {
    if (index < 0 || index >= offsets.length) {
      throw FormatException('PDB record $index is out of bounds');
    }
    final start = offsets[index];
    final end = index + 1 < offsets.length ? offsets[index + 1] : bytes.length;
    if (end < start || end > bytes.length) {
      throw FormatException('PDB record $index is truncated');
    }
    return Uint8List.sublistView(bytes, start, end);
  }
}
