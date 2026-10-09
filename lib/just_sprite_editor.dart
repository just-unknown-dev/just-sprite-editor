/// A pixel-art sprite editor and animator.
///
/// This library is the document core and the studio's widgets. The module
/// that plugs the studio into `just_game_engine_editor` is
/// `package:just_sprite_editor/editor.dart` — a game never imports that.
library;

export 'document.dart';
export 'src/studio/animator/animator_editor.dart';
export 'src/studio/animator/animator_session.dart';
export 'src/studio/sprite_studio.dart';
export 'src/studio/studio_canvas.dart'
    show imageFromPixels, pixelsFromImageBytes;
export 'src/studio/studio_session.dart';
export 'src/studio/studio_tools.dart';
