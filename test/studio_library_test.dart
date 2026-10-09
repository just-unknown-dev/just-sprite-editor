// The project's sprites: finding what is already there, and bringing one
// in from outside.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_sprite_editor/src/studio/studio_library.dart';

void main() {
  late Directory project;
  late SpriteLibrary library;

  setUp(() {
    project = Directory.systemTemp.createTempSync('sprite_library');
    library = SpriteLibrary(root: project.path.replaceAll(r'\', '/'));
    addTearDown(() {
      if (project.existsSync()) project.deleteSync(recursive: true);
    });
  });

  void write(String relative, [String content = 'x']) {
    final file = File('${project.path}/$relative');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  group('what the project holds', () {
    test('every project under assets, in order, and nothing else', () {
      write('assets/sprites/hero.jsprite');
      write('assets/ui/panel.jsprite');
      // A sheet beside a project is that project's export, and an image
      // with no project is not a sprite until it is imported: listing
      // either said the same sprite twice.
      write('assets/sprites/hero.png');
      write('assets/sprites/loose.png');
      write('assets/ui/old.aseprite');
      write('assets/levels/level_01.scene.json');
      write('assets/sprites/notes.txt');
      // Outside the assets folder: the studio does not offer it.
      write('build/leftover.jsprite');

      final found = [for (final a in library.scan()) a.path];

      expect(found, ['assets/sprites/hero.jsprite', 'assets/ui/panel.jsprite']);
    });

    test('a hidden folder is left alone', () {
      write('assets/.editor_trash/deleted.jsprite');
      write('assets/kept.jsprite');

      expect([for (final a in library.scan()) a.path], ['assets/kept.jsprite']);
    });

    test('a project with nothing in it is not an error', () {
      expect(library.scan(), isEmpty);
    });

    test('a row knows its name and the folder it is in', () {
      write('assets/sprites/hero.jsprite', 'abcdef');
      final asset = library.scan().single;

      expect(asset.name, 'hero.jsprite');
      expect(asset.folder, 'assets/sprites');
      expect(asset.bytes, 6);
    });
  });

  group('bringing one in from outside', () {
    late Directory elsewhere;

    setUp(() {
      elsewhere = Directory.systemTemp.createTempSync('outside');
      addTearDown(() {
        if (elsewhere.existsSync()) elsewhere.deleteSync(recursive: true);
      });
    });

    test('it is copied into the project, and opened from there', () async {
      final source = File('${elsewhere.path}/hero.png')
        ..writeAsStringSync('pixels');

      final path = await library.import(source.path, into: 'assets/sprites');

      expect(path, 'assets/sprites/hero.png');
      // The project holds it now — a sprite it does not hold is one the
      // game cannot load.
      expect(File('${project.path}/$path').readAsStringSync(), 'pixels');
      expect(source.existsSync(), isTrue, reason: 'copied, not moved');
      // Still an image: it joins the list once the studio has saved it
      // as a project, which importing does straight away.
      expect(library.scan(), isEmpty);
    });

    test('a name already taken is not overwritten', () async {
      write('assets/sprites/hero.png', 'the one already here');
      File('${elsewhere.path}/hero.png').writeAsStringSync('the new one');

      final path = await library.import(
        '${elsewhere.path}/hero.png',
        into: 'assets/sprites',
      );

      expect(path, 'assets/sprites/hero_2.png');
      expect(
        File('${project.path}/assets/sprites/hero.png').readAsStringSync(),
        'the one already here',
      );
    });

    test('the folder is made when it is not there yet', () async {
      File('${elsewhere.path}/coin.png').writeAsStringSync('pixels');

      final path = await library.import(
        '${elsewhere.path}/coin.png',
        into: 'assets/sprites',
      );

      expect(File('${project.path}/$path').existsSync(), isTrue);
    });
  });

  group('the panel', () {
    testWidgets('lists what is there and says which one is open', (
      tester,
    ) async {
      write('assets/sprites/hero.jsprite');
      write('assets/sprites/coin.jsprite');
      final assets = library.scan();
      SpriteAsset? opened;
      var imported = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SpriteLibraryPanel(
              assets: assets,
              openPath: 'assets/sprites/coin.jsprite',
              onOpen: (asset) => opened = asset,
              onImport: () => imported++,
              onRefresh: () {},
              isOpen: true,
              onToggle: () {},
              height: SpriteLibraryPanel.defaultHeight,
              onResize: (_) {},
            ),
          ),
        ),
      );

      expect(find.text('hero.jsprite'), findsOneWidget);
      expect(find.text('coin.jsprite'), findsOneWidget);
      // Grouped by the folder they live in.
      expect(find.text('assets/sprites'), findsOneWidget);

      await tester.tap(find.text('hero.jsprite'));
      await tester.pump();
      expect(opened?.path, 'assets/sprites/hero.jsprite');

      await tester.tap(find.text('Import…'));
      await tester.pump();
      expect(imported, 1);
    });

    testWidgets('an empty project says so', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SpriteLibraryPanel(
              assets: const [],
              openPath: null,
              onOpen: (_) {},
              onImport: () {},
              onRefresh: () {},
              isOpen: true,
              onToggle: () {},
              height: SpriteLibraryPanel.defaultHeight,
              onResize: (_) {},
            ),
          ),
        ),
      );

      expect(find.text('No sprites in this project yet.'), findsOneWidget);
      // And the way to bring one in is still there.
      expect(find.text('Import…'), findsOneWidget);
    });

    testWidgets('folded away, it is one line', (tester) async {
      write('assets/sprites/hero.jsprite');
      var toggled = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SpriteLibraryPanel(
              assets: library.scan(),
              openPath: null,
              onOpen: (_) {},
              onImport: () {},
              onRefresh: () {},
              isOpen: false,
              onToggle: () => toggled++,
              height: SpriteLibraryPanel.defaultHeight,
              onResize: (_) {},
            ),
          ),
        ),
      );

      // The header stays; the list and the way in fold with it, so the
      // colour and the layers have the height.
      expect(find.text('SPRITES'), findsOneWidget);
      expect(find.text('hero.jsprite'), findsNothing);
      expect(find.text('Import…'), findsNothing);

      await tester.tap(find.byIcon(Icons.expand_more));
      await tester.pump();
      expect(toggled, 1);
    });

    testWidgets('the handle under it reports what it was dragged', (
      tester,
    ) async {
      write('assets/sprites/hero.jsprite');
      var dragged = 0.0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SpriteLibraryPanel(
              assets: library.scan(),
              openPath: null,
              onOpen: (_) {},
              onImport: () {},
              onRefresh: () {},
              isOpen: true,
              onToggle: () {},
              height: SpriteLibraryPanel.defaultHeight,
              onResize: (dy) => dragged += dy,
            ),
          ),
        ),
      );

      final handle = find.byWidgetPredicate(
        (w) => w is MouseRegion && w.cursor == SystemMouseCursors.resizeRow,
      );
      expect(handle, findsOneWidget);
      await tester.drag(handle, const Offset(0, 40));
      await tester.pump();

      expect(dragged, 40);
    });
  });
}
