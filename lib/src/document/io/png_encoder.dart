import 'dart:typed_data';

import 'package:just_deflate/just_deflate.dart';

import '../pixel_buffer.dart';

/// Writes 8-bit RGBA PNGs. Small on purpose: a sprite sheet needs nothing a
/// PNG has beyond truecolour with alpha, and encoding here keeps the
/// document core free of the UI toolkit — it runs in a plain Dart test.
abstract final class PngEncoder {
  static const List<int> _signature = [137, 80, 78, 71, 13, 10, 26, 10];

  static Uint8List encode(PixelBuffer image) {
    final w = image.width, h = image.height;
    // Each scanline: filter byte 0 (none), then RGBA.
    final raw = Uint8List((w * 4 + 1) * h);
    var o = 0;
    for (var y = 0; y < h; y++) {
      raw[o++] = 0;
      for (var x = 0; x < w; x++) {
        final c = image.pixels[y * w + x];
        raw[o++] = (c >> 16) & 0xFF;
        raw[o++] = (c >> 8) & 0xFF;
        raw[o++] = c & 0xFF;
        raw[o++] = (c >> 24) & 0xFF;
      }
    }

    final header = ByteData(13)
      ..setUint32(0, w)
      ..setUint32(4, h)
      ..setUint8(8, 8) // bit depth
      ..setUint8(9, 6) // colour type: RGBA
      ..setUint8(10, 0)
      ..setUint8(11, 0)
      ..setUint8(12, 0);

    final out = BytesBuilder(copy: false)..add(_signature);
    _chunk(out, 'IHDR', header.buffer.asUint8List());
    _chunk(out, 'IDAT', const ZlibCodec(level: 9).encode(raw));
    _chunk(out, 'IEND', const []);
    return out.toBytes();
  }

  static void _chunk(BytesBuilder out, String type, List<int> data) {
    final typeBytes = type.codeUnits;
    final length = ByteData(4)..setUint32(0, data.length);
    final crc = ByteData(4)..setUint32(0, crc32(data, crc32(typeBytes)));
    out
      ..add(length.buffer.asUint8List())
      ..add(typeBytes)
      ..add(data)
      ..add(crc.buffer.asUint8List());
  }
}

/// CRC-32 as PNG (and zip) use it: `just_deflate`'s [crc32].
abstract final class Crc32 {
  static int of(List<int> bytes) => crc32(bytes);
}
