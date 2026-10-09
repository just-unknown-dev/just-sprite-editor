// The sprite document core: pixels, undo, drawing, and the files it writes.

import 'dart:convert';
import 'dart:io' as io;
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_deflate/just_deflate.dart';
import 'package:just_sprite_editor/document.dart';

const _red = 0xFFFF0000;
const _blue = 0xFF0000FF;

/// A buffer drawn as text: `#` for any pixel with alpha, `.` for none.
String _art(PixelBuffer b) => [
  for (var y = 0; y < b.height; y++)
    [
      for (var x = 0; x < b.width; x++) b.get(x, y) >> 24 == 0 ? '.' : '#',
    ].join(),
].join('\n');

PixelBuffer _draw(int w, int h, List<Pixel> points) {
  final b = PixelBuffer(w, h);
  Raster.stamp(b, points, Raster.brush(1), _red);
  return b;
}

void main() {
  group('pixels', () {
    test('reads outside are transparent and writes outside are ignored', () {
      final b = PixelBuffer(2, 2)
        ..set(5, 5, _red)
        ..set(-1, 0, _red);
      expect(b.isBlank, isTrue);
      expect(b.get(9, 9), 0);
    });

    test('composite blends by alpha and layer opacity', () {
      final under = PixelBuffer(1, 1)..fill(_blue);
      final over = PixelBuffer(1, 1)..fill(0x80FF0000);
      under.composite(over, 0, 0);
      expect(Argb.alpha(under.get(0, 0)), 255);
      expect(Argb.red(under.get(0, 0)), closeTo(128, 1));
      expect(Argb.blue(under.get(0, 0)), closeTo(127, 1));

      final clear = PixelBuffer(1, 1)..composite(over, 0, 0, opacity: 128);
      expect(Argb.alpha(clear.get(0, 0)), closeTo(64, 1));
      expect(Argb.red(clear.get(0, 0)), 255, reason: 'colour is not darkened');
    });

    test('flip, rotate and content bounds', () {
      final b = PixelBuffer(3, 2)..set(0, 0, _red);
      expect(_art(b.flippedHorizontally()), '..#\n...');
      expect(_art(b.flippedVertically()), '...\n#..');
      expect(_art(b.rotated90()), '.#\n..\n..');
      expect(_art(b.rotated90(clockwise: false)), '..\n..\n#.');
      expect(b.contentBounds, const IntRect(0, 0, 1, 1));
      expect(PixelBuffer(4, 4).contentBounds.isEmpty, isTrue);
    });

    test('hex colours', () {
      expect(Argb.parseHex('#ff8000'), 0xFFFF8000);
      expect(Argb.parseHex('80FF8000'), 0x80FF8000);
      expect(Argb.parseHex('f80'), 0xFFFF8800);
      expect(Argb.parseHex('nope'), isNull);
      expect(Argb.toHex(0xFFFF8000), '#FF8000');
      expect(Argb.toHex(0x80FF8000), '#80FF8000');
    });
  });

  group('drawing', () {
    test('a line includes both ends and has no gaps', () {
      final l = Raster.line(0, 0, 4, 2);
      expect(l.first, (x: 0, y: 0));
      expect(l.last, (x: 4, y: 2));
      for (var i = 1; i < l.length; i++) {
        expect((l[i].x - l[i - 1].x).abs() <= 1, isTrue);
        expect((l[i].y - l[i - 1].y).abs() <= 1, isTrue);
      }
    });

    test('pixel-perfect drops the corner of an L', () {
      final path = [(x: 0, y: 0), (x: 1, y: 0), (x: 1, y: 1), (x: 2, y: 1)];
      expect(Raster.pixelPerfect(path), [
        (x: 0, y: 0),
        (x: 1, y: 1),
        (x: 2, y: 1),
      ]);
      // A straight run is left alone.
      final straight = Raster.line(0, 0, 5, 0);
      expect(Raster.pixelPerfect(straight), straight);
    });

    test('rectangle and ellipse, outline and filled', () {
      expect(
        _art(_draw(4, 3, Raster.rectangle(3, 2, 0, 0))),
        '####\n#..#\n####',
      );
      expect(
        _art(_draw(5, 5, Raster.ellipse(0, 0, 4, 4))),
        '.###.\n#...#\n#...#\n#...#\n.###.',
      );
      // An even box is symmetric too.
      final even = _draw(6, 6, Raster.ellipse(0, 0, 5, 5, filled: true));
      expect(even.sameAs(even.flippedHorizontally()), isTrue);
      expect(even.sameAs(even.flippedVertically()), isTrue);
    });

    test('brush sizes', () {
      expect(Raster.brush(1), hasLength(1));
      expect(Raster.brush(2), hasLength(4));
      final five = _draw(5, 5, [
        for (final p in Raster.brush(5)) (x: p.x + 2, y: p.y + 2),
      ]);
      expect(_art(five), '.###.\n#####\n#####\n#####\n.###.');
    });

    test('symmetry mirrors across the canvas', () {
      final pts = Raster.mirrored([(x: 0, y: 0)], Symmetry.both, 4, 3);
      expect(pts.toSet(), {
        (x: 0, y: 0),
        (x: 3, y: 0),
        (x: 0, y: 2),
        (x: 3, y: 2),
      });
    });

    test('fill stays inside its region; global fill does not', () {
      // A wall down the middle.
      final b = _draw(5, 3, Raster.line(2, 0, 2, 2));
      expect(Raster.fill(b, 0, 0, _blue), 6);
      expect(b.get(4, 1), 0, reason: 'the far side is untouched');
      expect(Raster.fill(b, 0, 0, _blue), 0, reason: 'already that colour');

      final g = _draw(5, 3, Raster.line(2, 0, 2, 2));
      expect(Raster.fill(g, 0, 0, _blue, contiguous: false), 12);
    });

    test('a selection limits what a tool can touch', () {
      final mask = SelectionMask.rect(4, 4, const IntRect(1, 1, 3, 3));
      final b = PixelBuffer(4, 4);
      Raster.fill(b, 1, 1, _red, mask: mask);
      expect(_art(b), '....\n.##.\n.##.\n....');
      expect(Raster.fill(b, 0, 0, _red, mask: mask), 0, reason: 'outside');

      final lifted = mask.lift(b);
      expect(lifted.width, 2);
      mask.clearIn(b);
      expect(b.isBlank, isTrue);
      expect(mask.translated(1, 0).bounds, const IntRect(2, 1, 4, 3));
    });

    test('replace colour', () {
      final b = PixelBuffer(2, 1)
        ..set(0, 0, _red)
        ..set(1, 0, _blue);
      expect(Raster.replaceColor(b, _red, _blue), 1);
      expect(b.get(0, 0), _blue);
    });
  });

  group('the document', () {
    test('a blank sprite has a layer and a frame, and they cannot both go', () {
      final doc = SpriteDocument.blank(8, 8);
      expect(doc.layers, hasLength(1));
      expect(doc.frames, hasLength(1));
      expect(doc.removeLayer(doc.layers.first.id), isFalse);
      expect(doc.removeFrame(0), isFalse);
    });

    test('flatten draws visible layers bottom to top with their opacity', () {
      final doc = SpriteDocument.blank(1, 1);
      final bottom = doc.layers.first;
      final top = doc.addLayer();
      final f = doc.frames.first.id;
      doc.ensureCel(bottom.id, f).fill(_blue);
      doc.ensureCel(top.id, f).fill(_red);
      expect(doc.flatten(0).get(0, 0), _red);
      top.visible = false;
      expect(doc.flatten(0).get(0, 0), _blue);
      top
        ..visible = true
        ..opacity = 0;
      expect(doc.flatten(0).get(0, 0), _blue);
    });

    test('tags follow frames being added and removed', () {
      final doc = SpriteDocument.blank(2, 2);
      for (var i = 0; i < 4; i++) {
        doc.addFrame();
      }
      doc.tags.add(SpriteTag(name: 'run', from: 2, to: 3));
      doc.addFrame(after: 0);
      expect((doc.tags.single.from, doc.tags.single.to), (3, 4));
      doc.addFrame(after: 3); // inside the tag: it grows
      expect((doc.tags.single.from, doc.tags.single.to), (3, 5));
      doc.removeFrame(0);
      expect((doc.tags.single.from, doc.tags.single.to), (2, 4));
      doc
        ..removeFrame(2)
        ..removeFrame(2)
        ..removeFrame(2);
      expect(doc.tags, isEmpty, reason: 'a tag with no frames left goes');
    });

    test('ping-pong order matches what the engine plays', () {
      final tag = SpriteTag(
        name: 't',
        from: 1,
        to: 3,
        direction: TagDirection.pingpong,
      );
      expect(tag.playOrder, [1, 2, 3, 2]);
      tag.to = 2;
      expect(tag.playOrder, [1, 2]);
    });

    test('duplicate frame and layer copy the pixels, not share them', () {
      final doc = SpriteDocument.blank(2, 2);
      final l = doc.layers.first.id;
      doc.ensureCel(l, doc.frames.first.id).set(0, 0, _red);
      final copy = doc.duplicateFrame(0)!;
      doc.cel(l, copy.id)!.set(1, 1, _blue);
      expect(doc.cel(l, doc.frames.first.id)!.get(1, 1), 0);
      expect(doc.duplicateLayer(l)!.name, 'Layer 1 copy');
    });

    test('merge down, canvas resize, crop and rotate', () {
      final doc = SpriteDocument.blank(2, 2);
      final f = doc.frames.first.id;
      final top = doc.addLayer();
      doc.ensureCel(doc.layers.first.id, f).set(0, 0, _blue);
      doc.ensureCel(top.id, f).set(1, 1, _red);
      expect(doc.mergeDown(top.id), isTrue);
      expect(doc.layers, hasLength(1));
      expect(_art(doc.flatten(0)), '#.\n.#');

      doc.resizeCanvas(4, 3, dx: 1, dy: 1);
      expect(_art(doc.flatten(0)), '....\n.#..\n..#.');
      doc.cropTo(const IntRect(1, 1, 3, 3));
      expect((doc.width, doc.height), (2, 2));
      doc.resizeCanvas(3, 2);
      doc.rotateCanvas();
      expect((doc.width, doc.height), (2, 3));
    });
  });

  group('undo', () {
    test('a stroke is one step, and keeps only the rectangle it touched', () {
      final doc = SpriteDocument.blank(64, 64);
      final editor = DocumentEditor(doc);
      final l = doc.layers.first.id, f = doc.frames.first.id;
      final stroke = editor.beginStroke('Pencil', l, f)!;
      Raster.stamp(
        stroke.buffer,
        Raster.line(10, 10, 12, 11),
        Raster.brush(1),
        _red,
      );
      expect(stroke.commit(), isTrue);
      expect(editor.undoLabel, 'Pencil');
      expect(editor.isDirty, isTrue);

      expect(editor.undo(), isTrue);
      expect(doc.cel(l, f), isNull, reason: 'the cel it made is gone again');
      expect(editor.redo(), isTrue);
      expect(doc.cel(l, f)!.get(12, 11), _red);
    });

    test(
      'a stroke that changes nothing is not a step; cancel puts it back',
      () {
        final doc = SpriteDocument.blank(4, 4);
        final editor = DocumentEditor(doc);
        final l = doc.layers.first.id, f = doc.frames.first.id;
        expect(editor.beginStroke('Nothing', l, f)!.commit(), isFalse);
        expect(editor.canUndo, isFalse);
        expect(doc.celCount, 0);

        doc.ensureCel(l, f).set(0, 0, _blue);
        final s = editor.beginStroke('Oops', l, f)!;
        s.buffer.fill(_red);
        s.cancel();
        expect(doc.cel(l, f)!.get(0, 0), _blue);
        expect(doc.cel(l, f)!.get(1, 1), 0);
      },
    );

    test('a locked layer cannot be drawn on', () {
      final doc = SpriteDocument.blank(4, 4);
      doc.layers.first.locked = true;
      expect(
        DocumentEditor(
          doc,
        ).beginStroke('x', doc.layers.first.id, doc.frames.first.id),
        isNull,
      );
    });

    test('structural steps undo, pixels and all', () {
      final doc = SpriteDocument.blank(4, 4);
      final editor = DocumentEditor(doc);
      final l = doc.layers.first.id, f = doc.frames.first.id;
      final s = editor.beginStroke('Dot', l, f)!;
      s.buffer.set(3, 3, _red);
      s.commit();

      editor.structural('Crop', (d) => d.cropTo(const IntRect(2, 2, 4, 4)));
      expect(doc.width, 2);
      editor.structural('Add frame', (d) => d.addFrame());
      expect(doc.frames, hasLength(2));

      editor
        ..undo()
        ..undo();
      expect((doc.width, doc.frames.length), (4, 1));
      expect(doc.cel(l, f)!.get(3, 3), _red);
      editor.undo();
      expect(doc.cel(l, f), isNull);
      expect(editor.isDirty, isFalse, reason: 'back where it was saved');
    });

    test('saved point: dirty again after a new branch', () {
      final doc = SpriteDocument.blank(4, 4);
      final editor = DocumentEditor(doc);
      editor.structural('A', (d) => d.addFrame());
      editor.markSaved();
      expect(editor.isDirty, isFalse);
      editor.undo();
      expect(editor.isDirty, isTrue);
      editor.structural('B', (d) => d.addLayer());
      editor.undo();
      expect(editor.isDirty, isTrue, reason: 'the saved state is unreachable');
    });

    test('a thousand random edits undo back to the start, byte for byte', () {
      final random = Random(7);
      final doc = SpriteDocument.blank(16, 12);
      final editor = DocumentEditor(doc, maxSteps: 5000);
      String fingerprint() => JspriteCodec.encode(doc);
      final start = fingerprint();

      for (var i = 0; i < 1000; i++) {
        final layer = doc.layers[random.nextInt(doc.layers.length)];
        final frame = doc.frames[random.nextInt(doc.frames.length)];
        switch (random.nextInt(10)) {
          case 0:
            editor.structural('layer', (d) => d.addLayer());
          case 1:
            editor.structural(
              'frame',
              (d) => d.duplicateFrame(d.frames.length - 1),
            );
          case 2:
            editor.structural('rm frame', (d) => d.removeFrame(0));
          case 3:
            editor.structural('flip', (d) => d.flipCanvas(horizontal: true));
          case 4:
            editor.structural('merge', (d) => d.mergeDown(d.layers.last.id));
          case 5:
            if (editor.canUndo && random.nextBool()) {
              editor.undo();
              editor.redo();
            }
          default:
            final s = editor.beginStroke('draw', layer.id, frame.id);
            if (s == null) continue;
            Raster.stamp(
              s.buffer,
              Raster.line(
                random.nextInt(16),
                random.nextInt(12),
                random.nextInt(16),
                random.nextInt(12),
              ),
              Raster.brush(1 + random.nextInt(3)),
              random.nextBool() ? _red : Argb.transparent,
            );
            s.commit();
        }
      }
      final end = fingerprint();
      while (editor.undo()) {}
      expect(fingerprint(), start);
      while (editor.redo()) {}
      expect(fingerprint(), end);
    });
  });

  group('files', () {
    SpriteDocument sample() {
      final doc = SpriteDocument.blank(8, 8, palette: Palettes.pico8.colors);
      final l = doc.layers.first.id;
      doc.layers.first.name = 'Body';
      final shade = doc.addLayer(name: 'Shade')
        ..opacity = 128
        ..locked = true;
      doc.ensureCel(l, doc.frames.first.id).set(2, 3, _red);
      final f2 = doc.addFrame(durationMs: 250);
      doc.ensureCel(l, f2.id).set(5, 5, 0x80112233);
      doc.ensureCel(shade.id, f2.id); // blank: not worth saving
      doc.tags.add(
        SpriteTag(
          name: 'idle',
          from: 0,
          to: 1,
          direction: TagDirection.pingpong,
          loop: false,
          events: [const SpriteEvent(timeMs: 120, name: 'blink')],
        ),
      );
      return doc;
    }

    test('a project round-trips: layers, cels, tags, palette', () {
      final doc = sample();
      final back = JspriteCodec.decode(JspriteCodec.encode(doc));
      expect(JspriteCodec.encode(back), JspriteCodec.encode(doc));
      expect(back.layers[1].opacity, 128);
      expect(back.layers[1].locked, isTrue);
      expect(back.frames[1].durationMs, 250);
      expect(
        back.cel(back.layers.first.id, back.frames[1].id)!.get(5, 5),
        0x80112233,
      );
      expect(back.celCount, 2, reason: 'the blank cel was dropped');
      expect(back.tags.single.events.single.name, 'blink');
      expect(back.palette, Palettes.pico8.colors);
      // New ids do not collide with loaded ones.
      final ids = {
        for (final l in back.layers) l.id,
        for (final f in back.frames) f.id,
      };
      expect(ids.contains(back.addLayer().id), isFalse);
    });

    test('what is not a project says so', () {
      expect(() => JspriteCodec.decode('hello'), throwsFormatException);
      expect(
        () => JspriteCodec.decode('{"format":"other"}'),
        throwsFormatException,
      );
      expect(
        () => JspriteCodec.decode(
          '{"format":"jsprite","version":99,"width":1,"height":1}',
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('newer'),
          ),
        ),
      );
    });

    test('a project saved with dart:io\'s zlib still reads', () {
      // Cels written before the switch to just_deflate: zlib itself.
      final doc = sample();
      final json = JspriteCodec.toJson(doc);
      for (final cel in json['cels'] as List) {
        final c = cel as Map<String, dynamic>;
        final rgba = const ZlibCodec().decode(base64Decode(c['data']));
        c['data'] = base64Encode(io.ZLibEncoder(level: 9).convert(rgba));
      }
      final back = JspriteCodec.decode(jsonEncode(json));
      expect(JspriteCodec.encode(back), JspriteCodec.encode(doc));
    });

    test('a damaged cel says so', () {
      String withCel(List<int> zlib) {
        final json = JspriteCodec.toJson(sample());
        ((json['cels'] as List).first as Map)['data'] = base64Encode(zlib);
        return jsonEncode(json);
      }

      final damaged = throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          'A cel in this sprite is damaged.',
        ),
      );
      final cel = const ZlibCodec().encode(Uint8List(8 * 8 * 4));
      // A broken checksum, and more pixels than the cel holds.
      expect(() => JspriteCodec.decode(withCel([...cel]..last ^= 1)), damaged);
      expect(
        () => JspriteCodec.decode(
          withCel(const ZlibCodec().encode(Uint8List(8 * 8 * 4 + 4))),
        ),
        damaged,
      );
    });

    test(
      'the sheet JSON is Aseprite-shaped, with the extras under meta.just',
      () {
        final export = SheetExporter.export(
          sample(),
          name: 'hero',
          imageFile: 'hero.png',
          options: const SheetExportOptions(layout: SheetLayout.horizontal),
        );
        expect((export.sheet.width, export.sheet.height), (16, 8));
        expect(
          export.sheet.get(8 + 5, 5),
          0x80112233,
          reason: 'frame 2, second cell',
        );

        final meta = export.json['meta'] as Map;
        expect('${meta['app']}'.toLowerCase(), contains('aseprite'));
        expect(meta['image'], 'hero.png');
        expect(
          (meta['frameTags'] as List).single,
          containsPair('direction', 'pingpong'),
        );
        expect(meta['just'], {
          'clips': {
            'idle': {'loop': false},
          },
          'events': {
            'idle': [
              {'time': 0.12, 'name': 'blink'},
            ],
          },
        });
        final frames = export.json['frames'] as Map;
        expect(frames.keys, ['hero 0', 'hero 1']);
        expect((frames['hero 1'] as Map)['duration'], 250);
      },
    );

    test('trim cuts each frame to its content and remembers where it sat', () {
      final export = SheetExporter.export(
        sample(),
        name: 'hero',
        imageFile: 'hero.png',
        options: const SheetExportOptions(trim: true, padding: 1),
      );
      final first = (export.json['frames'] as Map)['hero 0'] as Map;
      expect(first['trimmed'], isTrue);
      expect(first['frame'], {'x': 1, 'y': 1, 'w': 1, 'h': 1});
      expect(first['spriteSourceSize'], {'x': 2, 'y': 3, 'w': 1, 'h': 1});
      expect(first['sourceSize'], {'w': 8, 'h': 8});
    });

    test('the PNG is a valid one', () {
      final png = PngEncoder.encode(sample().flatten(0));
      expect(png.sublist(0, 8), [137, 80, 78, 71, 13, 10, 26, 10]);
      expect(String.fromCharCodes(png.sublist(12, 16)), 'IHDR');
      expect(
        String.fromCharCodes(png.sublist(png.length - 8, png.length - 4)),
        'IEND',
      );
      expect(Crc32.of('123456789'.codeUnits), 0xCBF43926);
    });

    test('the PNG holds the pixels, and every chunk\'s CRC is right', () {
      final image = PixelBuffer(3, 2)
        ..set(0, 0, _red)
        ..set(2, 1, _blue);
      final png = PngEncoder.encode(image);
      final view = ByteData.sublistView(png);
      final idat = <int>[];
      for (var at = 8; at < png.length;) {
        final length = view.getUint32(at);
        final typeAndData = Uint8List.sublistView(png, at + 4, at + 8 + length);
        expect(view.getUint32(at + 8 + length), crc32(typeAndData));
        if (String.fromCharCodes(typeAndData.sublist(0, 4)) == 'IDAT') {
          idat.addAll(typeAndData.sublist(4));
        }
        at += 12 + length;
      }
      // Each row: filter byte 0, then RGBA.
      final rows = [
        [0, 255, 0, 0, 255, 0, 0, 0, 0, 0, 0, 0, 0],
        [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 255],
      ];
      expect(const ZlibCodec().decode(idat), [...rows[0], ...rows[1]]);
      expect(io.ZLibCodec().decode(idat), [...rows[0], ...rows[1]]);
    });

    test('a sheet is cut into frames, skipping empty cells', () {
      final sheet = PixelBuffer(8, 4)
        ..set(0, 0, _red)
        ..set(4, 0, _blue)
        ..set(0, 2, _red);
      final doc = SheetImporter.fromSheet(sheet, frameWidth: 4, frameHeight: 2);
      expect(doc.frames, hasLength(3));
      expect((doc.width, doc.height), (4, 2));
      expect(doc.flatten(1).get(0, 0), _blue);
      expect(SheetImporter.fromImage(sheet).frames, hasLength(1));
    });

    test('palette files: GPL, JASC and hex lists', () {
      const gpl =
          'GIMP Palette\nName: x\nColumns: 2\n# c\n255 0 0\tred\n  0 0 255 blue\n';
      expect(Palettes.parse(gpl), [_red, _blue]);
      expect(Palettes.parse('JASC-PAL\n0100\n2\n255 0 0\n0 0 255\n'), [
        _red,
        _blue,
      ]);
      expect(Palettes.parse('ff0000\n#0000FF\nff0000\n'), [_red, _blue]);
      expect(Palettes.parse(Palettes.toGpl('p', [_red, _blue])), [_red, _blue]);
      expect(Palettes.parse('not a palette'), isEmpty);
    });
  });
}
