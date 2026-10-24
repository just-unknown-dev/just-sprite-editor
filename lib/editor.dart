/// Plugs the Sprite Studio into `just_game_engine_editor`.
///
/// Design-time only, as is every library of this package: a game imports
/// none of them — the engine plays the sheets, atlases and animator graphs
/// the studio saves — so nothing of the editor reaches a release build.
/// Installed from the Asset Store, the module registers itself.
library;

import 'package:flutter/material.dart';
import 'package:just_game_engine/just_game_engine.dart' as jge;
import 'package:just_editor_core/just_editor_core.dart';

import 'just_sprite_editor.dart';
import 'src/studio/studio_theme.dart';

/// Adds the Sprite Studio to the editor: a workspace that opens images and
/// `.jsprite` projects, another for `.animator.json` state machines, "Edit"
/// and "New sprite" in the Assets dock, a toolbar button, and the
/// "Animated sprite" and "Animated character" prefabs for the Level
/// Designer.
///
/// Installed from the Asset Store it is registered for you (through the
/// generated `lib/editor/store_modules.g.dart`). In a project without the
/// store, hand it to the editor yourself:
///
/// ```dart
/// JustGameEditorPlugin.register(
///   engine: engine,
///   modules: [PlatformerModule(), SpriteStudioModule()],
/// );
/// ```
class SpriteStudioModule extends EditorModule {
  SpriteStudioModule({this.spriteFolder = 'assets/sprites'});

  /// Where new sprites are saved.
  final String spriteFolder;

  static const String workspaceId = 'sprite_studio';
  static const String animatorWorkspaceId = 'animator_graph';

  /// The state some entity in [scope]'s world is in for the graph at
  /// [graphPath]: the selected entity if it runs that graph, else the first
  /// that does.
  static String? _liveState(EditorScope scope, String graphPath) {
    String? of(jge.Entity? e) {
      final animator = e?.getComponent<jge.AnimatorComponent>();
      if (animator == null || animator.graphPath.trim() != graphPath) {
        return null;
      }
      return animator.currentState.isEmpty ? null : animator.currentState;
    }

    final selected = of(scope.sceneState.selectedEntity.value);
    if (selected != null) return selected;
    for (final e in scope.world.query([jge.AnimatorComponent])) {
      final state = of(e);
      if (state != null) return state;
    }
    return null;
  }

  @override
  String get id => 'just.sprite_studio';

  @override
  String get name => 'Sprite Studio';

  @override
  List<WorkspaceDefinition> get workspaces => [
    WorkspaceDefinition(
      id: workspaceId,
      label: 'Sprite Studio',
      icon: Icons.brush,
      fileExtensions: const ['jsprite', 'png', 'aseprite', 'ase'],
      build: (context, workspace) => _matchingTheEditor(
        SpriteStudio(
          path: workspace.path,
          newSpriteFolder: spriteFolder,
          onClose: workspace.onClose,
          // The level shows the new sheet the moment it is saved.
          onSaved: (saved) => workspace.reloadAssets?.call(saved.atlasPath),
          fullScreen: workspace.fullScreen,
          onToggleFullScreen: workspace.onToggleFullScreen,
          setCloseGuard: workspace.setCloseGuard,
        ),
      ),
    ),
    WorkspaceDefinition(
      id: animatorWorkspaceId,
      label: 'Animator',
      icon: Icons.account_tree_outlined,
      order: 110,
      fileExtensions: const [AnimatorGraphSession.extension],
      build: (context, workspace) => _matchingTheEditor(
        AnimatorGraphEditor(
          path: workspace.path,
          newGraphFolder: spriteFolder,
          onClose: workspace.onClose,
          // Animators running this graph start over with the new one.
          onSaved: (path) => workspace.reloadAssets?.call(path),
          liveState: (path) => _liveState(workspace.scope, path),
          bindings: workspace.scope.context.animatorBindings,
          fullScreen: workspace.fullScreen,
          onToggleFullScreen: workspace.onToggleFullScreen,
          setCloseGuard: workspace.setCloseGuard,
        ),
      ),
    ),
  ];

  /// [child], drawn in the editor's palette: the studio's own colours come
  /// from it, set here every time the editor builds the workspace — which it
  /// does again when the user picks another accent.
  static Widget _matchingTheEditor(Widget child) {
    final t = EditorTheme.current;
    StudioTheme.palette = StudioPalette(
      background: t.dialogBg,
      panel: t.menuBg,
      panelRaised: t.panelRaised,
      field: t.surfaceDarker,
      border: t.borderStrong,
      workArea: t.panelBg,
      text: t.textPrimary,
      textMuted: t.textMuted,
      accent: t.primaryBright,
      selected: t.selectionBg,
      danger: t.error,
      warning: t.warning,
    );
    return child;
  }

  @override
  List<AssetAction> get assetActions => [
    AssetAction(
      id: 'sprite_studio.edit',
      label: 'Edit in Sprite Studio',
      icon: Icons.brush,
      appliesTo: (path, {required isDirectory}) {
        final lower = path.toLowerCase();
        return !isDirectory &&
            (lower.endsWith('.jsprite') ||
                lower.endsWith('.aseprite') ||
                lower.endsWith('.ase') ||
                (lower.endsWith('.png') && !lower.endsWith('.original.png')));
      },
      run: (scope, path) => scope.openWorkspace(workspaceId, path: path),
    ),
    AssetAction(
      id: 'sprite_studio.edit_animator',
      label: 'Edit animator graph',
      icon: Icons.account_tree_outlined,
      appliesTo: (path, {required isDirectory}) =>
          !isDirectory &&
          path.toLowerCase().endsWith('.${AnimatorGraphSession.extension}'),
      run: (scope, path) =>
          scope.openWorkspace(animatorWorkspaceId, path: path),
    ),
    AssetAction(
      id: 'sprite_studio.new_animator',
      label: 'New animator graph',
      icon: Icons.add_link,
      order: 120,
      appliesTo: (path, {required isDirectory}) =>
          isDirectory && path.startsWith(spriteFolder),
      run: (scope, path) => scope.openWorkspace(animatorWorkspaceId),
    ),
    AssetAction(
      id: 'sprite_studio.new',
      label: 'New sprite',
      icon: Icons.add_photo_alternate_outlined,
      order: 110,
      appliesTo: (path, {required isDirectory}) =>
          isDirectory && (path == 'assets' || path.startsWith(spriteFolder)),
      run: (scope, path) => scope.openWorkspace(workspaceId),
    ),
  ];

  @override
  List<ToolbarButton> get toolbarButtons => [
    ToolbarButton(
      id: 'sprite_studio.open',
      icon: Icons.brush,
      tooltip: 'Sprite Studio: draw and animate sprites',
      onPressed: (scope) => scope.openWorkspace(workspaceId),
    ),
  ];

  @override
  List<PrefabCategory> get prefabCategories => const [
    PrefabCategory(label: 'Sprites', order: 60),
  ];

  @override
  List<PrefabDefinition> get prefabs => [
    PrefabDefinition(
      id: 'sprite_studio.animated_sprite',
      name: 'Animated sprite',
      category: 'Sprites',
      icon: Icons.movie_filter_outlined,
      color: const Color(0xFF7DE6B1),
      placement: PrefabPlacement.point,
      defaultSize: const Size(32, 32),
      description:
          'Plays a clip from a sprite atlas. Pick the atlas JSON the studio '
          'saved beside your sprite, then a clip.',
      namePrefix: 'Sprite',
      build: (position, size) => [
        jge.TransformComponent(
          position: jge.Vector3(position.dx, position.dy, 0),
        ),
        jge.SpriteAnimationComponent(),
      ],
    ),
    PrefabDefinition(
      id: 'sprite_studio.animated_character',
      name: 'Animated character',
      category: 'Sprites',
      icon: Icons.directions_run,
      color: const Color(0xFFFFCA28),
      placement: PrefabPlacement.point,
      defaultSize: const Size(32, 32),
      description:
          'A sprite whose clip is chosen by an animator graph: states, '
          'transitions and parameters.',
      namePrefix: 'Character',
      build: (position, size) => [
        jge.TransformComponent(
          position: jge.Vector3(position.dx, position.dy, 0),
        ),
        jge.SpriteAnimationComponent(),
        jge.AnimatorComponent(faceVelocity: true),
      ],
    ),
  ];
}
