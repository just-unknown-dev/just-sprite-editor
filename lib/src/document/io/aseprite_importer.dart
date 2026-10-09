import 'dart:convert';
import 'dart:typed_data';

import 'package:just_deflate/just_deflate.dart';

import '../pixel_buffer.dart';
import '../sprite_document.dart';

/// Reads Aseprite's own files (`.ase`, `.aseprite`) into a [SpriteDocument]:
/// layers, cels, frame durations, tags and the palette.
///
/// What this studio has no place for is flattened or dropped rather than
/// refused: group layers disappear (their children stay, in order), indexed
/// and greyscale sprites become RGBA, a cel's own opacity is folded into its
/// pixels, tilemap layers and blend modes other than normal are ignored.
/// [warnings] says which of those happened.
class AsepriteImporter {
  AsepriteImporter._(this._data) : _view = ByteData.sublistView(_data);

  final Uint8List _data;
  final ByteData _view;
  int _at = 0;

  /// What could not be carried over, in words for the artist.
  final List<String> warnings = [];

  static const int _fileMagic = 0xA5E0;
  static const int _frameMagic = 0xF1FA;

  /// Throws [FormatException] when [bytes] is not an Aseprite file.
  static (SpriteDocument, List<String> warnings) import(List<int> bytes) {
    final importer = AsepriteImporter._(
      bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
    );
    final doc = importer._read();
    return (doc, importer.warnings);
  }

  int _u8() => _view.getUint8(_at++);

  int _u16() {
    final v = _view.getUint16(_at, Endian.little);
    _at += 2;
    return v;
  }

  int _i16() {
    final v = _view.getInt16(_at, Endian.little);
    _at += 2;
    return v;
  }

  int _u32() {
    final v = _view.getUint32(_at, Endian.little);
    _at += 4;
    return v;
  }

  String _string() {
    final length = _u16();
    final s = utf8.decode(
      _data.sublist(_at, _at + length),
      allowMalformed: true,
    );
    _at += length;
    return s;
  }

  void _warn(String text) {
    if (!warnings.contains(text)) warnings.add(text);
  }

  SpriteDocument _read() {
    if (_data.length < 128) {
      throw const FormatException('Not an Aseprite file.');
    }
    _u32(); // file size
    if (_u16() != _fileMagic) {
      throw const FormatException('Not an Aseprite file.');
    }
    final frameCount = _u16();
    final width = _u16(), height = _u16();
    final depth = _u16();
    final flags = _u32();
    final defaultDuration = _u16();
    _at += 8;
    final transparentIndex = _u8();
    _at = 128;
    if (width < 1 ||
        height < 1 ||
        width > SpriteDocument.maxSize ||
        height > SpriteDocument.maxSize) {
      throw FormatException('A sprite cannot be $width × $height.');
    }
    if (depth != 32 && depth != 16 && depth != 8) {
      throw FormatException('Unknown colour depth: $depth bits.');
    }
    if (depth == 8) _warn('Indexed colours became RGBA.');
    if (depth == 16) _warn('Greyscale became RGBA.');
    final layerOpacityValid = flags & 1 != 0;

    final doc = SpriteDocument(width: width, height: height);
    // Every layer in the file, by its index there; null for the ones this
    // studio does not keep (groups, tilemaps).
    final layers = <SpriteLayer?>[];
    final isBackground = <bool>[];
    final palette = List<int>.filled(256, 0xFF000000);
    var paletteSize = 0;
    // For linked cels: what each (layer index, frame index) resolved to.
    final placed = <int, PixelBuffer>{};
    // Tags arrive with the first frame, naming frames not read yet; they
    // join the document once every frame is in.
    final tags = <SpriteTag>[];

    for (var f = 0; f < frameCount; f++) {
      final frameStart = _at;
      final frameBytes = _u32();
      if (_u16() != _frameMagic) {
        throw FormatException('Frame ${f + 1} is damaged.');
      }
      final oldChunks = _u16();
      final duration = _u16();
      _at += 2;
      final newChunks = _u32();
      final chunks = newChunks == 0 ? oldChunks : newChunks;
      final frame = doc.addFrame(
        durationMs: duration > 0
            ? duration
            : defaultDuration > 0
            ? defaultDuration
            : 100,
      );

      for (var c = 0; c < chunks; c++) {
        final chunkStart = _at;
        final size = _u32();
        final type = _u16();
        final chunkEnd = chunkStart + size;
        switch (type) {
          case 0x2004:
            final layerFlags = _u16();
            final layerType = _u16();
            _at += 2 + 2 + 2; // child level, default width, default height
            final blend = _u16();
            final opacity = _u8();
            _at += 3;
            final name = _string();
            isBackground.add(layerFlags & 8 != 0);
            if (layerType == 1) {
              _warn('Layer groups were flattened away.');
              layers.add(null);
            } else if (layerType == 2) {
              _warn('Tilemap layer "$name" was skipped.');
              layers.add(null);
            } else {
              if (blend != 0) {
                _warn('"$name" used a blend mode; it is Normal now.');
              }
              layers.add(
                doc.addLayer(name: name)
                  ..visible = layerFlags & 1 != 0
                  ..opacity = layerOpacityValid ? opacity : 255,
              );
            }
          case 0x2005:
            final layerIndex = _u16();
            final x = _i16(), y = _i16();
            final celOpacity = _u8();
            final celType = _u16();
            _at += 2 + 5; // z-index, reserved
            final layer = layerIndex < layers.length
                ? layers[layerIndex]
                : null;
            PixelBuffer? image;
            var ox = x, oy = y;
            if (celType == 1) {
              final linked = placed[layerIndex * 0x10000 + _u16()];
              if (linked != null && layer != null) {
                doc.setCel(layer.id, frame.id, linked.copy());
                placed[layerIndex * 0x10000 + f] = linked;
              }
              break;
            } else if (celType == 0 || celType == 2) {
              final w = _u16(), h = _u16();
              final raw = celType == 0
                  ? _data.sublist(_at, chunkEnd)
                  : _inflate(
                      _data.sublist(_at, chunkEnd),
                      w * h * (depth ~/ 8),
                    );
              image = _decodePixels(
                raw,
                w,
                h,
                depth,
                palette,
                // Index 0 (or whichever) is see-through — except on the
                // background layer, where it is just a colour.
                layerIndex < isBackground.length && isBackground[layerIndex]
                    ? -1
                    : transparentIndex,
              );
            } else {
              _warn('A tilemap cel was skipped.');
            }
            if (image == null || layer == null) break;
            if (celOpacity < 255) {
              for (var i = 0; i < image.pixels.length; i++) {
                final p = image.pixels[i];
                final a = ((p >> 24) & 0xFF) * celOpacity ~/ 255;
                image.pixels[i] = (p & 0x00FFFFFF) | (a << 24);
              }
            }
            final cel = PixelBuffer(width, height)..paste(image, ox, oy);
            doc.setCel(layer.id, frame.id, cel);
            placed[layerIndex * 0x10000 + f] = cel;
          case 0x2018:
            final count = _u16();
            _at += 8;
            for (var t = 0; t < count; t++) {
              final from = _u16(), to = _u16();
              final direction = _u8();
              final repeat = _u16();
              _at += 6;
              final r = _u8(), g = _u8(), b = _u8();
              _at += 1;
              final name = _string();
              if (direction == 3) {
                _warn(
                  '"$name" played ping-pong in reverse; it is ping-pong now.',
                );
              }
              tags.add(
                SpriteTag(
                  name: name,
                  from: from,
                  to: to,
                  direction: switch (direction) {
                    1 => TagDirection.reverse,
                    2 || 3 => TagDirection.pingpong,
                    _ => TagDirection.forward,
                  },
                  // Aseprite counts repeats; 0 is "for ever". Anything
                  // finite is closest to "plays, then holds".
                  loop: repeat == 0,
                  color: r == 0 && g == 0 && b == 0
                      ? 0xFF7DE6B1
                      : Argb.from(255, r, g, b),
                ),
              );
            }
          case 0x2019:
            final newSize = _u32();
            final first = _u32(), last = _u32();
            _at += 8;
            for (var i = first; i <= last && i < 256; i++) {
              final entryFlags = _u16();
              final r = _u8(), g = _u8(), b = _u8(), a = _u8();
              if (entryFlags & 1 != 0) _string();
              palette[i] = Argb.from(a, r, g, b);
            }
            if (newSize > paletteSize) paletteSize = newSize.clamp(0, 256);
          case 0x0004:
            // The old palette chunk; a newer one, if present, wins.
            if (paletteSize > 0) break;
            final packets = _u16();
            var index = 0;
            for (var p = 0; p < packets; p++) {
              index += _u8();
              var n = _u8();
              if (n == 0) n = 256;
              for (var i = 0; i < n && index < 256; i++, index++) {
                palette[index] = Argb.from(255, _u8(), _u8(), _u8());
              }
            }
            paletteSize = index.clamp(0, 256);
        }
        _at = chunkEnd;
      }
      _at = frameStart + frameBytes;
    }

    if (doc.layers.isEmpty) doc.addLayer(name: 'Layer 1');
    if (doc.frames.isEmpty) doc.addFrame();
    doc.tags.addAll(tags);
    final last = doc.frames.length - 1;
    for (final t in doc.tags) {
      t
        ..from = t.from.clamp(0, last)
        ..to = t.to.clamp(t.from.clamp(0, last), last);
    }
    // A default RGB sprite still carries Aseprite's 256-entry default
    // palette; a palette is only worth keeping when it is a chosen one.
    if (paletteSize > 0 && paletteSize <= 64) {
      for (var i = 0; i < paletteSize; i++) {
        if (depth == 8 && i == transparentIndex) continue;
        if (!doc.palette.contains(palette[i])) doc.palette.add(palette[i]);
      }
    }
    doc
      ..pruneBlankCels()
      ..revision = 0;
    return doc;
  }

  /// A compressed cel's pixels: no more than [size] bytes, so a damaged
  /// cel cannot unpack without end.
  static Uint8List _inflate(List<int> data, int size) {
    try {
      return const ZlibCodec().decode(data, maxOutputSize: size);
    } on FormatException {
      throw const FormatException('A cel in this file is damaged.');
    }
  }

  static PixelBuffer _decodePixels(
    Uint8List raw,
    int w,
    int h,
    int depth,
    List<int> palette,
    int transparentIndex,
  ) {
    final out = PixelBuffer(w, h);
    final bytesPerPixel = depth ~/ 8;
    if (raw.length < w * h * bytesPerPixel) {
      throw const FormatException('A cel in this file is damaged.');
    }
    for (var i = 0, o = 0; i < w * h; i++, o += bytesPerPixel) {
      out.pixels[i] = switch (depth) {
        32 => Argb.from(raw[o + 3], raw[o], raw[o + 1], raw[o + 2]),
        16 => Argb.from(raw[o + 1], raw[o], raw[o], raw[o]),
        _ => raw[o] == transparentIndex ? Argb.transparent : palette[raw[o]],
      };
    }
    return out;
  }
}
