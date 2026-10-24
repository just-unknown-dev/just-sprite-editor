// What the studio writes, and what it will not write over: saving, the
// sheets it opens, slicing, and the history a stroke leaves.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_sprite_editor/document.dart';
import 'package:just_sprite_editor/src/studio/studio_canvas.dart';
import 'package:just_sprite_editor/src/studio/studio_files.dart';
import 'package:just_sprite_editor/src/studio/studio_library.dart';
import 'package:just_sprite_editor/src/studio/studio_session.dart';
import 'package:just_sprite_editor/src/studio/studio_tools.dart';

const _ink = 0xFF101010;

/// A PNG's width and height, from its header.
(int, int) _pngSize(List<int> bytes) {
  final view = ByteData.sublistView(Uint8List.fromList(bytes));
  return (view.getUint32(16), view.getUint32(20));
}

void main() {
  late String root;

  setUp(() {
    final dir = Directory.systemTemp.createTempSync('studio_saving');
    root = dir.path.replaceAll(r'\', '/');
    Directory('$root/assets/sprites').createSync(recursive: true);
    addTearDown(() => dir.deleteSync(recursive: true));
  });

  File file(String relative) => File('$root/$relative');

  Future<SpriteStudioSession> openImage(String path, PixelBuffer image) async {
    final s = await SpriteStudioSession.open(
      path,
      root: root,
      decodeImage: (_) async => image,
    );
    addTearDown(s.dispose);
    return s;
  }

  group('an image opened and saved', () {
    test('keeps its size, and an atlas already there is kept aside', () async {
      final image = PixelBuffer(5, 3)..fill(_ink);
      file(
        'assets/sprites/tiles.png',
      ).writeAsBytesSync(PngEncoder.encode(image));
      file('assets/sprites/tiles.json').writeAsStringSync('{"theirs":true}');
      final s = await openImage('assets/sprites/tiles.png', image);

      // Its own image is no news; an atlas some other tool wrote is.
      expect(await s.filesInTheWay(s.path!), ['assets/sprites/tiles.json']);

      final saved = await s.save();
      expect(saved.sheetProblem, isNull);
      expect(_pngSize(file('assets/sprites/tiles.png').readAsBytesSync()), (
        5,
        3,
      ), reason: 'no padding: a tile map using it still lines up');
      final atlas = jsonDecode(
        file('assets/sprites/tiles.json').readAsStringSync(),
      );
      expect(atlas['meta']['size'], {'w': 5, 'h': 3});
      expect(
        file('assets/sprites/tiles.original.json').readAsStringSync(),
        '{"theirs":true}',
      );
      expect(file('assets/sprites/tiles.original.png').existsSync(), isTrue);
      // Saved again, it is the sprite's own: nothing is in the way.
      expect(await s.filesInTheWay(s.path!), isEmpty);
    });

    test('a new sprite is in the way of anything of its name', () async {
      final s = SpriteStudioSession(SpriteDocument.blank(2, 2), root: root);
      addTearDown(s.dispose);
      for (final ext in const ['jsprite', 'png', 'json']) {
        file('assets/sprites/hero.$ext').writeAsStringSync('x');
      }
      expect(await s.filesInTheWay('assets/sprites/hero.jsprite'), [
        'assets/sprites/hero.jsprite',
        'assets/sprites/hero.png',
        'assets/sprites/hero.json',
      ]);
      expect(await s.filesInTheWay('assets/sprites/other.jsprite'), isEmpty);
      expect(
        freeStem('$root/assets/sprites', 'hero', const ['.jsprite']),
        'hero_2',
      );
    });
  });

  group('a sheet bigger than a sprite can be', () {
    test('opens, will not save, and saves once sliced', () async {
      final sheet = PixelBuffer(3000, 4)..fill(_ink);
      file('assets/sprites/big.png').writeAsBytesSync([0]);
      final s = await openImage('assets/sprites/big.png', sheet);
      expect(s.document.fitsForSaving, isFalse);
      expect(s.message.value, contains('Slice it into frames'));
      await expectLater(s.save(), throwsStateError);
      expect(file('assets/sprites/big.jsprite').existsSync(), isFalse);

      expect(s.sliceIntoFrames(1000, 4), 3);
      expect(s.document.fitsForSaving, isTrue);
      await s.save();
      final again = await SpriteStudioSession.open(
        'assets/sprites/big.jsprite',
        root: root,
        decodeImage: (_) async => fail('a project now'),
      );
      addTearDown(again.dispose);
      expect((again.document.width, again.document.frames.length), (1000, 3));
    });

    testWidgets('an image too big to open is refused from its header', (
      tester,
    ) async {
      final png = PngEncoder.encode(
        PixelBuffer(SpriteDocument.maxImportSize + 1, 1),
      );
      Object? error;
      await tester.runAsync(() async {
        try {
          await pixelsFromImageBytes(png);
        } catch (e) {
          error = e;
        }
      });
      expect(error, isA<FormatException>());
    });
  });

  group('slicing', () {
    test('is one step: undo brings the sprite back', () {
      final doc = SpriteDocument.blank(8, 4);
      final s = SpriteStudioSession(doc, root: root);
      addTearDown(s.dispose);
      doc.ensureCel(doc.layers.first.id, doc.frames.first.id).fill(_ink);
      final before = JspriteCodec.encode(doc);
      s.editor.markSaved();

      expect(s.sliceIntoFrames(4, 4), 2);
      expect(s.isDirty, isTrue, reason: 'there is something to save');
      expect(s.editor.undoLabel, 'Slice into frames');
      s.undo();
      expect(JspriteCodec.encode(s.document), before);
      expect(s.isDirty, isFalse);
    });
  });

  group('while a stroke is drawn', () {
    test('only the canvas hears of each move; the panels hear of the step', () {
      final s = SpriteStudioSession(SpriteDocument.blank(8, 8), root: root)
        ..primary.value = _ink;
      addTearDown(s.dispose);
      final structure = s.structureRevision.value;
      final pixels = s.revision.value;
      final pencil = PixelTools.of(StudioTool.pencil)
        ..down(s, 0, 0, ToolButton.primary)
        ..drag(s, 3, 0)
        ..drag(s, 3, 3);
      expect(s.revision.value, greaterThan(pixels));
      expect(s.structureRevision.value, structure);
      pencil.up(s);
      expect(s.structureRevision.value, greaterThan(structure));
      expect(s.celHasArt(s.layer.id, s.frame.id), isTrue);
      s.undo();
      expect(s.celHasArt(s.layer.id, s.frame.id), isFalse);
    });

    test('an undo in the middle ends it: what follows draws nothing', () {
      final s = SpriteStudioSession(SpriteDocument.blank(8, 8), root: root)
        ..primary.value = _ink;
      addTearDown(s.dispose);
      // Something there already, saved: the cel the strokes go into.
      PixelTools.of(StudioTool.pencil)
        ..down(s, 7, 0, ToolButton.primary)
        ..up(s);
      s.editor.markSaved();
      final was = s.document.cel(s.layer.id, s.frame.id)!.copy();
      for (final tool in [StudioTool.pencil, StudioTool.line]) {
        final t = PixelTools.of(tool)
          ..down(s, 0, 0, ToolButton.primary)
          ..drag(s, 4, 0);
        s.undo();
        t
          ..drag(s, 4, 4)
          ..drag(s, 7, 7)
          ..up(s);
        final cel = s.document.cel(s.layer.id, s.frame.id)!;
        expect(cel.sameAs(was), isTrue, reason: '$tool');
        expect(s.editor.undoLabel, 'Pencil', reason: 'only the first');
        expect(s.isDirty, isFalse);
      }
    });

    test('a save while drawing goes on leaves the sprite unsaved', () async {
      final s = SpriteStudioSession(
        SpriteDocument.blank(4, 4),
        root: root,
        path: 'assets/sprites/busy.jsprite',
      )..primary.value = _ink;
      addTearDown(s.dispose);
      final saving = s.save();
      PixelTools.of(StudioTool.pencil)
        ..down(s, 1, 1, ToolButton.primary)
        ..up(s);
      await saving;
      expect(s.isDirty, isTrue, reason: 'the file has not got that stroke');
    });
  });

  group('files', () {
    test('a file is written whole, over what was there', () async {
      final target = file('assets/sprites/a.json')..writeAsStringSync('old');
      await writeAtomically(target, utf8.encode('new'));
      expect(target.readAsStringSync(), 'new');
      expect(
        Directory('$root/assets/sprites').listSync().map((e) => e.path),
        hasLength(1),
        reason: 'nothing left beside it',
      );
    });

    test(
      'a sheet too big to load: the project is saved, and says so',
      () async {
        final doc = SpriteDocument.blank(2048, 2)
          ..exportOptions = const SheetExportOptions(
            layout: SheetLayout.horizontal,
          );
        for (var i = 0; i < 8; i++) {
          doc.addFrame();
        }
        final s = SpriteStudioSession(doc, root: root);
        addTearDown(s.dispose);
        final saved = await s.save(to: 'assets/sprites/wide.jsprite');
        expect(saved.sheetProblem, contains('more than a game can load'));
        expect(s.message.value, contains('but not its sheet'));
        expect(file('assets/sprites/wide.jsprite').existsSync(), isTrue);
        expect(file('assets/sprites/wide.png').existsSync(), isFalse);
        expect(s.isDirty, isFalse);
      },
    );

    test(
      "a GIF named after a tag is a file's name, whatever the tag",
      () async {
        final doc = SpriteDocument.blank(2, 2)..addFrame();
        doc.tags.add(SpriteTag(name: 'attack/heavy: 2', from: 0, to: 1));
        final s = SpriteStudioSession(
          doc,
          root: root,
          path: 'assets/sprites/hero.jsprite',
        );
        addTearDown(s.dispose);
        s.playTag.value = 'attack/heavy: 2';
        expect(await s.exportGif(), 'assets/sprites/hero_attack_heavy_2.gif');
        expect(
          file('assets/sprites/hero_attack_heavy_2.gif').existsSync(),
          isTrue,
        );
      },
    );

    test('an import is not opened as a project already there', () async {
      final elsewhere = Directory.systemTemp.createTempSync('elsewhere');
      addTearDown(() => elsewhere.deleteSync(recursive: true));
      File('${elsewhere.path}/hero.aseprite').writeAsStringSync('art');
      file('assets/sprites/hero.jsprite').writeAsStringSync('{}');
      final library = SpriteLibrary(root: root);
      expect(
        await library.import(
          '${elsewhere.path}/hero.aseprite',
          into: 'assets/sprites',
        ),
        'assets/sprites/hero_2.aseprite',
      );
    });

    test('the sprite list is found away from the UI thread', () async {
      file('assets/sprites/hero.jsprite').writeAsStringSync('{}');
      final found = await SpriteLibrary(root: root).scanInBackground();
      expect([for (final a in found) a.path], ['assets/sprites/hero.jsprite']);
    });
  });
}
