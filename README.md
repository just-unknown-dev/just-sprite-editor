# Just Sprite Editor

A pixel-art sprite editor and animator for `just_game_engine`, in the spirit of
Aseprite: layers, frames, tags, onion skin — plus a node graph for the
animation state machine that decides which clip plays. It opens inside
`just_game_engine_editor` as a large dialog over the level (full screen is a
button away), and what it saves is
plain data the engine loads. None of it ships in your game.

## What it saves

Saving `assets/sprites/hero.jsprite` writes three files side by side:

| File | What it is | Who reads it |
|---|---|---|
| `hero.jsprite` | The editable project: layers, cels, tags, palette, export options | The studio |
| `hero.png` | The sprite sheet | The game |
| `hero.json` | The atlas: where each frame is, how long it shows, the clips | The game |

The atlas is Aseprite's JSON export format, so anything that reads that reads
this. What that format cannot say — a clip that plays once, frame events — is
under `meta.just`. An animator graph is a fourth file, `hero.animator.json`.

## Adding it to the editor

```dart
// lib/main_editor.dart — never lib/main.dart
import 'package:just_sprite_editor/editor.dart';

final plugin = await JustGameEditorPlugin.register(
  engine: engine,
  modules: [SpriteStudioModule()],
);
```

```yaml
# pubspec.yaml
flutter:
  assets:
    - assets/sprites/
```

You get a brush button on the play toolbar, **Edit in Sprite Studio** on
images in the Assets dock (double-click works too), **New sprite** and **New
animator graph** on the sprites folder, and two prefabs in the Level Designer:
*Animated sprite* and *Animated character*.

## Showing a sprite in the game

```dart
registerSpriteSystems(world); // once, at boot

world.createEntityWithComponents([
  TransformComponent(position: Vector3(100, 200, 0)),
  SpriteAnimationComponent(atlasPath: 'assets/sprites/hero.json', clip: 'idle'),
]);
```

`clip` is a tag from the studio's timeline. Change it with
`switchClip('run')`, or let a graph do it:

```dart
AnimatorComponent(
  graphPath: 'assets/sprites/hero.animator.json',
  faceVelocity: true, // flip the sprite to face where it is going
),
```

## The animator graph

States play a clip each. Transitions are arrows, taken when all their
conditions hold; **Any State** leads somewhere from wherever the machine is;
**exit time** waits for the clip before leaving. Conditions test parameters —
and a parameter can be *bound*, so it fills itself in from the entity:

| Binding | From |
|---|---|
| `velocityX`, `velocityY`, `speed`, `speedX`, `speedY` | `VelocityComponent` |
| `health`, `healthFraction`, `alive` | `HealthComponent` |
| `grounded`, `rising`, `falling`, `justLanded`, `invulnerable` | `just_platformer_kit` |

Anything else your game sets itself: `animator.setTrigger('attack')`. Your own
bindings are one line: `engine.context.animatorBindings.register('ammo', (e) => …)`. While
the game plays in the editor, the state an entity is in is lit on the graph.

## Drawing

| | |
|---|---|
| **B** pencil · **E** eraser · **G** fill · **I** pick colour | **L** line · **U** rectangle · **O** ellipse · **M** select · **V** move |
| Right button | draws with the secondary colour |
| **Alt** | any tool picks a colour while held |
| **X** swap colours · **[ ]** brush size | **Space**/middle-drag pan · wheel zoom · **+ −** |
| **, .** previous / next frame · **Enter** play | **Alt+N** duplicate frame |
| **Ctrl+Z / Y** undo / redo · **Ctrl+S** save | **Ctrl+A / D** select all / none · **Del** clear · **Esc** cancel |

Pixel-perfect strokes, mirror drawing on either axis, filled shapes and
contiguous fill are in the bar above the canvas. A selection fences every
tool in. Layers have visibility, lock, opacity, order, duplicate and merge
down. The timeline shows layers × frames; a tag is a bar over its frames —
click it for direction (forward, reverse, ping-pong), whether it loops, and
events. Onion skin shows up to three frames either side.

## Bringing art in, sending it out

- **PNG** — opens as one frame. *Slice into frames* cuts a sheet by grid. The
  first save keeps the file you imported as `name.original.png`.
- **`.aseprite` / `.ase`** — layers, cels (including linked ones), frame
  durations, tags and palette. Groups are flattened, indexed and greyscale
  become RGBA, tilemap layers and blend modes are dropped; the studio says
  which of those happened.
- **GIF** — the tag being played (or every frame), scaled up, beside the
  sprite.
- **Sheet options** — grid / row / column, padding, trim, 1–4× scale; kept in
  the project.
- **Palettes** — DB32, Endesga 32, PICO-8, Sweetie 16, DB16 and Game Boy
  built in; `Palettes.parse` reads `.gpl`, JASC `.pal` and `.hex`.

## Using the parts on their own

`package:just_sprite_editor/document.dart` is the core with no widgets in it:
`SpriteDocument`, `DocumentEditor` (undo), `Raster`, `JspriteCodec`,
`SheetExporter`, `AsepriteImporter`, `GifEncoder`, `PngEncoder`. It is what
`tool/make_player_sprite.dart` in the platformer template uses to draw its
sample player from a script. `SpriteStudio` and `AnimatorGraphEditor` are
ordinary widgets and run without the game editor.

## Not here yet

Lasso and magic-wand selection, layer blend modes, gradients and dithering
inks, tiled mode, custom brushes, reference layers, a true indexed colour
mode, animator blend trees and layers.
