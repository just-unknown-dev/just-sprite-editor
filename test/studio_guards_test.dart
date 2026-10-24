// The studio on screen, where it guards the artist's work: names that are
// taken, imports that do not happen, keys pressed mid-stroke — and where it
// keeps its own costs down: GPU images let go, a backdrop drawn for what
// shows.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_sprite_editor/just_sprite_editor.dart';
import 'package:just_sprite_editor/src/studio/studio_canvas.dart';

Future<SpriteStudioState> _pump(
  WidgetTester tester, {
  String? root,
  Future<String?> Function()? pickFile,
}) async {
  tester.view
    ..physicalSize = const Size(1400, 900)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final key = GlobalKey<SpriteStudioState>();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SpriteStudio(key: key, root: root, pickFile: pickFile),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return key.currentState!;
}

/// Lets work off the test's clock — files, other isolates, images being
/// made — finish, and the frames it asks for, until [until] holds.
Future<void> _settle(WidgetTester tester, {bool Function()? until}) async {
  for (var i = 0; i < 100 && !(until?.call() ?? false); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
}

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

Future<void> _ctrl(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
}

Directory _project() {
  final dir = Directory.systemTemp.createTempSync('studio_guards');
  Directory('${dir.path}/assets/sprites').createSync(recursive: true);
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir;
}

void main() {
  testWidgets('a new sprite is offered a free name, and asks before it '
      'replaces another', (tester) async {
    final dir = _project();
    final root = dir.path.replaceAll(r'\', '/');
    final taken = File('$root/assets/sprites/sprite.jsprite')
      ..writeAsStringSync('the first one');
    final studio = await _pump(tester, root: root);
    final s = studio.session!;

    await tester.tapAt(_pixel(tester, s, 2, 2));
    await _ctrl(tester, LogicalKeyboardKey.keyS);
    await tester.pumpAndSettle();
    final field = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    expect(
      tester.widget<TextField>(field).controller!.text,
      'sprite_2',
      reason: 'the name offered is one no sprite has',
    );

    await tester.enterText(field, 'sprite');
    await tester.tap(find.text('OK'));
    await _settle(
      tester,
      until: () => find.text('Replace sprite.jsprite?').evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();
    expect(find.text('Replace sprite.jsprite?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(taken.readAsStringSync(), 'the first one');
    expect(s.path, isNull, reason: 'still not saved');
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('an import that does not happen leaves nothing behind', (
    tester,
  ) async {
    final dir = _project();
    final root = dir.path.replaceAll(r'\', '/');
    final outside = Directory.systemTemp.createTempSync('outside');
    addTearDown(() => outside.deleteSync(recursive: true));
    File('${outside.path}/coin.png').writeAsBytesSync([1, 2, 3]);
    File(
      '${outside.path}/broken.aseprite',
    ).writeAsBytesSync(List.filled(300, 7));
    var picked = '${outside.path}/coin.png';
    final studio = await _pump(
      tester,
      root: root,
      pickFile: () async => picked,
    );
    final s = studio.session!;
    await tester.tapAt(_pixel(tester, s, 1, 1));
    expect(s.isDirty, isTrue);

    // "Save changes?" — Cancel: what is open stays, unsaved, and the copy
    // that was to be opened goes again.
    await tester.tap(find.text('Import…'));
    await _settle(
      tester,
      until: () => find.textContaining('Save changes').evaluate().isNotEmpty,
    );
    await tester.tap(find.text('Cancel'));
    await _settle(tester);
    expect(studio.session, same(s));
    expect(s.isDirty, isTrue);
    expect(s.path, isNull);
    expect(File('$root/assets/sprites/coin.png').existsSync(), isFalse);
    expect(find.textContaining('Imported'), findsNothing);

    // A file that will not open says why, over the sprite still open.
    picked = '${outside.path}/broken.aseprite';
    await tester.tap(find.text('Import…'));
    await _settle(
      tester,
      until: () => find.textContaining('Save changes').evaluate().isNotEmpty,
    );
    await tester.tap(find.text("Don't save"));
    await _settle(
      tester,
      until: () => find.textContaining('Could not open').evaluate().isNotEmpty,
    );
    expect(
      find.textContaining('Could not open broken.aseprite'),
      findsOneWidget,
    );
    expect(studio.session, same(s));
    expect(File('$root/assets/sprites/broken.aseprite').existsSync(), isFalse);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('Ctrl+Z mid-stroke takes the stroke back, and the rest of the '
      'drag draws nothing', (tester) async {
    final s = (await _pump(tester)).session!;
    // Something there already, saved: the cel the stroke goes into.
    await tester.tapAt(_pixel(tester, s, 0, 0));
    s.editor.markSaved();
    final gesture = await tester.startGesture(
      _pixel(tester, s, 1, 1),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveTo(_pixel(tester, s, 5, 1));
    await _ctrl(tester, LogicalKeyboardKey.keyZ);
    await gesture.moveTo(_pixel(tester, s, 5, 6));
    await gesture.moveTo(_pixel(tester, s, 9, 9));
    await gesture.up();
    await tester.pump();
    final cel = s.document.cel(s.layer.id, s.frame.id)!;
    expect(cel.get(0, 0), s.primary.value);
    for (final (x, y) in [(1, 1), (5, 1), (5, 6), (9, 9)]) {
      expect(cel.get(x, y), 0, reason: '($x, $y)');
    }
    expect(s.editor.undoLabel, 'Pencil', reason: 'the first one');
    expect(s.editor.canRedo, isTrue, reason: 'the stroke, to redo');
    expect(s.isDirty, isFalse, reason: 'back where it was saved');
  });

  testWidgets('Backspace is not Delete, except on a Mac', (tester) async {
    final s = (await _pump(tester)).session!;
    await tester.tapAt(_pixel(tester, s, 2, 2));
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    expect(s.document.cel(s.layer.id, s.frame.id)!.isBlank, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    expect(s.document.cel(s.layer.id, s.frame.id)!.isBlank, isTrue);

    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await tester.tapAt(_pixel(tester, s, 2, 2));
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    expect(s.document.cel(s.layer.id, s.frame.id)!.isBlank, isTrue);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a trackpad pans and pinches the canvas', (tester) async {
    final s = (await _pump(tester)).session!;
    final centre = tester.getCenter(find.byType(StudioCanvas));
    final pan = s.pan.value, zoom = s.zoom.value;
    final pointer = TestPointer(1, PointerDeviceKind.trackpad);
    await tester.sendEventToBinding(pointer.panZoomStart(centre));
    await tester.sendEventToBinding(
      pointer.panZoomUpdate(centre, pan: const Offset(30, 10)),
    );
    expect(s.pan.value, pan + const Offset(30, 10));
    await tester.sendEventToBinding(
      pointer.panZoomUpdate(centre, pan: const Offset(30, 10), scale: 1.5),
    );
    expect(s.zoom.value, greaterThan(zoom));
    await tester.sendEventToBinding(pointer.panZoomEnd());
  });

  testWidgets('the canvas lets its GPU images go, and brings the onion skin '
      'back after playing', (tester) async {
    final studio = await _pump(tester);
    final s = studio.session!;
    final canvas = tester.state<StudioCanvasState>(find.byType(StudioCanvas));
    s
      ..addFrame()
      ..addFrame()
      ..goToFrame(1)
      ..onionSkin.value = const OnionSkin(enabled: true);
    await _settle(tester, until: () => canvas.onionFrameCount == 2);
    expect(canvas.onionFrameCount, 2);

    // Many strokes, each move a new picture: what is held stays the frame
    // and its two neighbours.
    for (var i = 0; i < 12; i++) {
      await tester.tapAt(_pixel(tester, s, i, i));
      await _settle(tester, until: () => !canvas.isRefreshing);
    }
    expect(canvas.liveImageCount, 3);

    s.play();
    await _settle(tester, until: () => canvas.onionFrameCount == 0);
    expect(canvas.onionFrameCount, 0, reason: 'none while playing');
    s.stop();
    await _settle(tester, until: () => canvas.onionFrameCount == 2);
    expect(canvas.onionFrameCount, 2, reason: 'back when it stops');

    await tester.pumpWidget(const SizedBox());
    expect(canvas.liveImageCount, 0, reason: 'all let go with the canvas');
  });

  test('the checkerboard is drawn for the part of the sprite in view', () {
    final painter = BackdropPainter(
      origin: const Offset(-40000, -40000),
      zoom: 64,
      width: SpriteDocument.maxSize,
      height: SpriteDocument.maxSize,
    );
    final recorder = ui.PictureRecorder();
    painter.paint(Canvas(recorder), const Size(800, 600));
    recorder.endRecording().dispose();
    // 2048² pixels at 64× is 4 million squares; what shows is a few dozen.
    expect(painter.squaresPainted, greaterThan(0));
    expect(painter.squaresPainted, lessThan(200));
  });
}
