// The studio's typed fields keep what was typed when they are left — Tab, a
// click elsewhere — not only on Enter, as every typed field in the editor
// does. They used to keep it on Enter alone: a duration typed and left
// showed on screen while the frame kept its old one.

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_sprite_editor/just_sprite_editor.dart';

final _desktop = TargetPlatformVariant.only(TargetPlatform.windows);

Future<SpriteStudioSession> _pump(WidgetTester tester) async {
  tester.view
    ..physicalSize = const Size(1400, 900)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final key = GlobalKey<SpriteStudioState>();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: SpriteStudio(key: key)),
    ),
  );
  await tester.pump();
  await tester.pump();
  return key.currentState!.session!;
}

/// Types [text] into [field], then leaves it as a click elsewhere would.
Future<void> _typeAndLeave(
  WidgetTester tester,
  Finder field,
  String text,
) async {
  await tester.tap(field, kind: PointerDeviceKind.mouse);
  await tester.pump();
  await tester.enterText(field, text);
  await tester.pump();
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump();
}

final _duration = find.byWidgetPredicate(
  (w) => w is TextField && w.decoration?.suffixText == ' ms',
);
final _hex = find.byWidgetPredicate(
  (w) => w is TextField && w.style?.fontFamily == 'monospace',
);

void main() {
  testWidgets("a frame's duration is kept on leaving the field", (
    tester,
  ) async {
    final s = await _pump(tester);
    expect(_duration, findsOneWidget);

    await _typeAndLeave(tester, _duration, '250');

    expect(s.frame.durationMs, 250);
  }, variant: _desktop);

  testWidgets('a duration that is not a whole number above 0 is not kept', (
    tester,
  ) async {
    final s = await _pump(tester);
    final before = s.frame.durationMs;

    await _typeAndLeave(tester, _duration, '0');

    expect(s.frame.durationMs, before);
    expect(
      tester.widget<TextField>(_duration).controller!.text,
      '$before',
      reason: 'shows the one it has again',
    );
  }, variant: _desktop);

  testWidgets('a colour typed as hex is kept on leaving the field', (
    tester,
  ) async {
    final s = await _pump(tester);
    expect(_hex, findsOneWidget);

    await _typeAndLeave(tester, _hex, '#FF0000');

    expect(s.primary.value, 0xFFFF0000);
  }, variant: _desktop);

  testWidgets('Esc in the hex field puts the colour back', (tester) async {
    final s = await _pump(tester);
    final before = s.primary.value;
    await tester.tap(_hex, kind: PointerDeviceKind.mouse);
    await tester.pump();
    await tester.enterText(_hex, '#00FF00');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    expect(s.primary.value, before);
  }, variant: _desktop);
}
