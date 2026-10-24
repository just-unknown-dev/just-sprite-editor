/// A pixel-art sprite editor and animator.
///
/// This library is the document core and the studio's widgets — design
/// time only, like every library of this package: the widgets read and
/// write project files with `dart:io`, use `file_selector` for the Open
/// dialog and `just_editor_core` for keys and fields, and the store keeps
/// the whole package out of a game's release build. A game needs nothing
/// from here: the engine plays what the studio saves. The module that
/// plugs the studio into `just_game_engine_editor` is
/// `package:just_sprite_editor/editor.dart`.
library;

export 'document.dart';
export 'src/studio/animator/animator_editor.dart';
export 'src/studio/animator/animator_session.dart';
export 'src/studio/sprite_studio.dart';
export 'src/studio/studio_canvas.dart'
    show imageFromPixels, pixelsFromImageBytes;
export 'src/studio/studio_session.dart';
export 'src/studio/studio_tools.dart';
