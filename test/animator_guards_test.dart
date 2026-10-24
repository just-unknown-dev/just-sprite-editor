// The animator graph editor where it guards the graph: names kept unique,
// a removed parameter let go of, a node that keeps up with the pointer, a
// clip list not read from disk on every frame, a graph not written over.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_game_engine/just_game_engine.dart';
import 'package:just_sprite_editor/just_sprite_editor.dart';

List<int> _u32(int v) => [
  v & 255,
  (v >> 8) & 255,
  (v >> 16) & 255,
  (v >> 24) & 255,
];

void main() {
  late String root;
  setUp(() {
    final dir = Directory.systemTemp.createTempSync('animator_guards');
    root = dir.path.replaceAll(r'\', '/');
    addTearDown(() => dir.deleteSync(recursive: true));
  });

  AnimatorGraphSession session([AnimatorGraph graph = const AnimatorGraph()]) {
    final s = AnimatorGraphSession(graph, root: root);
    addTearDown(s.dispose);
    return s;
  }

  test('a state for every clip keeps every state name its own', () {
    final s = session()..addState(0, 0, clip: 'run_cycle');
    s.updateState(
      'run_cycle',
      s.g.stateNamed('run_cycle')!.copyWith(name: 'run', clip: 'run_cycle'),
    );
    expect(s.addStatesForClips(['run', 'run_cycle', 'idle']), 2);
    expect([for (final st in s.g.states) st.name], ['run', 'run2', 'idle']);
    expect(s.g.stateNamed('run2')!.clipName, 'run');
    expect(s.g.validate(), isEmpty);
  });

  test('a removed parameter is let go of by the blend trees too', () {
    final s = session()
      ..addParameter(name: 'speed')
      ..addState(0, 0, clip: 'walk');
    s.addBlendTree(s.g.stateNamed('walk')!);
    expect(s.g.stateNamed('walk')!.blend!.parameter, 'speed');
    s.removeParameter('speed');
    final tree = s.g.stateNamed('walk')!.blend!;
    expect(tree.parameter, isEmpty);
    expect(tree.motions, hasLength(1), reason: 'the motions are kept');
  });

  test('a drag the pointer lost is one step, where the node got to', () {
    final s = session()..addState(10, 10, clip: 'a');
    s
      ..moveState('a', 30, 10, commit: false)
      ..moveState('a', 50, 10, commit: false)
      ..endMove('a');
    expect(s.g.stateNamed('a')!.x, 50);
    s.undo();
    expect(s.g.stateNamed('a')!.x, 10);
    // With no drag going on, there is nothing to end.
    s.endMove('a');
    expect(s.canRedo, isTrue);
  });

  group('clips', () {
    void atlas(List<String> clips) => File('$root/hero.json').writeAsStringSync(
      jsonEncode({
        'frames': <String, dynamic>{},
        'meta': {
          'frameTags': [
            for (final c in clips) {'name': c, 'from': 0, 'to': 0},
          ],
        },
      }),
    );

    test('are kept between asks, and read again when the path changes', () {
      atlas(['idle']);
      final s = session(const AnimatorGraph(atlasPath: 'hero.json'));
      expect(s.clipNames(), ['idle']);
      atlas(['idle', 'run']);
      expect(s.clipNames(), ['idle'], reason: 'not read again at once');
      expect(s.readClipNames(), ['idle', 'run'], reason: 'unless asked');
      File('$root/other.json').writeAsStringSync(
        jsonEncode({
          'meta': {
            'frameTags': [
              {'name': 'jump'},
            ],
          },
        }),
      );
      s.apply(s.g.copyWith(atlasPath: 'other.json'));
      expect(s.clipNames(), ['jump']);
    });

    test("of a .glb come from its JSON, not the rest of it", () {
      final json = jsonEncode({
        'animations': [
          {'name': 'wave'},
        ],
      });
      final text = utf8.encode(json.padRight((json.length + 3) & ~3));
      // A JSON chunk, then a "binary" one that is not even complete.
      final glb = BytesBuilder()
        ..add(utf8.encode('glTF'))
        ..add(_u32(2))
        ..add(_u32(20 + text.length + (1 << 20)))
        ..add(_u32(text.length))
        ..add(utf8.encode('JSON'))
        ..add(text)
        ..add(Uint8List(64 * 1024));
      File('$root/hero.glb').writeAsBytesSync(glb.toBytes());
      final s = session(const AnimatorGraph(atlasPath: 'hero.glb'));
      expect(s.readClipNames(), ['wave']);
    });
  });

  testWidgets('a node dragged with several moves to a frame keeps up', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(1400, 800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey<AnimatorGraphEditorState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AnimatorGraphEditor(key: key, root: root),
        ),
      ),
    );
    await tester.pump();
    final s = key.currentState!.session!..addState(300, 60, clip: 'idle');
    await tester.pump();

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('idle').first),
    );
    await gesture.moveBy(const Offset(30, 0)); // past the drag slop
    await tester.pump();
    final start = s.g.stateNamed('idle')!.x;
    // Five moves before the next frame.
    for (var i = 0; i < 5; i++) {
      await gesture.moveBy(const Offset(10, 0));
    }
    await tester.pump();
    expect(s.g.stateNamed('idle')!.x, start + 50);
    await gesture.up();
    await tester.pump();
    expect(s.canUndo, isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a new graph is offered a free name, and asks before it '
      'replaces another', (tester) async {
    tester.view
      ..physicalSize = const Size(1400, 800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final taken = File('$root/assets/sprites/character.animator.json')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('{"entry":"theirs"}');
    final key = GlobalKey<AnimatorGraphEditorState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AnimatorGraphEditor(key: key, root: root),
        ),
      ),
    );
    await tester.pump();
    key.currentState!.session!.addState(300, 60, clip: 'idle');
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    final field = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    expect(tester.widget<TextField>(field).controller!.text, 'character_2');
    await tester.enterText(field, 'character');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text('Replace character.animator.json?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(taken.readAsStringSync(), '{"entry":"theirs"}');
    expect(key.currentState!.session!.path, isNull);
    await tester.pumpWidget(const SizedBox());
  });

  test('a saved graph is written whole, with nothing left beside it', () async {
    final s = session()..addState(0, 0, clip: 'idle');
    await s.save(to: 'g.animator.json');
    await s.save(to: 'g.animator.json');
    expect(
      Directory(
        root,
      ).listSync().map((e) => e.path.split(RegExp(r'[\\/]')).last),
      ['g.animator.json'],
    );
    expect(
      AnimatorGraph.parse(
        File('$root/g.animator.json').readAsStringSync(),
      ).entry,
      'idle',
    );
  });
}
