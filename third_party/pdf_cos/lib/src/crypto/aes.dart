import 'dart:typed_data';

/// AES block cipher (FIPS 197) with the CBC modes PDF encryption needs
/// (§7.6.2, §7.6.4.3): content decryption (16-byte IV prefix, PKCS#7
/// padding) and the unpadded CBC encryption inside the AES-256 password
/// hash (Algorithm 2.B). Pure Dart so it runs on the VM and the web.
class Aes {
  /// Key must be 16, 24, or 32 bytes.
  Aes(List<int> key)
      : assert(key.length == 16 || key.length == 24 || key.length == 32),
        _rounds = key.length ~/ 4 + 6,
        _roundKeys = _expandKey(key);

  final int _rounds;
  final Uint32List _roundKeys;

  // --- CBC convenience entry points ---

  /// Decrypts a PDF content payload: leading 16-byte IV, then ciphertext.
  /// PKCS#7 padding is stripped leniently (real files get it wrong);
  /// payloads too short or misaligned yield empty/truncated output rather
  /// than throwing.
  static Uint8List decryptContent(List<int> key, Uint8List data) {
    if (data.length < 32) return Uint8List(0);
    final blocks = (data.length - 16) & ~15;
    final plain = Aes(key)
        .cbcDecrypt(Uint8List.sublistView(data, 0, 16),
            Uint8List.sublistView(data, 16, 16 + blocks));
    final pad = plain.isEmpty ? 0 : plain.last;
    return pad >= 1 && pad <= 16
        ? Uint8List.sublistView(plain, 0, plain.length - pad)
        : plain;
  }

  /// Encrypts a PDF content payload: PKCS#7-pads [data], prepends the
  /// 16-byte [iv], CBC-encrypts. The inverse of [decryptContent].
  static Uint8List encryptContent(List<int> key, Uint8List data, List<int> iv) {
    final padLength = 16 - (data.length % 16);
    final padded = Uint8List(data.length + padLength)
      ..setRange(0, data.length, data)
      ..fillRange(data.length, data.length + padLength, padLength);
    return (BytesBuilder(copy: false)
          ..add(Uint8List.fromList(iv))
          ..add(Aes(key).cbcEncrypt(iv, padded)))
        .takeBytes();
  }

  /// Encrypts with CBC and no padding; [data] must be block-aligned.
  /// Used by Algorithm 2.B and by test fixtures (with PKCS#7 applied by
  /// the caller).
  Uint8List cbcEncrypt(List<int> iv, Uint8List data) {
    assert(data.length % 16 == 0);
    final out = Uint8List(data.length);
    var prev = Uint8List.fromList(iv);
    final block = Uint8List(16);
    for (var offset = 0; offset < data.length; offset += 16) {
      for (var i = 0; i < 16; i++) {
        block[i] = data[offset + i] ^ prev[i];
      }
      _encryptBlock(block);
      out.setRange(offset, offset + 16, block);
      prev = Uint8List.sublistView(out, offset, offset + 16);
    }
    return out;
  }

  /// Decrypts with CBC and no padding; [data] must be block-aligned.
  Uint8List cbcDecrypt(List<int> iv, Uint8List data) {
    assert(data.length % 16 == 0);
    final out = Uint8List(data.length);
    final block = Uint8List(16);
    var prev = iv;
    for (var offset = 0; offset < data.length; offset += 16) {
      block.setRange(0, 16, data, offset);
      final cipher = Uint8List.fromList(block);
      _decryptBlock(block);
      for (var i = 0; i < 16; i++) {
        out[offset + i] = block[i] ^ prev[i];
      }
      prev = cipher;
    }
    return out;
  }

  // --- block primitives ---

  void _encryptBlock(Uint8List b) {
    _addRoundKey(b, 0);
    for (var round = 1; round < _rounds; round++) {
      for (var i = 0; i < 16; i++) {
        b[i] = _sbox[b[i]];
      }
      _shiftRows(b);
      _mixColumns(b);
      _addRoundKey(b, round);
    }
    for (var i = 0; i < 16; i++) {
      b[i] = _sbox[b[i]];
    }
    _shiftRows(b);
    _addRoundKey(b, _rounds);
  }

  void _decryptBlock(Uint8List b) {
    _addRoundKey(b, _rounds);
    _invShiftRows(b);
    for (var i = 0; i < 16; i++) {
      b[i] = _invSbox[b[i]];
    }
    for (var round = _rounds - 1; round >= 1; round--) {
      _addRoundKey(b, round);
      _invMixColumns(b);
      _invShiftRows(b);
      for (var i = 0; i < 16; i++) {
        b[i] = _invSbox[b[i]];
      }
    }
    _addRoundKey(b, 0);
  }

  void _addRoundKey(Uint8List b, int round) {
    for (var c = 0; c < 4; c++) {
      final w = _roundKeys[round * 4 + c];
      b[c * 4] ^= w >>> 24;
      b[c * 4 + 1] ^= (w >>> 16) & 0xFF;
      b[c * 4 + 2] ^= (w >>> 8) & 0xFF;
      b[c * 4 + 3] ^= w & 0xFF;
    }
  }

  static void _shiftRows(Uint8List b) {
    for (var r = 1; r < 4; r++) {
      for (var shift = 0; shift < r; shift++) {
        final t = b[r];
        b[r] = b[r + 4];
        b[r + 4] = b[r + 8];
        b[r + 8] = b[r + 12];
        b[r + 12] = t;
      }
    }
  }

  static void _invShiftRows(Uint8List b) {
    for (var r = 1; r < 4; r++) {
      for (var shift = 0; shift < r; shift++) {
        final t = b[r + 12];
        b[r + 12] = b[r + 8];
        b[r + 8] = b[r + 4];
        b[r + 4] = b[r];
        b[r] = t;
      }
    }
  }

  static void _mixColumns(Uint8List b) {
    for (var c = 0; c < 4; c++) {
      final i = c * 4;
      final a0 = b[i], a1 = b[i + 1], a2 = b[i + 2], a3 = b[i + 3];
      b[i] = _mul2[a0] ^ _mul3[a1] ^ a2 ^ a3;
      b[i + 1] = a0 ^ _mul2[a1] ^ _mul3[a2] ^ a3;
      b[i + 2] = a0 ^ a1 ^ _mul2[a2] ^ _mul3[a3];
      b[i + 3] = _mul3[a0] ^ a1 ^ a2 ^ _mul2[a3];
    }
  }

  static void _invMixColumns(Uint8List b) {
    for (var c = 0; c < 4; c++) {
      final i = c * 4;
      final a0 = b[i], a1 = b[i + 1], a2 = b[i + 2], a3 = b[i + 3];
      b[i] = _mul14[a0] ^ _mul11[a1] ^ _mul13[a2] ^ _mul9[a3];
      b[i + 1] = _mul9[a0] ^ _mul14[a1] ^ _mul11[a2] ^ _mul13[a3];
      b[i + 2] = _mul13[a0] ^ _mul9[a1] ^ _mul14[a2] ^ _mul11[a3];
      b[i + 3] = _mul11[a0] ^ _mul13[a1] ^ _mul9[a2] ^ _mul14[a3];
    }
  }

  static Uint32List _expandKey(List<int> key) {
    final nk = key.length ~/ 4;
    final rounds = nk + 6;
    final w = Uint32List(4 * (rounds + 1));
    for (var i = 0; i < nk; i++) {
      w[i] = (key[4 * i] << 24) |
          (key[4 * i + 1] << 16) |
          (key[4 * i + 2] << 8) |
          key[4 * i + 3];
    }
    var rcon = 1;
    for (var i = nk; i < w.length; i++) {
      var t = w[i - 1];
      if (i % nk == 0) {
        t = _subWord((t << 8) | (t >>> 24)) ^ (rcon << 24);
        rcon = _xtime(rcon);
      } else if (nk > 6 && i % nk == 4) {
        t = _subWord(t);
      }
      w[i] = w[i - nk] ^ t;
    }
    return w;
  }

  static int _subWord(int w) =>
      (_sbox[(w >>> 24) & 0xFF] << 24) |
      (_sbox[(w >>> 16) & 0xFF] << 16) |
      (_sbox[(w >>> 8) & 0xFF] << 8) |
      _sbox[w & 0xFF];

  // --- GF(2^8) tables, computed once at first use ---

  static int _xtime(int x) => ((x << 1) ^ ((x & 0x80) != 0 ? 0x1B : 0)) & 0xFF;

  static int _gfMul(int a, int b) {
    var result = 0;
    while (b != 0) {
      if (b & 1 != 0) result ^= a;
      a = _xtime(a);
      b >>= 1;
    }
    return result;
  }

  static final Uint8List _sbox = _buildSbox();
  static final Uint8List _invSbox = () {
    final inv = Uint8List(256);
    for (var i = 0; i < 256; i++) {
      inv[_sbox[i]] = i;
    }
    return inv;
  }();

  static Uint8List _buildSbox() {
    // multiplicative inverses via the 3/0xF6 generator trick, then the
    // affine transform from FIPS 197 §5.1.1
    final box = Uint8List(256);
    var p = 1, q = 1;
    do {
      p = _gfMul(p, 3);
      q = _gfMul(q, 0xF6); // 3⁻¹
      var x = q;
      x ^= (q << 1) | (q >> 7);
      x ^= (q << 2) | (q >> 6);
      x ^= (q << 3) | (q >> 5);
      x ^= (q << 4) | (q >> 4);
      box[p] = (x ^ 0x63) & 0xFF;
    } while (p != 1);
    box[0] = 0x63;
    return box;
  }

  static Uint8List _mulTable(int factor) {
    final table = Uint8List(256);
    for (var i = 0; i < 256; i++) {
      table[i] = _gfMul(i, factor);
    }
    return table;
  }

  static final Uint8List _mul2 = _mulTable(2);
  static final Uint8List _mul3 = _mulTable(3);
  static final Uint8List _mul9 = _mulTable(9);
  static final Uint8List _mul11 = _mulTable(11);
  static final Uint8List _mul13 = _mulTable(13);
  static final Uint8List _mul14 = _mulTable(14);
}
