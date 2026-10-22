// The animator graph editor: what editing does to the graph, and the graph
// on screen.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_game_engine/just_game_engine.dart';
import 'package:just_sprite_editor/editor.dart';
import 'package:just_sprite_editor/just_sprite_editor.dart';

List<int> _u32(int v) => [v & 255, (v >> 8) & 255, (v >> 16) & 255, (v >> 24) & 255];

void main() {
  group('editing', () {
    late AnimatorGraphSession s;
    setUp(() => s = AnimatorGraphSession(const AnimatorGraph(), root: '.'));
    tearDown(() => s.dispose());

    test('the first state is the entry; names stay unique', () {
      expect(s.addState(0, 0, clip: 'idle'), 'idle');
      expect(s.addState(0, 0, clip: 'idle'), 'idle2');
      expect(s.g.entry, 'idle');
      expect(s.g.stateNamed('idle')!.clip, isEmpty, reason: 'named for it');
      expect(s.g.stateNamed('idle2')!.clip, 'idle');
      expect(s.selection.value, const GraphSelection.state('idle2'));
      expect(s.isDirty, isTrue);
    });

    test('blend trees: added on a number parameter, following its rename', () {
      s.addState(0, 0, clip: 'walk');
      s.addBlendTree(s.g.stateNamed('walk')!);
      expect(s.g.stateNamed('walk')!.blend, isNull);
      expect(s.message.value, contains('number parameter'));
      s.addParameter(name: 'speed', type: AnimatorParameterType.float);
      s.addBlendTree(s.g.stateNamed('walk')!);
      final tree = s.g.stateNamed('walk')!.blend!;
      expect((tree.parameter, tree.motions.single.clip), ('speed', 'walk'));
      s.updateParameter('speed', s.g.parameterNamed('speed')!.copyWith(name: 'pace'));
      expect(s.g.stateNamed('walk')!.blend!.parameter, 'pace');
      // A crossfade, and both read back from the saved file as version 2.
      s
        ..addState(0, 0, clip: 'idle')
        ..addTransition('idle', 'walk');
      s.updateTransition(0, s.g.transitions.first.copyWith(duration: 0.2));
      final back = AnimatorGraph.parse(s.g.encode());
      expect(jsonDecode(s.g.encode())['version'], 2);
      expect(back.transitions.first.duration, 0.2);
      expect(back.stateNamed('walk')!.blend!.parameter, 'pace');
    });

    test('renaming a state follows through transitions and the entry', () {
      s
        ..addState(0, 0, clip: 'idle')
        ..addState(0, 0, clip: 'run')
        ..addTransition('idle', 'run')
        ..addTransition(AnimatorTransition.anyState, 'idle');
      s.updateState('idle', s.g.stateNamed('idle')!.copyWith(name: 'stand'));
      expect(s.g.entry, 'stand');
      expect(
        [for (final t in s.g.transitions) '${t.from}>${t.to}'],
        ['stand>run', '*>stand'],
      );
      // A name already taken is refused.
      s.updateState('stand', s.g.stateNamed('stand')!.copyWith(name: 'run'));
      expect(s.g.stateNamed('stand'), isNotNull);
      expect(s.message.value, contains('name of its own'));
    });

    test(
      'a new transition waits for the clip; a repeat selects the old one',
      () {
        s
          ..addState(0, 0, clip: 'a')
          ..addState(0, 0, clip: 'b')
          ..addTransition('a', 'b');
        expect(s.g.transitions.single.hasExitTime, isTrue);
        expect(s.g.validate(), isEmpty);
        s.addTransition('a', 'b');
        expect(s.g.transitions, hasLength(1));
        expect(s.selection.value, const GraphSelection.transition(0));
        s.addTransition('a', 'a');
        expect(s.g.transitions, hasLength(1));
      },
    );

    test('removing a state or a parameter removes what hung on it', () {
      s
        ..addState(0, 0, clip: 'a')
        ..addState(0, 0, clip: 'b')
        ..addTransition('a', 'b')
        ..addParameter(name: 'speed', binding: 'speedX');
      final p = s.g.parameters.single;
      s.updateTransition(
        0,
        s.g.transitions.single.copyWith(conditions: [s.defaultConditionFor(p)]),
      );
      expect(s.g.transitions.single.conditions.single.op, AnimatorOp.greater);

      s.updateParameter('speed', p.copyWith(name: 'velocity'));
      expect(s.g.transitions.single.conditions.single.parameter, 'velocity');
      s.removeParameter('velocity');
      expect(s.g.transitions.single.conditions, isEmpty);
      s.removeState('b');
      expect(s.g.transitions, isEmpty);
    });

    test('dragging a node is one undo step', () {
      s.addState(10, 10, clip: 'a');
      for (var i = 1; i <= 5; i++) {
        s.moveState('a', 10.0 + i * 10, 10, commit: false);
      }
      s.moveState('a', 60, 10, commit: true);
      expect(s.g.stateNamed('a')!.x, 60);
      s.undo();
      expect(s.g.stateNamed('a')!.x, 10);
      s.undo();
      expect(s.g.states, isEmpty);
      s
        ..redo()
        ..redo();
      expect(s.g.stateNamed('a')!.x, 60);
    });

    test(
      'states for every clip in the atlas, and a save the engine reads',
      () async {
        final dir = Directory.systemTemp.createTempSync('animator_graph');
        addTearDown(() => dir.deleteSync(recursive: true));
        final root = dir.path.replaceAll('\\', '/');
        File('$root/hero.json').writeAsStringSync(
          jsonEncode({
            'frames': <String, dynamic>{},
            'meta': {
              'frameTags': [
                {'name': 'idle', 'from': 0, 'to': 1},
                {'name': 'run', 'from': 2, 'to': 5},
              ],
            },
          }),
        );
        final session = AnimatorGraphSession(
          const AnimatorGraph(atlasPath: 'hero.json'),
          root: root,
        );
        addTearDown(session.dispose);
        expect(session.readClipNames(), ['idle', 'run']);
        expect(session.addStatesForClips(session.readClipNames()), 2);
        expect(session.addStatesForClips(session.readClipNames()), 0);
        expect(session.g.entry, 'idle');

        await session.save(to: 'hero.animator.json');
        expect(session.isDirty, isFalse);
        final reopened = await AnimatorGraphSession.open(
          'hero.animator.json',
          root: root,
        );
        addTearDown(reopened.dispose);
        expect(reopened.g.toJson(), session.g.toJson());
      },
    );

    test("a 3-D model's animations are its clips, in a .gltf or a .glb", () {
      final dir = Directory.systemTemp.createTempSync('animator_model');
      addTearDown(() => dir.deleteSync(recursive: true));
      final root = dir.path.replaceAll('\\', '/');
      final json = jsonEncode({
        'asset': {'version': '2.0'},
        'animations': [
          {'name': 'walk', 'channels': [], 'samplers': []},
          {'channels': [], 'samplers': []},
        ],
      });
      File('$root/hero.gltf').writeAsStringSync(json);
      // A .glb: header, then the JSON chunk padded to 4 bytes.
      final text = utf8.encode(json.padRight((json.length + 3) & ~3));
      final glb = BytesBuilder()
        ..add(utf8.encode('glTF'))
        ..add(_u32(2))
        ..add(_u32(20 + text.length))
        ..add(_u32(text.length))
        ..add(utf8.encode('JSON'))
        ..add(text);
      File('$root/hero.glb').writeAsBytesSync(glb.toBytes());
      for (final file in ['hero.gltf', 'hero.glb']) {
        final session = AnimatorGraphSession(
          AnimatorGraph(atlasPath: file),
          root: root,
        );
        addTearDown(session.dispose);
        expect(session.readClipNames(), ['walk', 'animation 1'], reason: file);
      }
    });
  });

  testWidgets('its header: full screen beside close, a dot while unsaved, '
      'and the host asked before it goes', (tester) async {
    tester.view
      ..physicalSize = const Size(1400, 800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey<AnimatorGraphEditorState>();
    final fullScreen = ValueNotifier(false);
    addTearDown(fullScreen.dispose);
    Future<bool> Function()? guard;
    var closed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AnimatorGraphEditor(
            key: key,
            root: '.',
            fullScreen: fullScreen,
            onToggleFullScreen: () => fullScreen.value = !fullScreen.value,
            onClose: () => closed++,
            setCloseGuard: (g) => guard = g,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Animator'), findsOneWidget);
    expect(
      tester.getRect(find.byTooltip('Full screen')).left,
      lessThan(tester.getRect(find.byTooltip('Close')).left),
    );
    await tester.tap(find.byTooltip('Full screen'));
    expect(fullScreen.value, isTrue);

    expect(guard, isNotNull);
    expect(await guard!(), isTrue, reason: 'nothing to lose yet');
    expect(find.byTooltip('Not saved'), findsNothing);

    key.currentState!.session!.addState(300, 60, clip: 'idle');
    await tester.pump();
    expect(find.byTooltip('Not saved'), findsOneWidget);

    // Unsaved: the host's question is the close button's — and Cancel stays.
    final answer = guard!();
    await tester.pump();
    expect(find.text('Save changes to this animator?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(await answer, isFalse);
    expect(closed, 0);

    await tester.pumpWidget(const SizedBox());
    expect(guard, isNull, reason: 'gone with it');
  });

  testWidgets('the graph on screen: nodes, a transition by clicking, the '
      'inspector, the live state', (tester) async {
    tester.view
      ..physicalSize = const Size(1400, 800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey<AnimatorGraphEditorState>();
    String? live;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AnimatorGraphEditor(
            key: key,
            root: '.',
            liveState: (_) => live,
          ),
        ),
      ),
    );
    await tester.pump();
    final s = key.currentState!.session!
      ..addState(300, 60, clip: 'idle')
      ..addState(520, 200, clip: 'run')
      ..addParameter(name: 'speed', binding: 'speedX');
    await tester.pump();
    expect(find.text('Entry'), findsOneWidget);
    expect(find.text('Any State'), findsOneWidget);
    expect(find.text('idle'), findsWidgets);

    // The arrow button on "idle", then a click on "run".
    await tester.tap(
      find.descendant(
        of: find
            .ancestor(
              of: find.text('idle').first,
              matching: find.byType(GestureDetector),
            )
            .first,
        matching: find.byTooltip('Start a transition from here'),
      ),
    );
    await tester.pump();
    expect(
      find.textContaining('Click the state this leads to'),
      findsOneWidget,
    );
    await tester.tap(find.text('run').first);
    await tester.pump();
    expect(s.g.transitions.single.from, 'idle');
    expect(s.g.transitions.single.to, 'run');
    expect(find.text('idle  →  run'), findsOneWidget, reason: 'inspector');

    await tester.tap(find.byTooltip('Add a condition'));
    await tester.pump();
    expect(s.g.transitions.single.conditions.single.parameter, 'speed');

    // A running game lights its state; nothing is saved, so no path yet —
    // give the session one to be asked about.
    s.path = 'hero.animator.json';
    live = 'run';
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('● LIVE  run'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  test('the module opens animator graphs in their own workspace', () {
    final module = SpriteStudioModule();
    final byId = {for (final w in module.workspaces) w.id: w};
    final graph = byId[SpriteStudioModule.animatorWorkspaceId]!;
    final sprite = byId[SpriteStudioModule.workspaceId]!;
    const path = 'assets/sprites/hero.animator.json';
    expect(graph.matchOf(path), greaterThan(sprite.matchOf(path)));
    expect(
      module.assetActions
          .where((a) => a.appliesTo(path, isDirectory: false))
          .map((a) => a.id),
      ['sprite_studio.edit_animator'],
    );
  });
}
