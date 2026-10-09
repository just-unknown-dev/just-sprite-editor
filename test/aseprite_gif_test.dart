// Art coming in from Aseprite, and animations going out as GIFs.

import 'dart:io' show ZLibEncoder;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:just_sprite_editor/document.dart';

/// Builds an Aseprite file from the published format, chunk by chunk — a
/// fixture that can say exactly what is in it.
class _Ase {
  _Ase(this.width, this.height, {this.depth = 32});

  final int width;
  final int height;
  final int depth;
  static const int transparentIndex = 0;
  final List<Uint8List> _frames = [];
  List<Uint8List> _chunks = [];

  static Uint8List _bytes(void Function(BytesBuilder b) write) {
    final b = BytesBuilder();
    write(b);
    return b.toBytes();
  }

  static List<int> u16(int v) => [v & 0xFF, (v >> 8) & 0xFF];
  static List<int> u32(int v) => [
    ...u16(v & 0xFFFF),
    ...u16((v >> 16) & 0xFFFF),
  ];
  static List<int> str(String s) => [...u16(s.length), ...s.codeUnits];

  void _chunk(int type, List<int> data) => _chunks.add(
    _bytes(
      (b) => b
        ..add(u32(data.length + 6))
        ..add(u16(type))
        ..add(data),
    ),
  );

  void layer(String name, {int flags = 1, int type = 0, int opacity = 255}) =>
      _chunk(0x2004, [
        ...u16(flags),
        ...u16(type),
        ...u16(0),
        ...u16(0),
        ...u16(0),
        ...u16(0), // blend: normal
        opacity,
        0, 0, 0,
        ...str(name),
      ]);

  List<int> _celHeader(int layer, int x, int y, int opacity, int type) => [
    ...u16(layer),
    ...u16(x & 0xFFFF),
    ...u16(y & 0xFFFF),
    opacity,
    ...u16(type),
    ...u16(0),
    0,
    0,
    0,
    0,
    0,
  ];

  void cel(
    int layer,
    int x,
    int y,
    int w,
    int h,
    List<int> pixels, {
    bool compressed = true,
    int opacity = 255,
  }) => _chunk(0x2005, [
    ..._celHeader(layer, x, y, opacity, compressed ? 2 : 0),
    ...u16(w),
    ...u16(h),
    ...(compressed ? ZLibEncoder().convert(pixels) : pixels),
  ]);

  void linkedCel(int layer, int toFrame) =>
      _chunk(0x2005, [..._celHeader(layer, 0, 0, 255, 1), ...u16(toFrame)]);

  void tags(List<(String, int, int, int, int)> tags) => _chunk(0x2018, [
    ...u16(tags.length),
    ...List.filled(8, 0),
    for (final (name, from, to, direction, repeat) in tags) ...[
      ...u16(from),
      ...u16(to),
      direction,
      ...u16(repeat),
      ...List.filled(6, 0),
      255,
      128,
      0,
      0,
      ...str(name),
    ],
  ]);

  void palette(List<int> argb) => _chunk(0x2019, [
    ...u32(argb.length),
    ...u32(0),
    ...u32(argb.length - 1),
    ...List.filled(8, 0),
    for (final c in argb) ...[
      ...u16(0),
      (c >> 16) & 0xFF,
      (c >> 8) & 0xFF,
      c & 0xFF,
      (c >> 24) & 0xFF,
    ],
  ]);

  void endFrame(int durationMs) {
    final body = _bytes((b) {
      for (final c in _chunks) {
        b.add(c);
      }
    });
    _frames.add(
      _bytes(
        (b) => b
          ..add(u32(body.length + 16))
          ..add(u16(0xF1FA))
          ..add(u16(_chunks.length))
          ..add(u16(durationMs))
          ..add([0, 0])
          ..add(u32(_chunks.length))
          ..add(body),
      ),
    );
    _chunks = [];
  }

  Uint8List build() {
    final frames = _bytes((b) {
      for (final f in _frames) {
        b.add(f);
      }
    });
    final header = _bytes(
      (b) => b
        ..add(u32(128 + frames.length))
        ..add(u16(0xA5E0))
        ..add(u16(_frames.length))
        ..add(u16(width))
        ..add(u16(height))
        ..add(u16(depth))
        ..add(u32(1)) // layer opacity is valid
        ..add(u16(100))
        ..add(List.filled(8, 0))
        ..addByte(transparentIndex)
        ..add(List.filled(3, 0))
        ..add(u16(0)),
    );
    return _bytes(
      (b) => b
        ..add(header)
        ..add(List.filled(128 - header.length, 0))
        ..add(frames),
    );
  }
}

List<int> _rgba(List<int> argb) => [
  for (final c in argb) ...[
    (c >> 16) & 0xFF,
    (c >> 8) & 0xFF,
    c & 0xFF,
    (c >> 24) & 0xFF,
  ],
];

const _red = 0xFFFF0000;
const _blue = 0xFF0000FF;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('.aseprite', () {
    test('layers, cels (raw, compressed, linked), durations and tags', () {
      final file = _Ase(4, 3)
        ..layer('Body')
        ..layer('Group', type: 1)
        ..layer('Shade', flags: 0, opacity: 128)
        ..tags([('idle', 0, 1, 2, 0), ('hit', 2, 2, 0, 1)])
        ..cel(0, 1, 1, 2, 1, _rgba([_red, _blue]))
        ..endFrame(120)
        ..linkedCel(0, 0)
        ..cel(2, 0, 0, 1, 1, _rgba([_blue]), compressed: false, opacity: 128)
        ..endFrame(80)
        ..cel(0, -1, 0, 2, 1, _rgba([_red, _blue]))
        ..endFrame(0);

      final (doc, warnings) = AsepriteImporter.import(file.build());
      expect((doc.width, doc.height), (4, 3));
      expect([for (final l in doc.layers) l.name], ['Body', 'Shade']);
      expect(doc.layers[1].visible, isFalse);
      expect(doc.layers[1].opacity, 128);
      expect([for (final f in doc.frames) f.durationMs], [120, 80, 100]);
      expect(warnings.join(), contains('groups'));

      final body = doc.layers[0].id, shade = doc.layers[1].id;
      final first = doc.cel(body, doc.frames[0].id)!;
      expect((first.get(1, 1), first.get(2, 1)), (_red, _blue));
      // The linked cel is the same picture, its own copy.
      expect(doc.cel(body, doc.frames[1].id)!.sameAs(first), isTrue);
      // The cel's opacity is folded into its pixels; layer index 2 in the
      // file is layer 1 here, the group being gone.
      expect(doc.cel(shade, doc.frames[1].id)!.get(0, 0), 0x800000FF);
      // A cel hanging off the canvas is clipped, not refused.
      expect(doc.cel(body, doc.frames[2].id)!.get(0, 0), _blue);

      expect(doc.tags.map((t) => (t.name, t.from, t.to, t.direction, t.loop)), [
        ('idle', 0, 1, TagDirection.pingpong, true),
        ('hit', 2, 2, TagDirection.forward, false),
      ]);
      expect(doc.tags.first.color, 0xFFFF8000);
    });

    test('an indexed sprite becomes RGBA through its palette', () {
      final file = _Ase(2, 1, depth: 8)
        ..palette([0x00000000, _red, _blue])
        ..layer('Layer')
        ..cel(0, 0, 0, 2, 1, [1, 0])
        ..endFrame(100);
      final (doc, warnings) = AsepriteImporter.import(file.build());
      final cel = doc.cel(doc.layers.single.id, doc.frames.single.id)!;
      expect((cel.get(0, 0), cel.get(1, 0)), (_red, Argb.transparent));
      expect(doc.palette, [
        _red,
        _blue,
      ], reason: 'the see-through entry is not one');
      expect(warnings.join(), contains('Indexed'));
    });

    test('what is not an Aseprite file says so', () {
      expect(() => AsepriteImporter.import([1, 2, 3]), throwsFormatException);
      expect(
        () => AsepriteImporter.import(Uint8List(200)),
        throwsFormatException,
      );
    });

    // The fixtures compress with dart:io, which is zlib itself, so every
    // compressed cel above was also a check that real zlib data reads.
    group('a compressed cel', () {
      Uint8List file(List<int> pixels) =>
          (_Ase(2, 1)
                ..layer('Layer')
                ..cel(0, 0, 0, 2, 1, pixels)
                ..endFrame(100))
              .build();
      final damaged = throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          'A cel in this file is damaged.',
        ),
      );

      test('with a broken checksum says it is damaged', () {
        // The cel is the file's last chunk, so its zlib checksum ends it.
        final bytes = file(_rgba([_red, _blue]));
        bytes[bytes.length - 1] ^= 1;
        expect(() => AsepriteImporter.import(bytes), damaged);
      });

      test('that unpacks to more than its size says it is damaged', () {
        final bytes = file(_rgba([_red, _blue, _red]));
        expect(() => AsepriteImporter.import(bytes), damaged);
      });
    });
  });

  group('GIF', () {
    Future<List<(PixelBuffer, int)>> decode(
      WidgetTester tester,
      Uint8List gif,
    ) async {
      final out = <(PixelBuffer, int)>[];
      await tester.runAsync(() async {
        final codec = await ui.instantiateImageCodec(gif);
        for (var i = 0; i < codec.frameCount; i++) {
          final frame = await codec.getNextFrame();
          final data = await frame.image.toByteData(
            format: ui.ImageByteFormat.rawStraightRgba,
          );
          out.add((
            PixelBuffer.fromRgbaBytes(
              frame.image.width,
              frame.image.height,
              data!.buffer.asUint8List(),
            ),
            frame.duration.inMilliseconds,
          ));
        }
      });
      return out;
    }

    testWidgets('a real decoder reads back the frames, timing and '
        'transparency', (tester) async {
      final doc = SpriteDocument.blank(5, 4);
      final l = doc.layers.first.id;
      doc.ensureCel(l, doc.frames.first.id)
        ..set(0, 0, _red)
        ..set(4, 3, _blue);
      final second = doc.addFrame(durationMs: 250);
      doc.ensureCel(l, second.id).fill(0xFF00FF00);
      doc.ensureCel(l, second.id).set(2, 2, Argb.transparent);

      final gif = GifEncoder.encodeDocument(doc);
      expect(String.fromCharCodes(gif.sublist(0, 6)), 'GIF89a');
      final frames = await decode(tester, gif);
      expect(frames, hasLength(2));
      expect([for (final f in frames) f.$2], [100, 250]);
      expect(frames[0].$1.get(0, 0), _red);
      expect(frames[0].$1.get(4, 3), _blue);
      expect(Argb.alpha(frames[0].$1.get(1, 1)), 0);
      expect(frames[1].$1.get(0, 0), 0xFF00FF00);
      expect(
        Argb.alpha(frames[1].$1.get(2, 2)),
        0,
        reason: 'not frame one showing through',
      );
    });

    testWidgets('many colours and a long image survive the LZW table '
        'filling up', (tester) async {
      // 64 × 64 of noise-like colour (128 colours, within GIF's 255): far
      // more strings than 4096 codes.
      final image = PixelBuffer(64, 64);
      for (var i = 0; i < image.pixels.length; i++) {
        final v = (i * 2654435761) & 0xFFFFFF;
        image.pixels[i] =
            0xFF000000 |
            ((v >> 16) & 0xE0) << 16 |
            ((v >> 8) & 0xE0) << 8 |
            (v & 0x80);
      }
      final frames = await decode(tester, GifEncoder.encode([image], [100]));
      expect(frames.single.$1.sameAs(image), isTrue);
    });

    testWidgets('a tag exports in its playing order, scaled', (tester) async {
      final doc = SpriteDocument.blank(2, 2);
      final l = doc.layers.first.id;
      for (var i = 0; i < 2; i++) {
        doc.addFrame();
      }
      for (var i = 0; i < 3; i++) {
        doc
            .ensureCel(l, doc.frames[i].id)
            .fill(0xFF000000 | (40 * (i + 1)) << 16);
      }
      final tag = SpriteTag(
        name: 't',
        from: 0,
        to: 2,
        direction: TagDirection.pingpong,
      );
      final frames = await decode(
        tester,
        GifEncoder.encodeDocument(doc, tag: tag, scale: 3),
      );
      expect(frames, hasLength(4));
      expect(frames.first.$1.width, 6);
      expect(
        [for (final f in frames) Argb.red(f.$1.get(0, 0))],
        [40, 80, 120, 80],
      );
    });
  });
}
