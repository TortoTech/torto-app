/// PDF object model, lexer, and parser.
///
/// The low-level half of the pure-Dart PDF support (torto delegates this to
/// hayro): tokens, indirect objects, and stream bodies. Xref resolution
/// lives in `pdf_document.dart`; stream filters in `pdf_decode.dart`.
library;

import 'dart:typed_data';

class PdfRef extends PdfObject {
  final int id;
  final int generation;

  const PdfRef(this.id, this.generation);

  @override
  bool operator ==(Object other) =>
      other is PdfRef && other.id == id && other.generation == generation;

  @override
  int get hashCode => Object.hash(id, generation);

  @override
  String toString() => '$id $generation R';
}

sealed class PdfObject {
  const PdfObject();
}

class PdfBool extends PdfObject {
  final bool value;

  const PdfBool(this.value);
}

class PdfNum extends PdfObject {
  final double value;

  const PdfNum(this.value);

  int get asInt => value.toInt();

  bool get isInteger => value == value.truncateToDouble();
}

class PdfString extends PdfObject {
  final Uint8List bytes;

  const PdfString(this.bytes);
}

class PdfName extends PdfObject {
  final String name;

  const PdfName(this.name);
}

class PdfArray extends PdfObject {
  final List<PdfObject> items;

  const PdfArray(this.items);
}

class PdfDict extends PdfObject {
  final Map<String, PdfObject> entries;

  const PdfDict(this.entries);

  PdfObject? operator [](String name) => entries[name];
}

class PdfNull extends PdfObject {
  const PdfNull();
}

class PdfStream extends PdfObject {
  final PdfDict dict;

  /// Raw (still encoded) stream bytes.
  final Uint8List data;

  const PdfStream(this.dict, this.data);
}

/// A lazily parsed indirect object body.
class PdfIndirect {
  final int id;
  final PdfObject object;

  const PdfIndirect(this.id, this.object);
}

const Set<int> _whitespace = {0x00, 0x09, 0x0A, 0x0C, 0x0D, 0x20};
const Set<int> _delimiters = {
  0x28,
  0x29,
  0x3C,
  0x3E,
  0x5B,
  0x5D,
  0x7B,
  0x7D,
  0x2F,
  0x25,
};

bool _isRegular(int byte) =>
    !_whitespace.contains(byte) && !_delimiters.contains(byte);

/// Byte-level PDF tokenizer/object parser over a buffer.
class PdfParser {
  final Uint8List data;
  int position;

  PdfParser(this.data, [this.position = 0]);

  bool get isAtEnd => position >= data.length;

  void skipWhitespaceAndComments() {
    while (position < data.length) {
      final byte = data[position];
      if (_whitespace.contains(byte)) {
        position++;
      } else if (byte == 0x25 /* % */ ) {
        while (position < data.length &&
            data[position] != 0x0A &&
            data[position] != 0x0D) {
          position++;
        }
      } else {
        return;
      }
    }
  }

  /// Parses one object at the current position (after whitespace).
  PdfObject? parseObject({bool allowStreams = false}) {
    skipWhitespaceAndComments();
    if (position >= data.length) return null;
    final byte = data[position];
    switch (byte) {
      case 0x2F /* / */ :
        return _parseName();
      case 0x28 /* ( */ :
        return PdfString(_parseLiteralString());
      case 0x3C /* < */ :
        if (position + 1 < data.length && data[position + 1] == 0x3C) {
          return _parseDictionary(allowStreams: allowStreams);
        }
        return PdfString(_parseHexString());
      case 0x5B /* [ */ :
        position++;
        final items = <PdfObject>[];
        while (true) {
          skipWhitespaceAndComments();
          if (position >= data.length) break;
          if (data[position] == 0x5D /* ] */ ) {
            position++;
            break;
          }
          final item = parseObject();
          if (item == null) break;
          items.add(item);
        }
        return PdfArray(items);
      case 0x74 /* t */ :
        if (_matchKeyword('true')) return const PdfBool(true);
        return null;
      case 0x66 /* f */ :
        if (_matchKeyword('false')) return const PdfBool(false);
        return null;
      case 0x6E /* n */ :
        if (_matchKeyword('null')) return const PdfNull();
        return null;
      default:
        if ((byte >= 0x30 && byte <= 0x39) ||
            byte == 0x2B ||
            byte == 0x2D ||
            byte == 0x2E) {
          return _parseNumberOrRef();
        }
        position++;
        return null;
    }
  }

  bool _matchKeyword(String keyword) {
    final codes = keyword.codeUnits;
    if (position + codes.length > data.length) return false;
    for (var i = 0; i < codes.length; i++) {
      if (data[position + i] != codes[i]) return false;
    }
    // Must not be a prefix of a longer token.
    final after = position + codes.length;
    if (after < data.length && _isRegular(data[after])) return false;
    position = after;
    return true;
  }

  PdfName _parseName() {
    position++; // '/'
    final start = position;
    while (position < data.length && _isRegular(data[position])) {
      position++;
    }
    final raw = String.fromCharCodes(data.sublist(start, position));
    // '#' xx hex escapes.
    final buffer = StringBuffer();
    for (var i = 0; i < raw.length; i++) {
      if (raw.codeUnitAt(i) == 0x23 /* # */ && i + 2 < raw.length + 1) {
        final hex = int.tryParse(raw.substring(i + 1, i + 3), radix: 16);
        if (hex != null) {
          buffer.writeCharCode(hex);
          i += 2;
          continue;
        }
      }
      buffer.write(raw[i]);
    }
    return PdfName(buffer.toString());
  }

  Uint8List _parseLiteralString() {
    final output = BytesBuilder(copy: false);
    var depth = 1;
    position++; // '('
    while (position < data.length && depth > 0) {
      final byte = data[position];
      if (byte == 0x5C /* \ */ ) {
        position++;
        if (position >= data.length) break;
        final escape = data[position];
        switch (escape) {
          case 0x6E:
            output.addByte(0x0A);
            position++;
          case 0x72:
            output.addByte(0x0D);
            position++;
          case 0x74:
            output.addByte(0x09);
            position++;
          case 0x62:
            output.addByte(0x08);
            position++;
          case 0x66:
            output.addByte(0x0C);
            position++;
          case 0x0A:
            position++; // line continuation
          case 0x0D:
            position++;
            if (position < data.length && data[position] == 0x0A) position++;
          default:
            if (escape >= 0x30 && escape <= 0x37) {
              var value = 0;
              var digits = 0;
              while (digits < 3 &&
                  position < data.length &&
                  data[position] >= 0x30 &&
                  data[position] <= 0x37) {
                value = (value << 3) | (data[position] - 0x30);
                position++;
                digits++;
              }
              output.addByte(value & 0xff);
            } else {
              output.addByte(escape);
              position++;
            }
        }
        continue;
      }
      if (byte == 0x28 /* ( */ ) depth++;
      if (byte == 0x29 /* ) */ ) {
        depth--;
        if (depth == 0) {
          position++;
          break;
        }
      }
      output.addByte(byte);
      position++;
    }
    return output.takeBytes();
  }

  Uint8List _parseHexString() {
    position++; // '<'
    final output = BytesBuilder(copy: false);
    int? pending;
    while (position < data.length) {
      final byte = data[position];
      if (byte == 0x3E /* > */ ) {
        position++;
        break;
      }
      position++;
      if ((byte >= 0x30 && byte <= 0x39) ||
          (byte >= 0x41 && byte <= 0x46) ||
          (byte >= 0x61 && byte <= 0x66)) {
        final value = _hexValue(byte);
        if (pending == null) {
          pending = value;
        } else {
          output.addByte((pending << 4) | value);
          pending = null;
        }
      }
    }
    if (pending != null) output.addByte(pending << 4);
    return output.takeBytes();
  }

  static int _hexValue(int code) =>
      code >= 0x61 ? code - 0x57 : (code >= 0x41 ? code - 0x37 : code - 0x30);

  PdfObject _parseDictionary({required bool allowStreams}) {
    position += 2; // '<<'
    final entries = <String, PdfObject>{};
    while (true) {
      skipWhitespaceAndComments();
      if (position >= data.length) break;
      if (data[position] == 0x3E /* > */ &&
          position + 1 < data.length &&
          data[position + 1] == 0x3E) {
        position += 2;
        break;
      }
      if (data[position] != 0x2F /* / */ ) {
        position++;
        continue;
      }
      final key = _parseName();
      final value = parseObject(allowStreams: false);
      if (value == null) break;
      entries[key.name] = value;
    }
    final dict = PdfDict(entries);

    if (allowStreams && _peekKeyword('stream')) {
      position += 'stream'.length;
      // EOL after 'stream' (CR, LF, or CRLF).
      if (position < data.length && data[position] == 0x0D) position++;
      if (position < data.length && data[position] == 0x0A) position++;
      final bytes = _readStreamBody(dict);
      return PdfStream(dict, bytes);
    }
    return dict;
  }

  bool _peekKeyword(String keyword) {
    skipWhitespaceAndComments();
    final codes = keyword.codeUnits;
    if (position + codes.length > data.length) return false;
    for (var i = 0; i < codes.length; i++) {
      if (data[position + i] != codes[i]) return false;
    }
    final after = position + codes.length;
    if (after < data.length && _isRegular(data[after])) return false;
    return true;
  }

  /// True when [keyword] is at the current position (after whitespace).
  bool peekKeyword(String keyword) => _peekKeyword(keyword);

  /// Reads an optionally signed decimal integer (whitespace-skipping);
  /// null when absent.
  int? readInt() {
    skipWhitespaceAndComments();
    return _readInt();
  }

  /// Skips forward past one indirect object (to the next `endobj`/`obj`).
  void skipPastObject() {
    var guard = position + 1 << 20;
    while (position < data.length && guard-- > 0) {
      if (_matchesAt(position, 'endobj')) {
        position += 'endobj'.length;
        return;
      }
      if (_matchesAt(position, 'endstream')) {
        position += 'endstream'.length;
        continue;
      }
      position++;
    }
  }

  /// Reads stream bytes up to `endstream`, preferring the declared /Length.
  Uint8List _readStreamBody(PdfDict dict) {
    final length = dict['Length'];
    var declared = -1;
    if (length is PdfNum && length.isInteger) declared = length.asInt;
    if (declared >= 0 && position + declared <= data.length) {
      // Sanity: `endstream` must appear shortly after the declared length.
      final probe = position + declared;
      if (_endstreamNear(probe)) {
        final bytes = Uint8List.sublistView(data, position, probe);
        position = probe;
        _skipEndstream();
        return bytes;
      }
    }
    // Fallback: scan for the endstream keyword.
    final index = _indexOfEndstream(position);
    if (index < 0) {
      final end = data.length;
      final bytes = Uint8List.sublistView(data, position, end);
      position = end;
      return bytes;
    }
    // Strip the EOL that precedes endstream.
    var end = index;
    while (end > position && (data[end - 1] == 0x0A || data[end - 1] == 0x0D)) {
      end--;
    }
    final bytes = Uint8List.sublistView(data, position, end);
    position = index;
    _skipEndstream();
    return bytes;
  }

  bool _endstreamNear(int offset) {
    var probe = offset;
    while (probe < data.length &&
        (data[probe] == 0x0A || data[probe] == 0x0D)) {
      probe++;
    }
    return _matchesAt(probe, 'endstream');
  }

  bool _matchesAt(int offset, String keyword) {
    final codes = keyword.codeUnits;
    if (offset + codes.length > data.length) return false;
    for (var i = 0; i < codes.length; i++) {
      if (data[offset + i] != codes[i]) return false;
    }
    return true;
  }

  int _indexOfEndstream(int from) {
    for (var i = from; i + 9 <= data.length; i++) {
      if (data[i] == 0x65 /* e */ && _matchesAt(i, 'endstream')) return i;
    }
    return -1;
  }

  void _skipEndstream() {
    skipWhitespaceAndComments();
    if (_matchesAt(position, 'endstream')) position += 'endstream'.length;
    skipWhitespaceAndComments();
    if (_matchesAt(position, 'endobj')) position += 'endobj'.length;
  }

  PdfObject _parseNumberOrRef() {
    final start = position;
    while (position < data.length &&
        ((data[position] >= 0x30 && data[position] <= 0x39) ||
            data[position] == 0x2B ||
            data[position] == 0x2D ||
            data[position] == 0x2E)) {
      position++;
    }
    final text = String.fromCharCodes(data.sublist(start, position));
    final number = double.tryParse(text);
    if (number == null) return const PdfNull();
    // "num gen R" reference?
    final save = position;
    skipWhitespaceAndComments();
    final generation = _readInt();
    if (generation != null) {
      skipWhitespaceAndComments();
      if (position < data.length &&
          data[position] == 0x52 /* R */ &&
          (position + 1 >= data.length || !_isRegular(data[position + 1]))) {
        position++;
        return PdfRef(number.toInt(), generation);
      }
    }
    position = save;
    return PdfNum(number);
  }

  int? _readInt() {
    final start = position;
    while (position < data.length &&
        ((data[position] >= 0x30 && data[position] <= 0x39) ||
            data[position] == 0x2B ||
            data[position] == 0x2D)) {
      position++;
    }
    if (position == start) return null;
    return int.tryParse(String.fromCharCodes(data.sublist(start, position)));
  }
}
