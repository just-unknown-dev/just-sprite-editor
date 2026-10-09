import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../pixel_buffer.dart';
import '../sprite_document.dart';
import 'png_encoder.dart';
import 'sheet_options.dart';

export 'sheet_options.dart';

/// What an export produced: the sheet, and the JSON that describes it.
class SheetExport {
  SheetExport(this.sheet, this.json);

  final PixelBuffer sheet;
  final Map<String, dynamic> json;

  Uint8List get pngBytes => PngEncoder.encode(sheet);
  String get jsonText => const JsonEncoder.withIndent('  ').convert(json);
}

/// Turns a document into what the game loads: a sprite sheet PNG and the
/// atlas JSON beside it, in Aseprite's export format (hash frames,
/// `frameTags`, per-frame `duration`) — which the engine's atlas loader
/// already reads — plus a `meta.just` block for what that format cannot say:
/// which clips do not loop, and frame events.
abstract final class SheetExporter {
  static SheetExport export(
    SpriteDocument doc, {
    required String name,
    required String imageFile,
    SheetExportOptions options = const SheetExportOptions(),
  }) {
    final scale = options.scale < 1 ? 1 : options.scale;
    final pad = options.padding < 0 ? 0 : options.padding;
    final count = doc.frames.length;

    final images = <PixelBuffer>[];
    final sources = <IntRect>[];
    for (var i = 0; i < count; i++) {
      final flat = doc.flatten(i);
      var content = options.trim ? flat.contentBounds : flat.bounds;
      // A blank frame still needs a cell: one transparent pixel.
      if (content.isEmpty) content = const IntRect(0, 0, 1, 1);
      images.add(flat.copyRect(content));
      sources.add(content);
    }

    final cellW = images.fold(0, (m, i) => math.max(m, i.width));
    final cellH = images.fold(0, (m, i) => math.max(m, i.height));
    final columns = switch (options.layout) {
      SheetLayout.horizontal => count,
      SheetLayout.vertical => 1,
      SheetLayout.grid => math.max(1, math.sqrt(count).ceil()),
    };
    final rows = (count / columns).ceil();
    final sheet = PixelBuffer(
      pad + columns * (cellW + pad),
      pad + rows * (cellH + pad),
    );

    final frames = <String, dynamic>{};
    for (var i = 0; i < count; i++) {
      final x = pad + (i % columns) * (cellW + pad);
      final y = pad + (i ~/ columns) * (cellH + pad);
      sheet.paste(images[i], x, y);
      final src = sources[i];
      frames['$name $i'] = {
        'frame': _rect(x, y, images[i].width, images[i].height, scale),
        'rotated': false,
        'trimmed': options.trim && src != doc.bounds,
        'spriteSourceSize': _rect(
          src.left,
          src.top,
          src.width,
          src.height,
          scale,
        ),
        'sourceSize': {'w': doc.width * scale, 'h': doc.height * scale},
        'duration': doc.frames[i].durationMs,
      };
    }

    final out = scale == 1 ? sheet : sheet.scaledUp(scale);
    final noLoop = {
      for (final t in doc.tags)
        if (!t.loop) t.name: {'loop': false},
    };
    final events = {
      for (final t in doc.tags)
        if (t.events.isNotEmpty)
          t.name: [
            for (final e in t.events) {'time': e.timeMs / 1000, 'name': e.name},
          ],
    };

    return SheetExport(out, {
      'frames': frames,
      'meta': {
        // The engine picks its Aseprite parser by this word.
        'app': 'just_sprite_editor (aseprite-compatible)',
        'version': '1',
        'image': imageFile,
        'format': 'RGBA8888',
        'size': {'w': out.width, 'h': out.height},
        'scale': '$scale',
        'frameTags': [
          for (final t in doc.tags)
            {
              'name': t.name,
              'from': t.from,
              'to': t.to,
              'direction': t.direction.name,
              'color': '${Argb.toHex(t.color)}ff'.toLowerCase(),
            },
        ],
        if (noLoop.isNotEmpty || events.isNotEmpty)
          'just': {
            if (noLoop.isNotEmpty) 'clips': noLoop,
            if (events.isNotEmpty) 'events': events,
          },
      },
    });
  }

  static Map<String, int> _rect(int x, int y, int w, int h, int scale) => {
    'x': x * scale,
    'y': y * scale,
    'w': w * scale,
    'h': h * scale,
  };
}

/// Brings existing art in.
abstract final class SheetImporter {
  /// One image as a one-frame sprite.
  static SpriteDocument fromImage(PixelBuffer image) {
    final doc = SpriteDocument.blank(image.width, image.height);
    doc.setCel(doc.layers.first.id, doc.frames.first.id, image.copy());
    doc.revision = 0;
    return doc;
  }

  /// A sheet cut into frames of [frameWidth] × [frameHeight], reading rows
  /// left to right. [margin] is the border around the sheet and [spacing]
  /// the gap between cells. Cells with nothing in them are skipped when
  /// [skipBlank] — a sheet's last row is rarely full.
  static SpriteDocument fromSheet(
    PixelBuffer sheet, {
    required int frameWidth,
    required int frameHeight,
    int margin = 0,
    int spacing = 0,
    int durationMs = 100,
    bool skipBlank = true,
  }) {
    if (frameWidth <= 0 || frameHeight <= 0) {
      throw ArgumentError('A frame must be at least 1 × 1.');
    }
    final doc = SpriteDocument(width: frameWidth, height: frameHeight);
    final layer = doc.addLayer(name: 'Layer 1');
    for (
      var y = margin;
      y + frameHeight <= sheet.height - margin;
      y += frameHeight + spacing
    ) {
      for (
        var x = margin;
        x + frameWidth <= sheet.width - margin;
        x += frameWidth + spacing
      ) {
        final cell = sheet.copyRect(
          IntRect.fromLTWH(x, y, frameWidth, frameHeight),
        );
        if (skipBlank && cell.isBlank) continue;
        final frame = doc.addFrame(durationMs: durationMs);
        doc.setCel(layer.id, frame.id, cell);
      }
    }
    if (doc.frames.isEmpty) doc.addFrame(durationMs: durationMs);
    doc.revision = 0;
    return doc;
  }
}
