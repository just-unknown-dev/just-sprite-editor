// What the studio exports is what the game loads: the engine's own atlas
// loader reads the JSON, and a real PNG decoder reads the sheet.

import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:just_game_engine/just_game_engine.dart';
import 'package:just_sprite_editor/document.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the engine plays an exported sprite', (tester) async {
    final doc = SpriteDocument.blank(6, 4);
    final layer = doc.layers.first.id;
    doc.ensureCel(layer, doc.frames.first.id).set(1, 1, 0xFFFF0000);
    final second = doc.addFrame(durationMs: 300);
    doc.ensureCel(layer, second.id).set(4, 2, 0x8000FF00);
    final third = doc.addFrame(durationMs: 50);
    doc.ensureCel(layer, third.id).fill(0xFF0000FF);
    doc.tags
      ..add(
        SpriteTag(
          name: 'walk',
          from: 0,
          to: 2,
          direction: TagDirection.pingpong,
        ),
      )
      ..add(SpriteTag(name: 'land', from: 2, to: 2, loop: false));

    final export = SheetExporter.export(
      doc,
      name: 'hero',
      imageFile: 'hero.png',
      options: const SheetExportOptions(padding: 1),
    );

    late SpriteAtlas atlas;
    late ui.Image image;
    await tester.runAsync(() async {
      atlas = await SpriteAtlas.fromJson(
        export.json,
        basePath: 'assets/sprites/',
        loadImage: (path) async {
          expect(path, 'assets/sprites/hero.png');
          final codec = await ui.instantiateImageCodec(export.pngBytes);
          return image = (await codec.getNextFrame()).image;
        },
      );
    });

    // The PNG decodes to the sheet's size, and its pixels are the sheet's.
    expect(
      (image.width, image.height),
      (export.sheet.width, export.sheet.height),
    );
    late List<int> rgba;
    await tester.runAsync(() async {
      final data = await image.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      );
      rgba = data!.buffer.asUint8List();
    });
    expect(
      PixelBuffer.fromRgbaBytes(
        image.width,
        image.height,
        rgba,
      ).sameAs(export.sheet),
      isTrue,
    );

    // The clips are the tags, with the artist's timing.
    final walk = atlas.requireClip('walk');
    expect(
      [for (final f in walk.frames) f.regionName],
      ['hero 0', 'hero 1', 'hero 2', 'hero 1'],
    );
    expect([for (final f in walk.frames) f.duration], [0.1, 0.3, 0.05, 0.3]);
    expect(atlas.requireClip('land').loop, isFalse);
    expect(walk.loop, isTrue);

    // Each region is where its frame was put on the sheet.
    final region = atlas.requireRegion('hero 1');
    final x = region.frame.left.toInt(), y = region.frame.top.toInt();
    expect(export.sheet.get(x + 4, y + 2), 0x8000FF00);
    expect(region.sourceSize, const ui.Size(6, 4));
  });
}
