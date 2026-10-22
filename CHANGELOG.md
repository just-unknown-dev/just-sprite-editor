# Changelog

## 0.1.0 (unreleased)

- **Builds on `just_editor_core`**, the editor's module contract, instead of depending on `just_game_engine_editor`: the module's code needs nothing else of the editor.

- The animator graph editor edits animator graph format 2: a transition's **Blend (s)** (how long a 3-D model crossfades; a sprite always cuts), and a state's **blend tree**: one or two number parameters, and its motions (a clip each, at a threshold or a point). A sprite plays the heaviest motion. Renaming a parameter renames it in blend trees too.
- The animator's clip source ("Clips from") can be a 3-D model (`.glb` or `.gltf`) as well as an atlas: its animations are the clips offered, named as the game names them.

- **Typed values are kept when the field is left** — Enter, Tab, or a click anywhere else — in the frame duration, the hex colour and every animator field (parameters, conditions, the atlas path), as everywhere in the editor. They used to be kept on Enter alone, leaving a typed value on screen and the sprite as it was. Esc puts back what was there; a duration that is not a whole number above 0, or text that is not a colour, does too. They are `CommitTextField`s from the editor's kit.

- Compression comes from `just_deflate` instead of `dart:io`, for .jsprite cels, PNG pixels and Aseprite cels. The document core (`package:just_sprite_editor/document.dart`) no longer imports `dart:io`, so it runs on the web too. `Crc32.of` is now `just_deflate`'s `crc32`. Saved files read as before. Saved again, their cels are the same pixels in slightly smaller bytes.
- A compressed cel that is damaged, or unpacks to more than its size, is refused with "A cel in this file/sprite is damaged." rather than zlib's own message.
- The studio's and the animator's headers now match the engine editor's workspace header (`StudioHeader`, 36 px). From the left: the title, the file name, and a dot while there is unsaved work, which replaces the "•" in the title. Then Save, Undo and Redo, a divider, and the tool's own buttons. Full screen and close are on the right.
- The animator's header shows the full-screen button. It was passed the button's callback before, but never showed it.
- `SpriteStudio` and `AnimatorGraphEditor` take `setCloseGuard`. With it, the editor asks about unsaved work before it opens another workspace over them. `SpriteStudioModule` passes it.
- `fileName` on `SpriteStudioSession` and `AnimatorGraphSession`.
- 83 tests.
- The animator graph editor's state panel has a **Timeline** field: a `.timeline.json` the entity's Timeline Player plays on entering the state.
- Removed the `TimelineEventSink` the module offered the editor's old Timeline dock; that seam is gone. Clip events are edited on the tag, here.

- **Document core** (`package:just_sprite_editor/document.dart`, no widgets): `SpriteDocument` (layers, frames, canvas-sized cels, tags with direction / loop / events, palette), `DocumentEditor` (undo as dirty-rectangle cel patches and structure snapshots; one stroke is one step; saved-point tracking), `Raster` (line, pixel-perfect, brushes, rectangle, ellipse, scanline fill, symmetry, replace colour) and `SelectionMask`.
- **Files**: `JspriteCodec` (the `.jsprite` project), `SheetExporter` (PNG + Aseprite-format JSON with `meta.just` for clip loop flags and frame events — what `just_game_engine`'s atlas loader reads), `SheetImporter` (an image, or a sheet cut by grid), `PngEncoder`, and `Palettes` (presets; `.gpl`, JASC `.pal` and `.hex` parsing).
- **The studio** (`SpriteStudio`): a zoomable canvas with checkerboard, pixel grid, onion skins, selection outline, symmetry axes and brush preview; pencil, eraser, fill, colour picker, line, rectangle, ellipse, rectangular select and move (`PixelTool`, one class each), with brush size, pixel-perfect strokes, mirror drawing, filled shapes and contiguous fill; flip / rotate / delete / replace colour / crop / canvas size / slice into frames; an HSV + hex colour panel with the sprite's palette and presets; layers (visibility, lock, opacity, order, duplicate, merge down); a layers × frames timeline with per-frame duration, tags (direction, loop, events), playback per tag and onion skin; Aseprite-style shortcuts; undo/redo; an unsaved-changes prompt. Saving writes the project and re-exports the sheet and atlas beside it, keeping an imported original as `*.original.png`.
- **The animator graph editor** (`AnimatorGraphEditor`): states as draggable nodes, transitions as arrows (click to select, a node's arrow button to draw one), Entry and Any State, an inspector for states (clip, speed, loop) and transitions (conditions, exit time, priority), parameters with a binding dropdown, one state per atlas clip in a click, validation warnings, undo, and the live state of a running game lit on the graph.
- **`SpriteStudioModule`** (`package:just_sprite_editor/editor.dart`): both editors as `just_game_engine_editor` workspaces, asset actions, a toolbar button and two prefabs.
- **In and out**: `AsepriteImporter` (`.ase` / `.aseprite`: layers, raw / compressed / linked cels, durations, tags, palette; RGBA, greyscale and indexed), `GifEncoder` (global palette, transparency, per-frame delay, LZW), and sheet export options (layout, padding, trim, scale) kept in the project.
- A full-screen button beside the close button in both editors, for when the dialog over the level is not room enough.
- `SpriteStudioModule.timelineEventSinks`: the editor's Timeline can add and remove a sprite clip's frame events; they are written into the tag in the `.jsprite`, and the sheet and atlas are exported again.
