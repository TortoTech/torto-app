import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

/// History stores content hashes, never external paths or large base64 strings.
class ChatAttachments {
  final Directory directory;
  ChatAttachments(this.directory);
  static Future<ChatAttachments> open() async => ChatAttachments(
    Directory(
      '${(await getApplicationDocumentsDirectory()).path}/chat-images-v1',
    ),
  );
  Future<Map<String, String>> save(Uint8List bytes, String name) async {
    if (bytes.length > 20 * 1024 * 1024) {
      throw const FormatException('Image exceeds 20 MB');
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final codec = await ui.instantiateImageCodecWithSize(
      buffer,
      getTargetSize: (width, height) {
        final longest = width > height ? width : height;
        final pixelLimit = 4 * 1024 * 1024;
        if (longest <= 2048 && width * height <= pixelLimit) {
          return const ui.TargetImageSize();
        }
        return ui.TargetImageSize(
          width: (width * 2048 / longest).round().clamp(1, 2048),
          height: (height * 2048 / longest).round().clamp(1, 2048),
        );
      },
    );
    try {
      final image = (await codec.getNextFrame()).image;
      try {
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        if (png == null || png.lengthInBytes > 6 * 1024 * 1024) {
          throw const FormatException('Image exceeds attachment budget');
        }
        final normalized = png.buffer.asUint8List(
          png.offsetInBytes,
          png.lengthInBytes,
        );
        final hash = sha256.convert(normalized).toString();
        await directory.create(recursive: true);
        final file = File('${directory.path}/$hash.png');
        if (!await file.exists()) {
          await file.writeAsBytes(normalized, flush: true);
        }
        return {
          'hash': hash,
          'name': name.substring(0, name.length.clamp(0, 200)),
          'mime': 'image/png',
          'size': '${normalized.length}',
        };
      } finally {
        image.dispose();
      }
    } finally {
      codec.dispose();
    }
  }

  Future<Uint8List> read(Map<String, String> attachment) async {
    final hash = attachment['hash'] ?? '';
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
      throw const FormatException('Invalid attachment identity');
    }
    final file = File('${directory.path}/$hash.png');
    if (await file.length() > 6 * 1024 * 1024) {
      throw const FormatException('Attachment too large');
    }
    final bytes = await file.readAsBytes();
    if (sha256.convert(bytes).toString() != hash) {
      throw const FormatException('Attachment checksum failed');
    }
    return bytes;
  }

  static List<Map<String, String>> decode(String? value) {
    if (value == null) return [];
    final list = jsonDecode(value);
    if (list is! List || list.length > 8) {
      throw const FormatException('Invalid attachments');
    }
    return list.map((m) => Map<String, String>.from(m as Map)).toList();
  }

  Future<List<Map<String, dynamic>>> evidence(
    List<Map<String, String>> history,
  ) async {
    final images = <Map<String, dynamic>>[];
    var bytes = 0;
    for (final (turn, message) in history.indexed.toList().reversed) {
      for (final attachment in decode(message['attachments'])) {
        final data = await read(attachment);
        if (images.length >= 8 || bytes + data.length > 24 * 1024 * 1024) {
          message['image_labels'] =
              '${message['image_labels'] ?? ''} [older image ${attachment['name']} retained locally, omitted from this request]';
          continue;
        }
        bytes += data.length;
        images.add({
          'type': 'image_url',
          'image_url': {'url': 'data:image/png;base64,${base64Encode(data)}'},
        });
        message['image_labels'] =
            '${message['image_labels'] ?? ''} [image ${images.length}: turn $turn, ${attachment['name']}]';
      }
      message.remove('attachments');
    }
    return images;
  }
}
