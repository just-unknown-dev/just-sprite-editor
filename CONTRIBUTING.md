# Contributing to Just Sprite Editor

Thank you for your interest in contributing to **Just Sprite Editor**. Bug fixes, features, tests and documentation are all welcome.

---

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Reporting Bugs and Suggesting Features](#reporting-bugs-and-suggesting-features)
- [Development Setup](#development-setup)
- [Working Against Unpublished Dependencies](#working-against-unpublished-dependencies)
- [How the Package Fits Together](#how-the-package-fits-together)
- [Running the Tests](#running-the-tests)
- [Coding Guidelines](#coding-guidelines)
- [Submitting a Pull Request](#submitting-a-pull-request)
- [Commit Message Convention](#commit-message-convention)
- [License](#license)

---

## Code of Conduct

This project follows our [Code of Conduct](CODE_OF_CONDUCT.md). By taking part you agree to its terms. Please report unacceptable behaviour to the maintainers.

---

## Reporting Bugs and Suggesting Features

Before opening an issue, search the [existing issues](https://github.com/just-unknown-dev/just-sprite-editor/issues) and check that the problem happens on the latest version.

A bug report should have:

- a clear title;
- steps to reproduce, and what you expected instead of what happened;
- the output of `flutter --version`, and your operating system;
- which editor it was, the Sprite Studio or the animator graph editor, and whether it was open inside `just_game_engine_editor` or as a widget (`SpriteStudio`, `AnimatorGraphEditor`) in your own app;
- the file that shows the problem: the `.jsprite` or `.animator.json`, or the `.png`, `.ase` or `.aseprite` you imported. For an export bug, also the `.png` and `.json` the studio wrote beside the project;
- for a drawing bug, the tool and its options (brush size, pixel-perfect, symmetry, filled shapes, contiguous fill), and whether a selection was active;
- for a visual bug, a screenshot and the zoom.

Some bugs belong in a neighbouring package:

- A sprite that plays wrongly in a game, although the exported `.json` is right, belongs in [just_game_engine](https://github.com/just-unknown-dev/just-game-engine/issues): its atlas loader, `SpriteAnimationComponent` and `AnimatorComponent`.
- An `.animator.json` that does not load, or loads wrongly, belongs in [just_game_engine_formats](https://github.com/just-unknown-dev/just-game-engine-formats/issues), which owns `AnimatorGraph` and its format.
- Data that `just_deflate` packs or unpacks wrongly on its own belongs in [just_deflate](https://github.com/just-unknown-dev/just-deflate/issues).
- A bug in the engine editor around the workspaces, such as their dialog, the play toolbar or the Assets dock, belongs in `just_game_engine_editor`.

For a feature, open an issue labelled **`enhancement`** that describes the problem it solves and how it should behave. The package's scope is drawing and animating pixel-art sprites for `just_game_engine`: the `.jsprite` project, the sheet and atlas export, imports (PNG, sheets, Aseprite), GIF export, the animator graph editor, and the module for `just_game_engine_editor`. Playing sprites in a game is `just_game_engine`'s job, and the `.animator.json` format is `just_game_engine_formats`'. The README's *Not here yet* list names features we know are missing. A change to the `.jsprite` format or to what the export writes affects saved sprites and the games that load them, so open the issue first and agree the approach before you write it.

---

## Development Setup

| Tool | Minimum version |
|------|-----------------|
| Dart | 3.11.0 |
| Flutter | A stable release that ships Dart 3.11.0 or later |

Those are this package's own limits. Its dependencies ask for more: `just_game_engine` needs Flutter 3.44.0 or later, and `just_inputs`, which the engine depends on, needs Dart 3.12.0 or later.

There is no app to run here: you work on the package and its tests. To try a change in the engine editor, add the package to a game's `dev_dependencies` with a `path:` to your clone, and register `SpriteStudioModule()` as the [README](README.md) shows. `SpriteStudio` and `AnimatorGraphEditor` are ordinary widgets too, and run without the engine editor.

```bash
git clone https://github.com/just-unknown-dev/just-sprite-editor.git just_sprite_editor
cd just_sprite_editor
flutter pub get
flutter test
```

If you're working from the Just engine monorepo, run every command from `packages/just_sprite_editor`.

---

## Working Against Unpublished Dependencies

The package depends on four `just_*` packages from the engine: `just_game_engine`, `just_game_engine_editor`, `just_game_engine_formats` and `just_deflate`. When a change needs an unreleased version of one, or `flutter pub get` cannot find a version, check it out next to this repository and point this package at it with a `pubspec_overrides.yaml` in the repository root. The paths below use the package names as folder names, as the monorepo does:

```yaml
# pubspec_overrides.yaml: local only, keep it out of your pull request.
dependency_overrides:
  just_game_engine:
    path: ../just_game_engine
  just_game_engine_editor:
    path: ../just_game_engine_editor
  just_game_engine_formats:
    path: ../just_game_engine_formats
  just_deflate:
    path: ../just_deflate
```

If one of their own dependencies is unpublished too (`just_game_engine` depends on `just_inputs`, `just_physics_engine`, `just_audio_engine`, `just_tiled` and others), add an entry for it the same way. Then run `flutter pub get`. Delete the file (or the entry) and run `flutter pub get` again to go back to the published versions.

Do not change `pubspec.yaml` to a path dependency: the Asset Store refuses a package that depends on anything by path or git. If your pull request needs a version that is not published yet, say so in the pull request: this package can only be released after it.

No other `just_*` package depends on this one. Games add it as a dev dependency, because none of it may ship (the platformer template does), and the Asset Store registers its module from `just_store.json`. The platformer template's tools also draw its sample sprites with `package:just_sprite_editor/document.dart`, so if you change the document core's public API, say so in the pull request.

---

## How the Package Fits Together

| Path | Contents |
|------|----------|
| `lib/document.dart` | The document core library: no widgets and no `dart:io` |
| `lib/src/document/` | `SpriteDocument` (layers, frames, cels, tags, palette), `DocumentEditor` and its commands (undo), `PixelBuffer` and `Argb`, `Raster` and `SelectionMask` (drawing), `Palettes` |
| `lib/src/document/io/` | `JspriteCodec`, `SheetExporter`, `SheetImporter`, `SheetExportOptions`, `PngEncoder`, `GifEncoder` and `AsepriteImporter` |
| `lib/src/studio/` | The Sprite Studio: `SpriteStudio`, `SpriteStudioSession`, `StudioCanvas`, the tools (`PixelTool`, `PixelTools`, `StudioActions`), the panels, `TimelinePanel`, `SpriteLibrary` and `StudioTheme` |
| `lib/src/studio/animator/` | `AnimatorGraphEditor` and `AnimatorGraphSession` |
| `lib/just_sprite_editor.dart` | The core, plus the studio's and the animator's widgets |
| `lib/editor.dart` | `SpriteStudioModule`: both editors as workspaces of `just_game_engine_editor`, the Assets dock actions, the toolbar brush and two prefabs |
| `just_store.json` | The Asset Store manifest: an `editor-extension` whose module is `SpriteStudioModule`, with `editorOnlyLibraries: ["*"]`, so none of it may reach a release build |
| `test/` | The tests |

A few rules hold the package together. Keep them:

- **The document core is plain Dart.** Nothing under `lib/src/document/` imports Flutter, `dart:ui` or `dart:io`, so the core runs on the web and in scripts. Compression comes from `just_deflate`. No test checks this, so check your imports.
- **Every edit the studio makes goes through `DocumentEditor`.** Pixels are drawn in a `CelStroke` from `beginStroke`, which becomes one `CelPatchCommand` that keeps only the rectangle it touched. Everything else (layers, frames, tags, palette, canvas size) goes through `structural`, as one `StructureCommand`. One stroke or one action is one undo step. A change made behind the editor's back cannot be undone, and leaves `isDirty` wrong.
- **Saved projects must keep loading.** A `.jsprite` carries `format: jsprite` and `version: 1` (`JspriteCodec.formatVersion`). `fromJson` reads every version up to that one and refuses a newer one. A new field is optional, with a default that keeps the old behaviour, and then needs no new version. Layer and tag flags at their default are left out (a visible layer has no `visible`). Never rename or reuse a key. Add a test in `test/document_core_test.dart` that reads JSON written before your change.
- **Pixels are `0xAARRGGBB` ints with straight alpha in memory (`Argb`), and RGBA bytes in a file**, each cel deflated and base64'd, so a file reads the same on any machine.
- **Layer and frame ids are stable.** They come from the document's counter, never from a position, and cels are keyed by layer id and frame id. A codec that rebuilds a document calls `reserveIds`, so new ids never collide with loaded ones.
- **What the studio exports is what the game loads.** Saving writes `name.jsprite`, `name.png` and `name.json` side by side, and keeps an imported sheet once as `name.original.png`. The atlas is Aseprite's JSON format. `meta.app` must contain "aseprite", because the engine picks its parser by that word. What that format cannot say (a clip that does not loop, frame events) goes under `meta.just`. A new key the game should read needs the engine's atlas loader to read it too.
- **The animator graph format belongs to `just_game_engine_formats`.** `AnimatorGraphSession` edits an immutable `AnimatorGraph` from `just_game_engine_formats` and saves it with `encode()`; the format's version rules live there. Renaming a state follows through its transitions and the entry; renaming a parameter follows through the conditions and blend trees that read it.
- **A tool is a class.** Each drawing tool is a `PixelTool`, with an entry in `PixelTools.of` and in the `StudioTool` enum (its label and shortcut letter). A tool's `cancel` leaves no trace.
- **The studio runs without the engine editor.** `SpriteStudio` and `AnimatorGraphEditor` take their paths and callbacks through their constructors. From `just_game_engine_editor` they use only `CommitTextField` and `PackageAssetPaths`. Workspaces, asset actions, the toolbar button and prefabs belong in `lib/editor.dart`, whose module also sets `StudioTheme.palette` from `EditorTheme.current` each time it builds a workspace.
- **The store's names are fixed.** `just_store.json` names `SpriteStudioModule` in `package:just_sprite_editor/editor.dart`, and the store's generated `store_modules.g.dart` calls `SpriteStudioModule()`. Keep the class, the library and a constructor that needs no arguments. Keep `version` in `just_store.json` equal to the one in `pubspec.yaml`: the Asset Store refuses a package whose versions differ.

---

## Running the Tests

Run every command from the repository root.

```bash
# The whole suite.
flutter test

# One file.
flutter test test/document_core_test.dart
```

**Checks worth knowing.** `test/export_loads_in_engine_test.dart` exports a sprite and loads it with the engine's own `SpriteAtlas.fromJson` and a real PNG decoder: if it fails, a game would not load the export. `test/document_core_test.dart` makes a thousand random edits and undoes them back to the start, byte for byte, and reads a project whose cels were packed by `dart:io`'s zlib, as they were before the move to `just_deflate`. `test/aseprite_gif_test.dart` builds its `.aseprite` fixtures chunk by chunk from the published format, and reads the GIFs back with Flutter's own decoder.

**Writing tests.** Test the core without widgets, in `test/document_core_test.dart`. Drive tools through a `SpriteStudioSession`, as `test/studio_session_test.dart` does, and keep widget tests for what needs the screen. The studio's widget tests set `tester.view.physicalSize` to 1400 × 900 at a device pixel ratio of 1. Tests that save write under `Directory.systemTemp`, never in the repository. File work and image decoding go inside `tester.runAsync`. For desktop behaviour, run the test as Windows, as `test/studio_fields_test.dart` does with `TargetPlatformVariant.only(TargetPlatform.windows)`.

---

## Coding Guidelines

- **Formatting.** Code is formatted with `dart format`. Some files are not formatted yet, so format the files you change, and only those:

  ```bash
  dart format <the files you changed>
  ```

- **Analysis.** `flutter analyze` must report no issues at all: no errors, warnings or infos. The rules are in `analysis_options.yaml`: `flutter_lints`.
- **Design time only.** Nothing here ships in a game. Only the document core builds for the web; the studio and the module use `dart:io` and `file_selector`.
- **Look.** Draw the studio's panels, fields and text in `StudioTheme`'s colours and styles, so it matches the host's palette and accent. The canvas's fixed colours (checkerboard, pixel grid, onion skins) live in `StudioTheme` too. Use `CommitTextField` for typed values: it keeps the value on Enter, Tab or a click elsewhere, and Esc puts back what was there.
- **Shortcuts** follow Aseprite's where it has one, as the tool letters do.
- **Documentation.** Give every public API you add a `///` doc comment. Describe user-visible changes in [CHANGELOG.md](CHANGELOG.md), and update [README.md](README.md) if the public API, the shortcuts or the saved files change.
- **Tests.** Add or update tests for any behaviour you change. A bug fix comes with a test that fails without it.
- **Dependencies.** Do not add a dependency without discussing it in an issue first.
- **Structure.** Match the existing folders under `lib/src/`. Export the core's API through `lib/document.dart` and the widgets through `lib/just_sprite_editor.dart`. Only the module belongs in `lib/editor.dart`.

---

## Submitting a Pull Request

1. Create a topic branch from `main`:
   ```bash
   git checkout -b fix/tag-colour-on-frame-move
   ```
2. Make your change, following the [Coding Guidelines](#coding-guidelines).
3. Check that everything passes:
   ```bash
   dart format <the files you changed>
   flutter analyze
   flutter test
   ```
4. Commit with a [conventional commit message](#commit-message-convention).
5. Push to your fork and open a pull request against `main`. Say what changed and why, and list any unpublished `just_*` version it needs. For a change you can see, add before and after screenshots.
6. Answer review feedback.

Small pull requests are easier to review.

---

## Commit Message Convention

We use [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <short summary>
```

| Type | When to use |
|------|-------------|
| `feat` | New feature |
| `fix` | Bug fix |
| `docs` | Documentation only |
| `refactor` | Code change that neither fixes a bug nor adds a feature |
| `perf` | Performance improvement |
| `test` | Adding or updating tests |
| `chore` | Build process, tooling, dependencies |

Use the area as the scope: `document`, `io` (the files read and written), `studio`, `tools`, `timeline`, `animator` or `module`. Mark a change that breaks the public API or the `.jsprite` format with `!` and a `BREAKING CHANGE:` footer.

**Examples:**
```
fix(timeline): keep a tag's colour when its frames are moved
feat(io): import Aseprite group layers as separate layers
docs(contributing): explain the .jsprite format rules
```

---

## License

By contributing to Just Sprite Editor you agree that your contributions will be licensed under the [BSD-3-Clause License](LICENSE).
