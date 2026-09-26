import 'dart:isolate';
import 'dart:typed_data';
import 'package:image/image.dart' as img;

typedef FormulaImagePayload = ({Uint8List bytes, String mime, bool converted});

/// Vision endpoints do not consistently accept GIF. Preserve the original
/// resource and normalize its first displayed frame to PNG outside the UI
/// isolate. The reader itself already uses the first GIF frame.
Future<FormulaImagePayload?> prepareFormulaImagePayload(Uint8List bytes) async {
  if (bytes.length < 4 || bytes.length > 3 * 1024 * 1024) return null;
  if (bytes[0] == 137 && bytes[1] == 80) {
    return (bytes: bytes, mime: 'image/png', converted: false);
  }
  if (bytes[0] == 255 && bytes[1] == 216) {
    return (bytes: bytes, mime: 'image/jpeg', converted: false);
  }
  if (bytes.length > 12 &&
      String.fromCharCodes(bytes.take(4)) == 'RIFF' &&
      String.fromCharCodes(bytes.skip(8).take(4)) == 'WEBP') {
    return (bytes: bytes, mime: 'image/webp', converted: false);
  }
  final signature = String.fromCharCodes(bytes.take(6));
  if (signature != 'GIF87a' && signature != 'GIF89a') return null;
  return _convertGifInWorker(bytes);
}

Future<FormulaImagePayload?> _convertGifInWorker(Uint8List bytes) =>
    Isolate.run(() {
      try {
        final decoder = img.GifDecoder();
        final info = decoder.startDecode(bytes);
        if (info == null ||
            info.width <= 0 ||
            info.height <= 0 ||
            info.width > 8192 ||
            info.height > 8192 ||
            info.width * info.height > 16 * 1024 * 1024 ||
            info.numFrames == 0) {
          return null;
        }
        final frame = decoder.decodeFrame(0);
        if (frame == null) return null;
        final png = img.encodePng(frame, level: 3);
        if (png.length > 3 * 1024 * 1024) return null;
        return (bytes: png, mime: 'image/png', converted: true);
      } on Object {
        return null;
      }
    });
