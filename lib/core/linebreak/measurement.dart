// Shared shaping boundaries for reader prose and footnote text.
bool requiresStandaloneMeasurement(String grapheme) {
  for (final rune in grapheme.runes) {
    if (String.fromCharCode(rune).trim().isEmpty ||
        isMeasurementCjk(rune) ||
        const {
          0x2d,
          0x2010,
          0x2013,
          0x2014,
          0x200b,
          0x2060,
          0x00b7,
          0x30fb,
          0x300a,
          0x3008,
          0xff08,
          0x300e,
          0x300c,
          0x3010,
          0x3016,
          0x3014,
          0xff3b,
          0xff5b,
          0xff0c,
          0xff0e,
          0x3002,
          0x3001,
          0xff1a,
          0xff1b,
          0x300b,
          0x3009,
          0xff09,
          0x300f,
          0x300d,
          0x3011,
          0x3017,
          0x3015,
          0xff3d,
          0xff5d,
          0xff1f,
          0xff01,
          0x201c,
          0x2018,
          0x201d,
          0x2019,
        }.contains(rune)) {
      return true;
    }
  }
  return false;
}

bool isMeasurementCjk(int rune) =>
    rune == 0x30fc ||
    (rune >= 0x3040 && rune <= 0x30ff) ||
    (rune >= 0x3400 && rune <= 0x4dbf) ||
    (rune >= 0x4e00 && rune <= 0x9fff) ||
    (rune >= 0x20000 && rune <= 0x323af) ||
    (rune >= 0xac00 && rune <= 0xd7af) ||
    (rune >= 0xf900 && rune <= 0xfaff);
