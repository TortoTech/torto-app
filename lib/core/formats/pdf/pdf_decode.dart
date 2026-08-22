/// PDF stream filters and text-string decoding.
///
/// `pdf_decode.dart` handles FlateDecode (with PNG/TIFF predictors) and the
/// PDF text-string encodings (UTF-16 BOM, UTF-8 BOM, legacy Chinese, and
/// PDFDocEncoding) — the latter a direct port of torto's
/// `crates/formats/src/pdf/catalog.rs` decoding rules.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../cp1252.dart';
import 'pdf_syntax.dart';

/// Decodes [stream] through its /Filter chain. Throws [FormatException] on
/// unsupported filters or corrupt data.
Uint8List decodeStream(PdfStream stream, PdfObject? Function(PdfRef) resolve) {
  var bytes = stream.data;
  final filter = resolveDeep(stream.dict['Filter'], resolve);
  final params = resolveDeep(stream.dict['DecodeParms'], resolve);
  final filters = filter is PdfArray ? filter.items : [?filter];
  final paramList = params is PdfArray ? params.items : [?params];
  for (var i = 0; i < filters.length; i++) {
    final name = filters[i];
    if (name is! PdfName) continue;
    final parms = i < paramList.length ? paramList[i] : null;
    switch (name.name) {
      case 'FlateDecode':
      case 'Fl':
        bytes = _inflate(bytes);
        bytes = _applyPredictor(bytes, parms, resolve);
      case 'ASCIIHexDecode':
      case 'AHx':
        bytes = _asciiHex(bytes);
      case 'ASCII85Decode':
      case 'A85':
        bytes = _ascii85(bytes);
      case 'DCTDecode':
      case 'DCT':
        return bytes; // JPEG payload: caller handles raw.
      case 'LZWDecode':
      case 'LZW':
        throw const FormatException('PDF LZWDecode is not supported');
      case 'Crypt':
      case 'JPXDecode':
        throw const FormatException(
          'PDF encrypted/JPX streams are not supported',
        );
      default:
        throw FormatException('unsupported PDF filter /${name.name}');
    }
  }
  return bytes;
}

Uint8List _inflate(Uint8List bytes) {
  try {
    return ZLibDecoder().decodeBytes(bytes);
  } catch (error) {
    throw FormatException('PDF FlateDecode failed: $error');
  }
}

Uint8List _asciiHex(Uint8List bytes) {
  final output = BytesBuilder(copy: false);
  int? pending;
  for (final byte in bytes) {
    if (byte == 0x3E /* > */ ) break;
    final value = _hexDigit(byte);
    if (value == null) continue;
    if (pending == null) {
      pending = value;
    } else {
      output.addByte((pending << 4) | value);
      pending = null;
    }
  }
  if (pending != null) output.addByte(pending << 4);
  return output.takeBytes();
}

int? _hexDigit(int byte) {
  if (byte >= 0x30 && byte <= 0x39) return byte - 0x30;
  if (byte >= 0x41 && byte <= 0x46) return byte - 0x37;
  if (byte >= 0x61 && byte <= 0x66) return byte - 0x57;
  return null;
}

Uint8List _ascii85(Uint8List bytes) {
  final output = BytesBuilder(copy: false);
  var group = <int>[];
  var i = 0;
  while (i < bytes.length) {
    final byte = bytes[i++];
    if (byte == 0x7E /* ~ */ ) break;
    if (byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D) {
      continue;
    }
    if (byte == 0x7A /* z */ && group.isEmpty) {
      output.add([0, 0, 0, 0]);
      continue;
    }
    if (byte < 0x21 || byte > 0x75) throw const FormatException('bad ASCII85');
    group.add(byte - 0x21);
    if (group.length == 5) {
      output.add(_ascii85Group(group));
      group = [];
    }
  }
  if (group.isNotEmpty) {
    if (group.length < 2) throw const FormatException('bad ASCII85 tail');
    final padded = [...group, ...List.filled(5 - group.length, 84)];
    final full = _ascii85Group(padded);
    output.add(full.sublist(0, group.length - 1));
  }
  return output.takeBytes();
}

List<int> _ascii85Group(List<int> group) {
  var value = 0;
  for (final digit in group) {
    value = value * 85 + digit;
  }
  return [value >> 24, (value >> 16) & 0xff, (value >> 8) & 0xff, value & 0xff];
}

Uint8List _applyPredictor(
  Uint8List bytes,
  PdfObject? parms,
  PdfObject? Function(PdfRef) resolve,
) {
  final dict = resolveDeep(parms, resolve);
  if (dict is! PdfDict) return bytes;
  final predictor = _numOf(dict['Predictor'], resolve)?.asInt ?? 1;
  if (predictor < 2) return bytes;
  final colors = _numOf(dict['Colors'], resolve)?.asInt ?? 1;
  final bits = _numOf(dict['BitsPerComponent'], resolve)?.asInt ?? 8;
  final columns = _numOf(dict['Columns'], resolve)?.asInt ?? 1;
  final bytesPerPixel = (colors * bits + 7) ~/ 8;
  final rowLength = (colors * bits * columns + 7) ~/ 8;

  if (predictor == 2) {
    // TIFF horizontal differencing.
    if (bits != 8) return bytes; // 1/4-bit TIFF predictors are rare; skip.
    final output = Uint8List.fromList(bytes);
    for (var row = 0; row + rowLength <= output.length; row += rowLength) {
      for (var i = bytesPerPixel; i < rowLength; i++) {
        output[row + i] =
            (output[row + i] + output[row + i - bytesPerPixel]) & 0xff;
      }
    }
    return output;
  }

  // PNG predictors (10–15): each row starts with a filter byte.
  final output = BytesBuilder(copy: false);
  Uint8List? previous;
  var position = 0;
  while (position + rowLength + 1 <= bytes.length) {
    final filter = bytes[position];
    position++;
    final row = Uint8List.fromList(
      bytes.sublist(position, position + rowLength),
    );
    position += rowLength;
    switch (filter) {
      case 0: // None
        break;
      case 1: // Sub
        for (var i = bytesPerPixel; i < row.length; i++) {
          row[i] = (row[i] + row[i - bytesPerPixel]) & 0xff;
        }
      case 2: // Up
        if (previous != null) {
          for (var i = 0; i < row.length; i++) {
            row[i] = (row[i] + previous[i]) & 0xff;
          }
        }
      case 3: // Average
        for (var i = 0; i < row.length; i++) {
          final left = i >= bytesPerPixel ? row[i - bytesPerPixel] : 0;
          final up = previous != null ? previous[i] : 0;
          row[i] = (row[i] + ((left + up) >> 1)) & 0xff;
        }
      case 4: // Paeth
        for (var i = 0; i < row.length; i++) {
          final left = i >= bytesPerPixel ? row[i - bytesPerPixel] : 0;
          final up = previous != null ? previous[i] : 0;
          final upLeft = previous != null && i >= bytesPerPixel
              ? previous[i - bytesPerPixel]
              : 0;
          row[i] = (row[i] + _paeth(left, up, upLeft)) & 0xff;
        }
      default:
        throw FormatException('unknown PNG predictor $filter');
    }
    output.add(row);
    previous = row;
  }
  return output.takeBytes();
}

int _paeth(int a, int b, int c) {
  final p = a + b - c;
  final pa = (p - a).abs();
  final pb = (p - b).abs();
  final pc = (p - c).abs();
  if (pa <= pb && pa <= pc) return a;
  if (pb <= pc) return b;
  return c;
}

PdfObject? resolveDeep(
  PdfObject? object,
  PdfObject? Function(PdfRef) resolve, [
  int depth = 0,
]) {
  var current = object;
  var guard = 0;
  while (current is PdfRef && guard++ < 32) {
    current = resolve(current);
  }
  return current;
}

PdfNum? _numOf(PdfObject? object, PdfObject? Function(PdfRef) resolve) {
  final resolved = resolveDeep(object, resolve);
  return resolved is PdfNum ? resolved : null;
}

// ------------------------------------------------------- text string decoding

/// PDF text string → Dart string (torto `decode_pdf_text` port).
String? decodePdfText(Uint8List bytes, {bool tryLegacyChinese = true}) {
  String decoded;
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    decoded = _decodeUtf16(bytes.sublist(2), bigEndian: true);
  } else if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    decoded = _decodeUtf16(bytes.sublist(2), bigEndian: false);
  } else if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    decoded = utf8.decode(bytes.sublist(3), allowMalformed: true);
  } else if (tryLegacyChinese && _looksLegacyChinese(bytes)) {
    decoded = decodeCp1252(bytes); // GBK table unavailable; best-effort
  } else {
    decoded = _decodePdfDocEncoding(bytes);
  }
  final cleaned = _stripLanguageTags(decoded).trim();
  return cleaned.isEmpty ? null : cleaned;
}

String _decodeUtf16(List<int> bytes, {required bool bigEndian}) {
  final units = <int>[];
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    units.add(
      bigEndian
          ? (bytes[i] << 8) | bytes[i + 1]
          : bytes[i] | (bytes[i + 1] << 8),
    );
  }
  return String.fromCharCodes(units);
}

/// torto tries GBK when ≥4 high bytes dominate; without a GBK table we
/// cannot decode those correctly, so we decline and fall back to
/// PDFDocEncoding only when the string is mostly ASCII.
bool _looksLegacyChinese(Uint8List bytes) {
  var highBytes = 0;
  for (final byte in bytes) {
    if (byte >= 0x80) highBytes++;
  }
  return highBytes >= 4 && highBytes * 4 >= bytes.length;
}

String _decodePdfDocEncoding(Uint8List bytes) {
  // PDFDocEncoding = ASCII below 0x80 with the standard 0x18–0x1F and
  // 0x80–0xA3 high block (torto's decode_pdf_doc_encoding table).
  final pdfDocHigh = <int, String>{
    0x18: '\u02D8',
    0x19: '\u02C7',
    0x1A: '\u02C6',
    0x1B: '\u02D9',
    0x1C: '\u02DD',
    0x1D: '\u02DB',
    0x1E: '\u02DA',
    0x1F: '\u02DC',
    0x80: '\u2022',
    0x81: '\u2020',
    0x82: '\u2021',
    0x83: '\u2026',
    0x84: '\u2014',
    0x85: '\u2013',
    0x86: '\u0192',
    0x87: '\u2044',
    0x88: '\u2039',
    0x89: '\u203A',
    0x8A: '\u2212',
    0x8B: '\u2030',
    0x8C: '\u201E',
    0x8D: '\u201C',
    0x8E: '\u201D',
    0x8F: '\u2018',
    0x90: '\u2019',
    0x91: '\u201A',
    0x92: '\u2122',
    0x93: '\uFB01',
    0x94: '\uFB02',
    0x95: '\u0141',
    0x96: '\u0152',
    0x97: '\u0160',
    0x98: '\u0178',
    0x99: '\u017D',
    0x9A: '\u0131',
    0x9B: '\u0142',
    0x9C: '\u0153',
    0x9D: '\u0161',
    0x9E: '\u017E',
    0xA0: '\u20AC',
  };
  final buffer = StringBuffer();
  for (final byte in bytes) {
    buffer.write(pdfDocHigh[byte] ?? String.fromCharCode(byte));
  }
  return buffer.toString();
}

String _stripLanguageTags(String value) {
  final buffer = StringBuffer();
  var inTag = false;
  for (final character in value.runes) {
    if (character == 0x1B) {
      inTag = !inTag;
    } else if (!inTag) {
      buffer.writeCharCode(character);
    }
  }
  return buffer.toString();
}
