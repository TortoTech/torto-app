import 'dart:typed_data';

import '../objects.dart';
import 'filters.dart';

/// RunLengthDecode (§7.4.5): length byte 0–127 copies the next length+1
/// bytes literally; 129–255 repeats the next byte 257−length times; 128
/// is EOD.
class RunLengthFilter extends CosFilter {
  const RunLengthFilter();

  @override
  Uint8List decode(Uint8List data, CosDictionary? params) {
    final out = BytesBuilder(copy: false);
    var i = 0;
    while (i < data.length) {
      final length = data[i++];
      if (length == 128) break;
      if (length < 128) {
        final count = length + 1;
        final end = i + count > data.length ? data.length : i + count;
        out.add(Uint8List.sublistView(data, i, end));
        i = end;
      } else {
        if (i >= data.length) break;
        out.add(Uint8List(257 - length)..fillRange(0, 257 - length, data[i]));
        i++;
      }
    }
    return out.takeBytes();
  }
}
