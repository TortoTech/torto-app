/// LZX decompressor (pure Dart port of the CHMLib/cabextract decoder).
///
/// Handles the LZX variant used by CHM's `MSCompressed` storage: verbatim,
/// aligned, and uncompressed blocks, repeated-offset matches, tree deltas,
/// window resets, and the Intel E8 transform.
library;

import 'dart:typed_data';

const int _blockTypeVerbatim = 1;
const int _blockTypeAligned = 2;
const int _blockTypeUncompressed = 3;

const int _numChars = 256;
const int _numPrimaryLengths = 7;
const int _numSecondaryLengths = 249;

const int _mainTreeMaxSymbols = _numChars + 50 * 8; // 656
const int _lengthMaxSymbols = _numSecondaryLengths + 1;

const List<int> _extraBits = [
  0,
  0,
  0,
  0,
  1,
  1,
  2,
  2,
  3,
  3,
  4,
  4,
  5,
  5,
  6,
  6,
  7,
  7,
  8,
  8,
  9,
  9,
  10,
  10,
  11,
  11,
  12,
  12,
  13,
  13,
  14,
  14,
  15,
  15,
  16,
  16,
  17,
  17,
  17,
  17,
  17,
  17,
  17,
  17,
  17,
  17,
  17,
  17,
  17,
  17,
  17,
];

const List<int> _positionBase = [
  0,
  1,
  2,
  3,
  4,
  6,
  8,
  12,
  16,
  24,
  32,
  48,
  64,
  96,
  128,
  192,
  256,
  384,
  512,
  768,
  1024,
  1536,
  2048,
  3072,
  4096,
  6144,
  8192,
  12288,
  16384,
  24576,
  32768,
  49152,
  65536,
  98304,
  131072,
  196608,
  262144,
  393216,
  524288,
  655360,
  786432,
  917504,
  1048576,
  1179648,
  1310720,
  1441792,
  1572864,
  1703936,
  1835008,
  1966080,
  2097152,
];

/// Incremental LZX decoder: [decompress] is called once per 32 KiB block,
/// carrying window/Huffman-delta state between calls. [reset] restarts the
/// stream (CHM resets at each reset-interval boundary).
class LzxDecoder {
  final Uint8List window;
  final int windowSize;
  int _windowPosn = 0;
  int _r0 = 1, _r1 = 1, _r2 = 1;
  final int mainElements;
  bool _headerRead = false;
  int _blockType = 0;
  int _blockLength = 0;
  int _blockRemaining = 0;
  int _framesRead = 0;
  int _intelFilesize = 0;
  int _intelCurpos = 0;
  bool _intelStarted = false;

  final Uint16List _pretreeTable = Uint16List((1 << 6) + 20 * 2);
  final Uint8List _pretreeLen = Uint8List(20 + 64);
  final Uint16List _mainTable = Uint16List((1 << 12) + _mainTreeMaxSymbols * 2);
  final Uint8List _mainLen = Uint8List(_mainTreeMaxSymbols + 64);
  final Uint16List _lengthTable = Uint16List((1 << 12) + _lengthMaxSymbols * 2);
  final Uint8List _lengthLen = Uint8List(_lengthMaxSymbols + 64);
  final Uint16List _alignedTable = Uint16List((1 << 7) + 8 * 2);
  final Uint8List _alignedLen = Uint8List(8 + 64);

  LzxDecoder(int windowBits)
    : window = Uint8List(1 << windowBits),
      windowSize = 1 << windowBits,
      mainElements =
          _numChars +
          ((windowBits == 20
                  ? 42
                  : windowBits == 21
                  ? 50
                  : windowBits * 2) <<
              3) {
    if (windowBits < 15 || windowBits > 21) {
      throw FormatException('unsupported LZX window bits $windowBits');
    }
  }

  void reset() {
    _r0 = _r1 = _r2 = 1;
    _headerRead = false;
    _framesRead = 0;
    _blockRemaining = 0;
    _blockType = 0;
    _intelCurpos = 0;
    _intelStarted = false;
    _windowPosn = 0;
    _mainLen.fillRange(0, _mainLen.length, 0);
    _lengthLen.fillRange(0, _lengthLen.length, 0);
  }

  /// Current window write position (diagnostics/tests).
  int get debugWindowPosn => _windowPosn;

  /// Decompresses one block of [outLen] bytes from [input]. Returns the
  /// decompressed block.
  Uint8List decompress(Uint8List input, int outLen) {
    final bits = _BitReader(input);
    final out = Uint8List(outLen);

    if (!_headerRead) {
      var i = 0, j = 0;
      if (bits.read(1) != 0) {
        i = bits.read(16);
        j = bits.read(16);
      }
      _intelFilesize = (i << 16) | j;
      _headerRead = true;
    }

    var togo = outLen;
    while (togo > 0) {
      if (_blockRemaining == 0) {
        _startBlock(bits);
      }

      bits.checkExhausted();
      var thisRun = _blockRemaining;
      if (thisRun > togo) thisRun = togo;
      togo -= thisRun;
      _blockRemaining -= thisRun;

      _windowPosn &= windowSize - 1;
      if (_windowPosn + thisRun > windowSize) {
        throw const FormatException('LZX run crosses the window wraparound');
      }

      switch (_blockType) {
        case _blockTypeVerbatim:
          _decodeHuffmanRun(bits, thisRun, false);
        case _blockTypeAligned:
          _decodeHuffmanRun(bits, thisRun, true);
        case _blockTypeUncompressed:
          bits.copyBytes(window, _windowPosn, thisRun);
          _windowPosn += thisRun;
        default:
          throw const FormatException('invalid LZX block type');
      }
    }

    final start = (_windowPosn == 0 ? windowSize : _windowPosn) - outLen;
    out.setRange(0, outLen, window, start);
    _applyIntelE8(out);
    return out;
  }

  /// Reads one block header: type + 24-bit length, then per-type trees.
  void _startBlock(_BitReader bits) {
    if (_blockType == _blockTypeUncompressed) {
      if (_blockLength & 1 != 0) bits.skipPadByte();
      bits.resetBitstream();
    }
    _blockType = bits.read(3);
    final i = bits.read(16);
    final j = bits.read(8);
    _blockRemaining = _blockLength = (i << 8) | j;
    switch (_blockType) {
      case _blockTypeAligned:
        for (var k = 0; k < 8; k++) {
          _alignedLen[k] = bits.read(3);
        }
        _buildTable(8, 7, _alignedLen, _alignedTable);
        continue verbatim;
      verbatim:
      case _blockTypeVerbatim:
        _readLens(bits, _mainLen, 0, 256);
        _readLens(bits, _mainLen, 256, mainElements);
        _buildTable(_mainTreeMaxSymbols, 12, _mainLen, _mainTable);
        if (_mainLen[0xE8] != 0) _intelStarted = true;
        _readLens(bits, _lengthLen, 0, _numSecondaryLengths);
        _buildTable(_lengthMaxSymbols, 12, _lengthLen, _lengthTable);
      case _blockTypeUncompressed:
        _intelStarted = true;
        bits.alignAfterUncompressedHeader();
        _r0 = bits.readLE32();
        _r1 = bits.readLE32();
        _r2 = bits.readLE32();
      default:
        throw const FormatException('invalid LZX block type');
    }
  }

  /// Verbatim/aligned match decoding for one run.
  void _decodeHuffmanRun(_BitReader bits, int thisRun, bool alignedBlock) {
    while (thisRun > 0) {
      final mainElement = _readHuffSym(
        bits,
        _mainTable,
        _mainLen,
        12,
        _mainTreeMaxSymbols,
      );
      if (mainElement < _numChars) {
        window[_windowPosn++] = mainElement;
        thisRun--;
        continue;
      }
      final element = mainElement - _numChars;
      var matchLength = element & _numPrimaryLengths;
      if (matchLength == _numPrimaryLengths) {
        matchLength += _readHuffSym(
          bits,
          _lengthTable,
          _lengthLen,
          12,
          _lengthMaxSymbols,
        );
      }
      matchLength += 2; // LZX_MIN_MATCH

      var matchOffset = element >> 3;
      if (matchOffset > 2) {
        final extra = _extraBits[matchOffset];
        if (alignedBlock) {
          matchOffset = _positionBase[matchOffset] - 2;
          if (extra > 3) {
            matchOffset += bits.read(extra - 3) << 3;
            matchOffset += _readHuffSym(bits, _alignedTable, _alignedLen, 7, 8);
          } else if (extra == 3) {
            matchOffset += _readHuffSym(bits, _alignedTable, _alignedLen, 7, 8);
          } else if (extra > 0) {
            matchOffset += bits.read(extra);
          } else {
            matchOffset = 1;
          }
        } else {
          if (matchOffset != 3) {
            matchOffset = _positionBase[matchOffset] - 2 + bits.read(extra);
          } else {
            matchOffset = 1;
          }
        }
        _r2 = _r1;
        _r1 = _r0;
        _r0 = matchOffset;
      } else if (matchOffset == 0) {
        matchOffset = _r0;
      } else if (matchOffset == 1) {
        matchOffset = _r1;
        _r1 = _r0;
        _r0 = matchOffset;
      } else {
        matchOffset = _r2;
        _r2 = _r0;
        _r0 = matchOffset;
      }

      final dest = _windowPosn;
      final src = dest - matchOffset;
      _windowPosn += matchLength;
      if (_windowPosn > windowSize) {
        throw const FormatException('LZX match crosses the window end');
      }
      thisRun -= matchLength;
      for (var i = 0; i < matchLength; i++) {
        window[dest + i] = window[(src + i) & (windowSize - 1)];
      }
    }
  }

  void _readLens(_BitReader bits, Uint8List lens, int first, int last) {
    for (var x = 0; x < 20; x++) {
      _pretreeLen[x] = bits.read(4);
    }
    _buildTable(20, 6, _pretreeLen, _pretreeTable);
    var x = first;
    while (x < last) {
      var z = _readHuffSym(bits, _pretreeTable, _pretreeLen, 6, 20);
      if (z == 17) {
        final count = bits.read(4) + 4;
        for (var i = 0; i < count && x < last; i++) {
          lens[x++] = 0;
        }
      } else if (z == 18) {
        final count = bits.read(5) + 20;
        for (var i = 0; i < count && x < last; i++) {
          lens[x++] = 0;
        }
      } else if (z == 19) {
        final count = bits.read(1) + 4;
        z = _readHuffSym(bits, _pretreeTable, _pretreeLen, 6, 20);
        var value = lens[x] - z;
        if (value < 0) value += 17;
        for (var i = 0; i < count && x < last; i++) {
          lens[x++] = value;
        }
      } else {
        var value = lens[x] - z;
        if (value < 0) value += 17;
        lens[x++] = value;
      }
    }
  }

  int _readHuffSym(
    _BitReader bits,
    Uint16List table,
    Uint8List lens,
    int tableBits,
    int maxSymbols,
  ) {
    bits.ensure(16);
    var i = table[bits.peek(tableBits)];
    if (i >= maxSymbols) {
      // Walk the overflow tree bit by bit; the reference decoder tests bits
      // in a 32-bit top-aligned register.
      var j = 1 << (32 - tableBits);
      do {
        j >>= 1;
        i <<= 1;
        i |= bits.testBit(j) ? 1 : 0;
        if (j == 0) throw const FormatException('invalid LZX Huffman code');
      } while ((i = table[i]) >= maxSymbols);
    }
    final symbol = i;
    bits.remove(lens[symbol]);
    return symbol;
  }

  /// David Tritscher's canonical-Huffman lookup table builder.
  void _buildTable(
    int numSymbols,
    int numBits,
    Uint8List length,
    Uint16List table,
  ) {
    var bitNum = 1;
    var pos = 0;
    var tableMask = 1 << numBits;
    var bitMask = tableMask >> 1;
    var nextSymbol = bitMask;

    while (bitNum <= numBits) {
      for (var sym = 0; sym < numSymbols; sym++) {
        if (length[sym] != bitNum) continue;
        final leaf = pos;
        pos += bitMask;
        if (pos > tableMask) {
          throw const FormatException('invalid LZX Huffman table');
        }
        table.fillRange(leaf, leaf + bitMask, sym);
      }
      bitMask >>= 1;
      bitNum++;
    }

    if (pos != tableMask) {
      table.fillRange(pos, tableMask, 0);
      pos <<= 16;
      tableMask <<= 16;
      bitMask = 1 << 15;
      while (bitNum <= 16) {
        for (var sym = 0; sym < numSymbols; sym++) {
          if (length[sym] != bitNum) continue;
          var leaf = pos >> 16;
          for (var fill = 0; fill < bitNum - numBits; fill++) {
            if (table[leaf] == 0) {
              table[nextSymbol << 1] = 0;
              table[(nextSymbol << 1) + 1] = 0;
              table[leaf] = nextSymbol++;
            }
            leaf = table[leaf] << 1;
            if ((pos >> (15 - fill)) & 1 != 0) leaf++;
          }
          table[leaf] = sym;
          pos += bitMask;
          if (pos > tableMask) {
            throw const FormatException('invalid LZX Huffman table');
          }
        }
        bitMask >>= 1;
        bitNum++;
      }
    }

    if (pos != tableMask) {
      for (var sym = 0; sym < numSymbols; sym++) {
        if (length[sym] != 0) {
          throw const FormatException('invalid LZX Huffman table');
        }
      }
    }
  }

  /// Intel E8 translation (CALL-relative → absolute) on a decoded block.
  void _applyIntelE8(Uint8List out) {
    final frameActive = _framesRead++ < 32768 && _intelFilesize != 0;
    if (!frameActive) return;
    final outLen = out.length;
    if (outLen <= 6 || !_intelStarted) {
      _intelCurpos += outLen;
      return;
    }
    final startCurpos = _intelCurpos;
    _intelCurpos = startCurpos + outLen;
    var curpos = startCurpos;
    final filesize = _intelFilesize;
    final dataEnd = outLen - 10;
    var data = 0;
    while (data < dataEnd) {
      if (out[data++] != 0xE8) {
        curpos++;
        continue;
      }
      var absOff =
          out[data] |
          (out[data + 1] << 8) |
          (out[data + 2] << 16) |
          (out[data + 3] << 24);
      if (absOff >= -curpos && absOff < filesize) {
        final relOff = absOff >= 0 ? absOff - curpos : absOff + filesize;
        out[data] = relOff & 0xff;
        out[data + 1] = (relOff >> 8) & 0xff;
        out[data + 2] = (relOff >> 16) & 0xff;
        out[data + 3] = (relOff >> 24) & 0xff;
      }
      data += 4;
      curpos += 5;
    }
  }
}

/// MSB-first bit reader over a byte buffer, reading 16-bit words at a time
/// to match the reference decoder's alignment behavior. Reads past the end
/// yield zero words (the C decoder reads bounded garbage).
class _BitReader {
  final Uint8List data;
  int pos = 0;
  int _bitBuf = 0;
  int _bitCnt = 0;

  _BitReader(this.data);

  int _word() {
    if (pos + 1 < data.length) {
      final word = data[pos] | (data[pos + 1] << 8);
      pos += 2;
      return word;
    }
    var word = 0;
    if (pos < data.length) word = data[pos];
    pos += 2;
    return word;
  }

  void ensure(int n) {
    while (_bitCnt < n) {
      _bitBuf = (_bitBuf << 16) | _word();
      _bitCnt += 16;
    }
  }

  int peek(int n) {
    ensure(n);
    return _bitBuf >> (_bitCnt - n);
  }

  /// Tests a bit by its position in the reference 32-bit register (the
  /// buffer is top-aligned into 32 bits first).
  bool testBit(int maskBit) => ((_bitBuf << (32 - _bitCnt)) & maskBit) != 0;

  void remove(int n) {
    _bitBuf &= (1 << (_bitCnt - n)) - 1;
    _bitCnt -= n;
  }

  int read(int n) {
    if (n == 0) return 0;
    final value = peek(n);
    remove(n);
    return value;
  }

  /// Word-align the stream before an uncompressed block header
  /// (C: ENSURE_BITS(16); if (bitsleft > 16) inpos -= 2).
  void alignAfterUncompressedHeader() {
    ensure(16);
    if (_bitCnt > 16) {
      pos -= 2;
      _bitCnt -= 16;
      _bitBuf &= (1 << _bitCnt) - 1;
    }
  }

  int readLE32() {
    if (pos + 3 < data.length) {
      final value =
          data[pos] |
          (data[pos + 1] << 8) |
          (data[pos + 2] << 16) |
          (data[pos + 3] << 24);
      pos += 4;
      return value;
    }
    var value = 0;
    for (var i = 0; i < 4; i++) {
      value |= (pos < data.length ? data[pos] : 0) << (i * 8);
      pos++;
    }
    return value;
  }

  void copyBytes(Uint8List target, int offset, int length) {
    if (pos + length > data.length) {
      throw const FormatException('uncompressed LZX block underrun');
    }
    target.setRange(offset, offset + length, data, pos);
    pos += length;
  }

  void skipPadByte() => pos++;

  void resetBitstream() {
    _bitBuf = 0;
    _bitCnt = 0;
  }

  /// C: `if (inpos > endinp) { if (inpos > endinp+2 || bitsleft < 16) fail }`.
  void checkExhausted() {
    if (pos > data.length) {
      if (pos > data.length + 2 || _bitCnt < 16) {
        throw const FormatException('truncated LZX stream');
      }
    }
  }
}
