import 'package:flutter/material.dart';

/// The colours the studio is drawn in.
///
/// Its own type, so the studio runs without the editor; the editor's module
/// hands it the editor's palette ([StudioTheme.palette]) so that a studio
/// opened inside the editor matches it — the same surfaces, the same lines,
/// the accent the user picked.
@immutable
class StudioPalette {
  const StudioPalette({
    required this.background,
    required this.panel,
    required this.panelRaised,
    required this.field,
    required this.border,
    required this.workArea,
    required this.text,
    required this.textMuted,
    required this.accent,
    required this.selected,
    required this.danger,
    required this.warning,
  });

  /// What the studio looks like on its own: the editor's classic palette.
  static const StudioPalette standalone = StudioPalette(
    background: Color(0xFF161414),
    panel: Color(0xFF1C1919),
    panelRaised: Color(0xFF262020),
    field: Color(0xFF0A0909),
    border: Color(0xFF3A2C2C),
    workArea: Color(0xFF0F0D0D),
    text: Color(0xFFFFFFFF),
    textMuted: Color(0xFF999999),
    accent: Color(0xFFFF9C98),
    selected: Color(0xFF3D1A1A),
    danger: Color(0xFFE54B4B),
    warning: Color(0xFFFFD660),
  );

  final Color background;
  final Color panel;
  final Color panelRaised;
  final Color field;
  final Color border;
  final Color workArea;
  final Color text;
  final Color textMuted;
  final Color accent;
  final Color selected;
  final Color danger;
  final Color warning;
}

/// The studio's colours and text styles, read from [palette].
abstract final class StudioTheme {
  /// Set by the host — the editor's module — to match it.
  static StudioPalette palette = StudioPalette.standalone;

  static Color get background => palette.background;
  static Color get panel => palette.panel;
  static Color get panelRaised => palette.panelRaised;
  static Color get field => palette.field;
  static Color get border => palette.border;
  static Color get workArea => palette.workArea;

  static Color get text => palette.text;
  static Color get textMuted => palette.textMuted;
  static Color get accent => palette.accent;
  static Color get selected => palette.selected;
  static Color get danger => palette.danger;
  static Color get warning => palette.warning;

  // The canvas's own: what a pixel editor shows, whatever the chrome is.
  static const Color checkerLight = Color(0xFF3B3838);
  static const Color checkerDark = Color(0xFF2D2A2A);
  static const Color pixelGrid = Color(0x30000000);
  static const Color hover = Color(0x66FFFFFF);
  static const Color onionBefore = Color(0xFFFF6B6B);
  static const Color onionAfter = Color(0xFF5CA8FF);

  static TextStyle get label => TextStyle(color: textMuted, fontSize: 10);
  static TextStyle get body => TextStyle(color: text, fontSize: 11);
  static TextStyle get heading => TextStyle(
    color: textMuted,
    fontSize: 9,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.6,
  );
}
