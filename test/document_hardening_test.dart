// The document core against damaged files, sizes it cannot keep, and the
// shortcuts it takes to stay fast: each gives what the slow way gives.

import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_sprite_editor/document.dart';

const _red = 0xFFFF0000;
const _blue = 0xFF0000FF;

/// A small saved project, as JSON, to damage.
Map<String, dynamic> _project() {
  final doc = SpriteDocument.blank(4, 4);
  doc.ensureCel(doc.layers.first.id, doc.frames.first.id).set(1, 1, _red);
  return jsonDecode(JspriteCodec.encode(doc)) as Map<String, dynamic>;
}

Matcher _damaged(String says) => throwsA(
  isA<FormatException>().having((e) => e.message, 'message', contains(says)),
);

void main() {
  group('a damaged project', () {
    test('a value of the wrong type says the project is damaged', () {
      final breakages = <void Function(Map<String, dynamic>)>[
        (j) => (j['layers'] as List).first.remove('id'),
        (j) => (j['layers'] as List).first['name'] = 7,
        (j) => (j['layers'] as List).first['visible'] = 'yes',
        (j) => j['layers'] = {'a': 1},
        (j) => (j['frames'] as List).add('frame'),
        (j) => (j['cels'] as List).first.remove('w'),
        (j) => (j['cels'] as List).first['data'] = 12,
        (j) => j['version'] = 'one',
        (j) => j['export'] = {'trim': 'yes'},
      ];
      for (final (i, breakIt) in breakages.indexed) {
        final json = _project();
        breakIt(json);
        expect(
          () => JspriteCodec.decode(jsonEncode(json)),
          _damaged('damaged'),
          reason: 'breakage $i',
        );
      }
    });

    test('an id used twice, or out of range, is refused', () {
      final twice = _project();
      final layers = twice['layers'] as List;
      layers.add(Map.of(layers.first as Map));
      expect(
        () => JspriteCodec.decode(jsonEncode(twice)),
        _damaged('used twice'),
      );
      for (final id in [0, -3, SpriteDocument.idLimit]) {
        final json = _project();
        (json['frames'] as List).first['id'] = id;
        expect(
          () => JspriteCodec.decode(jsonEncode(json)),
          _damaged('out of range'),
          reason: '$id',
        );
      }
    });

    test('a cel outside the canvas is refused before it is unpacked', () {
      for (final change in <(String, int)>[
        ('x', -1),
        ('x', 4),
        ('w', 100000),
        ('h', 0),
        ('w', -1),
      ]) {
        final json = _project();
        (json['cels'] as List).first[change.$1] = change.$2;
        expect(
          () => JspriteCodec.decode(jsonEncode(json)),
          _damaged('A cel in this sprite is damaged'),
          reason: '$change',
        );
      }
    });

    test('a sprite too big to open again is never written', () {
      final doc = SpriteDocument(width: SpriteDocument.maxSize + 1, height: 2)
        ..addLayer()
        ..addFrame();
      expect(doc.fitsForSaving, isFalse);
      expect(() => JspriteCodec.encode(doc), throwsArgumentError);
    });
  });

  group('images in, sheets out', () {
    test('one image saved untouched is the same size, the same pixels', () {
      final image = PixelBuffer(5, 3)
        ..fill(_blue)
        ..set(0, 0, _red);
      final doc = SheetImporter.fromImage(image);
      final sheet = SheetExporter.export(
        doc,
        name: 'bg',
        imageFile: 'bg.png',
        options: doc.exportOptions,
      ).sheet;
      expect((sheet.width, sheet.height), (5, 3));
      expect(sheet.sameAs(image), isTrue);
    });

    test('an image too big to open says so; a big one opens to be sliced', () {
      const most = SpriteDocument.maxImportSize;
      expect(
        () => SheetImporter.checkImportSize(most + 1, 1),
        throwsFormatException,
      );
      final big = SheetImporter.fromImage(PixelBuffer(3000, 16));
      expect(big.fitsForSaving, isFalse);
    });

    test('a slice spacing or margin below zero is refused', () {
      final sheet = PixelBuffer(8, 8)..fill(_red);
      expect(
        () => SheetImporter.fromSheet(
          sheet,
          frameWidth: 4,
          frameHeight: 4,
          spacing: -4,
        ),
        throwsArgumentError,
      );
      expect(
        () => SheetImporter.fromSheet(
          sheet,
          frameWidth: 4,
          frameHeight: 4,
          margin: -1,
        ),
        throwsArgumentError,
      );
    });

    test('a sheet too big for a game to load is refused', () {
      final doc = SpriteDocument.blank(2048, 4);
      for (var i = 0; i < 8; i++) {
        doc.addFrame();
      }
      expect(
        () => SheetExporter.export(
          doc,
          name: 'wide',
          imageFile: 'wide.png',
          options: const SheetExportOptions(layout: SheetLayout.horizontal),
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '${e.message}',
            'message',
            contains('more than a game can load'),
          ),
        ),
      );
    });
  });

  group('the shortcuts give what the long way gives', () {
    test('one pixel of the picture is that pixel of the flattened frame', () {
      final random = Random(3);
      final doc = SpriteDocument.blank(6, 5);
      doc.addLayer();
      doc.addLayer();
      doc.layers[1].opacity = 140;
      doc.layers[2].visible = false;
      for (final l in doc.layers) {
        final cel = doc.ensureCel(l.id, doc.frames.first.id);
        for (var i = 0; i < 20; i++) {
          cel.set(
            random.nextInt(6),
            random.nextInt(5),
            random.nextInt(1 << 32),
          );
        }
      }
      final flat = doc.flatten(0);
      for (var y = -1; y <= 5; y++) {
        for (var x = -1; x <= 6; x++) {
          expect(doc.pixelAt(0, x, y), flat.get(x, y), reason: '($x, $y)');
        }
      }
    });

    test('pixel-perfect a point at a time is pixel-perfect all at once', () {
      final random = Random(11);
      for (var run = 0; run < 300; run++) {
        final path = <Pixel>[(x: 10, y: 10)];
        for (var i = 0; i < 2 + random.nextInt(40); i++) {
          final last = path.last;
          final next = (
            x: last.x + random.nextInt(5) - 2,
            y: last.y + random.nextInt(5) - 2,
          );
          if (next != last) {
            path.addAll(Raster.line(last.x, last.y, next.x, next.y).skip(1));
          }
        }
        final steps = PixelPerfectPath();
        for (final p in path) {
          steps.add(p);
        }
        expect(steps.points, Raster.pixelPerfect(path), reason: '$path');
      }
    });

    test("a selection's outline is its edge, in runs", () {
      final mask = SelectionMask.rect(8, 8, const IntRect(1, 2, 5, 4));
      expect(
        mask.outline,
        unorderedEquals([
          (1, 2, 5, 2),
          (1, 4, 5, 4),
          (1, 2, 1, 4),
          (5, 2, 5, 4),
        ]),
      );
      // An L: six edges.
      final l = SelectionMask(4, 4)
        ..set(0, 0, true)
        ..set(0, 1, true)
        ..set(1, 1, true);
      expect(l.outline, hasLength(6));
      l.set(1, 0, true);
      expect(l.outline, hasLength(4), reason: 'a square again');
    });

    test('a selection moved row by row is the selection moved', () {
      final mask = SelectionMask(6, 5)
        ..set(1, 1, true)
        ..set(2, 1, true)
        ..set(4, 3, true);
      for (final (dx, dy) in [(0, 0), (1, 1), (-2, 1), (3, -1), (9, 0)]) {
        final moved = mask.translated(dx, dy);
        for (var y = 0; y < 5; y++) {
          for (var x = 0; x < 6; x++) {
            expect(
              moved.contains(x, y),
              mask.contains(x - dx, y - dy),
              reason: '($dx, $dy) at ($x, $y)',
            );
          }
        }
      }
    });

    test('a stroke resets only what it is told to, and nothing once done', () {
      final doc = SpriteDocument.blank(4, 4);
      final editor = DocumentEditor(doc);
      final stroke = editor.beginStroke(
        'Pencil',
        doc.layers.first.id,
        doc.frames.first.id,
      )!;
      stroke.buffer
        ..set(0, 0, _red)
        ..set(3, 3, _red);
      stroke.reset(const IntRect(0, 0, 2, 2));
      expect(stroke.buffer.get(0, 0), 0);
      expect(stroke.buffer.get(3, 3), _red, reason: 'outside the area');
      expect(stroke.commit(), isTrue);
      expect(stroke.isDone, isTrue);
      stroke.reset();
      expect(stroke.buffer.get(3, 3), _red, reason: 'a done stroke is left');
    });
  });

  group('undo', () {
    test("a step weighs the cels only it keeps alive", () {
      final doc = SpriteDocument.blank(64, 64);
      final editor = DocumentEditor(doc, maxBytes: 64 * 64 * 4 * 3);
      for (var i = 0; i < 5; i++) {
        doc.addLayer();
      }
      for (final l in doc.layers) {
        doc.ensureCel(l.id, doc.frames.first.id).fill(_red);
      }
      // Each deleted layer's cel is the step's own, now: three are as much
      // as the budget holds.
      for (var i = 0; i < 5; i++) {
        editor.structural('Delete', (d) => d.removeLayer(d.layers.last.id));
      }
      var steps = 0;
      while (editor.undo()) {
        steps++;
      }
      expect(steps, lessThan(5));
      // A rename keeps nothing of its own.
      final light = SpriteDocument.blank(64, 64);
      light.ensureCel(light.layers.first.id, light.frames.first.id);
      final before = light.snapshot();
      light.layers.first.name = 'x';
      expect(StructureCommand('Rename', before, light.snapshot()).weight, 1024);
    });

    test('a sprite cut into frames in place is one step back', () {
      final doc = SpriteDocument.blank(8, 4);
      final editor = DocumentEditor(doc);
      final cel = doc.ensureCel(doc.layers.first.id, doc.frames.first.id)
        ..fill(_blue);
      final before = JspriteCodec.encode(doc);
      final sliced = SheetImporter.fromSheet(
        doc.flatten(0),
        frameWidth: 4,
        frameHeight: 4,
      );
      final usedIds = {
        for (final l in doc.layers) l.id,
        for (final f in doc.frames) f.id,
      };
      editor.structural('Slice', (d) => d.replaceWith(sliced));
      expect((doc.width, doc.frames.length), (4, 2));
      for (final f in doc.frames) {
        expect(usedIds.contains(f.id), isFalse, reason: 'ids are new');
      }
      expect(editor.isDirty, isTrue);
      editor.undo();
      expect(JspriteCodec.encode(doc), before);
      expect(doc.cel(doc.layers.first.id, doc.frames.first.id), same(cel));
    });
  });
}
