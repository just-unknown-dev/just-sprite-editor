// The studio as the artist meets it: a pointer on the canvas, keys, the
// panels — and the module that puts it in the game editor.

import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_game_engine_editor/just_game_engine_editor.dart';
import 'package:just_sprite_editor/editor.dart';
import 'package:just_sprite_editor/just_sprite_editor.dart';
import 'package:just_sprite_editor/src/studio/studio_canvas.dart';

Future<SpriteStudioSession> _pump(
  WidgetTester tester, {
  String? root,
  void Function(SavedSprite)? onSaved,
  VoidCallback? onClose,
}) async {
  tester.view
    ..physicalSize = const Size(1400, 900)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final key = GlobalKey<SpriteStudioState>();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SpriteStudio(
          key: key,
          root: root,
          onSaved: onSaved,
          onClose: onClose,
        ),
      ),
    ),
  );
  // Opening is async, then the canvas fits the sprite to its view.
  await tester.pump();
  await tester.pump();
  return key.currentState!.session!;
}

/// The screen position of the middle of sprite pixel ([x], [y]).
Offset _pixel(WidgetTester tester, SpriteStudioSession s, int x, int y) {
  final box = tester.getRect(find.byType(StudioCanvas));
  final z = s.zoom.value;
  final origin =
      box.topLeft +
      Offset(
        (box.width - s.document.width * z) / 2,
        (box.height - s.document.height * z) / 2,
      ) +
      s.pan.value;
  return origin + Offset((x + 0.5) * z, (y + 0.5) * z);
}

void main() {
  testWidgets('a drag on the canvas draws; Ctrl+Z takes it back', (
    tester,
  ) async {
    final s = await _pump(tester);
    expect(s.zoom.value, greaterThan(8), reason: 'fitted to the view');

    final gesture = await tester.startGesture(
      _pixel(tester, s, 2, 2),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveTo(_pixel(tester, s, 6, 2));
    await gesture.up();
    await tester.pump();

    final cel = s.document.cel(s.layer.id, s.frame.id)!;
    expect([
      for (var x = 2; x <= 6; x++) cel.get(x, 2),
    ], everyElement(s.primary.value));
    expect(s.isDirty, isTrue);
    expect(
      find.byTooltip('Not saved'),
      findsOneWidget,
      reason: 'unsaved shows',
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(s.document.celCount, 0);
  });

  testWidgets('the right button draws with the secondary colour', (
    tester,
  ) async {
    final s = await _pump(tester);
    final gesture = await tester.startGesture(
      _pixel(tester, s, 1, 1),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pump();
    expect(
      s.document.cel(s.layer.id, s.frame.id)!.get(1, 1),
      s.secondary.value,
    );
  });

  testWidgets('letters pick tools, brackets size the brush, X swaps colours', (
    tester,
  ) async {
    final s = await _pump(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
    expect(s.tool.value, StudioTool.fill);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
    expect(s.tool.value, StudioTool.eraser);
    await tester.sendKeyEvent(LogicalKeyboardKey.bracketRight);
    expect(s.brushSize.value, 2);
    final was = s.primary.value;
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    expect(s.secondary.value, was);
    await tester.pump();
    expect(find.text('Eraser'), findsOneWidget, reason: 'the options bar says');
  });

  testWidgets('frames, layers and tags from the panels', (tester) async {
    final s = await _pump(tester);
    await tester.tap(find.byTooltip('Duplicate frame  (Alt+N)'));
    await tester.tap(find.byTooltip('New layer'));
    await tester.pump();
    expect(s.document.frames, hasLength(2));
    expect(s.document.layers, hasLength(2));
    expect(find.text('Frame 2/2'), findsOneWidget);

    await tester.tap(find.byTooltip('Tag this frame as a clip'));
    await tester.pump();
    expect(s.document.tags.single.from, 1);
    expect(find.text('tag'), findsOneWidget);

    // A palette swatch sets the primary colour.
    await tester.tap(find.byTooltip('#AC3232'));
    expect(s.primary.value, 0xFFAC3232);
  });

  testWidgets('Ctrl+S names a new sprite and writes three files', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('studio_widget');
    addTearDown(() => dir.deleteSync(recursive: true));
    final root = dir.path.replaceAll('\\', '/');
    SavedSprite? saved;
    final s = await _pump(tester, root: root, onSaved: (v) => saved = v);

    final gesture = await tester.startGesture(
      _pixel(tester, s, 3, 3),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.up();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      'my hero',
    );
    await tester.tap(find.text('OK'));
    // The dialog closes on the test's clock; the files are written on the
    // real one. Give each its turn until the save reports back.
    for (var i = 0; i < 40 && saved == null; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
    }
    await tester.pumpAndSettle();

    expect(saved?.projectPath, 'assets/sprites/my_hero.jsprite');
    for (final ext in const ['jsprite', 'png', 'json']) {
      expect(File('$root/assets/sprites/my_hero.$ext').existsSync(), isTrue);
    }
    expect(s.isDirty, isFalse);
    // Let the "Saved" note's timer run out before the test ends.
    await tester.pump(const Duration(seconds: 3));
  });

  test('the module offers the studio for sprites, and only sprites', () {
    final module = SpriteStudioModule();
    final workspace = module.workspaces.firstWhere(
      (w) => w.id == SpriteStudioModule.workspaceId,
    );
    expect(workspace.matchOf('assets/sprites/hero.jsprite'), greaterThan(0));
    expect(workspace.matchOf('assets/sprites/hero.PNG'), greaterThan(0));
    expect(workspace.matchOf('assets/scenes/level.json'), 0);

    final edit = module.assetActions.firstWhere(
      (a) => a.id == 'sprite_studio.edit',
    );
    expect(edit.appliesTo('assets/a.png', isDirectory: false), isTrue);
    expect(
      edit.appliesTo('assets/a.original.png', isDirectory: false),
      isFalse,
      reason: 'a kept original is not the sprite',
    );
    final create = module.assetActions.firstWhere(
      (a) => a.id == 'sprite_studio.new',
    );
    expect(create.appliesTo('assets/sprites', isDirectory: true), isTrue);
    expect(create.appliesTo('assets/audio', isDirectory: true), isFalse);

    final character = module.prefabs.last.build(
      Offset.zero,
      const Size(32, 32),
    );
    expect(character.map((c) => c.runtimeType.toString()), [
      'TransformComponent',
      'SpriteAnimationComponent',
      'AnimatorComponent',
    ]);
    expect(module, isA<EditorModule>());
  });

  testWidgets('the full-screen button toggles, and is absent on its own', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(1400, 900)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fullScreen = ValueNotifier(false);
    addTearDown(fullScreen.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SpriteStudio(
            fullScreen: fullScreen,
            onToggleFullScreen: () => fullScreen.value = !fullScreen.value,
            onClose: () {},
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    // It sits left of the close button.
    final button = find.byTooltip('Full screen');
    expect(
      tester.getRect(button).left,
      lessThan(tester.getRect(find.byTooltip('Close the studio')).left),
    );
    await tester.tap(button);
    await tester.pump();
    expect(fullScreen.value, isTrue);
    expect(find.byTooltip('Leave full screen'), findsOneWidget);
    await tester.tap(find.byTooltip('Leave full screen'));
    await tester.pump();
    expect(fullScreen.value, isFalse);

    // Run on its own, with no host to ask: no button.
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SpriteStudio())),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byTooltip('Full screen'), findsNothing);
  });

  testWidgets("the studio lists the project's own sprites", (tester) async {
    final project = Directory.systemTemp.createTempSync('studio_library');
    addTearDown(() {
      if (project.existsSync()) project.deleteSync(recursive: true);
    });
    File('${project.path}/assets/sprites/hero.jsprite')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('{}');

    await _pump(tester, root: project.path);

    // The panel is there from the start: opening another sprite in the
    // same project should not mean going back to the Assets dock.
    expect(find.text('SPRITES'), findsOneWidget);
    expect(find.text('hero.jsprite'), findsOneWidget);
    expect(find.text('Import…'), findsOneWidget);
  });

  testWidgets('the sprite list can be dragged taller, within reason', (
    tester,
  ) async {
    final project = Directory.systemTemp.createTempSync('studio_resize');
    addTearDown(() {
      if (project.existsSync()) project.deleteSync(recursive: true);
    });
    File('${project.path}/assets/sprites/hero.jsprite')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('{}');

    await _pump(tester, root: project.path);

    Finder handle() => find.byWidgetPredicate(
      (w) => w is MouseRegion && w.cursor == SystemMouseCursors.resizeRow,
    );
    final list = find.ancestor(
      of: find.text('hero.jsprite'),
      matching: find.byType(ListView),
    );
    final was = tester.getSize(list).height;

    await tester.drag(handle(), const Offset(0, 60));
    await tester.pump();
    expect(tester.getSize(list).height, was + 60);

    // Dragged far past what the window can give, it stops rather than
    // pushing the colour and the layers off the bottom.
    await tester.drag(handle(), const Offset(0, 4000));
    await tester.pump();
    expect(tester.getSize(list).height, lessThan(900));

    // And it cannot be squeezed away to nothing either.
    await tester.drag(handle(), const Offset(0, -4000));
    await tester.pump();
    expect(tester.getSize(list).height, 72);
  });
}
