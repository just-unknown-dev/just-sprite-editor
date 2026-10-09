import 'dart:convert';
import 'dart:typed_data';

import 'package:just_deflate/just_deflate.dart';

import '../pixel_buffer.dart';
import '../sprite_document.dart';
import 'sheet_options.dart';

/// The studio's own project file: everything editable — layers, cels, tags,
/// palette — kept intact. JSON, so it diffs and merges as text where it can;
/// each cel is its content rectangle, deflated and base64'd.
abstract final class JspriteCodec {
  static const int formatVersion = 1;
  static const String extension = 'jsprite';

  static String encode(SpriteDocument doc) =>
      const JsonEncoder.withIndent(' ').convert(toJson(doc));

  static Map<String, dynamic> toJson(SpriteDocument doc) => {
    'format': 'jsprite',
    'version': formatVersion,
    'width': doc.width,
    'height': doc.height,
    'export': doc.exportOptions.toJson(),
    'palette': [for (final c in doc.palette) Argb.toHex(c)],
    'layers': [
      for (final l in doc.layers)
        {
          'id': l.id,
          'name': l.name,
          if (!l.visible) 'visible': false,
          if (l.locked) 'locked': true,
          if (l.opacity != 255) 'opacity': l.opacity,
        },
    ],
    'frames': [
      for (final f in doc.frames) {'id': f.id, 'duration': f.durationMs},
    ],
    'tags': [
      for (final t in doc.tags)
        {
          'name': t.name,
          'from': t.from,
          'to': t.to,
          'direction': t.direction.name,
          if (!t.loop) 'loop': false,
          'color': Argb.toHex(t.color),
          if (t.events.isNotEmpty)
            'events': [
              for (final e in t.events) {'time': e.timeMs, 'name': e.name},
            ],
        },
    ],
    'cels': [
      for (final l in doc.layers)
        for (final f in doc.frames)
          if (doc.cel(l.id, f.id) case final cel? when !cel.isBlank)
            _celToJson(l.id, f.id, cel),
    ],
  };

  static Map<String, dynamic> _celToJson(
    int layer,
    int frame,
    PixelBuffer cel,
  ) {
    final r = cel.contentBounds;
    final part = cel.copyRect(r);
    // RGBA bytes rather than the buffer's own words, so a file reads the
    // same on any machine.
    final bytes = part.toRgbaBytes();
    return {
      'layer': layer,
      'frame': frame,
      'x': r.left,
      'y': r.top,
      'w': r.width,
      'h': r.height,
      'data': base64Encode(const ZlibCodec(level: 9).encode(bytes)),
    };
  }

  /// A cel's RGBA bytes: no more than [size] of them, so a damaged cel
  /// cannot unpack without end.
  static Uint8List _inflate(String data, int size) {
    try {
      return const ZlibCodec().decode(base64Decode(data), maxOutputSize: size);
    } on FormatException {
      throw const FormatException('A cel in this sprite is damaged.');
    }
  }

  /// Throws [FormatException] for a file that is not a jsprite, or is from
  /// a newer studio than this one.
  static SpriteDocument decode(String source) {
    final Object? json;
    try {
      json = jsonDecode(source);
    } on FormatException {
      throw const FormatException(
        'Not a sprite project: the file is not JSON.',
      );
    }
    if (json is! Map<String, dynamic> || json['format'] != 'jsprite') {
      throw const FormatException('Not a sprite project.');
    }
    return fromJson(json);
  }

  static SpriteDocument fromJson(Map<String, dynamic> json) {
    final version = (json['version'] as num?)?.toInt() ?? 0;
    if (version > formatVersion) {
      throw FormatException(
        'This sprite was saved by a newer studio (format v$version).',
      );
    }
    final width = (json['width'] as num?)?.toInt() ?? 0;
    final height = (json['height'] as num?)?.toInt() ?? 0;
    if (width <= 0 ||
        height <= 0 ||
        width > SpriteDocument.maxSize ||
        height > SpriteDocument.maxSize) {
      throw FormatException('A sprite cannot be $width × $height.');
    }
    final doc = SpriteDocument(width: width, height: height);
    var highest = 0;

    for (final raw in (json['layers'] as List?) ?? const []) {
      final l = (raw as Map).cast<String, dynamic>();
      final id = (l['id'] as num).toInt();
      if (id > highest) highest = id;
      doc.layers.add(
        SpriteLayer(
          id: id,
          name: l['name'] as String? ?? 'Layer',
          visible: l['visible'] as bool? ?? true,
          locked: l['locked'] as bool? ?? false,
          opacity: ((l['opacity'] as num?)?.toInt() ?? 255).clamp(0, 255),
        ),
      );
    }
    for (final raw in (json['frames'] as List?) ?? const []) {
      final f = (raw as Map).cast<String, dynamic>();
      final id = (f['id'] as num).toInt();
      if (id > highest) highest = id;
      doc.frames.add(
        SpriteFrame(
          id: id,
          durationMs: ((f['duration'] as num?)?.toInt() ?? 100).clamp(1, 65535),
        ),
      );
    }
    doc.reserveIds(highest);
    if (doc.layers.isEmpty) doc.addLayer(name: 'Layer 1');
    if (doc.frames.isEmpty) doc.addFrame();

    for (final raw in (json['palette'] as List?) ?? const []) {
      final c = raw is String ? Argb.parseHex(raw) : null;
      if (c != null) doc.palette.add(c);
    }
    final last = doc.frames.length - 1;
    for (final raw in (json['tags'] as List?) ?? const []) {
      final t = (raw as Map).cast<String, dynamic>();
      final from = ((t['from'] as num?)?.toInt() ?? 0).clamp(0, last);
      doc.tags.add(
        SpriteTag(
          name: t['name'] as String? ?? 'tag',
          from: from,
          to: ((t['to'] as num?)?.toInt() ?? from).clamp(from, last),
          direction:
              TagDirection.values.asNameMap()[t['direction']] ??
              TagDirection.forward,
          loop: t['loop'] as bool? ?? true,
          color: Argb.parseHex(t['color'] as String? ?? '') ?? 0xFF7DE6B1,
          events: [
            for (final e in (t['events'] as List?) ?? const [])
              if (e is Map)
                SpriteEvent(
                  timeMs: (e['time'] as num?)?.toInt() ?? 0,
                  name: e['name'] as String? ?? '',
                ),
          ],
        ),
      );
    }

    for (final raw in (json['cels'] as List?) ?? const []) {
      final c = (raw as Map).cast<String, dynamic>();
      final layer = (c['layer'] as num).toInt();
      final frame = (c['frame'] as num).toInt();
      if (doc.layerById(layer) == null || doc.frameIndex(frame) < 0) continue;
      final w = (c['w'] as num).toInt(), h = (c['h'] as num).toInt();
      final bytes = _inflate(c['data'] as String, w * h * 4);
      if (bytes.length != w * h * 4) {
        throw const FormatException('A cel in this sprite is damaged.');
      }
      final part = PixelBuffer.fromRgbaBytes(w, h, bytes);
      doc
          .ensureCel(layer, frame)
          .paste(part, (c['x'] as num).toInt(), (c['y'] as num).toInt());
    }
    if (json['export'] case final Map<String, dynamic> export) {
      doc.exportOptions = SheetExportOptions.fromJson(export);
    }
    doc.revision = 0;
    return doc;
  }
}
