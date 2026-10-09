// The studio without its widgets: tools drawing through a session, and the
// files a save leaves behind.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_sprite_editor/document.dart';
import 'package:just_sprite_editor/src/studio/studio_session.dart';
import 'package:just_sprite_editor/src/studio/studio_tools.dart';

const _ink = 0xFF101010;

String _art(PixelBuffer b) => [
  for (var y = 0; y < b.height; y++)
    [
      for (var x = 0; x < b.width; x++) b.get(x, y) >> 24 == 0 ? '.' : '#',
    ].join(),
].join('\n');

void main() {
  late SpriteStudioSession s;
  PixelBuffer cel() => s.document.cel(s.layer.id, s.frame.id)!;

  setUp(() {
    s = SpriteStudioSession(SpriteDocument.blank(6, 4))..primary.value = _ink;
  });
  tearDown(() => s.dispose());

  void gesture(StudioTool tool, List<(int, int)> points, {bool right = false}) {
    final t = PixelTools.of(tool);
    t.down(
      s,
      points.first.$1,
      points.first.$2,
      right ? ToolButton.secondary : ToolButton.primary,
    );
    for (final p in points.skip(1)) {
      t.drag(s, p.$1, p.$2);
    }
    t.up(s);
  }

  test('a pencil drag joins the dots, cleans its corners, and is one undo', () {
    gesture(StudioTool.pencil, [(0, 0), (1, 0), (1, 1), (3, 3)]);
    expect(_art(cel()), '#.....\n.#....\n..#...\n...#..');
    s.undo();
    expect(s.document.celCount, 0);
    s.redo();
    expect(cel().get(3, 3), _ink);
  });

  test('the right button draws in the secondary colour; the eraser clears', () {
    gesture(StudioTool.pencil, [(0, 0), (5, 0)], right: true);
    expect(cel().get(2, 0), s.secondary.value);
    gesture(StudioTool.eraser, [(2, 0), (3, 0)]);
    expect(_art(cel()).split('\n').first, '##..##');
  });

  test('shapes follow the pointer and only the last one stays', () {
    final t = PixelTools.of(StudioTool.rectangle)
      ..down(s, 0, 0, ToolButton.primary)
      ..drag(s, 5, 3)
      ..drag(s, 2, 2);
    t.up(s);
    expect(_art(cel()), '###...\n#.#...\n###...\n......');

    s.filledShapes.value = true;
    gesture(StudioTool.ellipse, [(3, 0), (5, 2)]);
    expect(cel().get(4, 1), _ink);
  });

  test('symmetry and brush size apply to every drawing tool', () {
    s
      ..symmetry.value = Symmetry.horizontal
      ..brushSize.value = 2;
    gesture(StudioTool.pencil, [(1, 1)]);
    expect(_art(cel()), '##..##\n##..##\n......\n......');
  });

  test('a selection fences tools in; move carries its pixels', () {
    gesture(StudioTool.select, [(0, 0), (1, 1)]);
    expect(s.selection.value!.bounds, const IntRect(0, 0, 2, 2));
    gesture(StudioTool.fill, [(0, 0)]);
    expect(_art(cel()), '##....\n##....\n......\n......');

    gesture(StudioTool.move, [(0, 0), (3, 1)]);
    expect(_art(cel()), '......\n...##.\n...##.\n......');
    expect(s.selection.value!.bounds, const IntRect(3, 1, 5, 3));

    // A click with the select tool lets go.
    gesture(StudioTool.select, [(0, 0)]);
    expect(s.selection.value, isNull);
  });

  test('the picker reads the picture, and cancel leaves nothing', () {
    gesture(StudioTool.pencil, [(2, 2)]);
    s.addLayer();
    s.primary.value = 0xFFABCDEF;
    gesture(StudioTool.picker, [(2, 2)]);
    expect(s.primary.value, _ink, reason: 'seen through the empty top layer');

    final t = PixelTools.of(StudioTool.line)
      ..down(s, 0, 0, ToolButton.primary)
      ..drag(s, 5, 3);
    t.cancel(s);
    expect(s.document.cel(s.layer.id, s.frame.id), isNull);
    expect(s.editor.undoLabel, 'New layer');
  });

  test('a locked or hidden layer says so instead of drawing', () {
    s.layer.locked = true;
    gesture(StudioTool.pencil, [(0, 0)]);
    expect(s.document.celCount, 0);
    expect(s.message.value, contains('locked'));
    s.layer
      ..locked = false
      ..visible = false;
    gesture(StudioTool.pencil, [(0, 0)]);
    expect(s.message.value, contains('hidden'));
  });

  test('edit actions: flip, rotate, delete, replace colour, crop', () {
    gesture(StudioTool.pencil, [(0, 0)]);
    StudioActions.flip(s, horizontal: true);
    expect(cel().get(5, 0), _ink);
    StudioActions.replaceColor(s);
    expect(cel().get(5, 0), s.secondary.value);
    gesture(StudioTool.select, [(4, 0), (5, 1)]);
    StudioActions.cropToSelection(s);
    expect((s.document.width, s.document.height), (2, 2));
    expect(s.selection.value, isNull);
    StudioActions.deletePixels(s);
    expect(cel().isBlank, isTrue);
  });

  test('frames and layers follow the cursor; the last of each stays', () {
    s.addFrame();
    expect(s.frameIndex.value, 1);
    s.addLayer();
    expect(s.layerIndex.value, 1);
    s
      ..removeFrame()
      ..removeFrame();
    expect(s.document.frames, hasLength(1));
    expect(s.message.value, contains('needs one frame'));
    s.addTag(0, 0, name: 'idle');
    s.addTag(0, 0, name: 'idle');
    expect([for (final t in s.document.tags) t.name], ['idle', 'idle2']);
  });

  test('playback visits a tag in its direction', () {
    for (var i = 0; i < 3; i++) {
      s.addFrame(duplicate: false);
    }
    s.document.tags.add(
      SpriteTag(name: 't', from: 1, to: 3, direction: TagDirection.pingpong),
    );
    s.playTag.value = 't';
    expect(s.playOrder, [1, 2, 3, 2]);
    s.playTag.value = null;
    expect(s.playOrder, [0, 1, 2, 3]);
  });

  test('saving writes project, sheet and atlas, and keeps an imported '
      'original', () async {
    final dir = await Directory.systemTemp.createTemp('jsprite_test');
    addTearDown(() => dir.delete(recursive: true));
    final root = dir.path.replaceAll('\\', '/');
    await Directory('$root/assets/sprites').create(recursive: true);
    final original = PngEncoder.encode(PixelBuffer(3, 3)..fill(_ink));
    await File('$root/assets/sprites/hero.png').writeAsBytes(original);

    final opened = await SpriteStudioSession.open(
      'assets/sprites/hero.png',
      root: root,
      decodeImage: (_) async => PixelBuffer(3, 3)..fill(_ink),
    );
    addTearDown(opened.dispose);
    expect(opened.path, 'assets/sprites/hero.jsprite');
    expect(opened.document.flatten(0).get(1, 1), _ink);

    final saved = await opened.save();
    expect(saved.atlasPath, 'assets/sprites/hero.json');
    for (final f in const [
      'hero.jsprite',
      'hero.png',
      'hero.json',
      'hero.original.png',
    ]) {
      expect(File('$root/assets/sprites/$f').existsSync(), isTrue, reason: f);
    }
    expect(
      File('$root/assets/sprites/hero.original.png').readAsBytesSync(),
      original,
    );
    expect(opened.isDirty, isFalse);

    // Opening the image again now opens the project beside it.
    final again = await SpriteStudioSession.open(
      'assets/sprites/hero.png',
      root: root,
      decodeImage: (_) async => fail('the project is the original now'),
    );
    addTearDown(again.dispose);
    expect(again.document.width, 3);
  });
}
