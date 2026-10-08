import 'package:flutter_test/flutter_test.dart';

import 'package:just_sprite_editor/just_sprite_editor.dart';

void main() {
  test('adds one to input values', () {
    final calculator = Calculator();
    expect(calculator.addOne(2), 3);
    expect(calculator.addOne(-7), -6);
    expect(calculator.addOne(0), 1);
  });
}
