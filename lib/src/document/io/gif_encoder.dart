import 'dart:typed_data';

import '../pixel_buffer.dart';
import '../sprite_document.dart';

/// Writes animated GIFs: for showing a sprite to someone, not for the game.
///
/// GIF has 256 colours and one-bit transparency. Pixel art almost always
/// fits; when a sprite has more colours, the least used are mapped to their
/// nearest kept neighbour. A pixel is opaque at alpha 128 and above.
abstract final class GifEncoder {
  /// [doc]'s frames — those of [tag], in its playing order, when given —
  /// scaled by whole-number [scale].
  static Uint8List encodeDocument(
    SpriteDocument doc, {
    SpriteTag? tag,
    int scale = 1,
    bool loop = true,
  }) {
    final order =
        tag?.playOrder ?? [for (var i = 0; i < doc.frames.length; i++) i];
    return encode(
      [
        for (final i in order)
          scale <= 1 ? doc.flatten(i) : doc.flatten(i).scaledUp(scale),
      ],
      [for (final i in order) doc.frames[i].durationMs],
      loop: loop,
    );
  }

  static Uint8List encode(
    List<PixelBuffer> frames,
    List<int> durationsMs, {
    bool loop = true,
  }) {
    assert(frames.isNotEmpty && frames.length == durationsMs.length);
    final width = frames.first.width, height = frames.first.height;

    // One palette for the whole animation: index 0 is "transparent".
    final counts = <int, int>{};
    for (final f in frames) {
      for (final p in f.pixels) {
        if ((p >> 24) & 0xFF < 128) continue;
        final rgb = p & 0xFFFFFF;
        counts[rgb] = (counts[rgb] ?? 0) + 1;
      }
    }
    final byUse = counts.keys.toList()
      ..sort((a, b) => counts[b]!.compareTo(counts[a]!));
    final kept = byUse.take(255).toList();
    final indexOf = <int, int>{
      for (var i = 0; i < kept.length; i++) kept[i]: i + 1,
    };
    int nearest(int rgb) {
      var best = 1, bestDistance = 1 << 30;
      final r = (rgb >> 16) & 0xFF, g = (rgb >> 8) & 0xFF, b = rgb & 0xFF;
      for (var i = 0; i < kept.length; i++) {
        final k = kept[i];
        final dr = r - ((k >> 16) & 0xFF);
        final dg = g - ((k >> 8) & 0xFF);
        final db = b - (k & 0xFF);
        final d = dr * dr + dg * dg + db * db;
        if (d < bestDistance) {
          bestDistance = d;
          best = i + 1;
        }
      }
      return best;
    }

    var bits = 1;
    while ((1 << bits) < kept.length + 1) {
      bits++;
    }
    final tableSize = 1 << bits;

    final out = BytesBuilder(copy: false)
      ..add('GIF89a'.codeUnits)
      ..add(_u16(width))
      ..add(_u16(height))
      ..addByte(0x80 | 0x70 | (bits - 1)) // global table, 8-bit colour
      ..addByte(0) // background: the transparent index
      ..addByte(0);
    for (var i = 0; i < tableSize; i++) {
      final rgb = i == 0 || i > kept.length ? 0 : kept[i - 1];
      out
        ..addByte((rgb >> 16) & 0xFF)
        ..addByte((rgb >> 8) & 0xFF)
        ..addByte(rgb & 0xFF);
    }
    if (loop && frames.length > 1) {
      out
        ..add([0x21, 0xFF, 0x0B])
        ..add('NETSCAPE2.0'.codeUnits)
        ..add([0x03, 0x01, 0x00, 0x00, 0x00]);
    }

    final minCodeSize = bits < 2 ? 2 : bits;
    for (var f = 0; f < frames.length; f++) {
      // GIF counts in hundredths of a second, and most players treat
      // anything under 2 as "as slow as you like".
      final delay = (durationsMs[f] / 10).round().clamp(2, 65535);
      out
        ..add([0x21, 0xF9, 0x04])
        // Dispose to background, so a transparent pixel is not the last
        // frame showing through; transparency on.
        ..addByte(0x08 | 0x01)
        ..add(_u16(delay))
        ..addByte(0) // the transparent index
        ..addByte(0)
        ..addByte(0x2C)
        ..add(_u16(0))
        ..add(_u16(0))
        ..add(_u16(width))
        ..add(_u16(height))
        ..addByte(0);

      final indices = Uint8List(width * height);
      final px = frames[f].pixels;
      final cache = <int, int>{};
      for (var i = 0; i < indices.length; i++) {
        final p = px[i];
        if ((p >> 24) & 0xFF < 128) continue;
        final rgb = p & 0xFFFFFF;
        indices[i] = indexOf[rgb] ?? (cache[rgb] ??= nearest(rgb));
      }
      out.addByte(minCodeSize);
      final data = _lzw(indices, minCodeSize);
      for (var i = 0; i < data.length; i += 255) {
        final n = data.length - i < 255 ? data.length - i : 255;
        out
          ..addByte(n)
          ..add(Uint8List.sublistView(data, i, i + n));
      }
      out.addByte(0);
    }
    out.addByte(0x3B);
    return out.toBytes();
  }

  static List<int> _u16(int v) => [v & 0xFF, (v >> 8) & 0xFF];

  /// GIF's variable-width LZW, least significant bit first.
  static Uint8List _lzw(Uint8List indices, int minCodeSize) {
    final clear = 1 << minCodeSize;
    final end = clear + 1;
    final out = BytesBuilder(copy: false);
    var bitBuffer = 0, bitCount = 0;
    var codeSize = minCodeSize + 1;
    var next = end + 1;
    var table = <int, int>{};

    void emit(int code) {
      bitBuffer |= code << bitCount;
      bitCount += codeSize;
      while (bitCount >= 8) {
        out.addByte(bitBuffer & 0xFF);
        bitBuffer >>= 8;
        bitCount -= 8;
      }
    }

    emit(clear);
    if (indices.isNotEmpty) {
      var prefix = indices[0];
      for (var i = 1; i < indices.length; i++) {
        final k = indices[i];
        // A string is its prefix code and one more index, packed in a key.
        final key = (prefix << 8) | k;
        final found = table[key];
        if (found != null) {
          prefix = found;
          continue;
        }
        emit(prefix);
        if (next < 4096) {
          table[key] = next++;
          if (next > (1 << codeSize) && codeSize < 12) codeSize++;
        } else {
          emit(clear);
          table = <int, int>{};
          codeSize = minCodeSize + 1;
          next = end + 1;
        }
        prefix = k;
      }
      emit(prefix);
    }
    emit(end);
    if (bitCount > 0) out.addByte(bitBuffer & 0xFF);
    return out.toBytes();
  }
}
