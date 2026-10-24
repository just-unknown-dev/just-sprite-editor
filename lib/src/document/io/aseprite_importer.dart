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
  AsepriteImporter._(this._data)
    : _view = ByteData.sublistView(_data),
      _end = _data.length;

  final Uint8List _data;
  final ByteData _view;
  int _at = 0;

  /// Where reading must stop: the end of the chunk being read, of its
  /// frame, or of the file. Every read checks it, so a size in the file
  /// that is a lie is a damaged file, not a read past the end.
  int _end;

  /// Bytes of canvas-sized cels built so far, against [maxCelBytes].
  int _celBytes = 0;

  /// What could not be carried over, in words for the artist.
  final List<String> warnings = [];

  static const int _fileMagic = 0xA5E0;
  static const int _frameMagic = 0xF1FA;

  /// The most memory an import may give its cels — each is a canvas-sized
  /// buffer — before the file is refused as too big to open.
  static const int maxCelBytes = 1 << 30;

  /// The most pixels one cel of the file may hold.
  static const int maxCelPixels = 4096 * 4096;

  /// The most layers a file may have.
  static const int maxLayers = 4096;

  static const FormatException _damaged = FormatException(
    'This Aseprite file is damaged.',
  );

  /// Throws [FormatException] when [bytes] is not an Aseprite file, is
  /// damaged or cut short, or is too big to open.
  static (SpriteDocument, List<String> warnings) import(List<int> bytes) {
    final importer = AsepriteImporter._(
      bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
    );
    try {
      final doc = importer._read();
      return (doc, importer.warnings);
    } on RangeError {
      // Every read is bounded; this is the net under them.
      throw _damaged;
    }
  }

  void _need(int bytes) {
    if (_at < 0 || _at + bytes > _end) throw _damaged;
  }

  int _u8() {
    _need(1);
    return _view.getUint8(_at++);
  }

  int _u16() {
    _need(2);
    final v = _view.getUint16(_at, Endian.little);
    _at += 2;
    return v;
  }

  int _i16() {
    _need(2);
    final v = _view.getInt16(_at, Endian.little);
    _at += 2;
    return v;
  }

  int _u32() {
    _need(4);
    final v = _view.getUint32(_at, Endian.little);
    _at += 4;
    return v;
  }

  String _string() {
    final length = _u16();
    _need(length);
    final s = utf8.decode(
      Uint8List.sublistView(_data, _at, _at + length),
      allowMalformed: true,
    );
    _at += length;
    return s;
  }

  /// Counts one more canvas-sized cel against [maxCelBytes], before it is
  /// made.
  void _chargeCel(int width, int height) {
    _celBytes += width * height * 4;
    if (_celBytes > maxCelBytes) {
      throw const FormatException(
        'This Aseprite file is too big to open: its cels would need more '
        'than ${maxCelBytes >> 20} MB.',
      );
    }
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
    // Every frame is at least its 16-byte header.
    if (frameCount * 16 > _data.length - 128) throw _damaged;
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
      _end = _data.length;
      final frameBytes = _u32();
      final frameEnd = frameStart + frameBytes;
      if (_u16() != _frameMagic || frameBytes < 16 || frameEnd > _data.length) {
        throw FormatException('Frame ${f + 1} is damaged.');
      }
      _end = frameEnd;
      final oldChunks = _u16();
      final duration = _u16();
      _at += 2;
      final newChunks = _u32();
      final chunks = newChunks == 0 ? oldChunks : newChunks;
      // Every chunk is at least its 6-byte header: a count the frame cannot
      // hold is damage, not a reason to read the same bytes again.
      if (chunks > (frameEnd - _at) ~/ 6) {
        throw FormatException('Frame ${f + 1} is damaged.');
      }
      final frame = doc.addFrame(
        durationMs: duration > 0
            ? duration
            : defaultDuration > 0
            ? defaultDuration
            : 100,
      );

      for (var c = 0; c < chunks; c++) {
        final chunkStart = _at;
        _end = frameEnd;
        final size = _u32();
        final type = _u16();
        final chunkEnd = chunkStart + size;
        if (size < 6 || chunkEnd > frameEnd) throw _damaged;
        _end = chunkEnd;
        switch (type) {
          case 0x2004:
            final layerFlags = _u16();
            final layerType = _u16();
            _at += 2 + 2 + 2; // child level, default width, default height
            final blend = _u16();
            final opacity = _u8();
            _at += 3;
            final name = _string();
            if (layers.length >= maxLayers) {
              throw const FormatException(
                'This Aseprite file has more layers than the studio opens '
                '($maxLayers).',
              );
            }
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
                _chargeCel(width, height);
                doc.setCel(layer.id, frame.id, linked.copy());
                placed[layerIndex * 0x10000 + f] = linked;
              }
              break;
            } else if (celType == 0 || celType == 2) {
              final w = _u16(), h = _u16();
              if (w * h > maxCelPixels) {
                throw const FormatException(
                  'A cel in this file is too big to open.',
                );
              }
              final data = Uint8List.sublistView(_data, _at, chunkEnd);
              final raw = celType == 0
                  ? data
                  : _inflate(data, w * h * (depth ~/ 8));
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
            _chargeCel(width, height);
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
      _at = frameEnd;
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
    final bytesPerPixel = depth ~/ 8;
    // Checked before anything the size of the cel is made.
    if (raw.length < w * h * bytesPerPixel) {
      throw const FormatException('A cel in this file is damaged.');
    }
    final out = PixelBuffer(w, h);
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
