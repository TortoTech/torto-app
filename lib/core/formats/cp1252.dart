/// Windows-1252 → Unicode decoding for legacy e-book encodings
/// (MOBI text records, CHM pages).
library;

const String _cp1252High =
    '\u20AC\u0081\u201A\u0192\u201E\u2026\u2020\u2021'
    '\u02C6\u2030\u0160\u2039\u0152\u008D\u017D\u008F\u0090\u2018\u2019\u201C'
    '\u201D\u2022\u2013\u2014\u02DC\u2122\u0161\u203A\u0153\u009D\u017E\u0178';

String decodeCp1252(List<int> bytes) {
  final codes = List<int>.generate(bytes.length, (index) {
    final byte = bytes[index] & 0xff;
    return byte < 0x80 || byte >= 0xA0
        ? byte
        : _cp1252High.codeUnitAt(byte - 0x80);
  });
  return String.fromCharCodes(codes);
}
