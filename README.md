# Just Sprite Editor

A pixel-art sprite editor and animator for `just_game_engine`, in the spirit of Aseprite: layers, frames, tags, onion skin — plus a node graph for the animation state machine that decides which clip plays. It opens inside `just_game_engine_editor` as a large dialog over the level (full screen is a button away), and what it saves is plain data the engine loads. None of it ships in your game.

It is made for pixel art: up to about 512 × 512 the canvas keeps up with the pen. A canvas can be as large as 2048 × 2048, but past 1024 or so the picture falls behind the stroke — draw small and use the export's 2–4× scale instead.

## What it saves

Saving `assets/sprites/hero.jsprite` writes three files side by side:

| File | What it is | Who reads it |
|---|---|---|
| `hero.jsprite` | The editable project: layers, cels, tags, palette, export options | The studio |
| `hero.png` | The sprite sheet | The game |
| `hero.json` | The atlas: where each frame is, how long it shows, the clips | The game |

The atlas is Aseprite's JSON export format, so anything that reads that reads this. What that format cannot say — a clip that plays once, frame events — is under `meta.just`. An animator graph is a fourth file, `hero.animator.json`.

Each file is written whole or not at all, so a save that fails half-way leaves the old one. A new sprite is offered a name nothing else has, and the studio asks before it writes over another sprite, or over an atlas it did not write itself.

## Adding it to the editor

Installed from the Asset Store, it is registered for you: the store adds it to the project as a dev dependency and lists `SpriteStudioModule` in the generated `lib/editor/store_modules.g.dart`. In a project without the store, hand it to the editor yourself:

```dart
// lib/main_editor.dart — never lib/main.dart
import 'package:just_sprite_editor/editor.dart';

final plugin = await JustGameEditorPlugin.register(
  engine: engine,
  modules: [SpriteStudioModule()],
);
```

Either way, the game needs the sheets and atlases as assets:

```yaml
# pubspec.yaml
flutter:
  assets:
    - assets/sprites/
```

You get a brush button on the play toolbar, **Edit in Sprite Studio** on images in the Assets dock (double-click works too), **New sprite** and **New animator graph** on the sprites folder, and two prefabs in the Level Designer: *Animated sprite* and *Animated character*.

## Showing a sprite in the game

```dart
registerSpriteSystems(world); // once, at boot

world.createEntityWithComponents([
  TransformComponent(position: Vector3(100, 200, 0)),
  SpriteAnimationComponent(atlasPath: 'assets/sprites/hero.json', clip: 'idle'),
]);
```

`clip` is a tag from the studio's timeline. Change it with `switchClip('run')`, or let a graph do it:

```dart
AnimatorComponent(
  graphPath: 'assets/sprites/hero.animator.json',
  faceVelocity: true, // flip the sprite to face where it is going
),
```

## The animator graph

States play a clip each. Transitions are arrows, taken when all their conditions hold; **Any State** leads somewhere from wherever the machine is; **exit time** waits for the clip before leaving. Conditions test parameters — and a parameter can be *bound*, so it fills itself in from the entity:

| Binding | From |
|---|---|
| `velocityX`, `velocityY`, `speed`, `speedX`, `speedY` | `VelocityComponent` |
| `health`, `healthFraction`, `alive` | `HealthComponent` |
| `grounded`, `rising`, `falling`, `justLanded`, `invulnerable` | `just_platformer_kit` |

Anything else your game sets itself: `animator.setTrigger('attack')`. Your own bindings are one line: `engine.context.animatorBindings.register('ammo', (e) => …)`. While the game plays in the editor, the state an entity is in is lit on the graph.

A state can also **blend by a parameter**: a blend tree over one or two number parameters, each motion a clip at a threshold (or a point). A 3-D model crossfades its motions; a sprite plays the heaviest one. A transition's **Blend (s)** is how long a 3-D model crossfades into the next state; a sprite always cuts. The clips offered come from the graph's **Clips from**: an atlas (`hero.json`) or a 3-D model (`hero.glb`, `hero.gltf`).

## Drawing

On a Mac, **Cmd** stands in for **Ctrl** below, and the delete key (Backspace) clears.

| | |
|---|---|
| **B** pencil · **E** eraser · **G** fill · **I** pick colour | **L** line · **U** rectangle · **O** ellipse · **M** select · **V** move |
| Right button | draws with the secondary colour |
| **Alt** | any tool picks a colour while held |
| **X** swap colours · **[ ]** brush size | **Space**/middle-drag pan · wheel zoom · trackpad pan and pinch · **+ −** |
| **, .** previous / next frame · **Enter** play | **Alt+N** duplicate frame |
| **Ctrl+Z / Y** undo / redo · **Ctrl+S** save | **Ctrl+A / D** select all / none · **Del** clear · **Esc** cancel |

Pixel-perfect strokes, mirror drawing on either axis, filled shapes and contiguous fill are in the bar above the canvas. A selection fences every tool in. Layers have visibility, lock, opacity, order, duplicate and merge down. The timeline shows layers × frames; a tag is a bar over its frames — click it for direction (forward, reverse, ping-pong), whether it loops, and events. Onion skin shows up to three frames either side.

## Bringing art in, sending it out

- **PNG** — opens as one frame, the same size as the image: saved untouched, the sheet is the image again, so a tile map or a background that uses it still lines up. *Slice into frames* cuts a sheet by grid, as one step undo takes back. An image over 2048 either way (up to 8192) opens to be sliced, and is saved once it fits. The first save keeps what was there as `name.original.png`, and an atlas some other tool wrote as `name.original.json`.
- **`.aseprite` / `.ase`** — layers, cels (including linked ones), frame durations, tags and palette. Groups are flattened, indexed and greyscale become RGBA, tilemap layers and blend modes are dropped; the studio says which of those happened. A damaged file is refused with a message, never half-read.
- **GIF** — the tag being played (or every frame), scaled up, beside the sprite.
- **Sheet options** — grid / row / column, padding, trim, 1–4× scale; kept in the project. A sheet larger than 16384 either way is not written (no GPU loads it); the project still is, and the studio says why.
- **Palettes** — DB32, Endesga 32, PICO-8, Sweetie 16, DB16 and Game Boy built in; `Palettes.parse` reads `.gpl`, JASC `.pal` and `.hex`.

## Using the parts on their own

`package:just_sprite_editor/document.dart` is the core with no widgets in it: `SpriteDocument`, `DocumentEditor` (undo), `Raster`, `JspriteCodec`, `SheetExporter`, `AsepriteImporter`, `GifEncoder`, `PngEncoder`. It is pure Dart, with no `dart:io`, and it is what `tool/make_player_sprite.dart` in the platformer template uses to draw its sample player from a script. `SpriteStudio` and `AnimatorGraphEditor` are ordinary widgets and run without the game editor (they use `just_editor_core`'s keys and fields).

Every library of this package is design-time only, the document core included: the store keeps all of them out of a game's code, and the game needs none of them — the engine plays what the studio saves.

## Not here yet

Lasso and magic-wand selection, layer blend modes, gradients and dithering inks, tiled mode, custom brushes, reference layers, a true indexed colour mode, and animator layers.
